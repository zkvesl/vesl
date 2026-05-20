::  forge-kernel.hoon: STARK tier — generic Merkle verification + proving
::
::  NockApp kernel for domain-agnostic STARK proof generation.
::  Verifies leaf-level Merkle inclusion proofs, then proves correct
::  Nock execution via the STARK prover.  No domain types.  Ship the JAM,
::  developer never touches Hoon.
::
::  Poke causes:
::    [%register hull=@ root=@]  — register a hull's Merkle root
::    [%settle payload=@]         — verify leaves + settle note
::    [%verify payload=@]         — verify leaves (read-only)
::    [%prove payload=@]          — verify + STARK proof + settle
::
::  Compiled: hoonc --new protocol/lib/forge-kernel.hoon hoon/
::  Output:   assets/forge.jam
::
/+  *vesl-merkle
/+  *vesl-prover
/=  *  /common/wrapper
::
=>
|%
::  AUDIT 2026-05-19 H-01: state carries epoch-rotation fields so the
::  `settled` set stays bounded (see settle-graft.hoon). The `%v1` tag
::  is unchanged but the tuple is wider — a pre-H-01 snapshot does not
::  resume into this shape; rebuild boots fresh.
::
+$  versioned-state
  $:  %v1
      epoch=@
      registered=(map @ @)
      settled=(set @)
      settle-count=@
      prior-settled=(set @)
  ==
+$  effect  *
+$  forge-payload
  $:  note=[id=@ hull=@ root=@ state=[%pending ~]]
      leaves=(list [dat=@ proof=(list [hash=@ side=?])])
      expected-root=@
  ==
+$  cause
  $%  [%register hull=@ root=@]
      [%settle payload=@]
      [%verify payload=@]
      [%prove payload=@]
  ==
