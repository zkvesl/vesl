::  protocol/lib/vesl-kernel.hoon: NockApp kernel for settlement + proving
::
::  Proper NockApp kernel with versioned state, poke, peek, and load arms.
::  Poke causes:
::    [%register hull=@ root=@]  — register a hull root
::    [%settle payload=@]          — verify manifest + settle note
::    [%prove  payload=@]          — settle + generate STARK proof
::    [%sig-hash seeds-jam=@ fee=@] — compute sig-hash from seeds + fee
::    [%tx-id spends-jam=@]        — compute tx-id from spends
::
::  The settle/prove payload is a jammed settlement-payload atom.
::  The sig-hash/tx-id pokes use Hoon's tx-engine hashable infrastructure
::  to produce byte-exact hashes for Rust-assembled transactions.
::
::  Security hardening:
::    - %settle/%prove reject unregistered roots (must %register first)
::    - %settle/%prove reject duplicate note IDs (replay protection)
::
::  Dispatcher layout: ++poke is a thin selector over per-cause +handle-*
::    arms.  Handlers live in the enclosing core (the fort mold requires
::    the inner door to expose exactly load/peek/poke), so each handler
::    takes state as its first argument.  Settlement-guard chain lives
::    in kernel-arms.hoon; STARK input prep lives in vesl-stark.hoon.
::
::  Compiled: hoonc --new protocol/lib/vesl-kernel.hoon hoon/
::
/-  *vesl
/+  *rag-logic
/+  *vesl-prover
/+  *vesl-merkle
/+  *kernel-arms
/+  *vesl-stark
/=  *  /common/wrapper
/=  txv1  /common/tx-engine-1
::
=>
|%
::  Kernel state — tracks registered roots and settled notes
::
+$  versioned-state
  $:  %v1
      registered=(map @ @)
      settled=(set @)
  ==
::  Effects the kernel can produce
::
+$  effect  *
::  Causes the kernel accepts
::
+$  cause
  $%  [%register hull=@ root=@]
      [%settle payload=@]
      [%prove payload=@]
      [%sig-hash seeds-jam=@ fee=@]
      [%tx-id spends-jam=@]
      [%diag-cue seeds-jam=@]
      [%diag-sieve seeds-jam=@]
      [%diag-hash seeds-jam=@ fee=@]
  ==
--
|%
++  moat  (keep versioned-state)
::
++  handle-register-arm
  |=  [state=versioned-state act=[%register hull=@ root=@]]
  ^-  [(list effect) versioned-state]
  =/  res  (handle-register registered.state hull.act root.act 'vesl:')
  ?~  res  [~ state]
  :_  state(registered u.res)
  ^-  (list effect)
  ~[[%registered hull.act root.act]]
::
++  handle-settle
  |=  [state=versioned-state act=[%settle payload=@]]
  ^-  [(list effect) versioned-state]
  ::  AUDIT 2026-04-19 M-02: mule-wrap cue + sieve. A malformed
  ::  payload atom or a cell that fails the strict-mold otherwise
  ::  panics the kernel on every attacker poke.
  ::
  =/  parsed
    %-  mule  |.
    =/  raw=*  (cue payload.act)
    ;;(settlement-payload raw)
  ?:  ?=(%| -.parsed)
    ~>  %slog.[3 'vesl: malformed settle payload']
    :_  state
    ^-  (list effect)
    ~[[%settle-error 'vesl: malformed payload']]
  =/  res  (validate-settlement-args p.parsed registered.state settled.state %mutate 'vesl:')
  ?:  ?=(%.n -.res)  [~ state]
  =/  args=settlement-payload  args.res
  =/  result  (settle-note note.args mani.args expected-root.args)
  =/  new-settled  (~(put in settled.state) id.note.args)
  :_  state(settled new-settled)
  ^-  (list effect)
  ~[result]
::
++  handle-prove
  |=  [state=versioned-state act=[%prove payload=@]]
  ^-  [(list effect) versioned-state]
  ::  AUDIT 2026-04-19 M-02: mule-wrap cue + sieve (see handle-settle).
  ::
  =/  parsed
    %-  mule  |.
    =/  raw=*  (cue payload.act)
    ;;(settlement-payload raw)
  ?:  ?=(%| -.parsed)
    ~>  %slog.[3 'vesl: malformed prove payload']
    :_  state
    ^-  (list effect)
    ~[[%prove-error 'vesl: malformed payload']]
  =/  res  (validate-settlement-args p.parsed registered.state settled.state %mutate 'vesl:')
  ?:  ?=(%.n -.res)  [~ state]
  =/  args=settlement-payload  args.res
  =/  result-note  (settle-note note.args mani.args expected-root.args)
  =/  belt-digest=@  (split-and-fold mani.args)
  =/  fs-formula=*  build-fs-formula
  =/  proof-attempt
    %-  mule  |.
    (prove-computation belt-digest fs-formula expected-root.args hull.note.args)
  ?.  -.proof-attempt
    ~>  %slog.[3 'vesl: prove-computation crashed']
    :_  state
    ^-  (list effect)
    ~[[%prove-failed (jam p.proof-attempt)]]
  =/  new-settled  (~(put in settled.state) id.note.args)
  :_  state(settled new-settled)
  ^-  (list effect)
  ~[[result-note p.proof-attempt]]
