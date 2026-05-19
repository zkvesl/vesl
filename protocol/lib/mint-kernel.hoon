::  mint-kernel.hoon: lightest tier — commitment only
::
::  NockApp kernel for Merkle root registration and leaf hashing.
::  No verification, no settlement, no STARK, no tx-engine.
::  Just math and a map.
::
::  Poke causes:
::    [%register hull=@ root=@]  — register a hull's Merkle root
::    [%hash-leaf dat=@]           — hash raw data, return tip5 digest
::
::  Compiled: hoonc --new protocol/lib/mint-kernel.hoon hoon/
::  Output:   assets/mint.jam
::
/+  *vesl-mint
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
      [%hash-leaf dat=@]
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
      ~>  %slog.[3 'mint: invalid cause']
      [~ state]
    ?-  -.u.act
      ::
      ::  %register — store hull root
      ::
        %register
      =/  res  (handle-register registered.state hull.u.act root.u.act 'mint:')
      ?~  res  [~ state]
      :_  state(registered u.res)
      ^-  (list effect)
      ~[[%registered hull.u.act root.u.act]]
      ::
      ::  %hash-leaf — hash raw data, return digest
      ::
        %hash-leaf
      =/  h=@  (hash-leaf dat.u.act)
      :_  state
      ^-  (list effect)
      ~[[%hashed h]]
    ==
  --
--
((moat |) inner)