::  AUDIT 2026-05-19 H-01: capacity caps + settled-set rotation.
::  forge-kernel does not import kernel-arms, so these mirror the
::  settle-graft.hoon constants locally.
::
++  registered-cap  ^~((mul 10.000 1.000))
++  epoch-cap  ^~((mul 1.000 1.000))
::  +settle-id: record `id` in the settled set, rotating the epoch
::  (prior-settled := settled, settled := {id}) once the current epoch
::  is at capacity so kernel state stays bounded.
::
++  settle-id
  |=  [st=versioned-state id=@]
  ^-  versioned-state
  ?.  (gte settle-count.st epoch-cap)
    st(settled (~(put in settled.st) id), settle-count +(settle-count.st))
  ~>  %slog.[3 'forge: settled set rotated (epoch advance)']
  %=  st
    epoch          +(epoch.st)
    prior-settled  settled.st
    settled        (~(put in *(set @)) id)
    settle-count   1
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
        ``|((~(has in settled.state) nid) (~(has in prior-settled.state) nid))
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
      ~>  %slog.[3 'forge: invalid cause']
      [~ state]
    ?-  -.u.act
      ::
      ::  %register — store hull root
      ::
        %register
      ?:  (~(has by registered.state) hull.u.act)
        ~>  %slog.[3 'forge: hull already registered']
        [~ state]
      ::  AUDIT 2026-05-19 H-01: reject once registered is at capacity.
      ::
      ?:  (gte ~(wyt by registered.state) registered-cap)
        ~>  %slog.[3 'forge: registered map at capacity']
        [~ state]
      =/  new-reg  (~(put by registered.state) hull.u.act root.u.act)
      :_  state(registered new-reg)
      ^-  (list effect)
      ~[[%registered hull.u.act root.u.act]]
      ::
      ::  %settle — verify all leaves and transition note to %settled
      ::    Guards: root registered, root match, no replay
      ::
        %settle
      ::  AUDIT 2026-04-19 M-02: mule-wrap cue + sieve so malformed
      ::  payload yields a typed error instead of panicking.
      ::
      =/  parsed
        %-  mule  |.
        =/  raw=*  (cue payload.u.act)
        ;;(forge-payload raw)
      ?:  ?=(%| -.parsed)
        ~>  %slog.[3 'forge: malformed settle payload']
        :_  state
        ^-  (list effect)
        ~[[%settle-error 'forge: malformed payload']]
      =/  args=forge-payload  p.parsed
      ::  Guard: reject unregistered roots
      ::
      ?.  (~(has by registered.state) hull.note.args)
        ~>  %slog.[3 'forge: root not registered']
        [~ state]
      ::  Guard: expected root must match registered root
      ::
      ?.  =(expected-root.args (~(got by registered.state) hull.note.args))
        ~>  %slog.[3 'forge: root mismatch']
        [~ state]
      ::  Guard: note header root must match expected root (H-07)
      ::
      ?.  =(root.note.args expected-root.args)
        ~>  %slog.[3 'forge: note root does not match expected root']
        [~ state]
      ::  Guard: reject duplicate note IDs — replay protection across
      ::  the current and prior epoch (AUDIT 2026-05-19 H-01)
      ::
      ?:  (~(has in settled.state) id.note.args)
        ~>  %slog.[3 'forge: note already settled (replay rejected)']
        [~ state]
      ?:  (~(has in prior-settled.state) id.note.args)
        ~>  %slog.[3 'forge: note already settled (prior epoch, replay rejected)']
        [~ state]
      ::  Verify all leaves — crash on first failure
      ::
      ?>
        =/  lvs  leaves.args
        |-
        ?~  lvs  %.y
        ?.  (verify-chunk dat.i.lvs proof.i.lvs expected-root.args)  %.n
        $(lvs t.lvs)
      ::  All leaves verified — settle
      ::
      :_  (settle-id state id.note.args)
      ^-  (list effect)
      ~[[id.note.args hull.note.args root.note.args [%settled ~]]]
      ::
      ::  %verify — verify leaves (read-only, no state change)
      ::
        %verify
      ::  AUDIT 2026-04-19 M-02: mule-wrap cue + sieve for read-only
      ::  soft preflight.
      ::
      =/  parsed
        %-  mule  |.
        =/  raw=*  (cue payload.u.act)
        ;;(forge-payload raw)
      ?:  ?=(%| -.parsed)
        :_  state
        ^-  (list effect)
        ~[[%verified %.n]]
      =/  args=forge-payload  p.parsed
      ?.  (~(has by registered.state) hull.note.args)
        :_  state
        ^-  (list effect)
        ~[[%verified %.n]]
      ?.  =(expected-root.args (~(got by registered.state) hull.note.args))
        :_  state
        ^-  (list effect)
        ~[[%verified %.n]]
      ::  Guard: note header root must match expected root (H-07)
      ::
      ?.  =(root.note.args expected-root.args)
        :_  state
        ^-  (list effect)
        ~[[%verified %.n]]
      =/  ok=?
        =/  lvs  leaves.args
        |-
        ?~  lvs  %.y
        ?.  (verify-chunk dat.i.lvs proof.i.lvs expected-root.args)  %.n
        $(lvs t.lvs)
      :_  state
      ^-  (list effect)
      ~[[%verified ok]]
      ::
      ::  %prove — verify leaves + generate STARK proof (atomic)
      ::    Guards: same as %settle
      ::    If proving crashes, nothing settles.
      ::
        %prove
      ::  AUDIT 2026-04-19 M-02: mule-wrap cue + sieve (see %settle).
      ::
      =/  parsed
        %-  mule  |.
        =/  raw=*  (cue payload.u.act)
        ;;(forge-payload raw)
      ?:  ?=(%| -.parsed)
        ~>  %slog.[3 'forge: malformed prove payload']
        :_  state
        ^-  (list effect)
        ~[[%prove-error 'forge: malformed payload']]
      =/  args=forge-payload  p.parsed
      ::  Guard: reject unregistered roots
      ::
      ?.  (~(has by registered.state) hull.note.args)
        ~>  %slog.[3 'forge: root not registered']
        [~ state]
      ::  Guard: expected root must match registered root
      ::
      ?.  =(expected-root.args (~(got by registered.state) hull.note.args))
        ~>  %slog.[3 'forge: root mismatch']
        [~ state]
      ::  Guard: note header root must match expected root (H-07)
      ::
      ?.  =(root.note.args expected-root.args)
        ~>  %slog.[3 'forge: note root does not match expected root']
        [~ state]
      ::  Guard: reject duplicate note IDs — replay protection across
      ::  the current and prior epoch (AUDIT 2026-05-19 H-01)
      ::
      ?:  (~(has in settled.state) id.note.args)
        ~>  %slog.[3 'forge: note already settled (replay rejected)']
        [~ state]
      ?:  (~(has in prior-settled.state) id.note.args)
        ~>  %slog.[3 'forge: note already settled (prior epoch, replay rejected)']
        [~ state]
      ::  Verify all leaves — crash on first failure
      ::
      ?>
        =/  lvs  leaves.args
        |-
        ?~  lvs  %.y
        ?.  (verify-chunk dat.i.lvs proof.i.lvs expected-root.args)  %.n
        $(lvs t.lvs)
      ::  Belt-decompose all leaf data
      ::
      =/  all-belts=(list @)
        =|  acc=(list @)
        =/  lvs  leaves.args
        |-
        ?~  lvs  (flop acc)
        $(acc (weld (flop (split-to-belts dat.i.lvs)) acc), lvs t.lvs)
      ::  Fold all belts to single atom < Goldilocks prime
      ::  p = 2^64 - 2^32 + 1
      ::
      =/  p=@  (add (sub (bex 64) (bex 32)) 1)
      ::  AUDIT 2026-04-19 C-lead-3: Horner polynomial fold so the STARK
      ::  subject is permutation-sensitive. base = 2^56 exceeds any 7-byte
      ::  belt, giving an injective fold. `b` is accumulator, `a` is the
      ::  current belt (per `roll`'s gate convention).
      ::
      =/  base=@  (bex 56)
      =/  belt-digest=@
        %+  roll  all-belts
        |=  [a=@ b=@]
        (mod (add (mul b base) a) p)
      ::  64 nested increments on [0 1]
      ::  known-working pattern: atom subject + Nock 0/4 only
      ::
      =/  fs-formula=*
        =/  f=*  [0 1]
        =|  i=@
        |-
        ?:  =(i 64)  f
        $(f [4 f], i +(i))
      =/  result-note  [id.note.args hull.note.args root.note.args [%settled ~]]
      =/  proof-attempt
        %-  mule  |.
        (prove-computation belt-digest fs-formula expected-root.args hull.note.args)
      ?.  -.proof-attempt
        ::  Proof FAILED — jam the trace for Rust-side decoding
        ::
        ~>  %slog.[3 'forge: prove-computation crashed']
        :_  state
        ^-  (list effect)
        ~[[%prove-failed (jam p.proof-attempt)]]
      ::  AUDIT 2026-05-19 C-03: sieve `prove-computation`'s `each` variant.
      ::  `mule` only catches crashes — a successful return of `[%| err]`
      ::  (e.g. [%| %too-big heights=...]) has -.proof-attempt = %.y. Without
      ::  this sieve, the kernel falls through to "settled" with an error
      ::  noun as the emitted proof, permanently blocking re-settle of id.
      ::
      ?.  ?=(%& -.p.proof-attempt)
        ~>  %slog.[3 'forge: prover returned error variant']
        :_  state
        ^-  (list effect)
        ~[[%prove-failed (jam p.proof-attempt)]]
      ::  Proof succeeded — settle and return [result-note proof]
      ::
      =/  the-proof  +.p.proof-attempt
      :_  (settle-id state id.note.args)
      ^-  (list effect)
      ~[[result-note the-proof]]
    ==
  --
--
((moat |) inner)
