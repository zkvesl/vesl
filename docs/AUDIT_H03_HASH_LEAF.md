# H-03 Follow-Up — `hash-leaf` Collision Remediation

Companion to `docs/AUDIT_REPORT.md` §3.H-03. Both Rust and Hoon
sides of `hash-leaf` strip trailing zero bytes from the input before
chunking into 7-byte Belts. This is intentional cross-VM bignum
alignment (Hoon atoms are bignums; `0x05` and `0x05 00 00` are the
same value) and is documented at both sides — but it means
`hash_leaf("x")` == `hash_leaf("x\0")`.

Any caller that treats byte-length as semantic sees hash collisions.
The current attestation paths happen to feed `hash-leaf` with
fixed-width digests where length doesn't carry meaning, so the
in-the-wild exposure is narrow. But the primitive is wrong, the
audit explicitly recommends adding a length-prefixed / domain-
separated variant, and a single new caller that didn't read the
warning comments could open the hole.

This doc captures the API choice and the migration story.

## 1. Current state

### 1.1 Implementations

- **Rust:** `crates/nockchain-tip5-rs/src/lib.rs:127-173`
  (`atom_bytes_to_belts` + `hash_leaf`). The trailing-zero strip is
  at line 147: `bytes.iter().rposition(|&b| b != 0).map_or(0, ...)`.
  The trade-off is documented at lines 132-145 with the explicit
  audit pointer (`AUDIT 2026-04-17 L-07`).
- **Hoon:** `protocol/lib/vesl-merkle.hoon:38-89`
  (`split-to-belts` + `hash-leaf` + `hash-leaf-digest`). The bignum
  semantics are documented at lines 38-43.

Both sides intentionally normalize identically so cross-VM hashes
agree. That property is load-bearing for the protocol and must be
preserved — the fix is **additive**, not a replacement.

### 1.2 Production call sites

**Highest-risk: signature attestation.**
- `protocol/lib/vesl-gates.hoon:60` —
  `sig-verify-ed25519`: `(hash-leaf pubkey.p) == expected-root`.
- `protocol/lib/vesl-gates.hoon:94` —
  `sig-verify-schnorr`: `(hash-leaf pubkey.p) == expected-root`.
- `protocol/lib/vesl-gates.hoon:96` —
  `sig-verify-schnorr`: `(hash-leaf-digest data.p)` is the signed
  message digest passed to the Schnorr verify.

The 97-byte canonical pubkey ends in `0x01` (`signing.rs:180`), so
the pubkey hashing is safe today by construction. The audit calls
this out — the specific path is fine; the general primitive isn't.

**Graft leaf bindings:**
- `protocol/lib/guard-graft.hoon:106` —
  `%guard-check`: `(hash-leaf data.cause) == registered root`.
- `protocol/lib/forge-graft.hoon:68` —
  Fiat-Shamir leaf binding: `root = (hash-leaf data.cause)`.
- `protocol/lib/settle-graft.toml:41,53,65` — three settle-graft
  variants computing `=((hash-leaf ;;(@ data)) expected-root)`.
- `protocol/lib/mint-kernel.hoon:74-75` — `%hash-leaf` cause exposes
  raw `hash-leaf` as a kernel primitive (`(hash-leaf dat.u.act)`).

**Merkle primitives:**
- `protocol/lib/vesl-merkle.hoon:122` — `verify-chunk` walks proof
  starting from `(hash-leaf chunk)`.
- `crates/nockchain-tip5-rs/src/lib.rs:203` — `verify_proof`
  mirror.
- `crates/nockchain-tip5-rs/src/lib.rs:239` — `MerkleTree::new`
  builds the leaf row.

**SDK helper (cross-couples to H-04):**
- `crates/vesl-core/src/signing.rs:206` —
  `schnorr_message_digest_for_data` digests via `hash_leaf` and
  hands the digest to `sign()`. The H-03 collision flows directly
  into Schnorr message uniqueness (see `AUDIT_H04_SIGNING_AUDIT.md`).

## 2. Proposed remediation

### 2.1 Option A — Length-prefix only

Add `hash_leaf_v2(data)` that prepends a 4-byte big-endian length:

```
hash_leaf_v2(data) := hash_leaf(concat(len_be4(data), data))
```

