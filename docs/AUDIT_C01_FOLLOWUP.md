# C-01 Follow-Up — Deferred Kernel Work

Companion to `docs/AUDIT_REPORT.md` §2.C-01. The surgical Rust-only
fix landed on `parametize-3` across three vesl-core commits
(`commit_handler`, `settle_handler`, regression tests) plus a sister
fix in hull-llm. This doc catalogues the kernel-level work the audit
recommended that we deliberately deferred so the integrity fix stays
small, reviewable, and durable across upstream STARK pipeline
progress.

## 1. Why deferred

- Every kernel change regenerates `assets/settle.jam` and
  `assets/CHECKSUMS.sha256` per `CLAUDE.md` §3 ("Modifying a Hoon
  kernel"). The byte change needs its own commit and review focus.
- `scripts/check-jam.sh` plus CI's `jam-determinism.yml` gate every
  kernel Hoon edit. Layering kernel work onto a Rust integrity fix
  obscures both reviews.
- The signature surface for `%rotate-root` and the payload plumbing
  for real `%settle` are design decisions, not bug fixes. Each
  deserves a fresh review session with the operator and the
  STARK-pipeline considerations from `AUDIT_REPORT.md` §7 in scope.

## 2. Real `%settle` for the generic hull (audit §2.C-01 fix 3)

**Current state.** `protocol/lib/settle-kernel.hoon:86-103` already
implements `%settle` end-to-end: parses the settlement payload via
the shared `parse-payload` arm in `kernel-arms.hoon`, runs the four
`validate-settlement-args` checks (root-registered, expected-root
match, note-root match, replay), invokes `settle-note`, and emits
the result effect. The hull never calls this — both `/commit` and
`/settle` build a `%register` poke.

**Work to do.**

- Rust side: a `build_settle_payload(note, manifest, expected_root)`
  helper in `vesl-core::noun_builder`, mirroring the existing
  `build_register_poke` shape.
- Hull side: a richer `SettleRequest` schema carrying note metadata
  + manifest + expected-root + the signature material the settlement
  payload needs.
- Effect decoding: pattern-match the `%settled` (or whatever the
  result tag is — confirm against the kernel's `settle-note` return
  shape) effect tag instead of relying on empty-vs-non-empty.
- Tests: extend `hull/tests/desync_regression.rs` with the real
  settle path once `/settle` no longer re-uses `%register`.

**Open design question.** Whether `/settle` keeps its current name
(now meaning real settlement) or the generic hull grows a new
endpoint and `/settle` retires. Today's mislabel (`/settle` pokes
`%register`) is what makes this confusing; once the real-settle
path lands the names should match.

## 3. `%rotate-root` cause (audit §2.C-01 fix 2)

**Current state.** `protocol/lib/settle-kernel.hoon:34-38` lists
only `%register`, `%settle`, and `%verify` as valid causes.
`handle-register` rejects duplicates outright. No rotation primitive
exists.

**Work to do.**

- Add a `%rotate-root` case to `settle-kernel.hoon` between
  `%register` and `%settle`. Conceptually the inverse of
  `handle-register`: takes `(hull, old-root, new-root, sig)`, asserts
  the hull is currently registered to `old-root`, verifies the
  signature, swaps `registered.state` to point at `new-root`.
- Auth design: signature over the rotation tuple verified against a
  designated rotation pubkey. Two options, pick one:
  - **Per-hull rotation key** baked into the kernel state at
    `%register` time. Most isolation but doubles the registration
    payload.
  - **Operator global key** stored in kernel state at boot. Simpler
    but couples every hull's rotation to a single operator.
- Emit `[%revoked hull old-root]` and `[%registered hull new-root]`
  effects as a pair so Rust callers see both transitions.
- Hull side: `build_rotate_root_poke(hull, old_root, new_root, sig)`
  plus a `POST /rotate` endpoint (or a flag on `/commit` — design
  call during that session).

## 4. `%register-rejected` effect (audit §3.L-09)

**Current state.** `protocol/lib/kernel-arms.hoon:17-23`'s
`handle-register` returns `~` on duplicate; the kernel arm at
`settle-kernel.hoon:79-84` translates that to `[~ state]` — no
effect emitted. Rust callers must infer rejection from
`effects.is_empty()`. The surgical fix in vesl-core hull (the
two commits this doc references) does exactly that, and the same
in hull-llm.

**Work to do.**

- Change `handle-register` to return a discriminant —
  e.g. `[%.y new-map]` on insert, `[%.n %already-registered]` on
  duplicate.
- Update the kernel arm to emit
  `[%register-rejected hull old-root]` on the failure path so
  callers see an explicit tag instead of an empty list.
- Rust side: keep the `effects.is_empty()` belt-and-suspenders
  check, but prefer pattern-matching on the explicit tag once it
  lands. Tag mismatch then becomes the only 502 path; empty list
  becomes a 5xx because it means the kernel did not respond at all.

## 5. Sequencing

Recommended order when the next kernel session happens:

1. **§4 (L-09 explicit rejection effect)** first. Lowest risk,
   smallest kernel diff, no signature design. Improves the Rust
   diagnostics without changing API contracts.
2. **§2 (real `%settle`)** second. Unblocks the hull from being
   effectively single-shot, since each settled note advances state.
   Independent of §3.
3. **§3 (`%rotate-root`)** last. Most design surface; depends on
   the auth model resolving cleanly.

Each step ends with `scripts/check-jam.sh` and a commit that bumps
`assets/settle.jam` plus `CHECKSUMS.sha256`.

## 6. Out of scope here

- **Multi-hull-per-process** (audit §L-08). Distinct problem.
- **STARK verifier `test-mode` removal** (audit §H-01). Distinct
  surface; covered in `docs/AUDIT_REPORT.md` §7 "Fix now despite
  the STARK pipeline being in flux."
- **The 6 templates that print `(no effects)`** (`graft-settle`,
  `graft-mint`, etc.). The audit framing treats their existing
  visibility helper as acceptable; only `templates/vesl` matched
  the hull's original silence pattern and was fixed alongside the
  hull.

## 7. Links

- Audit report: `docs/AUDIT_REPORT.md`
- Settle kernel source: `protocol/lib/settle-kernel.hoon`
- Shared dispatch arms: `protocol/lib/kernel-arms.hoon`
- Kernel JAM regen flow: `CLAUDE.md` §3
- Surgical fix commits on `parametize-3`: see
  `git log --grep '§2.C-01'`
