# C-01 Follow-Up — Real %settle for the Generic Hull (Audit Fix 3)

Companion to `docs/AUDIT_REPORT.md` §2.C-01 remediation option 3.

**Status (updated post hull-lib-factor):** the core swap is
landed. vesl-nockup commit `877988f` on `hull-lib-factor`
replaced the legacy `build_register_poke` re-poke in
`vesl-nockup/crates/vesl-hull/src/api.rs` with a real
`build_settle_note_poke` against settle-graft's umbrella
`graft-payload`. Single-leaf hulls (the default hash-gate) now
register and settle end-to-end via `/commit` + `/settle`. What
remains is the **richer `SettleRequest` schema** so callers can
drive arbitrary notes against structured data, and the
**`%settle-error` msg cord decoding** so the API surfaces the
kernel's specific rejection reason. This doc tracks the
still-outstanding work.

## 1. Where the post-fix mismatch is

settle-graft already implements the umbrella cause end-to-end at
`protocol/lib/settle-graft.hoon` (`%settle-note` arm, lines
170-228). The validate chain runs root-registered, expected-root,
note-root, and replay checks; on accept it emits
`[%settle-noted note=[id=@ hull=@ root=@ state=[%settled ~]]]`,
and on any check failure it emits a typed `%settle-error msg=@t`.

The Rust side as of `877988f`:

```rust
// vesl-nockup/crates/vesl-hull/src/api.rs (settle_handler)
let leaf_bytes = st.fields.first().map(field_to_leaf_bytes).ok_or_else(...)?;
let note_id    = req.note_id.unwrap_or(st.note_counter + 1);
let settle_poke = vesl_core::build_settle_note_poke(note_id, st.hull_id, &root, &leaf_bytes);
let effects     = poke_kernel_with_timeout(&mut st.app, settle_poke, "settle-note").await?;
```

The remaining lies:

- `leaf_bytes` is hardcoded to `field[0]`. A caller can `POST
  /commit` an N-field array, but `/settle` will only ever attest
  to the first field. For the default single-leaf hash-gate, N>1
  commits gate-deny silently (kernel returns `%settle-error`); the
  generic hull never exposes a way to pick which leaf gets the
  note.
- `SettleRequest` carries only `note_id`. There's no
  request-side surface to set the hull (assumed `st.hull_id = 1`),
  the note's `state`, or to drive a structured `data` for a
  non-default gate (schnorr, manifest-verify, STARK).
