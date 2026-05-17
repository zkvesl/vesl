# C-01 Follow-Up — Index

Companion to `docs/AUDIT_REPORT.md` §2.C-01.

## Where the work lives now

The surgical fix originally landed on `parametize-3` against
`vesl-core/hull/` and `vesl-core/hull-llm/`. Both directories have
since been removed — vesl-core's hull was factored into a
vesl-nockup-native lib at `vesl-nockup/crates/vesl-hull/`, and the
LLM hull was retired. The vesl template's `src/main.rs` and its
`tests/desync_regression.rs` moved with the factoring to
`vesl-nockup/templates/vesl/`.

Cross-reference for fresh sessions:

| Concern                | Current location |
|---|---|
| Hull HTTP API          | `vesl-nockup/crates/vesl-hull/src/api.rs` |
| Hull-side tests        | `vesl-nockup/templates/vesl/tests/desync_regression.rs` |
| Template smoke binary  | `vesl-nockup/templates/vesl/src/main.rs` |
| Settle kernel (graft)  | `vesl-core/protocol/lib/settle-graft.hoon` (canonical) |
|                        | `vesl-nockup/hoon/lib/settle-graft.hoon` (synced) |
| Poke builders          | `vesl-core/crates/vesl-core/src/graft_pokes/settle.rs` (`build_settle_*`) |
| Legacy monolith kernel | `vesl-core/protocol/lib/settle-kernel.hoon` (no live consumer; kept for parity) |

vesl-nockup's settle-graft is the active kernel (composed into user
kernels via `nockup graft inject`). The standalone monolithic
`settle-kernel.hoon` in vesl-core is orphaned by hull-removal; the
deferred remediations below target settle-graft.

## Two deferred remediations

- **`docs/AUDIT_C01_ROTATE_ROOT.md`** — audit fix 2. Adds a
  `%settle-rotate-root` cause to settle-graft so operators can
  rotate a hull's registered root without restarting the process.
  Bundles the §3.L-09 `%settle-register-rejected` emission work
  (typed reason instead of free-form `%settle-error msg=@t`)
  because it touches the same kernel arms.
- **`docs/AUDIT_C01_REAL_SETTLE.md`** — audit fix 3. The original
  scope ("replace the generic hull's `/settle` placeholder which
  re-pokes `%register` with a real `%settle` poke") is **partially
  landed** as of vesl-nockup `877988f` on `hull-lib-factor`:
  `/commit` and `/settle` now poke `%settle-register` and
  `%settle-note` against settle-graft's umbrella cause, settling
  one note per call against `field[0]`. What remains is the
  richer `SettleRequest { note, data }` schema so callers can
  drive multi-note settlement against a structured payload. See
  the doc for the still-outstanding work.

Read either or both depending on which kernel session is next.
They're independent — no shared dependency, no shared kernel arm.

## What landed in the surgical fix

- vesl-nockup `crates/vesl-hull/src/api.rs` (`/commit`, `/settle`):
  409 on duplicate register (empty effects) or `%settle-error`
  emission, 502 on unexpected effect tag, no local-state overwrite
  on rejection, counter advance gated on kernel accept. Builders
  swapped from legacy `build_register_poke` to settle-graft's
  `build_settle_register_poke` / `build_settle_note_poke`
  (`877988f`).
- vesl-nockup `templates/vesl/tests/desync_regression.rs`: three
  integration tests against the settle-graft kernel.
- vesl-nockup `templates/vesl/src/main.rs`: poke helper errors on
  empty effects so the starter demo binary exits non-zero on
  rejection.
- vesl-nockup `crates/vesl-hull/` factoring (`1f6196f`,
  `a947fdc`): hull lifted out of vesl-core as a vesl-nockup-native
  crate, driving `out.jam` from disk instead of an embedded
  `kernels_settle::KERNEL`.

## What's deliberately out of scope here

- Multi-hull-per-process (audit §L-08).
- STARK verifier `test-mode` removal (audit §H-01).

## Links

- Audit report: `docs/AUDIT_REPORT.md`
- Rotate-root deferral: `docs/AUDIT_C01_ROTATE_ROOT.md`
- Real-settle deferral: `docs/AUDIT_C01_REAL_SETTLE.md`
- Settle-graft source (canonical): `protocol/lib/settle-graft.hoon`
- Legacy monolith kernel: `protocol/lib/settle-kernel.hoon`
- Shared dispatch arms: `protocol/lib/kernel-arms.hoon`
- Hull-Rust (factored consumer): `vesl-nockup/crates/vesl-hull/`
- Surgical-fix commit (real-settle): vesl-nockup `877988f` on
  `hull-lib-factor`
- Original parametize-3 fix history: `git log --grep '§2.C-01'`
- Kernel JAM regen flow: `CLAUDE.md` §3
