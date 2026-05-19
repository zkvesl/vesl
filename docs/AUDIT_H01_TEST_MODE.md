# H-01 Follow-Up — STARK Verifier `test-mode` Removal

Companion to `docs/AUDIT_REPORT.md` §3.H-01. The verifier door
exposes a `test-mode` parameter that, when flipped to `%.y`, silently
skips Merkle opening verification. The flag is not absorbed by the
Fiat-Shamir transcript and is not asserted at production call sites.
A single-bit slip at any caller reduces the STARK to "proof of
well-formed transcript" with no commitment to the actual evaluation
domain.

This doc captures the design surface for closing that hole. The fix
itself is intentionally small — the value is in being explicit about
which option survives the upstream STARK pipeline rewrite without
rework.

## 1. Current state

`protocol/lib/vesl-stark-verifier.hoon` declares `test-mode=_|` at
four spots:

- **Line 16** — top-level `++verify` arm, default `%.n`.
- **Line 46** — top-level `++verify-settlement` arm, default `%.n`.
- **Line 73** — inner `++verify` inside the `verify-door`, default `%.n`.
- **Line 552** — inner `++verify-settlement` inside the `verify-door`,
  default `%.n`.

Each top-level arm threads the parameter unchanged into the door:

```
%-  ~(. verify test-mode)
[proof override verifier-eny s f]
```

The gate at **line 510** inside `++verify-inner` is the soundness
hinge:

```
?:  &(=(test-mode %.n) !(verify-merk-proofs merk-proofs verifier-eny))
  ~&  %failed-to-verify-merk-proofs  !!
```

When `test-mode = %.y`, the gate short-circuits and the
`verify-merk-proofs` call never runs. An attacker who can influence
the caller to pass `%.y` gets arbitrary `proof.merk-data` accepted as
valid. The verifier doors at line 73 and 552 also pack
`test-mode` into the `args` cell before delegating to `verify-inner`
(line 76-77, 555-556), so the parameter is plumbed end-to-end.

The flag is not bound into `version.proof` and not absorbed at any
Fiat-Shamir step — there is no transcript-level evidence that a given
proof was verified in production mode versus test mode.

## 2. Proposed remediation

Three viable shapes. The doc presents all three so the implementer
(and any reviewer) can compare; recommendation in §2.4.

### 2.1 Option A — Remove the parameter entirely

Drop `=|  test-mode=_|` from all four arm declarations. Inline the
gate at line 510 as the unconditional `?>  (verify-merk-proofs ...)`
form. Every test caller that currently passes `test-mode=%.y` must
migrate to a separate test-only arm (see Option C) or accept the
verify cost.

**Pros.** Smallest production surface; the parameter stops existing
at all, so no future caller can re-introduce the footgun.

**Cons.** Largest churn for existing tests if any currently use
`test-mode=%.y`. The implementer must grep test callers before
landing (see §3).

### 2.2 Option B — Hard-assert `test-mode=%.n` at the top-level entries

Add `?>  =(test-mode %.n)` as the first line of the top-level
`++verify` (after line 17) and `++verify-settlement` (after line 47).
Production callers pass `%.n` (default) and proceed; any caller
passing `%.y` crashes immediately. The inner door arms at lines 73
and 552 keep the parameter — they're not the trust boundary, the
top-level arms are.

**Pros.** Two-line kernel diff. Preserves the existing arm shape, so
no downstream test/test-harness signature changes. Fails closed
loudly (the `?>` crash is unambiguous in the log stream).

**Cons.** Loses the test-skip capability — any test currently passing
`%.y` starts crashing. The parameter still exists at the door
declaration, so a determined future maintainer could remove the
assert and re-open the hole; the protection is review-level, not
structural.

### 2.3 Option C — Split into `verify-test-only`

Remove `test-mode` from the production arms (per Option A); add a
separate `++verify-test-only` and `++verify-settlement-test-only`
arms that skip Merkle verification by construction. Production
kernels never reach these arms because they're not exported into the
production door surface.

**Pros.** Cleanest semantic separation. The test capability is
preserved but lives at a name production code cannot accidentally
call. Survives review-level regressions (no shared parameter to
flip).

**Cons.** Largest surface change. Two new arms to maintain; any
future change to the verify pipeline ripples into both production
and test arms. Tests that currently inline `test-mode=%.y` need to
be rewritten against the new arm.

### 2.4 Recommendation — Option B

Option **B** is the right immediate fix. Three reasons:

1. **Audit §7 calls it durable.** The stash re-apply plan keeps the
   existing `verify` / `verify-settlement` arms intact and only adds
   `verify-settlement-full` alongside (see §4). Option B carries
   through the upstream rewrite unchanged.
2. **Minimum kernel diff.** Two `?>` lines. The risk of a refactor
   introducing a regression is near-zero.
3. **Fail-closed is the right default.** The current behavior
   silently succeeds when `test-mode=%.y`; Option B converts that
   into an explicit crash with a recognizable trace.