- The `%settle-error` branch returns a hardcoded 409 with a
  generic hint string ("note already settled, root not
  registered, root mismatch, gate deny"). The actual `msg=@t`
  cord from the effect is dropped; callers can't distinguish
  these cases via HTTP without reading the kernel slog.

## 2. graft-payload structure

From `protocol/lib/settle-graft.hoon:95-99` (canonical) and its
mirror at `vesl-nockup/hoon/lib/settle-graft.hoon`:

```hoon
+$  graft-payload
  $:  note=[id=@ hull=@ root=@ state=[%pending ~]]
      data=*
      expected-root=@
  ==
```

- `note` is structured: replay protection on `id`, registration
  check on `hull`, root-mismatch check on `root`. `state` is
  always `[%pending ~]` on the way in; the kernel rewrites it to
  `[%settled ~]` on emit.
- `data=*` is opaque. Per the doc comment on `:91-92`: "the
  verification gate knows the shape. for RAG, this is a manifest.
  for other domains, anything." The default single-leaf hash gate
  hashes `data` as bytes and compares to `expected-root`.
  Catalog gates (schnorr, ed25519, membership, bounded, STARK)
  destructure `data` as a typed cell — see the per-gate
  convenience builders in
  `crates/vesl-core/src/graft_pokes/settle.rs:133-231`.
- `expected-root=@` is the Merkle root the kernel matches against
  `registered.get(hull)`.

The umbrella is genuinely domain-agnostic. The richer schema in
§3 is about exposing this umbrella's full surface over HTTP, not
about adding kernel-side complexity.

## 3. Rust work

### 3.1 Builder — LANDED

`build_settle_note_poke(note_id, hull, root, data: &[u8])` is
already in `crates/vesl-core/src/graft_pokes/settle.rs:59`,
with a closure-driven escape hatch at
`build_settle_note_poke_with_data` (:91) for gates whose `data`
slot is a structured cell. Per-gate convenience wrappers
(schnorr, ed25519, membership, bounded, manifest, STARK) live
alongside at :133-231. No new builder is required.

For the request-schema work in §3.2, the only addition that may
be useful is a `build_settle_note_poke_from_jammed_data` shape
that takes a pre-jammed `&[u8]` and threads it as a single atom —
useful when the HTTP body carries a fully-jammed `data` noun
constructed client-side.

### 3.2 Richer SettleRequest schema — OUTSTANDING

The generic hull's `SettleRequest` today is:

```rust
// vesl-nockup/crates/vesl-hull/src/api.rs
#[derive(Deserialize)]
pub struct SettleRequest {
    pub note_id: Option<u64>,
}
```

Real umbrella settlement needs:

```rust
#[derive(Deserialize)]
pub struct SettleRequest {
    /// The note's id (replay key) and target hull. `hull` defaults
    /// to `st.hull_id`; `id` defaults to the auto-incrementing
    /// counter.
    pub note_id: Option<u64>,
    pub hull:    Option<u64>,

    /// The data the note attests to. For the default single-leaf
    /// hash gate, this is the raw bytes that hash to
    /// `expected_root`. For catalog gates, this is the gate's
    /// structured payload pre-jammed by the caller. Defaults to
    /// `field[0]`'s leaf bytes when omitted (current behavior).
    #[serde(default, with = "hex")]
    pub data: Option<Vec<u8>>,
}
```

Two design questions to resolve before implementing:

- **Pass-through vs typed.** For domain hulls (LLM, registry,
  marketplaces), `data` is structured: a manifest cell, a
  signed payload, a STARK witness. The generic hull doesn't
  know the shape, so:
  - *Pass-through* (recommended): accept `data: Vec<u8>` as a
    pre-jammed noun. Caller is responsible for gate-correct
    shape. Aligns with the "generic hull is domain-blind"
    framing.
  - *Typed at the SDK layer*: define per-gate `SettleRequest`
    variants in `vesl-hull`'s lib surface, let domain hulls
    pick the right one. More work, more coupling.

- **Expected-root derivation.** The kernel takes
  `expected-root=@` as the third graft-payload field. The
  current code derives it from `tree.root()` (the locally-stored
  Merkle root). For multi-leaf commits where the caller wants to
  settle a specific leaf, `expected-root` is still `tree.root()`
  (the registered top-level), but `data` is a single leaf's
  bytes and the gate must reconstruct the proof. The hash-gate
  doesn't support this; users who want it install a multi-leaf
  gate per the template README's "Customizing" section.

Recommended scope for this remediation: **pass-through with
optional `data` byte field, `hull` and `note_id` optional**. Skip
the typed SDK layer; domain hulls wrap their own client.

### 3.3 Effect decoding — PARTIALLY LANDED

`877988f` dispatches on the first effect tag:

- `settle-noted` → 200.
- `settle-error` → 409 with a generic hint.
- other → 502.

What's outstanding: extract the `msg=@t` cord from the
`%settle-error` effect and surface it in the 409 body. The cord
is one of seven known reasons emitted by the
`%settle-note` arm (`settle-graft.hoon:181-218`):

| Cord                                                  | Mapped status |
|---|---|
| `settle-graft: malformed payload`                     | 400 (caller's data is uncue-able / wrong sieve) |
| `settle-graft: root not registered`                   | 409 (need `/commit` first) |
| `settle-graft: root mismatch`                         | 409 (caller's `expected-root` ≠ registered) |
| `settle-graft: note root does not match expected root`| 409 (note header `root` ≠ payload `expected-root`) |
| `settle-graft: note already settled`                  | 409 (replay) |
| `settle-graft: note already settled (prior epoch)`    | 409 (replay across epoch) |
| `settle-graft: verify gate crashed`                   | 502 (gate panic; caller's `data` shape mismatched the gate's sieve) |

A `decode_settle_error` helper in `vesl-core`'s effect-decoders
returns the cord as `String`; the handler then maps it to the
right status + body. The malformed-payload + gate-crash paths
are caller-visible bugs (4xx → "your `data` was wrong shape"
vs 5xx → "your `data` panicked the gate"); the replay /
not-registered / mismatch family is operational state (409).

### 3.4 Backwards compatibility — LANDED

`SettleResponse { note_id, merkle_root, settled, effects_count }`
is preserved. Counter advance still gates on kernel-accept
(unconditional `+= 1` on success, persisted via
`save_note_counter`). The `settled` flag now means what it says:
true iff the first effect tag is `settle-noted`.

For §3.2, the new optional fields on `SettleRequest`
(`hull`, `data`) are additive — existing callers passing only
`note_id` keep working.

## 4. Tests

The harness pattern is in place at
`vesl-nockup/templates/vesl/tests/desync_regression.rs`. Extend
with three cases:

- `settle_with_explicit_data_succeeds_against_commit` — POST
  `/commit` with two fields, POST `/settle` with `data` hex of
  the second field's leaf bytes, assert 200 + `settled: true`.
  Requires a multi-leaf gate; document that prerequisite.
- `settle_with_replay_id_returns_409_with_cord` — POST
  `/commit`, two POSTs to `/settle` with the same `note_id`,
  assert the second 409 body contains the cord
  `settle-graft: note already settled` (lifted from
  `%settle-error`).
- `settle_with_unregistered_hull_returns_409` — POST `/settle`
  with `hull: 99` (not registered), assert 409 with cord
  `settle-graft: root not registered`.

The third test exercises the new optional `hull` field. Keep the
existing 1-field happy-path test as the regression baseline.

## 5. Sequencing relative to other follow-ups

Real `%settle-note` is independent of:

- Root rotation (`docs/AUDIT_C01_ROTATE_ROOT.md`) — a different
  kernel arm; can land in parallel.
- L-09 `%settle-register-rejected` emission (covered in the
  rotate-root doc) — different effect path.

Recommended order for the remaining work: §3.3 (cord decoding,
Rust-only, no kernel change) first; then §3.2 (richer schema,
also Rust-only). Both land in a single vesl-nockup feature
branch off `hull-lib-factor` or `main`. No kernel JAM regen
needed.

## 6. Out of scope

- Multi-hull-per-process (audit §L-08).
- The 6 sibling templates' `print_effects` helpers — they already
  display empty effects; the audit framing accepts that.
- Catalog-gate-specific request schemas (typed `SettleRequest`
  per gate). Pass-through is the recommended generic-hull shape.

## 7. Links

- Audit report: `docs/AUDIT_REPORT.md`
- Companion rotate-root doc: `docs/AUDIT_C01_ROTATE_ROOT.md`
- Umbrella index: `docs/AUDIT_C01_FOLLOWUP.md`
- Settle-graft source (canonical): `protocol/lib/settle-graft.hoon`
  (mirrored at `vesl-nockup/hoon/lib/settle-graft.hoon`)
- Shared dispatch arms: `protocol/lib/kernel-arms.hoon`
- Hull-Rust (current consumer):
  `vesl-nockup/crates/vesl-hull/src/api.rs`
- Settle poke builders:
  `crates/vesl-core/src/graft_pokes/settle.rs`
- Surgical fix commit (real-settle): vesl-nockup `877988f` on
  `hull-lib-factor`
- Original parametize-3 fix history (now archived):
  `git log --grep '§2.C-01'`