::
++  handle-sig-hash
  |=  [state=versioned-state act=[%sig-hash seeds-jam=@ fee=@]]
  ^-  [(list effect) versioned-state]
  ::  AUDIT 2026-04-19 H-08: wrap cue+sieve+hash chain in mule so a
  ::  malformed seeds-jam or shape-incompatible noun yields a typed
  ::  error effect instead of crashing the kernel.
  ::
  =/  attempt
    %-  mule  |.
    =/  sds=seeds:txv1  ;;(seeds:txv1 (cue seeds-jam.act))
    ^-  hash:txv1
    %-  hash-hashable:tip5
    [(sig-hashable:seeds:txv1 sds) leaf+fee.act]
  :_  state
  ^-  (list effect)
  ?:  -.attempt
    ~[[%sig-hash p.attempt]]
  ~[[%sig-hash-error (jam p.attempt)]]
::
++  handle-tx-id
  |=  [state=versioned-state act=[%tx-id spends-jam=@]]
  ^-  [(list effect) versioned-state]
  ::  AUDIT 2026-04-19 H-08: mirror handle-sig-hash — mule-wrap
  ::  cue+sieve+hash so malformed spends-jam emits a typed error
  ::  instead of crashing.
  ::
  =/  attempt
    %-  mule  |.
    =/  sps=spends:txv1  ;;(spends:txv1 (cue spends-jam.act))
    ^-  tx-id:txv1
    %-  hash-hashable:tip5
    [leaf+%1 (hashable:spends:txv1 sps)]
  :_  state
  ^-  (list effect)
  ?:  -.attempt
    ~[[%tx-id p.attempt]]
  ~[[%tx-id-error (jam p.attempt)]]
::
++  handle-diag-cue
  |=  [state=versioned-state act=[%diag-cue seeds-jam=@]]
  ^-  [(list effect) versioned-state]
  ::  AUDIT 2026-04-19 H-08: wrap cue in mule — a malformed jam bunt
  ::  otherwise crashes the kernel from this diagnostic arm.
  ::
  =/  attempt  (mule |.((cue seeds-jam.act)))
  :_  state
  ^-  (list effect)
  ?:  -.attempt
    =/  raw=*  p.attempt
    =/  is-cell=?  ?=(^ raw)
    ~[[%diag-cue is-cell raw]]
  ~[[%diag-cue-error (jam p.attempt)]]
::
++  handle-diag-sieve
  |=  [state=versioned-state act=[%diag-sieve seeds-jam=@]]
  ^-  [(list effect) versioned-state]
  ::  AUDIT 2026-04-19 H-08: bring cue inside mule — the earlier wrap
  ::  protected the sieve but not the cue, so a malformed jam still
  ::  crashed before reaching the sieve.
  ::
  =/  attempt
    %-  mule  |.
    ;;(seeds:txv1 (cue seeds-jam.act))
  :_  state
  ^-  (list effect)
  ?:  -.attempt
    ~[[%diag-sieve %fail (jam p.attempt)]]
  ~[[%diag-sieve %ok ~]]
::
++  handle-diag-hash
  |=  [state=versioned-state act=[%diag-hash seeds-jam=@ fee=@]]
  ^-  [(list effect) versioned-state]
  ::  AUDIT 2026-04-19 H-08: pull the cue+sieve into the mule — an
  ::  outer ;;(seeds:txv1 ...) on a malformed cue crashes before the
  ::  hash attempt had a chance to catch.
  ::
  =/  attempt
    %-  mule  |.
    =/  sds=seeds:txv1  ;;(seeds:txv1 (cue seeds-jam.act))
    %-  hash-hashable:tip5
    [(sig-hashable:seeds:txv1 sds) leaf+fee.act]
  ?:  -.attempt
    :_  state
    ^-  (list effect)
    ~[[%diag-hash %ok p.attempt]]
  :_  state
  ^-  (list effect)
  ~[[%diag-hash %fail (jam p.attempt)]]
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
    ==
  ::
  ++  poke
    |=  =ovum:moat
    ^-  [(list effect) _state]
    =/  act  ((soft cause) cause.input.ovum)
    ?~  act
      ~>  %slog.[3 'vesl: invalid cause']
      [~ state]
    ?-  -.u.act
      %register    (handle-register-arm state u.act)
      %settle      (handle-settle state u.act)
      %prove       (handle-prove state u.act)
      %sig-hash    (handle-sig-hash state u.act)
      %tx-id       (handle-tx-id state u.act)
      %diag-cue    (handle-diag-cue state u.act)
      %diag-sieve  (handle-diag-sieve state u.act)
      %diag-hash   (handle-diag-hash state u.act)
    ==
  --
--
((moat |) inner)
