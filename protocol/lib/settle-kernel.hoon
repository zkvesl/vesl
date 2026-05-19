::  settle-kernel.hoon: heavy tier — full settlement, no STARK
::
::  NockApp kernel for Merkle root registration, generic payload
::  verification, and note settlement.  Domain-agnostic: verifies
::  payload integrity via vesl-merkle.verify-payload, then transitions
::  the note from %pending to %settled.  No prompt reconstruction, no
::  manifest semantics — that lives in domain-specific kernels (e.g.
::  hull-llm's vesl-kernel) that wrap this layer.
::
::  Why no tx-engine: sig-hash/tx-id computation pulled in tx-engine-0
::  (71K lines, 135s compile) making the JAR 18MB — same as forge.
::  The Rust hull handles transaction building natively.  Settle stays
::  focused: verify data, settle notes, done.
::
::  Poke causes:
::    [%register hull=@ root=@]  — register a hull's Merkle root
::    [%settle payload=@]          — verify payload + settle note
::    [%verify payload=@]          — verify payload (read-only)
::
::  Compiled: hoonc --new protocol/lib/settle-kernel.hoon hoon/
::  Output:   assets/settle.jam
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
      settled=(set @)
  ==
+$  effect  *
+$  cause
  $%  [%register hull=@ root=@]
      [%settle payload=@]
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
      [%settled note-id=@ ~]
        =/  nid  +<.path
        ``(~(has in settled.state) nid)
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
      ~>  %slog.[3 'settle: invalid cause']
      [~ state]
    ?-  -.u.act
      ::
      ::  %register — store hull root
      ::
        %register
      =/  res  (handle-register registered.state hull.u.act root.u.act 'settle:')
      ?~  res  [~ state]
      :_  state(registered u.res)
      ^-  (list effect)
      ~[[%registered hull.u.act root.u.act]]
      ::
      ::  %settle — verify payload and transition note to %settled
      ::    Guards: root must be registered, note ID must not be settled
      ::
        %settle
      =/  attempt
        %-  mule  |.
        =/  raw  (cue payload.u.act)
        ;;(settlement-payload raw)
      ?:  ?=(%| -.attempt)
        ~>  %slog.[3 'settle: malformed settle payload']
        :_  state
        ^-  (list effect)
        ~[[%settle-error 'settle: malformed payload']]
      =/  args=settlement-payload  p.attempt
      =/  validation
        %-  validate-settlement-args
        [note.args expected-root.args registered.state settled.state %mutate 'settle:']
      ?:  ?=(%.n -.validation)  [~ state]
      =/  ok=?
        %-  verify-payload
        [leaves.args proofs.args expected-root.args]
      ?.  ok
        ~>  %slog.[3 'settle: payload verification failed']
        :_  state
        ^-  (list effect)
        ~[[%settle-error 'settle: payload verification failed']]
      =/  settled-note=[id=@ hull=@ root=@ state=[%settled ~]]
        [id.note.args hull.note.args root.note.args [%settled ~]]
      =/  new-settled  (~(put in settled.state) id.note.args)
      :_  state(settled new-settled)
      ^-  (list effect)
      ~[settled-note]
      ::
      ::  %verify — verify payload (read-only, no state change)
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
        [note.args expected-root.args registered.state settled.state %verify 'settle:']
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
