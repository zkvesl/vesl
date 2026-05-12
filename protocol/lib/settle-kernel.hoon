::  settle-kernel.hoon: heavy tier — full settlement, no STARK
::
::  NockApp kernel for Merkle root registration, manifest verification,
::  and note settlement.  Everything vesl-kernel.hoon does, minus the
::  STARK prover and tx-engine.  Settlement is where soft state becomes
::  hard record.
::
::  Why no tx-engine: sig-hash/tx-id computation pulled in tx-engine-0
::  (71K lines, 135s compile) making the JAR 18MB — same as forge.
::  The Rust hull handles transaction building natively.  Settle stays
::  focused: verify data, settle notes, done.
::
::  Poke causes:
::    [%register hull=@ root=@]  — register a hull's Merkle root
::    [%settle payload=@]          — verify manifest + settle note
::    [%verify payload=@]          — verify manifest (read-only)
::
::  Compiled: hoonc --new protocol/lib/settle-kernel.hoon hoon/
::  Output:   assets/settle.jam
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
      ::  %settle — verify manifest and transition note to %settled
      ::    Guards: root must be registered, note ID must not be settled
      ::
        %settle
      ::  AUDIT 2026-04-19 M-02: mule-wrap cue + sieve so a malformed
      ::  payload atom emits a typed error instead of panicking.
      ::
      =/  parsed
        %-  mule  |.
        =/  raw=*  (cue payload.u.act)
        ;;(settlement-payload raw)
      ?:  ?=(%| -.parsed)
        ~>  %slog.[3 'settle: malformed settle payload']
        :_  state
        ^-  (list effect)
        ~[[%settle-error 'settle: malformed payload']]
      =/  res  (validate-settlement-args p.parsed registered.state settled.state %mutate 'settle:')
      ?:  ?=(%.n -.res)  [~ state]
      =/  args=settlement-payload  args.res
      =/  result  (settle-note note.args mani.args expected-root.args)
      =/  new-settled  (~(put in settled.state) id.note.args)
      :_  state(settled new-settled)
      ^-  (list effect)
      ~[result]
      ::
      ::  %verify — verify manifest (read-only, no state change)
      ::
        %verify
      ::  AUDIT 2026-04-19 M-02: mule-wrap cue + sieve. %verify is a
      ::  read-only soft preflight — crashing on malformed payload
      ::  contradicts the contract for polling callers.
      ::
      =/  parsed
        %-  mule  |.
        =/  raw=*  (cue payload.u.act)
        ;;(settlement-payload raw)
      ?:  ?=(%| -.parsed)
        :_  state
        ^-  (list effect)
        ~[[%verified %.n]]
      =/  res  (validate-settlement-args p.parsed registered.state settled.state %verify 'settle:')
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
