# C-01 Follow-Up — Real %settle for the Generic Hull (Audit Fix 3)

Companion to `docs/AUDIT_REPORT.md` §2.C-01 remediation option 3.
The surgical Rust-only fix landed on `parametize-3` made the
hull's `/settle` honest about kernel rejection, but it did not
fix the deeper issue: `/settle` builds a `%register` poke, not a
`%settle` poke. The endpoint's name and its implementation are
mismatched. This doc captures the work to make them line up.

## 1. Why the mismatch exists

The settle kernel already implements `%settle` end-to-end at
`protocol/lib/settle-kernel.hoon:86-103`:

```
%settle
=/  parsed  (parse-payload payload.u.act)
?~  parsed  ...
=/  res  (validate-settlement-args u.parsed registered.state settled.state %mutate 'settle:')
?:  ?=(%.n -.res)  [~ state]
=/  args=settlement-payload  args.res
=/  result  (settle-note note.args mani.args expected-root.args)
=/  new-settled  (~(put in settled.state) id.note.args)
:_  state(settled new-settled)
^-  (list effect)
~[result]
```

The validate chain is real (`validate-settlement-args` runs
root-registered, expected-root, note-root, replay checks). The
`settle-note` arm computes the actual settlement result. What's
missing is the Rust side that constructs the `settlement-payload`
the kernel expects.

Today's `hull/src/api.rs:432-498` builds a `register_poke` instead:

```rust
let settle_poke = vesl_core::noun_builder::build_register_poke(st.hull_id, &root);
let effects = poke_kernel_with_timeout(&mut st.app, settle_poke, "settle").await?;
```

The variable name says settle, the helper says register. After the
surgical fix in commit `afa5d9c`, the endpoint at least returns
409 instead of lying, but it still doesn't do real settlement.

Note: **hull-llm's `/query` does build a real `%settle` poke** via
`noun_builder::build_settle_poke(&note, &manifest, &root)` at
`hull-llm/src/api.rs:755`. The generic hull is the laggard here,
not hull-llm. Use hull-llm's call site as the reference shape.

## 2. settlement-payload structure

From `protocol/sur/vesl.hoon` (verify exact shape during impl):

```
+$  settlement-payload
  $:  note=note
      mani=manifest
      expected-root=@
  ==
```

The kernel reads this via `parse-payload` (`kernel-arms.hoon:31-39`)
which cues the jammed atom and sieves to the `settlement-payload`
type.

`note` carries `id`, `hull`, `root`, `state`. `manifest` carries
the domain content the note attests to. `expected-root` is the
Merkle root the kernel will match against `registered.get(hull)`.

## 3. Rust work

### 3.1 Builder

Add to `crates/vesl-core/src/noun_builder.rs`:

```rust
pub fn build_settle_payload(
    note: &Note,
    manifest: &Manifest,
    expected_root: &Tip5Hash,
) -> NounSlab { ... }

pub fn build_settle_poke(
    note: &Note,
    manifest: &Manifest,
    expected_root: &Tip5Hash,
) -> NounSlab {
    // [%settle payload=<jammed settlement-payload>]
}
```

Mirror the shape hull-llm uses today. If hull-llm's
`build_settle_poke` already lives in `vesl_core::noun_builder`,
reuse it directly; otherwise lift it from `hull-llm/src/noun_builder.rs`
into vesl-core so both consumers share one definition.

### 3.2 Richer SettleRequest schema

The generic hull's `SettleRequest` today is essentially empty
(just an optional `note_id`). Real settlement needs:

```rust
#[derive(Deserialize)]
pub struct SettleRequest {
    /// Note being settled. Carries id, hull (defaults to st.hull_id),
    /// the Merkle root we're claiming, and the target state.
    pub note: NotePayload,
    /// Domain manifest the note attests to. Hull-generic, so the
    /// shape here is `Vec<u8>` (caller jams whatever their domain
    /// uses); hull-llm's RAG manifest is one example.
    pub manifest: Vec<u8>,
}
```

