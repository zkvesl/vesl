::  lib/forge-graft.hoon: stateless STARK proving for single-leaf commits
::
::  The Graft is a library, not a kernel. It provides:
::    1. A poke dispatcher for %forge-prove
::    2. No state, no peek — forge is one-shot. Each %forge-prove
::       hashes the data, generates a STARK proof over the hashing
::       computation, and emits the proof as an effect. Nothing
::       persists.
::
::  Forge is the heaviest commitment tier:
::    mint-graft  — commit a root under a hull-id. No verify.
::    guard-graft — commit + leaf-hash verification. No proof.
::    settle-graft  — full verify-gate lifecycle with replay protection.
::    forge-graft — same leaf-hash as guard, plus a STARK proof over
::                  the hashing. Pair with a stateful graft (usually
::                  settle-graft) for registration-check semantics;
::                  forge itself trusts the caller's hull/note-id.
::
::  The proof is bound to `hull` and `root = hash-leaf(data)` via the
::  Fiat-Shamir transcript inside prove-computation. Modifying either
::  after proof generation invalidates all FRI challenges.
::
::  Usage:
::    /+  *forge-graft
::    ...your kernel...
::    ?+  -.cause  [~ state]
::      %forge-prove  [(forge-poke cause) state]
::    ==
::
/+  *vesl-merkle
/+  *vesl-prover
/+  *vesl-lower
|%
::  +$forge-effect: effects the Graft can produce
::
+$  forge-effect
  $%  [%forge-proved hull=@ note-id=@ proof=*]
      [%forge-error msg=@t]
  ==
::
::  +$forge-cause: tagged pokes the Graft handles
::
+$  forge-cause
  $%  [%forge-prove hull=@ note-id=@ data=@]
  ==
::
::  +forge-poke: dispatch a forge cause
::
::  No state — forge is pure (modulo the randomness the prover
::  mixes in). Returns an effects list; callers keep their own state
::  untouched when threading the result.
::
::  AUDIT 2026-05-21 L-11: forge-poke does NOT check that the cause's
::  `hull` / `note-id` reference a registered root — forge is stateless
::  by construction (see the file header). A composer that needs
::  registration enforcement must pair forge-graft with a stateful
::  graft, e.g. settle-graft, which holds the registered-roots set.
::
++  forge-poke
  |=  cause=forge-cause
  ^-  (list forge-effect)
  ?-  -.cause
    ::
    ::  %forge-prove — hash the data, generate a STARK proof
    ::
    ::  root = hash-leaf(data) — the commitment this proof attests to.
    ::  The subject is a belt-folded representation of data (each
    ::  belt < Goldilocks prime p = 2^64 - 2^32 + 1). The formula
    ::  is a fixed 64-nested-increment pattern matching the existing
    ::  forge-kernel: prove-computation only requires correct Nock VM
    ::  execution, not a specific program shape.
    ::
      %forge-prove
    =/  root=@  (hash-leaf data.cause)
    =/  belts=(list @)  (split-to-belts data.cause)
    =/  p=@  (add (sub (bex 64) (bex 32)) 1)
    ::  AUDIT 2026-04-19 C-lead-3: polynomial (Horner) fold so permutations
    ::  of `belts` produce distinct subjects. base = 2^56 is strictly
    ::  greater than max belt value (7 bytes = 56 bits), keeping the fold
    ::  injective on reorderings. `b` is the accumulator, `a` is the
    ::  current belt element (per `roll`'s gate convention).
    ::
    =/  base=@  (bex 56)
    =/  subject=@
      %+  roll  belts
      |=  [a=@ b=@]
      (mod (add (mul b base) a) p)
    =/  formula=*
      =/  f=*  [0 1]
      =|  i=@
      |-
      ?:  =(i 64)  f
      $(f [4 f], i +(i))
    ::  mule catches prover crashes so the kernel emits a diagnostic
    ::  effect instead of bricking on a failed prove attempt.
    ::
    =/  attempt
      %-  mule  |.
      (prove-computation subject formula root hull.cause)
    ?.  -.attempt
      ~[[%forge-error 'forge-graft: prove-computation crashed']]
    ::  AUDIT 2026-05-25 H-23: sieve the inner +each discriminator.
    ::  A clean [%| %too-big ...] prover error has -.attempt=%.y
    ::  (the mule didn't crash) but p.attempt is the error variant,
    ::  not a proof. Without this guard the kernel emits the err-noun
    ::  as if it were a proof. Same bug class as production C-03
    ::  (forge-kernel.hoon:329); kept the wording symmetric.
    ::
    ?.  ?=(%& -.p.attempt)
      ~[[%forge-error 'forge-graft: prover returned error variant']]
    ~[[%forge-proved hull.cause note-id.cause +.p.attempt]]
  ==
--
