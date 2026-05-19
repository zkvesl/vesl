::  guard-kernel.hoon: mid tier — commitment + verification
::
::  NockApp kernel for Merkle root registration and generic payload
::  verification.  Domain-agnostic: verifies that each leaf in the
::  payload has a Merkle proof leading to the registered root.  No
::  semantic interpretation of leaf contents (that lives in the
::  application layer or in a domain-specific kernel that wraps this).
::
::  Keep guard: verify data integrity without settling.
::
::  Poke causes:
::    [%register hull=@ root=@]  — register a hull's Merkle root
::    [%verify payload=@]          — verify payload against registered root
::
::  The verify payload is a jammed settlement-payload (reuses the type
::  for compatibility; only the leaves/proofs/expected-root fields are
::  read for verification).
::
::  Compiled: hoonc --new protocol/lib/guard-kernel.hoon hoon/
::  Output:   assets/guard.jam
::
/-  *vesl
/+  *vesl-merkle
/+  *kernel-arms
/=  *  /common/wrapper
::
=>
|%
+$  versioned-state
  $:  %v1
      registered=(map @ @)
  ==
+$  effect  *
+$  cause
  $%  [%register hull=@ root=@]
      [%verify payload=@]
  ==
--
|%
++  moat  (keep versioned-state)
::
++  inner
  |_  state=versioned-state
  ::
  ++  load
    |=  old-state=versioned-state
    ^-  _state
    old-state
  ::
  ++  peek
    |=  =path
    ^-  (unit (unit *))
    ?+  path  ~
      [%registered hull=@ ~]
        =/  vid  +<.path
        ``(~(has by registered.state) vid)
      ::
      [%root hull=@ ~]
        =/  vid  +<.path
        ``(~(get by registered.state) vid)
    ==
  ::
  ++  poke
    |=  =ovum:moat
    ^-  [(list effect) _state]
    =/  act  ((soft cause) cause.input.ovum)
    ?~  act
      ~>  %slog.[3 'guard: invalid cause']
      [~ state]
    ?-  -.u.act
      ::
      ::  %register — store hull root
      ::
        %register
      =/  res  (handle-register registered.state hull.u.act root.u.act 'guard:')
      ?~  res  [~ state]
      :_  state(registered u.res)
      ^-  (list effect)
      ~[[%registered hull.u.act root.u.act]]
      ::
      ::  %verify — verify payload against registered root
      ::    Guard: root must be registered
      ::    Returns [%verified ok=?] — no state change
      ::
        %verify
      =/  attempt
        %-  mule  |.
        =/  raw  (cue payload.u.act)
        ;;(settlement-payload raw)
      ?:  ?=(%| -.attempt)
        :_  state
        ^-  (list effect)
        ~[[%verified %.n]]
      =/  args=settlement-payload  p.attempt
      =/  validation
        %-  validate-settlement-args
        [note.args expected-root.args registered.state ~ %verify 'guard:']
      ?:  ?=(%.n -.validation)
        :_  state
        ^-  (list effect)
        ~[[%verified %.n]]
      =/  ok=?
        %-  verify-payload
        [leaves.args proofs.args expected-root.args]
      :_  state
      ^-  (list effect)
      ~[[%verified ok]]
    ==
  --
--
((moat |) inner)
