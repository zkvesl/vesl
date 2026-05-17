# C-01 Follow-Up — Root Rotation (Audit Fix 2)

Companion to `docs/AUDIT_REPORT.md` §2.C-01 remediation option 2.
The surgical Rust-only fix landed on `parametize-3` and made
vesl-core/hull honest about kernel rejection — it now returns 409
Conflict instead of silently overwriting local state. That fix
has since moved with the hull factoring: it now lives in
`vesl-nockup/crates/vesl-hull/src/api.rs` (commit `877988f` on
`hull-lib-factor`).

What that fix does **not** address is the underlying constraint:
each hull process can register exactly one root in its lifetime
on settle-graft. Operators who want to rotate a hull's root
without restarting the process need a new kernel primitive on
settle-graft. This doc captures the design surface for that work.

The original doc targeted `protocol/lib/settle-kernel.hoon` (the
LLM-flavored monolith). vesl-nockup's live kernel is
**settle-graft**, composed into user kernels via `nockup graft
inject`; this rewrite retargets the design at
`protocol/lib/settle-graft.hoon` (canonical) and its mirror at
`vesl-nockup/hoon/lib/settle-graft.hoon`.

## 1. Current state

- `settle-graft.hoon:129-133` (`+$ settle-cause`) lists three
  arms: `%settle-register`, `%settle-note`, `%settle-verify`. No
  rotation primitive exists.
- `++ settle-poke`'s `%settle-register` branch
  (`settle-graft.hoon:147-160`) rejects duplicates by emitting
  `[%settle-error 'settle-graft: hull already registered']` and
  leaving state unchanged. The free-form cord works but is opaque
  to programmatic dispatch.