Closes the trailing-zero collision. Does not protect against cross-
context leaf reuse — a chunk leaf could still be replayed as a
kv-graft leaf if their encodings ever overlap.

### 2.2 Option B — Domain-tag only

Add `hash_leaf_domain(tag, data)` that prepends an 8-byte domain tag:

```
hash_leaf_domain(tag, data) := hash_leaf(concat(tag_bytes, data))
```

Modeled on the existing `tip5_with_domain`, which the audit cites
as the reference shape. Closes cross-context replay; does not close
the trailing-zero collision.

### 2.3 Option C — Both

Add a single primitive that does both:

```
hash_leaf_v2_domain(tag, data)
  := hash_leaf(concat(tag_bytes, len_be4(data), data))
```

8 bytes of overhead per leaf (8-byte tag, 4-byte length — round to
12, or pack into 8 if we squeeze tag width to 4 bytes). Two new
primitives (one per VM side). Closes both classes of collision.

### 2.4 Recommendation — Option C

Option **C** is the right choice. Both classes of collision are
real; both fixes are cheap; doing them as one primitive avoids a
third migration if a future leaf class trips the other.

**Concrete API.**

Rust (in `crates/nockchain-tip5-rs/src/lib.rs`):

```rust
pub fn hash_leaf_v2_domain(domain: &[u8; 8], data: &[u8]) -> Tip5Hash {
    let mut prefixed = Vec::with_capacity(8 + 4 + data.len());
    prefixed.extend_from_slice(domain);
    prefixed.extend_from_slice(&(data.len() as u32).to_be_bytes());
    prefixed.extend_from_slice(data);
    hash_leaf(&prefixed)
}
```

Hoon (in `protocol/lib/vesl-merkle.hoon`):

```
++  hash-leaf-v2-domain
  |=  [tag=@ux dat=@]
  ^-  @
  ::  pack [tag(8 bytes BE) | len(4 bytes BE) | data] then hash
  =/  dlen=@  (met 3 dat)
  =/  prefixed=@
    %+  con
      (lsh [3 +(4)] tag)
    %+  con
      (lsh [3 4] dlen)
    dat
  (hash-leaf prefixed)
```

(The exact `con`/`lsh` packing details need to be verified during
implementation — the goal is a canonical byte-equivalent layout
between the two sides.)

**Domain tag table.** A shared constant block in `vesl-merkle.hoon`
+ a matching Rust constant module:

| Tag  | Purpose                              | First user                  |
|------|--------------------------------------|------------------------------|
| `pk-leaf`     | signature-attestation pubkey leaf      | `sig-verify-*` gates        |
| `chunk-leaf`  | RAG-style chunk content                | `verify-chunk` Merkle walk  |
| `kv-leaf`     | key-value graft entries                | `guard-graft` extension     |
| `forge-leaf`  | Fiat-Shamir leaf binding               | `forge-graft`, settle-graft |
| `manifest`    | settlement-payload manifest leaf       | `settle-kernel.hoon` arms   |

Tag bytes are short ASCII (left-padded to 8). The table is
authoritative — no caller picks a custom tag without adding a row
here first.

## 3. Migration story

The new primitive is additive. Migration of existing call sites
happens in priority order so that the highest-risk surfaces flip
first and the lowest-impact tree migrations land last.

### 3.1 Phase 1 — Attestation paths

Switch `vesl-gates.hoon:60,94,96` to
`(hash-leaf-v2-domain pk-leaf pubkey.p)` and
`(hash-leaf-v2-domain manifest data.p)` (for the schnorr message
digest variant). Bumps the verifier domain; every signature
verification path now binds the leaf to its tag.

**Schnorr message digest helper:** update
`crates/vesl-core/src/signing.rs:206` to call
`hash_leaf_v2_domain(MANIFEST_DOMAIN, data)`. This closes the H-04
side channel where two `data` values differing only in trailing
zeros produce the same signature.

JAM regen required for any kernel that imports `vesl-gates`. Check
during implementation — likely all three of guard/mint/settle.

### 3.2 Phase 2 — Graft leaf bindings

Switch `guard-graft.hoon:106`, `forge-graft.hoon:68`, and the three
`settle-graft.toml` variants to the domain-tagged form. Each
requires a state-schema version bump on the affected kernel because
the on-chain root that pre-dates migration was computed with the old
`hash-leaf`. Two options for handling existing registered hulls:

