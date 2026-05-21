::  lib/vesl-gates.hoon: named verification gate catalog (Tier 1a).
::
::  EXPANSION Phase 01.  Library of pre-written `verify-gate` arms
::  users select by name in a settle-graft manifest, replacing hand-
::  written Hoon for the common verification shapes (signatures,
::  structured manifests, set membership).
::
::  Each arm conforms to the post-H-03 verify-gate signature:
::
::    $-([note-id=@ data=* expected-root=@] ?)
::
::  C1 (poke-input hygiene, see vesl-nockup/.dev/OVERVIEW.md):
::  every arm wraps its `;;` cast and verification body in a single
::  `mule` so a malformed `data=*` returns %.n rather than crashing
::  the kernel.  The outer mule in settle-graft.hoon converts any
::  residual crash into %settle-error; gates themselves cannot emit
::  effects (they return ? by signature) so the "must emit
::  %<gate>-error" phrasing in OVERVIEW C1 is satisfied through that
::  outer wrap.  Gate authors: do not introduce bare `?>` or `;;`
::  outside the mule; a crash inside a gate is a kernel DoS surface.
::
::  Tier 1a (this file):
::    sig-verify-ed25519       ed25519 signature on attestation data
::    sig-verify-schnorr       cheetah-curve schnorr signature on attestation data
::    manifest-verify          AND-fold of merkle proofs over named fields
::    set-membership-verify    leaf-in-merkle-tree membership proof
::    bounded-value-verify     numeric value falls in committed [lo, hi]
::
::  Tier 1b (future, demand-gated): threshold-sig-verify, merkle-kv-
::  verify, timelock-verify, commit-reveal-verify.
::  See vesl-nockup/.dev/01_GATE_CATALOG.md for the rollout schedule.
::
::  Binding convention: every gate ties payload data back to
::  `expected-root` via hash-leaf or verify-chunk.  Without that
::  binding, a signature gate would degenerate into a pure oracle
::  (any valid sig over any data passes).  Each arm's docstring
::  states the exact binding it enforces.
::
/+  *vesl-merkle
/=  *  /common/zose
::
|%
::  +sig-verify-ed25519: ed25519-signed attestation against a registered key.
::
::  Payload  : [data=@ sig=@ pubkey=@]
::  Binding  : expected-root = hash-leaf(pubkey)
::             (the hull's commitment IS the public key; the gate
::             enforces that the signature was produced by *that* key)
::  Use case : notarization, signed timestamps, off-chain attestations.
::  Stdlib   : ++veri:ed:crypto from /common/zose.  Returns %.n on
::             oversized atoms (no crash).
::
++  sig-verify-ed25519
  |=  [note-id=@ data=* expected-root=@]
  ^-  ?
  =/  attempt
    %-  mule  |.
    =/  p=[data=@ sig=@ pubkey=@]
      ;;([data=@ sig=@ pubkey=@] data)
    ?&  =((hash-leaf pubkey.p) expected-root)
        (veri:ed:crypto sig.p data.p pubkey.p)
    ==
  ?:  ?=(%| -.attempt)  %.n
  p.attempt
::
::  +sig-verify-schnorr: cheetah-curve schnorr signature on attestation data.
::
::  Payload  : [data=@ sig=@ pubkey=@]
::             - data:    raw attested bytes (any size)
::             - sig:     (chal << 256) | s; both halves are 32 bytes,
::                        bounded by g-order:curve:cheetah
::             - pubkey:  serialized affine point via ser-a-pt:cheetah
::                        (the wallet-export shape)
::  Binding  : expected-root = hash-leaf(pubkey)
::             same convention as sig-verify-ed25519: the hull's
::             commitment IS the serialized pubkey atom.
::  Use case : on-chain Nockchain attestations, intent signing, any
::             flow whose verification will eventually be cross-checked
::             against an on-chain belt-schnorr signature.
::  Stdlib   : verify:affine:schnorr:cheetah from /common/ztd/three
::             (transitively reachable via /common/zose).  Returns %.n
::             on out-of-range chal/sig (no crash).  de-a-pt asserts
::             the recovered point is on-curve via in-g:affine:curve;
::             a malformed pubkey atom triggers that ?> and the outer
::             mule converts it to %.n per C1.
::
++  sig-verify-schnorr
  |=  [note-id=@ data=* expected-root=@]
  ^-  ?
  =/  attempt
    %-  mule  |.
    =/  p=[data=@ sig=@ pubkey=@]
      ;;([data=@ sig=@ pubkey=@] data)
    ?&  =((hash-leaf pubkey.p) expected-root)
        =/  pk=a-pt:curve:cheetah  (de-a-pt:cheetah pubkey.p)
        =/  m=noun-digest:tip5     (hash-leaf-digest data.p)
        =/  chal=@                 (rsh 8 sig.p)
        =/  s=@                    (end 8 sig.p)
        (verify:affine:schnorr:cheetah pk m chal s)
    ==
  ?:  ?=(%| -.attempt)  %.n
  p.attempt
