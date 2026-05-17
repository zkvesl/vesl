# Audit Follow-Up — Top-Level Index

Companion to `docs/AUDIT_REPORT.md` §10 ("Recommended Next Steps").
Tracks the disposition of every finding in the audit so anyone
opening the repo cold can see what's been addressed, what's planned,
and what's deferred.

If you're looking for the C-01 fix details specifically, the
`docs/AUDIT_C01_FOLLOWUP.md` sub-index covers the surgical Rust fix
and the two kernel-level follow-ups.

## 1. C-01 (Critical) — landed + planned

Status: surgical Rust fix landed on `parametize-3`. Two kernel-level
follow-ups documented but unimplemented.

- Surgical fix: `git log --grep '§2.C-01'` shows the commits across
  vesl-core hull, hull-llm, and the vesl template.
- Planning sub-index: `docs/AUDIT_C01_FOLLOWUP.md`
- Rotate-root design: `docs/AUDIT_C01_ROTATE_ROOT.md`
- Real-settle design: `docs/AUDIT_C01_REAL_SETTLE.md`

## 2. Active Highs — planning docs landed

Per-finding planning docs ready for implementation sessions. Each
doc captures the design surface, recommendation, migration story,
and stash coordination notes.

| Finding | Planning doc | Recommendation |
|---------|-------------|----------------|
| H-01 (verifier `test-mode` removal) | `docs/AUDIT_H01_TEST_MODE.md` | Option B — hard-assert `?>  =(test-mode %.n)` at top-level entries |
| H-03 (hash-leaf collision) | `docs/AUDIT_H03_HASH_LEAF.md` | Option C — `hash-leaf-v2-domain` with tag + length prefix |
| H-04 (Schnorr message-uniqueness) | `docs/AUDIT_H04_SIGNING_AUDIT.md` | Audit-output doc; annotate sites 1/3/5/6, verify site 2, inspect sites 4/7 |

## 3. Deferred per §7 — no action this cycle

These items are blocked on upstream STARK pipeline coordination
(the cell-subject memory-table multi-subject gap). Revisited when
the stash at `~/projects/nockchain/stark-proof-stash` re-applies.

- **H-02** — verifier completeness / perf TODO (`C-lead-2`). Needs
  STARK-fluent second reviewer per the audit author's own note.
- **L-11** — `mule`-wrap collapses constraint errors to `%.n`.
  Diagnostics-quality; revisited alongside `~&` decisions when
  `verify-settlement-full` lands.
- **L-12** — `verifier-eny` controls Merk-proof check ordering.
  STARK-internal design-intent question; soundness unaffected.
- **C-lead-1** — STARK formula hardcoding. Dissolves when cell-
  subject proving ships.

## 4. Active Mediums needing a planning doc — pending

These have real design surface and will get their own per-finding
docs in subsequent slices. Pre-decisions from the planning session
recorded here.

- **M-04** — settled set unbounded growth. Three-option doc planned
  (epoch GC / LRU cap / accept). Filename: `AUDIT_M04_SETTLED_GC.md`.
- **M-05 + M-06** — replay cache persistence + size cap. Backend
  choice (Redis / SQL) anchored to ADR-0010. Filename:
  `AUDIT_M05_REPLAY_PERSISTENCE.md`.

## 5. Active items — direct fixes (no planning doc)

Each lands as a single commit. Pre-decisions baked in where the
planning session resolved them.

| Finding | File | Fix |
|---------|------|-----|
| **M-01** | `hull/src/api.rs:262` | Wire `tower-governor` per-IP middleware alongside the existing global bucket (per planning-session decision) |
| **M-03** | `crates/nock-noun-rs/src/lib.rs:187` | Change `rejam_atom` to return `Result<Vec<u8>, RejamError>` |
| **M-07** | `vesl-nockup/crates/vesl-signing/src/caip122.rs:261` | Cap window: `cache.seen(key, window.min(MAX_SIWN_WINDOW))` |
| **M-08** | `vesl-nockup/crates/vesl-signing/src/schnorr.rs:119` | u64-overflow guard in `Schnorr::from_belts` |
| **M-09** | `hull/src/config.rs:117` | `if is_demo_key(&sk) { return Err(...) }` in `SettlementConfig::resolve_dumbnet` |
| **L-04** | `hull/src/api.rs:242-247` | Broaden loopback parser (or document the bind-format expectation) |
| **L-05** | `vesl-nockup/sync.sh:306-308` | Anchor `sed` regex to graft-inject binary-name context |
| **L-08** | `hull/src/api.rs:158` | Document hardcoded `hull_id=1` invariant (or expose to config) |
| **L-14** | `hull/src/api.rs:459-486` | Decide: document or remove `merkle_root` param on `/verify` |
| **L-15** | `hull/src/api.rs:69-88` | Document single-writer invariant on counter file |
| **L-16** | `crates/nockchain-tip5-rs/src/lib.rs:77-121` | Add fuzz harness for `tip5_to_atom_le_bytes` |

## 6. Info-only / already addressed — no action

