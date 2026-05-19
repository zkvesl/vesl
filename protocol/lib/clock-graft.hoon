::  lib/clock-graft.hoon: deterministic event-counter clock
::
::  The Graft is a library, not a kernel. It provides:
::    1. A state fragment (clock-state) you graft onto your kernel state
::    2. A poke dispatcher for %clock-tick
::    3. A peek helper for the current @da
::
::  Determinism floor: clock-graft v0.1 ships ONE source — `event-count`
::  — backed by a kernel-internal monotonic tick counter advanced by
::  explicit %clock-tick pokes. There is no host wall-clock, no boot
::  stamp, no environmental input. Determinism is the whole point: the
::  kernel must produce identical state across every replay, on every
::  node, for STARK soundness to hold.
::
::  Two sources from .dev/03_BEHAVIOR_GRAFTS.md were considered and
::  deferred:
::    - boot-offset (capture host wall-clock once at mount): the boot
::      stamp itself is non-deterministic environmental input. Even
::      though derived advancement is deterministic given the stamp,
::      the kernel has no way to recover the same stamp on a fresh
::      replay. Out for v0.1.
::    - block-time (read block height/timestamp from the chain): the
::      natural future answer for callers who need real-world time;
::      requires Rust-side plumbing not yet present. Phase 05
::      territory; revisit when the chain bridge lands.
::
::  Tick semantics: @da is opaque kernel-time units. One %clock-tick
::  advances the counter by 1; callers pace their own ticks. For real-
::  world time, swap in a future block-time source.
::
::  No C1 mule-wrap site: %clock-tick has no payload to cue. The error
::  variant is reserved for future config-validation needs.
::
::  Usage:
::    /+  *clock-graft
::    ...your kernel...
::    +$  my-state  [clock=clock-state ...your-fields...]
::    ...in poke arm...
::    ?+  -.cause  [~ state]
::      %clock-tick  (clock-poke clock.state cause)
::    ==
::
|%
::  +$clock-state: the state fragment — graft this onto your kernel
::
::    ticks — monotonic event counter advanced on every %clock-tick.
::            Returned (cast as @da) by the [%clock-now ~] peek.
::
+$  clock-state
  $:  ticks=@ud
  ==
::
::  +new-state: fresh empty graft state (ticks=0)
::
++  new-state
  ^-  clock-state
  :*  ticks=`@ud`0
  ==
::
::  +$clock-effect: effects the Graft can produce
::
+$  clock-effect
  $%  [%clock-ticked now=@da]
      [%clock-error msg=@t]
  ==
::
::  +$clock-cause: tagged pokes the Graft handles
::
+$  clock-cause
  $%  [%clock-tick ~]
  ==
::
::  +clock-poke: dispatch a clock cause against clock state
::
::  ticks=@ud is unbounded-precision; no saturation guard needed.
::
++  clock-poke
  |=  [state=clock-state cause=clock-cause]
  ^-  [(list clock-effect) clock-state]
  ?-  -.cause
    ::
    ::  %clock-tick — advance the monotonic tick counter by 1.
    ::
      %clock-tick
    =/  next=@ud  +(ticks.state)
    :_  state(ticks next)
    ~[[%clock-ticked `@da`next]]
  ==
::
::  +clock-peek: query clock state by path
::
::  Returns ~ for unrecognized paths (pass through to your kernel's peek).
::  [%clock-now ~] always returns Some(now); the inner [~ ...] wrap
::  keeps now=0 (pre-tick state) from being mis-decoded as "missing"
::  by the standard triple-unit unwrap convention.
::
++  clock-peek
  |=  [state=clock-state =path]
  ^-  (unit (unit *))
  ?+  path  ~
    [%clock-now ~]
      ``[~ `@da`ticks.state]
  ==
--
