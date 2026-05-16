# C-01 Follow-Up — Root Rotation (Audit Fix 2)

Companion to `docs/AUDIT_REPORT.md` §2.C-01 remediation option 2.
The surgical Rust-only fix landed on `parametize-3` and made the
hull / hull-llm honest about kernel rejection — they now return 409
Conflict instead of silently overwriting local state. What that fix
does **not** address is the underlying constraint: each hull
process can register exactly one root in its lifetime. Operators
who want to rotate a hull's root without restarting the process
need a new kernel primitive.

This doc captures the design surface that next session needs to
resolve.

## 1. Current state

- `protocol/lib/settle-kernel.hoon:34-38` lists three valid causes:
  `%register`, `%settle`, `%verify`. No rotation primitive exists.
- `handle-register` at `protocol/lib/kernel-arms.hoon:17-23` rejects
  duplicates with `~` (empty `unit`). The kernel arm at
  `settle-kernel.hoon:79-84` translates `~` into `[~ state]` — no
  effect emitted, state unchanged. The Rust hull infers rejection
  from `effects.is_empty()` (audit C-01 surgical fix).
- The infer-by-emptiness path works but is brittle: it conflates
  "kernel didn't respond" (5xx) with "kernel responded by rejecting"
  (4xx). The audit's §3.L-09 flagged this; this doc bundles the L-09
  emission work with the rotate-root design because they touch the
  same arms.

## 2. Proposed kernel surface

### 2.1 New cause: `%rotate-root`

Add a fourth cause to `settle-kernel.hoon:34-38`:

```
+$  cause
  $%  [%register hull=@ root=@]
      [%rotate-root hull=@ old-root=@ new-root=@ sig=@]
      [%settle payload=@]
      [%verify payload=@]
  ==
```

Semantics (conceptually the inverse of `handle-register`):

1. Look up `registered.get(hull)`. If absent → emit
   `[%rotate-rejected hull %not-registered]` and return.
2. If `registered.get(hull) != old-root` → emit
   `[%rotate-rejected hull %old-root-mismatch]` and return.
3. Verify `sig` over `(hull, old-root, new-root)` against the
   designated rotation pubkey (see §2.3).
4. On verify failure → emit `[%rotate-rejected hull %bad-sig]`
   and return.
5. Otherwise, swap `registered.put(hull, new-root)`, emit BOTH
   `[%revoked hull old-root]` and `[%registered hull new-root]`
   so Rust callers see the full transition pair.

### 2.2 New peek path

`settle-kernel.hoon:55-66` already exposes `[%root hull=@ ~]`
returning `(unit @)`. No new peek needed; callers can re-read the
post-rotation root through the existing path.

### 2.3 Auth model — the open question

Two viable designs; pick one before implementing:

**Option A — Per-hull rotation pubkey.** `%register` grows a
fourth field: `rotation-pk`. The kernel state shape becomes
`registered=(map @ [root=@ rotation-pk=@])`. Most isolated: each
hull's rotation key is independent and gets pinned at registration.
Downside: doubles the register payload, and the operator has to
remember to set the rotation key when they first register.

**Option B — Global operator key.** Kernel state grows an
`operator-pk=@` field set at boot via a `--operator-pubkey`
flag. Single key authorises every hull's rotation. Simpler but
couples every hull's rotation lifecycle to one operator.

Recommended: **Option A**. The hull-id model is already per-hull
(each process is hull_id=1 by convention); the rotation key
should match that granularity so a compromised operator key
can't rotate every hull at once.

### 2.4 New effect tags

In addition to the existing `%registered`, three new tags:

- `[%revoked hull=@ root=@]` — emitted alongside `%registered`
  on a successful rotation, gives Rust callers an explicit
  signal for the "old root is no longer valid" half of the
  transition.
- `[%rotate-rejected hull=@ reason=?(%not-registered %old-root-mismatch %bad-sig)]`
  — emitted on rotation failures so Rust callers can return
  the right 4xx (404 for not-registered, 409 for mismatch, 403
  for bad-sig).
- `[%register-rejected hull=@ existing-root=@]` — see §3 below.

## 3. L-09 emission (bundled here)

The audit's §3.L-09 noted that `handle-register` is silent on
duplicate. While we're touching `kernel-arms.hoon` and
`settle-kernel.hoon` for rotation, fix L-09 in the same session:

- Change `handle-register` to return a discriminant:
  `[%.y new-map]` on insert, `[%.n %already-registered]` on duplicate.
- Update the `%register` kernel arm to emit
  `[%register-rejected hull=@ existing-root=@]` on the failure
  path so Rust callers can pattern-match on the explicit tag
  instead of inferring rejection from an empty effect list.
- Keep the empty-effects check in vesl-core hull + hull-llm as
  belt-and-suspenders for one revision cycle; remove once both
  consumers have pulled the new kernel rev.

## 4. Rust side

After the kernel work:

- `vesl_core::noun_builder`: add
  `build_rotate_root_poke(hull, old_root, new_root, sig)`.
- `vesl_core` signing helpers: a `sign_rotate_root(sk, hull,
  old_root, new_root)` that produces the `sig` field with the
  same Schnorr-over-Cheetah convention as the existing settlement
  signature.
- Hull (`hull/src/api.rs`): a new `POST /rotate` endpoint accepting
  `{ old_root, new_root, sig }`. Returns 200 on
  `[%revoked, %registered]` effect pair; 404 / 409 / 403 on the
  three rejection variants.
- hull-llm (`hull-llm/src/api.rs`): same `POST /rotate` shape if
  the use case calls for it; defer until a concrete operator need
  surfaces.
- Tests: extend `hull/tests/desync_regression.rs` with rotate-root
  golden / rejection paths.

## 5. Kernel JAM regen flow

Per `CLAUDE.md` §3, every kernel touch requires:

1. `hoonc --new protocol/lib/settle-kernel.hoon hoon/`
2. `mv out.jam assets/settle.jam`
3. `cd assets && sha256sum guard.jam mint.jam settle.jam > CHECKSUMS.sha256`
4. `scripts/check-jam.sh` — must return all-green.
5. Dedicated commit: `sync kernel JAM artifacts with source` —
   never bundle with Rust edits.

CI's `jam-determinism.yml` gates the same assertion on every PR.

## 6. Out of scope

- The real `%settle` plumbing — see `docs/AUDIT_C01_REAL_SETTLE.md`.
- STARK verifier work — see `docs/AUDIT_REPORT.md` §7.

## 7. Links

- Audit report: `docs/AUDIT_REPORT.md`
- Companion real-settle doc: `docs/AUDIT_C01_REAL_SETTLE.md`
- Umbrella index: `docs/AUDIT_C01_FOLLOWUP.md`
- Settle kernel source: `protocol/lib/settle-kernel.hoon`
- Shared dispatch arms: `protocol/lib/kernel-arms.hoon`
- Kernel JAM regen flow: `CLAUDE.md` §3
- Surgical fix commits on `parametize-3`: `git log --grep '§2.C-01'`
