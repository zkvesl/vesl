::  protocol/lib/vesl-entrypoint.hoon: ABI Boundary for the Vesl ZK-Prover
::
::  STAGED: canonical ABI placeholder. Imported only by
::  protocol/tests/{cross-vm,test-entrypoint}.hoon today; no shipped
::  kernel composes it yet. Kept here so future kernel work can adopt
::  the entrypoint shape without re-deriving it. See README "Graft
::  catalog" for the support-library status note.
::
::  Universal entrypoint gate. Accepts a single jammed atom (@)
::  from the off-chain Rust Hull, deserializes via cue, validates
::  via strict mold (;;), and runs settlement logic.
::
::  ABI contract: Rust sends  jam([note manifest root])
::  This gate: cue -> mold -> settle -> settled note or crash
::
::  Defense-in-depth: malformed payloads crash at the mold boundary
::  BEFORE reaching any logic gates. The Nock VM enforces this.
::
/-  *vesl
/+  *rag-logic
::
|%
::
::  Local RAG-flavored payload shape.  Wraps a manifest (vs. the
::  generic leaves/proofs lists in sur/vesl.hoon's settlement-payload)
::  so rag-logic.settle-note can consume it directly.  Moves to
::  hull-llm/protocol/sur/rag.hoon in the architectural-split refactor's
::  Phase 4.
::
+$  rag-settlement-payload
  $:  note=[id=@ hull=@ root=@ state=[%pending ~]]
      mani=manifest
      expected-root=@
  ==
::
::  +vesl-entrypoint: universal ABI wrapper
::
::  Single atom in, settled note out (or crash).
::  Three-phase pipeline:
::    1. cue: deserialize jammed atom to raw noun
::    2. ;;:  strict mold — validate noun structure against
::           rag-settlement-payload type. Crashes on any mismatch.
::    3. settle-note: verify manifest + transition state
::
++  vesl-entrypoint
  |=  payload=@
  ^-  [id=@ hull=@ root=@ state=[%settled ~]]
  =/  raw=*  (cue payload)
  =/  args=rag-settlement-payload  ;;(rag-settlement-payload raw)
  (settle-note note.args mani.args expected-root.args)
--
