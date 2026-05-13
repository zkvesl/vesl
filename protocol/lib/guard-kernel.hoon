::  guard-kernel.hoon: mid tier — commitment + verification
::
::  NockApp kernel for Merkle root registration, chunk verification,
::  and full manifest verification.  No settlement state transitions,
::  no STARK proofs, no tx-engine.
::
::  Keep guard: verify data integrity without settling.
::
::  Poke causes:
::    [%register hull=@ root=@]  — register a hull's Merkle root
::    [%verify payload=@]          — verify manifest against registered root
::
::  The verify payload is a jammed settlement-payload (reuses the type
::  for compatibility, but only reads the manifest + root fields).
::
::  Compiled: hoonc --new protocol/lib/guard-kernel.hoon hoon/
::  Output:   assets/guard.jam
::
/-  *vesl
/+  *rag-logic
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
      ::  %verify — verify manifest against registered root
      ::    Guard: root must be registered
      ::    Returns [%verified ok=?] — no state change
      ::
        %verify
      =/  parsed  (parse-payload payload.u.act)
      ?~  parsed
        :_  state
        ^-  (list effect)
        ~[[%verified %.n]]
      =/  res  (validate-settlement-args u.parsed registered.state ~ %verify 'guard:')
      ?:  ?=(%.n -.res)
        :_  state
        ^-  (list effect)
        ~[[%verified %.n]]
      =/  args=settlement-payload  args.res
      =/  ok=?  (verify-manifest mani.args expected-root.args)
      :_  state
      ^-  (list effect)
      ~[[%verified ok]]
    ==
  --
--
((moat |) inner)