::
::  +manifest-verify: AND-fold of merkle proofs over named fields.
::
::  Payload  : [fields=(list [name=@t value=@])
::              proofs=(list (list [hash=@ side=?]))]
::  Binding  : every (value, proof) pair must verify against
::             expected-root.  Field names are descriptive only --
::             they aid debugging but do not affect verification.
::  Use case : structured-document commitment (KYC bundle, RAG
::             manifest, signed JSON, multi-field attestation).
::
::  Lengths must match.  Mismatch -> %.n.  Empty lists -> %.y
::  (vacuously true; callers should reject empty payloads at the
::  edge if that semantics is unwanted).
::
++  manifest-verify
  |=  [note-id=@ data=* expected-root=@]
  ^-  ?
  =/  attempt
    %-  mule  |.
    =/  p=[fields=(list [name=@t value=@]) proofs=(list (list [hash=@ side=?]))]
      ;;([fields=(list [name=@t value=@]) proofs=(list (list [hash=@ side=?]))] data)
    ?.  =((lent fields.p) (lent proofs.p))  %.n
    =/  fs  fields.p
    =/  ps  proofs.p
    |-
    ?~  fs  %.y
    ?~  ps  %.y
    ?.  (verify-chunk value.i.fs i.ps expected-root)  %.n
    $(fs t.fs, ps t.ps)
  ?:  ?=(%| -.attempt)  %.n
  p.attempt
::
::  +set-membership-verify: prove an element is in a merkle-committed set.
::
::  Payload  : [elem=@ proof=(list [hash=@ side=?])]
::  Binding  : verify-chunk(elem, proof, expected-root) -- elem's
::             leaf-hash is bound to the root via the supplied path.
::  Use case : allowlists, blocklists, voter rosters, membership rolls.
::
::  AUDIT 2026-05-21 L-13: this gate takes the typed sibling-list
::  `proof=(list [hash=@ side=?])` directly — there is no `proof=@`
::  jammed-blob shorthand path. An app that ships a jammed proof must
::  `cue` it at the edge before poking the kernel.
::
++  set-membership-verify
  |=  [note-id=@ data=* expected-root=@]
  ^-  ?
  =/  attempt
    %-  mule  |.
    =/  p=[elem=@ proof=(list [hash=@ side=?])]
      ;;([elem=@ proof=(list [hash=@ side=?])] data)
    (verify-chunk elem.p proof.p expected-root)
  ?:  ?=(%| -.attempt)  %.n
  p.attempt
::
::  +bounded-value-verify: prove a merkle-committed numeric value
::  falls in a committed [lo, hi] interval.
::
::  Payload  : [value=@ bounds=[lo=@ hi=@] proof=(list [hash=@ side=?])]
::  Binding  : verify-chunk's leaf is hash-leaf(jam([value bounds])) --
::             value AND bounds are jammed together so an attacker
::             cannot substitute their own range.  Without bounds in
::             the leaf this would degenerate into "claim any range
::             you like over an attested value."  We pass the raw
::             jam atom to verify-chunk; verify-chunk applies
::             hash-leaf internally (per convention shared with
::             set-membership-verify and manifest-verify).
::  Use case : age gates, balance ranges, score brackets -- any
::             "attested numeric value falls in this interval" check.
::  Stdlib   : gte/lte for the bounds check; jam to canonicalize the
::             leaf payload before hashing; verify-chunk for the
::             merkle path.
::
::  Note: this is NOT a zero-knowledge proof.  `value` is plaintext
::  in the payload.  Real ZK range proofs (Bulletproofs, etc.) are
::  out of scope for the gate catalog -- see EMPIRE track.  The name
::  is `bounded-value-verify` rather than `range-proof-verify`
::  precisely because the latter implies ZK semantics this gate does
::  not provide.
::
::  Edge: lo > hi yields a vacuously-false predicate (gte/lte fail
::  for any value); the gate returns %.n without special-casing.
::
++  bounded-value-verify
  |=  [note-id=@ data=* expected-root=@]
  ^-  ?
  =/  attempt
    %-  mule  |.
    =/  p=[value=@ bounds=[lo=@ hi=@] proof=(list [hash=@ side=?])]
      ;;([value=@ bounds=[lo=@ hi=@] proof=(list [hash=@ side=?])] data)
    ?&  (gte value.p lo.bounds.p)
        (lte value.p hi.bounds.p)
        (verify-chunk (jam [value.p bounds.p]) proof.p expected-root)
    ==
  ?:  ?=(%| -.attempt)  %.n
  p.attempt
--
