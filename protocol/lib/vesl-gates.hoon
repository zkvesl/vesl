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
::    manifest-verify          AND-fold of merkle proofs over named fields
::    set-membership-verify    leaf-in-merkle-tree membership proof
::
::  Tier 1b (future, demand-gated): sig-verify-schnorr, range-proof-
::  verify, threshold-sig-verify, merkle-kv-verify, timelock-verify,
::  commit-reveal-verify.  See vesl-nockup/.dev/01_GATE_CATALOG.md
::  for the rollout schedule.  Schnorr in particular needs cheetah-
::  curve typing settled (Nockchain's on-chain schnorr is
::  `belt-schnorr:cheetah`, not the BIP-340 secp256k1 form in zose),
::  so its payload shape and stdlib selection are deferred.
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
::  Note: catalog's `proof=@` shorthand resolves to the typed
::  sibling-list here, avoiding an extra `cue` step inside the gate.
::  Apps that ship jammed proofs should cue them at the edge before
::  poking the kernel.
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
--
