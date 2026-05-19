::  protocol/lib/vesl-stark.hoon: STARK input preparation for vesl-kernel
::
::  Two arms extracted from vesl-kernel.hoon's %prove body so the kernel
::  dispatcher fits on one screen.  See audit §3.1.
::
::    +split-and-fold   manifest -> single Goldilocks field element.
::                      Belt-decomposes text fields, Horner-folds.
::    +build-fs-formula 64-nested-increment Nock formula proved per call.
::
::  STARK semantics live with vesl-prover.hoon; this file is the
::  pre-prover shaping that the kernel hands the prover.
::
/-  *vesl
/+  *vesl-merkle
|%
::  +split-and-fold: prepare the STARK subject from a manifest.
::
::    Each manifest text field (query, output, prompt, every chunk dat)
::    is split into 7-byte field-element belts via split-to-belts,
::    welded in canonical order, then Horner-folded to a single
::    Goldilocks element.  Cells cannot be STARK subjects (the memory
::    table can't represent cell nodes), so we collapse to an atom.
::    Root + hull binding is the prover's Fiat-Shamir job; this fold
::    only commits to manifest content.  See vesl-prover.hoon.
::
++  split-and-fold
  |=  mani=manifest
  ^-  @
  =/  qb=(list @)  (split-to-belts query.mani)
  =/  ob=(list @)  (split-to-belts output.mani)
  =/  pb=(list @)  (split-to-belts prompt.mani)
  =/  chunk-belts=(list @)
    =|  acc=(list @)
    =/  res  results.mani
    |-
    ?~  res  (flop acc)
    $(acc (weld (flop (split-to-belts dat.chunk.i.res)) acc), res t.res)
  =/  all-belts=(list @)
    (weld qb (weld ob (weld pb chunk-belts)))
  ::  Goldilocks prime: 2^64 - 2^32 + 1
  ::
  =/  p=@  (add (sub (bex 64) (bex 32)) 1)
  ::  AUDIT 2026-04-19 C-lead-3: Horner polynomial fold. Plain sum
  ::  mod p is commutative, so the STARK subject would not
  ::  distinguish belt permutations. base = 2^56 > max belt (7 bytes)
  ::  keeps the fold order-sensitive. `b` is accumulator; `a` is the
  ::  current belt (per `roll`'s gate convention).
  ::
  =/  base=@  (bex 56)
  %+  roll  all-belts
  |=  [a=@ b=@]
  (mod (add (mul b base) a) p)
::  +build-fs-formula: produce the Fiat-Shamir formula noun.
::
::    Hand-crafted 64-nested-increment [4 [4 [4 ... [4 [0 1]]]]] bound
::    to the Fiat-Shamir transcript via vesl-prover.  Do not edit
::    without coordinated cross-VM prove->verify (see C-lead-1 below).
::
++  build-fs-formula
  ^-  *
  ::  TODO: AUDIT 2026-04-17 C-lead-1 — STARK formula hardcoding
  ::
  ::  The proved formula below is a hardcoded 64-nested-increment
  ::  `[4 [4 [4 ... [4 [0 1]]]]]`. No version tag, no length prefix,
  ::  no explicit commitment to the formula shape is absorbed into
  ::  the Fiat-Shamir transcript beyond the root/hull digests set by
  ::  vesl-prover. If the Rust prover's opcode count or structure
  ::  silently drifts (refactor, jet change, upstream nockvm update),
  ::  the verifier could accept a STARK that proves a *different*
  ::  formula without raising an error.
  ::
  ::  Suggested fix (requires STARK-fluent reviewer):
  ::    Hash the formula noun and absorb the digest into the
  ::    Fiat-Shamir transcript before challenge derivation, or
  ::    prepend a version tag to the proof header. Do not edit
  ::    this site without cross-VM prove->verify on a perturbed
  ::    formula to confirm binding holds.
  ::
  ::  See .dev/CRITICAL_LEADS.md.
  ::
  =/  f=*  [0 1]
  =|  i=@
  |-
  ?:  =(i 64)  f
  $(f [4 f], i +(i))
--