Implementation step before landing: `grep -rn 'test-mode=%.y'` across
the workspace (Hoon and any Rust test driver). If any production-
equivalent test currently passes `%.y`, escalate to Option C — but
the audit's own remediation list treats this as the fallback path,
not the primary.

The two **inner** arms inside `verify-door` (lines 73 and 552) keep
their `test-mode` parameter for now. They're not the trust boundary;
the top-level arms are. Future hardening (Option A or C, in a
separate session) can prune the inner parameter too once the test-
caller picture is fully understood.

## 3. Pre-merge grep checklist

Before merging the two `?>` assertions, the implementer must verify:

1. `grep -rn 'test-mode=%.y\|test-mode=%y\|test-mode %.y'` across
   `vesl-core/`, `vesl-nockup/`, `hull-llm/`, and any sibling repo
   that imports the verifier. Expect zero matches in production code.
   Any matches in test code must be triaged: legitimate test (escalate
   to Option C) vs. accidental holdover (delete the parameter pass).
2. `grep -rn 'verify-test\|verify_test'` to confirm no caller already
   relies on a `verify-test-only` arm name (would conflict with a
   future Option C migration).
3. `cargo test --workspace` after the change — any test that
   constructs proofs intended to fail merge verification will now
   surface as a `?>` crash instead of returning `%.n`. Update those
   tests to expect the crash, or rewrite them against Option C if the
   skip is semantically required.

## 4. Stash coordination

The stash (`~/projects/nockchain/stark-proof-stash`) adds an
`++verify-settlement-full` arm at
`protocol/lib/vesl-stark-verifier.hoon:65`. That arm declares its own
`=|  test-mode=_|` local at line 66 (default `%.n`) and passes the
local into `verify-settlement` at line 80.

Critically, **the stash arm's `test-mode` is a local, not a door
parameter** — callers of `verify-settlement-full` cannot flip it.
The arm is safe by construction. Option B's hard-assert on the
top-level `verify-settlement` flows through the
`verify-settlement-full → verify-settlement` call without rework
because the always-`%.n` local satisfies the assert.

When the stash re-applies, no additional `?>` is needed inside
`verify-settlement-full`. The fix surface is the two top-level arms
in vesl-core; everything downstream inherits.

The stash's own `PROMPT_NEXT.md` and `README` document a separate
soundness concern (the op0-mset multiset gap blocking cell-subject
proofs); that issue is independent of H-01 and not addressed here.

## 5. JAM regen — not required

`protocol/lib/vesl-stark-verifier.hoon` is a library, not a boot
kernel. The kernel JAMs in `assets/` are guard, mint, and settle.
The verifier library is imported by callers but is not compiled to
its own JAM artifact, so `scripts/check-jam.sh` does not need to
rerun for this change.

Confirm during execution by running `scripts/check-jam.sh` after the
edit — if it stays green without any `mv out.jam` step, the
no-regen assumption holds.

## 6. Test plan

Add to `protocol/tests/` (or the existing verifier test harness):

- `verify_rejects_test_mode_y` — construct a minimal valid proof,
  call `verify` with `test-mode=%.y`, expect `?>` crash.
- `verify_settlement_rejects_test_mode_y` — same shape against
  `verify-settlement`.
- `verify_inner_door_still_accepts_test_mode_y` — confirms the
  inner door arms (line 73, 552) intentionally still accept the
  parameter; the test documents the boundary.

Existing verifier tests should continue to pass unchanged because
they default to `test-mode=%.n`.

## 7. Sequencing relative to other follow-ups

H-01 is independent of H-03 and H-04. It can land in any order
relative to them. The constraint is: land it **before** the stash
re-apply, so the stash's `verify-settlement-full` inherits the
assert through its `verify-settlement` call rather than landing
into a still-test-mode-permitting boundary.

H-01 is also independent of the C-01 follow-ups (`rotate-root`,
`real-settle`) — different files, different kernel arms.

## 8. Out of scope

- The `mule`-wrap diagnostics collapse (L-11) — deferred per §7.
- `verifier-eny` randomization for DDOS resistance (L-12) — deferred per §7.
- The constraint-completeness TODO (H-02) — deferred per §7 pending
  STARK-fluent second reviewer.
- Pruning the inner arms' `test-mode` parameter — separate session
  if/when the test-caller picture is fully mapped.

## 9. Links

- Audit report: `docs/AUDIT_REPORT.md`
- Umbrella index: `docs/AUDIT_FOLLOWUP_INDEX.md`
- Companion H-finding docs: `docs/AUDIT_H03_HASH_LEAF.md`,
  `docs/AUDIT_H04_SIGNING_AUDIT.md`
- Verifier source: `protocol/lib/vesl-stark-verifier.hoon`
- Stash re-apply plan: `~/projects/nockchain/stark-proof-stash/README.md`
- STARK boundary notes: `docs/AUDIT_REPORT.md` §6
- Deferred-item rationale: `docs/AUDIT_REPORT.md` §7
