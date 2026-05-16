# C-01 Follow-Up — Index

Companion to `docs/AUDIT_REPORT.md` §2.C-01. The surgical Rust-only
fix landed on `parametize-3` across the hull + hull-llm + vesl
template (see `git log --grep '§2.C-01'`). What that fix did NOT
address is documented in two separate follow-up docs, one per
deferred remediation option from the audit:

- **`docs/AUDIT_C01_ROTATE_ROOT.md`** — audit fix 2. Adds a
  `%rotate-root` cause to the settle kernel so operators can
  rotate a hull's registered root without restarting the process.
  Bundles the §3.L-09 `%register-rejected` emission work because
  it touches the same kernel arms.
- **`docs/AUDIT_C01_REAL_SETTLE.md`** — audit fix 3. Replaces the
  generic hull's `/settle` placeholder (which today re-pokes
  `%register`) with a real `%settle` poke carrying a full
  settlement-payload. hull-llm's `/query` already does this; the
  generic hull needs to catch up.

Read either or both depending on which kernel session is next.
They're independent — no shared dependency, no shared kernel arm.

## What landed in the surgical fix

- vesl-core hull `/commit` and `/settle`: 409 on duplicate
  register (empty effects), 502 on unexpected effect tag, no
  local-state overwrite on rejection, counter advance gated on
  kernel accept.
- vesl-core `hull/tests/desync_regression.rs`: three integration
  tests against the real settle kernel.
- vesl-core `templates/vesl/src/main.rs`: poke helper errors on
  empty effects so the starter demo binary exits non-zero on
  rejection.
- hull-llm `/ingest` and `/query`: same fix shape, using bare
  `effects.is_empty()` (no tag-pattern-match) because
  `effect_head_tag` post-dates the pinned vesl-core rev.
- vesl-nockup: sync.sh mirrors the vesl template fix to the
  shipped template bundle.

## What's deliberately out of scope here

- Multi-hull-per-process (audit §L-08).
- STARK verifier `test-mode` removal (audit §H-01).

## Links

- Audit report: `docs/AUDIT_REPORT.md`
- Rotate-root deferral: `docs/AUDIT_C01_ROTATE_ROOT.md`
- Real-settle deferral: `docs/AUDIT_C01_REAL_SETTLE.md`
- Settle kernel source: `protocol/lib/settle-kernel.hoon`
- Shared dispatch arms: `protocol/lib/kernel-arms.hoon`
- Kernel JAM regen flow: `CLAUDE.md` §3