- **v2-only for new hulls.** Existing hulls continue to use the old
  `hash-leaf`; new hulls register against the v2-domain root. The
  kernel branches on a state-tagged version field. Cheaper, but
  doubles the verify path.
- **One-shot migration.** Use the rotate-root machinery from
  `docs/AUDIT_C01_ROTATE_ROOT.md` to atomically re-register every
  existing hull against its v2-domain root. Sequencing constraint:
  rotate-root must land first. Cleaner end state.

Recommend the **one-shot migration** if rotate-root lands before
this phase. Otherwise, ship the v2-only-for-new-hulls split and
plan a cleanup pass.

JAM regen required for guard/mint/settle.

### 3.3 Phase 3 — Merkle tree primitives

`vesl-merkle.hoon:122` (`verify-chunk`) and the Rust mirrors at
`tip5-rs:203,239` get the v2-domain treatment last. Touching these
invalidates every committed Merkle tree, so the rollout is
gated on a tree-version field in any stored commitment. New trees
get v2-domain; old trees stay verifiable against the legacy
primitive for one revision cycle, then get migrated or expired.

JAM regen required for any kernel that builds or verifies a tree.

### 3.4 Phase 4 — Kernel-exposed primitive

`mint-kernel.hoon:74-75` exposes `%hash-leaf` as a cause. Add a
parallel `%hash-leaf-v2-domain` cause with `[%hash-leaf-v2-domain
tag=@ux dat=@]`. Do not remove the original — external callers may
be relying on the legacy primitive for opaque reasons.

JAM regen required for mint-kernel.

## 4. Cross-VM coordination

Any drift between Rust `hash_leaf_v2_domain` and Hoon
`hash-leaf-v2-domain` silently breaks every consumer that crosses
the boundary. Discipline:

- Both sides land in the same PR. CI must reject a PR that
  modifies one without the other.
- Add parity tests modeled on the existing
  `crates/nockchain-tip5-rs` Rust-Hoon roundtrip golden vectors.
  Each entry: `(tag, data)` → expected digest, generated once by
  the Hoon side and copy-pasted into the Rust harness (or vice
  versa).
- Add a collision-fix property test:
  `hash_leaf_v2_domain(tag, "x") != hash_leaf_v2_domain(tag, "x\0")`.
  This is the audit-property check.
- Add a regression test that pre-existing `hash_leaf` golden vectors
  are unchanged. The legacy primitive must stay byte-stable while
  the v2 primitive rolls out.

## 5. Stash coordination

The stash (`~/projects/nockchain/stark-proof-stash`) adds exactly
**one** new `hash-leaf` call site:
`stark-proof-stash/protocol/lib/vesl-stark-verifier.hoon:101`,
inside the additive `++verify-settlement-full` arm.

The additive arms `belts-to-btree`, `btree-to-belts`, `btree-depth`
(on `vesl-merkle.hoon`), `rag-logic-standalone.hoon`, and
`rag-logic-provable.hoon` do **not** call `hash-leaf`. They are
pure tree-manipulation and manifest-structuring arms. The H-03
migration surface is bounded; the earlier assumption that the stash
adds many new leaves was incorrect.

When the stash re-applies:

1. Migrate the new `verify-settlement-full:101` call to
   `hash-leaf-v2-domain` with the `forge-leaf` tag (matches the
   Fiat-Shamir binding pattern in `forge-graft.hoon:68`).
2. Update the stash's own `README` re-apply checklist (per audit
   §7) to call out this single migration step.

The H-03 implementation should land **before** the stash re-apply
so that the new primitive exists for the stash to consume. If the
stash re-applies first, the single migration step in §3 becomes
mandatory cleanup; it's cheaper to have it ready.

## 6. JAM regen + check-jam

Per `CLAUDE.md` §3, every kernel whose Hoon imports change requires:

1. `hoonc --new protocol/lib/<kernel>.hoon hoon/`
2. `mv out.jam assets/<kernel>.jam`
3. `cd assets && sha256sum guard.jam mint.jam settle.jam > CHECKSUMS.sha256`
4. `scripts/check-jam.sh` — must return all-green.
5. Dedicated `sync kernel JAM artifacts with source` commit per
   kernel (or one combined commit if all three regen at once),
   never bundled with the Rust + Hoon edits.

CI's `jam-determinism.yml` gates the same assertion on every PR.

