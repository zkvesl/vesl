::  lib/counter-graft.hoon: named counters (sequence numbers, nonces)
::
::  The Graft is a library, not a kernel. It provides:
::    1. A state fragment (counter-state) you graft onto your kernel state
::    2. A poke dispatcher for %counter-increment / %counter-reset /
::       %counter-set
::    3. A peek helper for reading a named counter's value
::
::  Counters are init-on-touch: incrementing or resetting an unset
::  name initializes it (to 1 or 0 respectively). Set is a plain
::  overwrite. Increment saturates at 2^64 so Rust u64 callers don't
::  encounter values they can't represent — overflow returns
::  %counter-error and leaves the counter unchanged.
::
::  Usage:
::    /+  *counter-graft
::    ...your kernel...
::    +$  my-state  [counter=counter-state ...your-fields...]
::    ...in poke arm...
::    ?+  -.cause  [~ state]
::      %counter-increment  (counter-poke counter.state cause)
::      %counter-reset      (counter-poke counter.state cause)
::      %counter-set        (counter-poke counter.state cause)
::    ==
::
|%
::  +$counter-state: the state fragment — graft this onto your kernel
::
::    counters — name=@t -> value=@ud
::
+$  counter-state
  $:  counters=(map @t @ud)
  ==
::
::  +new-state: fresh empty graft state
::
++  new-state
  ^-  counter-state
  :*  counters=*(map @t @ud)
  ==
::
::  +counters-cap: upper bound on the `counters` map.
::
::  Mirror of mint/guard/settle/kv caps (AUDIT 2026-04-17 H-02).
::  Only enforced on insertion of a NEW name; existing names that
::  increment/set/reset don't grow the map.
::
++  counters-cap  ^~((mul 10.000 1.000))
::
::  +$counter-effect: effects the Graft can produce
::
::  Past-participle convention has two collisions on this graft:
::  %counter-set (imperative) reads identically to %counter-set
::  (past), and %counter-reset is its own past tense. Spec
::  (.dev/02_STATE_GRAFTS.md L45) keeps them — context disambiguates.
::
+$  counter-effect
  $%  [%counter-incremented name=@t value=@ud]
      [%counter-reset name=@t]
      [%counter-set name=@t value=@ud]
      [%counter-error msg=@t]
  ==
::
::  +$counter-cause: tagged pokes the Graft handles
::
+$  counter-cause
  $%  [%counter-increment name=@t]
      [%counter-reset name=@t]
      [%counter-set name=@t value=@ud]
  ==
::
::  +counter-poke: dispatch a counter cause against counter state
::
++  counter-poke
  |=  [state=counter-state cause=counter-cause]
  ^-  [(list counter-effect) counter-state]
  ?-  -.cause
    ::
    ::  %counter-increment — init-to-1 on unset; saturate at 2^64-1.
    ::
      %counter-increment
    =/  current=@ud  (~(gut by counters.state) name.cause 0)
    ::  Saturation guard: refuse increment that would push value
    ::  out of u64 range. Caller must reset the counter first.
    ::
    ?:  (gte +(current) (bex 64))
      :_  state
      ~[[%counter-error 'counter-graft: counter saturated at 2^64']]
    ::  Capacity guard: only relevant when initializing a new name.
    ::
    ?:  ?&  !(~(has by counters.state) name.cause)
            (gte ~(wyt by counters.state) counters-cap)
        ==
      :_  state
      ~[[%counter-error 'counter-graft: counters map at capacity']]
    =/  next=@ud  +(current)
    =/  new-counters  (~(put by counters.state) name.cause next)
    :_  state(counters new-counters)
    ~[[%counter-incremented name.cause next]]
    ::
    ::  %counter-reset — init-to-0 on unset; idempotent.
    ::
      %counter-reset
    ::  Capacity guard for the init case.
    ::
    ?:  ?&  !(~(has by counters.state) name.cause)
            (gte ~(wyt by counters.state) counters-cap)
        ==
      :_  state
      ~[[%counter-error 'counter-graft: counters map at capacity']]
    =/  new-counters  (~(put by counters.state) name.cause 0)
    :_  state(counters new-counters)
    ~[[%counter-reset name.cause]]
    ::
    ::  %counter-set — overwrite-on-existing, init on unset.
    ::
      %counter-set
    ?:  ?&  !(~(has by counters.state) name.cause)
            (gte ~(wyt by counters.state) counters-cap)
        ==
      :_  state
      ~[[%counter-error 'counter-graft: counters map at capacity']]
    =/  new-counters  (~(put by counters.state) name.cause value.cause)
    :_  state(counters new-counters)
    ~[[%counter-set name.cause value.cause]]
  ==
::
::  +counter-peek: query counter state by path
::
::  Returns ~ for unrecognized paths (pass through to your kernel's peek).
::
++  counter-peek
  |=  [state=counter-state =path]
  ^-  (unit (unit *))
  ?+  path  ~
    [%counter-value name=@t ~]
      =/  n  +<.path
      ``(~(get by counters.state) n)
  ==
--
