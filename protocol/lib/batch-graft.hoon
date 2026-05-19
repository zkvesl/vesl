::  lib/batch-graft.hoon: settlement-flush buffer
::
::  The Graft is a library, not a kernel. It provides:
::    1. A state fragment (batch-state) you graft onto your kernel state
::    2. A poke dispatcher for %batch-init / %batch-add / %batch-flush
::    3. A peek helper for the pending list length
::
::  Phase 03e, behavior-graft band priority 145. Buffers caller intents
::  and emits a single %batch-flushed effect once the configured trigger
::  fires — amortizing on-chain settlement cost. The downstream
::  orchestrator (Rust side) listens for %batch-flushed and routes each
::  bundled intent into settle-graft on its own time.
::
::  Scope (v0.1): COUNT trigger only. The .dev/03 doc envisioned three
::  triggers (count / pages / time):
::    - count : SHIPPED. Flush every N successful adds.
::    - pages : DEFERRED. Tracks kernel event-count delta — that
::              counter isn't currently exposed to graft state. See
::              .dev/03_DEFERRALS.md.
::    - time  : DEFERRED. Requires `after = ["clock-graft"]`; v0.1
::              keeps batch-graft standalone. See .dev/03_DEFERRALS.md.
::
::  Degenerate cases:
::    - threshold=0  → auto-flush disabled. Only %batch-flush manual
::                     pokes drain the buffer.
::    - threshold=1  → flush on every add (functionally equivalent to
::                     no-batch — included so the count knob has a
::                     well-defined low end without special-casing).
::
::  C1: %batch-add cues a caller-supplied jammed intent atom. Wrap is
::  the canonical mule pattern from queue-graft / log-graft.
::
::  Usage:
::    /+  *batch-graft
::    ...your kernel...
::    +$  my-state  [batch=batch-state ...your-fields...]
::    ...in poke arm...
::    ?+  -.cause  [~ state]
::      %batch-init   (batch-poke batch.state cause)
::      %batch-add    (batch-poke batch.state cause)
::      %batch-flush  (batch-poke batch.state cause)
::    ==
::
|%
::  +$batch-state: the state fragment — graft this onto your kernel
::
::    pending — newest-last list of accumulated intents
::    counter — monotonic id assigned to each %batch-add
::    threshold — count trigger; 0 = manual flush only
::
+$  batch-state
  $:  pending=(list *)
      counter=@ud
      threshold=@ud
  ==
::
::  +new-state: fresh empty graft state (auto-flush disabled)
::
++  new-state
  ^-  batch-state
  :*  pending=*(list *)
      counter=`@ud`0
      threshold=`@ud`0
  ==
::
::  +pending-cap: hard upper bound on the pending list length.
::
::  Mirror of queue-graft cap (10M). Defends against an adversarial
::  caller filling the buffer past the byte budget. Caps the
::  threshold check at a reasonable ceiling so misconfiguration
::  (e.g. threshold=1G) doesn't silently let the buffer grow forever.
::
++  pending-cap  ^~((mul 10.000 1.000))
::
::  +$batch-effect: effects the Graft can produce
::
+$  batch-effect
  $%  [%batch-initialized threshold=@ud]
      [%batch-added id=@ud]
      [%batch-flushed bundle=(list *) count=@ud]
      [%batch-error msg=@t]
  ==
::
::  +$batch-cause: tagged pokes the Graft handles
::
::  payload=@ on %batch-add is a jammed intent the kernel cue's
::  inside the poke arm — same C1 inner-jam pattern as queue-graft.
::
+$  batch-cause
  $%  [%batch-init threshold=@ud]
      [%batch-add payload=@]
      [%batch-flush ~]
  ==
::
::  +batch-poke: dispatch a batch cause against batch state
::
++  batch-poke
  |=  [state=batch-state cause=batch-cause]
  ^-  [(list batch-effect) batch-state]
  ?-  -.cause
    ::
    ::  %batch-init — set the count threshold. 0 = manual flush only.
    ::                Reasonable upper bound: pending-cap (anything
    ::                higher than the buffer cap can never fire).
    ::
      %batch-init
    ?:  (gth threshold.cause pending-cap)
      :_  state
      ~[[%batch-error 'batch-graft: threshold exceeds pending cap']]
    :_  state(threshold threshold.cause)
    ~[[%batch-initialized threshold.cause]]
    ::
    ::  %batch-add — cue caller-supplied intent, append to pending,
    ::               auto-flush if threshold reached.
    ::
    ::  C1: wrap cue in mule. intent payload accepts any noun shape;
    ::  the wrap defends against truncated or malformed jam atoms.
    ::
      %batch-add
    =/  parsed
      %-  mule  |.
      (cue payload.cause)
    ?:  ?=(%| -.parsed)
      :_  state
      ~[[%batch-error 'batch-graft: malformed intent payload']]
    =/  intent=*  p.parsed
    ?:  (gte (lent pending.state) pending-cap)
      :_  state
      ~[[%batch-error 'batch-graft: pending list at capacity']]
    =/  id=@ud  +(counter.state)
    =/  new-pending=(list *)  (snoc pending.state intent)
    =/  added-effect=batch-effect  [%batch-added id]
    ::  Auto-flush check: threshold>0 AND pending now meets or
    ::  exceeds threshold. The post-add length is `(lent new-pending)`.
    ::
    ?:  ?&  (gth threshold.state 0)
            (gte (lent new-pending) threshold.state)
        ==
      :_  state(pending ~, counter id)
      :~  added-effect
          [%batch-flushed new-pending (lent new-pending)]
      ==
    :_  state(pending new-pending, counter id)
    ~[added-effect]
    ::
    ::  %batch-flush — manual drain. Empty buffer flushes an empty
    ::                 bundle (still emits the effect so external
    ::                 listeners can observe the boundary).
    ::
      %batch-flush
    =/  drained=(list *)  pending.state
    :_  state(pending ~)
    ~[[%batch-flushed drained (lent drained)]]
  ==
::
::  +batch-peek: query batch state by path
::
::  [%batch-pending-len ~] — current pending list length
::  [%batch-threshold ~]   — current threshold setting
::
++  batch-peek
  |=  [state=batch-state =path]
  ^-  (unit (unit *))
  ?+  path  ~
      [%batch-pending-len ~]
    ``[~ (lent pending.state)]
  ::
      [%batch-threshold ~]
    ``[~ threshold.state]
  ==
--