These findings are either operator-awareness items (documented in
the audit and accepted as design choices) or already addressed by
work that's landed.

- **L-01** — Build-time JAM path is environment-trusted. Documented
  behavior; flag for ops.
- **L-02** — `pubkey_canonical_bytes` panics on point-at-infinity.
  Documented invariant.
- **L-03** — `derive_pubkey` `.expect()` if `sk` scalar ≥ G_ORDER.
  Documented invariant.
- **L-06** — `cp -rL` in sync.sh dereferences symlinks. Documented
  supply-chain caution.
- **L-07** — `NOCK_PIN` is the only protection for shipped templates'
  nockchain rev. Trust contract: GitHub honors immutable refs.
- **L-09** — `handle-register` slogs but emits no error effect on
  duplicate. Bundled into `AUDIT_C01_ROTATE_ROOT.md` §3.
- **L-10** — Settle-kernel `%verify` mode skips the replay check.
  Documented design.
- **L-13** — `build-prompt` 10MB cap is independent of HTTP body
  limit. Defense-in-depth; documented relationship.
- **L-17** — Demo signing key documented but no warning when used
  outside fakenet. Covered when M-09 fixes.
- **M-02** — `poke_kernel_with_timeout` discards effect contents.
  Covered by C-01 surgical fix (effect-tag pattern-match landed).

## 7. Cross-repo coordination — `stark-proof-stash`

The stash at `~/projects/nockchain/stark-proof-stash` is paused
awaiting upstream coordination on the cell-subject memory-table
multi-subject gap. The stash is **additive-only** on top of
vesl-core's verifier / merkle / signing surfaces — see the stash's
own `README` for the re-apply checklist.

**Working principle.** Audit fixes that land in vesl-core flow
through to the stash via re-apply because the stash never modifies
existing arms in place. The exception: any vesl-core change that
removes or renames an existing arm requires a parallel patch in the
stash.

**Stash impact for the three Highs in this slice:**

- **H-01** — impact: **none**. The stash's `verify-settlement-full`
  declares its own `test-mode` as a local (not a door parameter),
  defaulting to `%.n`. Callers cannot flip it. Safe by construction.
  Option B's hard-assert at the top-level `verify-settlement` flows
  through the `verify-settlement-full → verify-settlement` call
  without rework.
- **H-03** — impact: **one new call site to migrate at re-apply**.
  `stark-proof-stash/protocol/lib/vesl-stark-verifier.hoon:101`
  calls `hash-leaf` inside `verify-settlement-full`. Migration to
  `hash-leaf-v2-domain` (likely with the `forge-leaf` tag) is the
  single coordination item. Recommend updating the stash's own
  `README` re-apply checklist with this step.
- **H-04** — impact: **none**. Zero new signing call sites in the
  stash.

The stash's other additive arms (`belts-to-btree`, `btree-to-belts`,
`btree-depth`, `rag-logic-standalone.hoon`, `rag-logic-provable.hoon`)
do **not** add new leaf-hashing or signing surface — verified by
grep across the stash tree during the planning session.

## 8. Slice sequencing — recommended order for implementation

Per `AUDIT_REPORT.md` §10's priority order, with the
cross-dependencies surfaced by the planning docs:

1. **C-01 follow-ups** (rotate-root, real-settle) — already
   planned; each is independent and can land in any order. Rotate-
   root is also a migration vehicle for H-03 Phase 2.
2. **H-01** — independent of everything; smallest diff. Land
   anytime.
3. **H-03** — must land before H-04 annotations and before stash
   re-apply. Largest of the three Highs.
4. **H-04** — pure annotations (sites 1, 3, 5, 6) batched into one
   commit; verify/inspect sites (2, 4, 7) get their own sessions.
5. **M-09, M-07, M-08, M-01** — direct fixes; each is one commit.
6. **M-04 plan**, then implementation.
7. **M-05/M-06 plan**, then implementation (ADR-0010 anchor).
8. **L-batch** (M-03, L-04, L-05, L-08, L-14, L-15, L-16) — cleanup
   batch; one commit each or grouped where they touch the same file.

Items in §3 (deferred) are revisited when the stash re-applies. The
stash's `PROMPT_NEXT.md` and `README` define the upstream
coordination shape.

## 9. Links

- Audit report: `docs/AUDIT_REPORT.md`
- C-01 sub-index: `docs/AUDIT_C01_FOLLOWUP.md`
- C-01 rotate-root design: `docs/AUDIT_C01_ROTATE_ROOT.md`
- C-01 real-settle design: `docs/AUDIT_C01_REAL_SETTLE.md`
- H-01 plan: `docs/AUDIT_H01_TEST_MODE.md`
- H-03 plan: `docs/AUDIT_H03_HASH_LEAF.md`
- H-04 plan: `docs/AUDIT_H04_SIGNING_AUDIT.md`
- Kernel JAM regen flow: `CLAUDE.md` §3
- Stash re-apply plan: `~/projects/nockchain/stark-proof-stash/README.md`
- vesl-nockup sync scope: `vesl-nockup/sync.sh`
