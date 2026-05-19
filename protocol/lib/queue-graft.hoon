::  lib/queue-graft.hoon: FIFO job queue with monotonic IDs
::
::  The Graft is a library, not a kernel. It provides:
::    1. A state fragment (queue-state) you graft onto your kernel state
::    2. A poke dispatcher for %queue-push / %queue-pop / %queue-clear
::    3. A peek helper for the queue length
::
::  Queue is the first state-graft with a C1 mule-wrap site:
::  %queue-push receives a jammed body atom from the caller, cue's
::  it inside the poke arm, and emits %queue-error rather than
::  crashing the kernel on malformed jam (AUDIT 2026-04-19 H-08
::  pattern). Bodies are typed as `*` (any noun) — domain-specific
::  validation belongs in a Phase 03 validate-graft, not here.
::
::  Order is FIFO: %queue-push appends to the tail (`snoc`, O(n)),
::  %queue-pop returns the head and shifts (O(1)). For deployments
::  pushing millions of jobs the linear-snoc cost is a known cap;
::  Phase 03 batch-graft can layer a more efficient queue if needed.
::
::  Usage:
::    /+  *queue-graft
::    ...your kernel...
::    +$  my-state  [queue=queue-state ...your-fields...]
::    ...in poke arm...
::    ?+  -.cause  [~ state]
::      %queue-push   (queue-poke queue.state cause)
::      %queue-pop    (queue-poke queue.state cause)
::      %queue-clear  (queue-poke queue.state cause)
::    ==
::
|%
::  +$queue-state: the state fragment — graft this onto your kernel
::
::    pending — list of [id body] cells in FIFO order (head pops first)
::    next-id — monotonic id assigned to the next pushed body
::
+$  queue-state
  $:  pending=(list [id=@ud body=*])
      next-id=@ud
  ==
::
::  +new-state: fresh empty graft state
::
++  new-state
  ^-  queue-state
  :*  pending=*(list [id=@ud body=*])
      next-id=`@ud`1
  ==
::
::  +pending-cap: upper bound on the `pending` list length.
::
::  Mirror of mint/guard/settle/kv/counter caps. 10M pending jobs
::  is generous for any legitimate workload, restrictive enough
::  that an unbounded poke caller can't brick kernel memory.
::
++  pending-cap  ^~((mul 10.000 1.000))
::
::  +$queue-effect: effects the Graft can produce
::
+$  queue-effect
  $%  [%queue-pushed id=@ud]
      [%queue-popped job=(unit [id=@ud body=*])]
      [%queue-cleared ~]
      [%queue-error msg=@t]
  ==
::
::  +$queue-cause: tagged pokes the Graft handles
::
::  payload=@ on %queue-push is a jammed body the kernel cue's
::  inside the poke arm. The C1 mule-wrap on cue is the whole
::  reason this graft uses an inner-jam encoding rather than
::  carrying body=* in the cause cell directly: it gives the
::  graft an explicit decode boundary where malformed input
::  surfaces as %queue-error rather than as a kernel panic.
::
+$  queue-cause
  $%  [%queue-push payload=@]
      [%queue-pop ~]
      [%queue-clear ~]
  ==
::
::  +queue-poke: dispatch a queue cause against queue state
::
++  queue-poke
  |=  [state=queue-state cause=queue-cause]
  ^-  [(list queue-effect) queue-state]
  ?-  -.cause
    ::
    ::  %queue-push — append to the tail; assign monotonic id.
    ::
    ::  C1: wrap cue in mule. body=* accepts any noun shape, so no
    ::  ;; cast follows; the wrap defends against truncated or
    ::  malformed jam atoms that crash inside cue itself.
    ::
      %queue-push
    =/  parsed
      %-  mule  |.
      (cue payload.cause)
    ?:  ?=(%| -.parsed)
      :_  state
      ~[[%queue-error 'queue-graft: malformed payload']]
    =/  body=*  p.parsed
    ::  Capacity guard.
    ::
    ?:  (gte (lent pending.state) pending-cap)
      :_  state
      ~[[%queue-error 'queue-graft: pending list at capacity']]
    =/  id=@ud  next-id.state
    =/  new-pending  (snoc pending.state [id body])
    =/  new-next-id  +(id)
    :_  state(pending new-pending, next-id new-next-id)
    ~[[%queue-pushed id]]
    ::
    ::  %queue-pop — remove the head; emit job=~ on empty.
    ::
      %queue-pop
    ?~  pending.state
      :_  state
      ~[[%queue-popped ~]]
    =/  head=[id=@ud body=*]  i.pending.state
    :_  state(pending t.pending.state)
    ~[[%queue-popped `head]]
    ::
    ::  %queue-clear — drop all pending jobs (next-id preserved).
    ::
      %queue-clear
    :_  state(pending ~)
    ~[[%queue-cleared ~]]
  ==
::
::  +queue-peek: query queue state by path
::
::  Returns ~ for unrecognized paths (pass through to your kernel's peek).
::  [%queue-len ~] always returns Some(len); the inner [~ ...] wrap
::  keeps len=0 from being mis-decoded as "missing" by the standard
::  triple-unit unwrap convention.
::
++  queue-peek
  |=  [state=queue-state =path]
  ^-  (unit (unit *))
  ?+  path  ~
    [%queue-len ~]
      ``[~ (lent pending.state)]
  ==
--
