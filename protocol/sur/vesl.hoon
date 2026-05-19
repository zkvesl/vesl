::  sur/vesl.hoon: Verified-RAG core data structures
::
::  Tier 1-4 types for the Hull architecture.
::  Designed for ZK-circuit translation via Zorp ZKVM.
::  All hash fields are bare @ for minimal prover overhead.
::
|%
::  Tier 1: Storage
::
+$  chunk-id  @
+$  chunk  [id=chunk-id dat=@t]
+$  merkle-root  @
+$  proof-node  [hash=@ side=?]
+$  merkle-proof  (list proof-node)
::
::  Tier 2: Local Inference
::
+$  retrieval
  $:  =chunk
      proof=merkle-proof
      score=@ud
  ==
+$  manifest
  $:  query=@t
      results=(list retrieval)
      prompt=@t
      output=@t
      page=@ud
  ==
::
::  Tier 3: Nock-Prover
::
+$  nock-zkp
  $:  root=merkle-root
      prf=@
      stamp=@da
  ==
::
::  Tier 4: Settlement
::
+$  hull-id  @
+$  note-state
  $%  [%pending ~]
      [%verified p=nock-zkp]
      [%settled ~]
  ==
+$  note
  $:  id=@
      hull=hull-id
      root=merkle-root
      state=note-state
  ==
::
::  Tier 5: ABI Boundary
::
::  The strict type for cross-runtime settlement payloads.
::  Defines the exact noun structure the Rust Hull must produce.
::
::  Domain-agnostic.  `leaves` is the list of raw data atoms the caller
::  is attesting are bound to the Merkle root; `proofs` is the parallel
::  list of sibling-hash chains.  Each (leaf, proof) pair must verify
::  against expected-root via vesl-merkle.verify-payload.
::
::  Domain-specific verifiers (e.g. RAG manifest verification in
::  hull-llm) define their own extended payload type that wraps a
::  manifest noun, and convert it to (leaves, proofs) before passing
::  through to the generic guard/settle kernels — or compose their
::  own kernel that operates on their domain type directly.
::
+$  settlement-payload
  $:  note=[id=@ hull=@ root=@ state=[%pending ~]]
      leaves=(list @t)
      proofs=(list merkle-proof)
      expected-root=@
  ==
--