- vesl-hull (`crates/vesl-hull/src/api.rs`, post-`877988f`) maps
  both the empty-effects path AND the `%settle-error` path to
  409. The 409 body hint enumerates likely causes ("hull already
  registered, registered-map at capacity") but the API can't
  distinguish them without re-reading the kernel slog. The
  audit's §3.L-09 flagged this; this doc bundles the L-09 emission
  work with the rotate-root design because they touch the same
  arm.

## 2. Proposed kernel surface

### 2.1 New cause: `%settle-rotate-root`

Add a fourth arm to `settle-graft.hoon`'s `+$ settle-cause`:

```hoon
+$  settle-cause
  $%  [%settle-register hull=@ root=@]
      [%settle-rotate-root hull=@ old-root=@ new-root=@ sig=@]
      [%settle-note payload=@]
      [%settle-verify payload=@]
  ==
```

Semantics in the new `%settle-rotate-root` branch of
`++settle-poke`:

1. Look up `(~(get by registered.state) hull.cause)`. If `~` →
   emit `[%settle-rotate-rejected hull %not-registered]`, state
   unchanged.
2. Decompose the registered value (see §2.3 for the Option A
   shape `[root=@ rotation-pk=@]`). If
   `root.registered-value != old-root.cause` → emit
   `[%settle-rotate-rejected hull %old-root-mismatch]`, state
   unchanged.
3. Verify `sig` over `(hull, old-root, new-root)` against
   `rotation-pk.registered-value` using the same
   Schnorr-over-Cheetah convention as catalog gate
   `sig-verify-schnorr` (see `vesl-gates.hoon`).
4. On verify failure → emit
   `[%settle-rotate-rejected hull %bad-sig]`, state unchanged.
5. Otherwise, swap the registered entry's `root` field to
   `new-root` (keeping the same `rotation-pk`), and emit BOTH
   `[%settle-revoked hull old-root]` and
   `[%settle-registered hull new-root]` so Rust callers see the
   full transition pair.

Note the wrapping `mule` around the sig-verify step — per the
existing `%settle-note` arm (`settle-graft.hoon:213-218`), gate
crashes must become typed effects, not kernel panics. Reuse the
same pattern here.

### 2.2 Peeks

`settle-graft.hoon` already exposes a hull-keyed root peek at
`[%settle-root hull=@ ~]` (see the peek arm in the same file).
No new peek needed; callers can re-read the post-rotation root
through the existing path.

### 2.3 Auth model — the open question

Two viable designs; pick one before implementing:

**Option A — Per-hull rotation pubkey.** `%settle-register`
grows a third field: `rotation-pk`. The kernel state shape
becomes `registered=(map @ [root=@ rotation-pk=@])`. Each hull's
rotation key is independent and pinned at registration. Most
isolated; downside: state-graft migration on settle-state shape
(see §2.4), `%settle-register` payload grows, operator has to
set the rotation key at first register.

**Option B — Global operator key.** settle-state grows an
`operator-pk=@` field set at scaffold time via a hoon-level
`/+ operator-pk` or a graft compose-time constant. Single key
authorises every hull's rotation. Simpler migration; downside:
couples every hull's rotation lifecycle to one operator.

Recommended: **Option A**. The hull-id model is already per-hull
(each process is `hull_id=1` by convention; multi-hull-per-
process is itself a deferred remediation, audit §L-08), and the
rotation key should match that granularity so a compromised
operator key can't rotate every hull at once.

### 2.4 State-graft migration

settle-graft already runs a `++load` migration path via the
`nockup:load-defaults` codegen marker. Option A's state-shape
change (`(map @ @)` → `(map @ [root=@ rotation-pk=@])`) lands
through that path:

- Bump `versioned-state` from `%v1` to `%v2` in the kernel
  template; declare the new shape under the `nockup:state`
  marker.
- The codegen-generated `++load` walks `%v1 → %v2` by reshaping
  each `(map @ @)` entry into `(map @ [root=@ rotation-pk=@])`.
  Existing entries need a placeholder `rotation-pk`; either
  reject migration if any hull lacks an explicit key (forces
  re-register) OR default to a zero atom and refuse rotation
  until set (lazy migration).
- Lazy migration is the safer default: existing deployments
  keep registering / settling exactly as before, and rotation
  is opt-in per hull via a new `%settle-set-rotation-pk` cause.
  That adds a fifth arm — keep it scoped to this same kernel
  session.

### 2.5 New effect tags

In addition to the existing `%settle-registered`, three new tags:

- `[%settle-revoked hull=@ root=@]` — emitted alongside
  `%settle-registered` on a successful rotation, gives Rust
  callers an explicit signal for the "old root is no longer
  valid" half of the transition.
- `[%settle-rotate-rejected hull=@ reason=?(%not-registered %old-root-mismatch %bad-sig)]`
  — emitted on rotation failures so Rust callers can return the
  right 4xx (404 for not-registered, 409 for mismatch, 403 for
  bad-sig). Replaces a generic `%settle-error` for the rotate
  path.
- `[%settle-register-rejected hull=@ existing-root=@]` — see §3
  below.

Add all three under `+$ settle-effect`
(`settle-graft.hoon:119-125`).

## 3. L-09 emission (bundled here)

The audit's §3.L-09 wanted typed-reason emission on duplicate
register. settle-graft already emits a `%settle-error` with a
free-form msg cord, but Rust callers can't pattern-match on a
typed reason without parsing the cord. While we're editing the
`%settle-register` branch for rotation, fix L-09 in the same
session:

- Replace the duplicate-register emit
  (`settle-graft.hoon:151-152`):

  ```hoon
  ~[[%settle-error 'settle-graft: hull already registered']]
  ```

  with:

  ```hoon
  =/  existing  (~(got by registered.state) hull.cause)
  ~[[%settle-register-rejected hull.cause existing]]
  ```

  (For Option A: `existing` is the registered tuple's `root`
  field; the emit's `existing-root` field stays a flat atom for
  caller convenience.)

- The capacity-cap branch (`settle-graft.hoon:155-157`) stays on
  `%settle-error` — capacity is operational state, not a
  semantic conflict.

- Keep the empty-effects check in vesl-hull as
  belt-and-suspenders for one revision cycle; remove once
  callers have pulled the new kernel rev. Update the 409 body
  hint to point at the new typed tag.

## 4. Rust side

After the kernel work:

- `crates/vesl-core/src/graft_pokes/settle.rs`: add
  `build_settle_rotate_root_poke(hull, old_root, new_root, sig)`
  alongside the existing builders.
- `crates/vesl-core/src/signing.rs`: add
  `sign_settle_rotate_root(sk, hull, old_root, new_root)`
  producing the `sig` field with the same Schnorr-over-Cheetah
  convention as the existing schnorr gate helpers.
- vesl-hull (`vesl-nockup/crates/vesl-hull/src/api.rs`): new
  `POST /rotate` endpoint accepting `{ old_root, new_root, sig }`
  (all hex-encoded). Returns 200 on the
  `[%settle-revoked, %settle-registered]` effect pair; 404 / 409
  / 403 on the three `%settle-rotate-rejected` variants. Update
  the router's `vesl_hull::router(state)` to mount it.
- Tests: extend
  `vesl-nockup/templates/vesl/tests/desync_regression.rs` with
  rotate-root golden + rejection paths. Add an explicit cord-
  decode test confirming the new `%settle-register-rejected`
  tag is emitted on duplicate.

If a future LLM-hull-style consumer appears, the same `/rotate`
shape applies — vesl-hull's router is reusable via
`Router::merge(...)` and the per-graft builders live in
vesl-core.

## 5. Kernel JAM regen flow

settle-graft is **not** a standalone kernel; it's composed into
user kernels via `nockup graft inject`. There's no
`assets/settle.jam` artifact to refresh — the per-user `out.jam`
is regenerated at scaffold-build time. Verification is:

1. Edit `protocol/lib/settle-graft.hoon` + `settle-graft.toml`
   in vesl-core.
2. Bump the graft version in `settle-graft.toml`.
3. Sync into vesl-nockup via `./sync.sh` (or wait for CI's
   sync-verify against `VESL_CORE_PIN`).
4. Re-run the vesl template smoke
   (`tools/test-registry/run-init.sh`) to confirm the composed
   kernel boots and the new arm is reachable.
5. Run the extended `desync_regression.rs` tests against a
   fresh scaffold.

Dedicated commit shape (per `CLAUDE.md` §3): one commit for the
hoon (`settle-graft: %settle-rotate-root + L-09 typed reject`),
one for the SDK builders + signing
(`vesl-core: build_settle_rotate_root_poke`), one for the hull
endpoint (`vesl-hull: POST /rotate`), one for the tests. Each
revertable in isolation per `feedback_rollback_atomic_commits`.

## 6. Out of scope

- The real `%settle-note` plumbing — see
  `docs/AUDIT_C01_REAL_SETTLE.md`. Mostly landed in `877988f`;
  remaining schema work is independent of rotate-root.
- STARK verifier work — see `docs/AUDIT_REPORT.md` §7.
- Multi-hull-per-process (audit §L-08) — orthogonal; rotation
  is per-hull regardless of how many hulls share a process.

## 7. Links

- Audit report: `docs/AUDIT_REPORT.md`
- Companion real-settle doc: `docs/AUDIT_C01_REAL_SETTLE.md`
- Umbrella index: `docs/AUDIT_C01_FOLLOWUP.md`
- Settle-graft source (canonical): `protocol/lib/settle-graft.hoon`
  (mirrored at `vesl-nockup/hoon/lib/settle-graft.hoon`)
- Settle-graft manifest: `protocol/lib/settle-graft.toml`
- Shared dispatch arms: `protocol/lib/kernel-arms.hoon`
- Hull-Rust (consumer): `vesl-nockup/crates/vesl-hull/src/api.rs`
- Settle poke builders:
  `crates/vesl-core/src/graft_pokes/settle.rs`
- Signing helpers: `crates/vesl-core/src/signing.rs`
- Test fixture: `vesl-nockup/templates/vesl/tests/desync_regression.rs`
- Surgical fix commit (real-settle): vesl-nockup `877988f` on
  `hull-lib-factor`
- Kernel JAM regen flow: `CLAUDE.md` §3