The generic hull does not know about RAG manifests / chunk
content / LLM output, so it can't construct a typed manifest.
Two options:

- **Pass-through.** Accept `manifest: Vec<u8>` as a pre-jammed
  noun, hash it through `hash_leaf` server-side to derive
  `expected_root`, and let the caller deal with what's in there.
  Aligns with the "generic hull is domain-blind" framing.
- **Typed at the SDK layer.** Define `vesl_core::Manifest` as
  the common shape, expose `from_kv_pairs` and `from_raw_bytes`
  builders, let domain hulls (hull-llm) wrap their content type
  before sending.

Recommended: **pass-through** for the generic hull. Domain hulls
that need typed manifests already wrap their own client; the
generic hull's contract is "I'll register and settle whatever
Merkle commitment you hand me."

### 3.3 Effect decoding

After the poke, pattern-match on the first effect tag. The
`settle-note` return shape (see `protocol/lib/rag-logic.hoon` or
the equivalent settle-graft path) emits something like
`[%settle-noted note=[id=@ hull=@ root=@ state=[%settled ~]]]`.
Decode that into the HTTP response.

If the kernel returns `[%settle-error msg=@t]` (parse failure
path), bubble up the error message — that's a 400, not a 409.

The surgical fix's current empty-effects → 409 stays as the
catch-all for `validate-settlement-args` rejections; the new tag
decoding adds richer cases on top.

### 3.4 Backwards compatibility

The current `/settle` re-pokes `%register` and returns
`SettleResponse { note_id, merkle_root, settled, effects_count }`.
Real settlement should keep the same response field names so
existing callers don't break, but the `settled` flag finally
means what it says — true iff the kernel emitted `%settle-noted`,
false iff the parse path emitted `%settle-error`. 409 returns
unchanged.

## 4. Tests

Extend `hull/tests/desync_regression.rs` with:

- `settle_with_valid_payload_succeeds_after_commit` — POST
  `/commit`, then POST `/settle` with a valid payload, assert
  200 + `settled: true`.
- `settle_with_replay_id_returns_409` — POST `/commit`, two
  POSTs to `/settle` with the same note_id, assert second is 409.
- `settle_with_unregistered_root_returns_409` — POST `/settle`
  before any `/commit`, assert 409 with the `%root-not-registered`
  cause surfaced.

The harness pattern is already in place from the surgical fix
commit `6e8187c`.

## 5. Sequencing relative to other follow-ups

Real `%settle` is independent of:

- Root rotation (`docs/AUDIT_C01_ROTATE_ROOT.md`) — a different
  kernel arm; can land in parallel.
- L-09 `%register-rejected` emission (covered in the rotate-root
  doc) — different effect path.

Recommended order: land L-09 first (smallest kernel diff), then
real `%settle` (unblocks `/settle` semantics), then rotate-root
(largest design surface). Each gets its own kernel JAM regen +
checksum commit per `CLAUDE.md` §3.

## 6. Out of scope

- Multi-hull-per-process (audit §L-08).
- The 6 sibling templates' `print_effects` helpers — they already
  display empty effects; the audit framing accepts that.

## 7. Links

- Audit report: `docs/AUDIT_REPORT.md`
- Companion rotate-root doc: `docs/AUDIT_C01_ROTATE_ROOT.md`
- Umbrella index: `docs/AUDIT_C01_FOLLOWUP.md`
- Settle kernel source: `protocol/lib/settle-kernel.hoon`
- Shared dispatch arms: `protocol/lib/kernel-arms.hoon`
- Reference Rust impl: `hull-llm/src/api.rs:617-783` (query_handler)
  and `hull-llm/src/noun_builder.rs` (build_settle_poke)
- Kernel JAM regen flow: `CLAUDE.md` §3
- Surgical fix commits on `parametize-3`: `git log --grep '§2.C-01'`