Expected regen surface per phase:
- Phase 1 (attestation): guard, mint, settle if any imports
  `vesl-gates`. Check during implementation.
- Phase 2 (graft bindings): guard, mint, settle.
- Phase 3 (Merkle): guard, mint, settle.
- Phase 4 (kernel cause): mint only.

## 7. vesl-nockup sync

`vesl-nockup/sync.sh` mirrors `crates/` from vesl-core (per
`reference_sync_sh_scope`). The new Rust primitive flows through
automatically on the next `./sync.sh` run. No manual template edits
needed. The shipped templates' `hoon/` symlink layer (per CLAUDE.md
§3 "Adding a new Hoon library") may need a refresh if a template's
Hoon imports a `vesl-merkle` arm that previously didn't exist —
check during implementation.

## 8. Out of scope

- Differential fuzzing of `tip5_to_atom_le_bytes` (L-16) — separate
  ticket; complements this work but doesn't block it.
- Removing the legacy `hash-leaf` / `hash_leaf` primitives — defer
  to a future cycle once every consumer migrates. The legacy stays
  as long as any committed root depends on it.
- Domain-tag table expansion for new leaf classes — additive when
  needed; the initial table in §2.4 covers the audit-cited surface.

## 9. Sequencing relative to other follow-ups

H-03 is the largest of the three Highs and has dependencies in
both directions:

- **H-04** depends on H-03. Site #2 in the H-04 inventory
  (`hull-llm/src/tx_builder.rs:117`) and the helper at
  `vesl-core/src/signing.rs:206` both flow through `hash_leaf`. The
  H-04 call-site annotations should cite the v2-domain primitive
  once it exists — so H-03 lands first, then H-04 annotations.
- **STARK stash re-apply** depends on H-03 (per §5). One new call
  site to migrate at re-apply; cleaner if v2-domain exists first.
- **H-01** is independent.
- **C-01 rotate-root** is independent but synergistic — Phase 2 of
  the H-03 migration can use rotate-root as the migration vehicle
  for existing hulls.

## 10. Test plan

Per-language unit tests:

- **Rust:** golden vectors in `nockchain-tip5-rs/tests/`. Each entry
  `(tag, data, expected_hex)`. Generated by reading the Hoon side's
  output once and pasting in.
- **Hoon:** golden vectors in `protocol/tests/` (or wherever the
  existing `vesl-merkle` tests live). Same vectors, asserted via
  the existing assert-hash-eq pattern from `protocol/lib/README.md`.

Cross-VM parity:

- `nockchain-tip5-rs` already has Rust-Hoon roundtrip tests against
  golden vectors (per the existing `hash_leaf` parity pattern). Add
  matching coverage for `hash_leaf_v2_domain`.

Property tests:

- `hash_leaf_v2_domain(tag, "x") != hash_leaf_v2_domain(tag, "x\0")`
  — the collision-fixed property.
- `hash_leaf_v2_domain(tag_a, x) != hash_leaf_v2_domain(tag_b, x)`
  for `tag_a != tag_b` — the domain-separation property.
- `hash_leaf_v2_domain(tag, x) != hash_leaf(x)` — the v2 primitive
  is distinct from the legacy primitive even when input matches.

Regression:

- All pre-existing `hash_leaf` golden vectors unchanged — proves the
  v2 rollout did not silently alter the legacy primitive.

## 11. Links

- Audit report: `docs/AUDIT_REPORT.md`
- Umbrella index: `docs/AUDIT_FOLLOWUP_INDEX.md`
- Companion H-finding docs: `docs/AUDIT_H01_TEST_MODE.md`,
  `docs/AUDIT_H04_SIGNING_AUDIT.md`
- C-01 rotate-root (migration vehicle): `docs/AUDIT_C01_ROTATE_ROOT.md`
- Rust source: `crates/nockchain-tip5-rs/src/lib.rs`
- Hoon source: `protocol/lib/vesl-merkle.hoon`,
  `protocol/lib/vesl-gates.hoon`
- Schnorr digest helper: `crates/vesl-core/src/signing.rs:206`
- Stash re-apply plan: `~/projects/nockchain/stark-proof-stash/README.md`
- Kernel JAM regen flow: `CLAUDE.md` §3
- vesl-nockup sync scope: `feedback_verify_downstream_by_grep` (memory)
