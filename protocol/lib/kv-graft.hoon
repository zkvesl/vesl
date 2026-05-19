::  lib/kv-graft.hoon: simple key-value store
::
::  The Graft is a library, not a kernel. It provides:
::    1. A state fragment (kv-state) you graft onto your kernel state
::    2. A poke dispatcher for %kv-set / %kv-delete
::    3. A peek helper for querying values by key
::
::  KV is the loose store: opaque atom values, overwrite-on-set, noop
::  on delete-missing. Pair with registry-graft when callers want
::  strict semantics (error on overwrite, error on missing-update,
::  error on missing-delete) or structured records.
::
::  Usage:
::    /+  *kv-graft
::    ...your kernel...
::    +$  my-state  [kv=kv-state ...your-fields...]
::    ...in poke arm...
::    ?+  -.cause  [~ state]
::      %kv-set     (kv-poke kv.state cause)
::      %kv-delete  (kv-poke kv.state cause)
::    ==
::
|%
::  +$kv-state: the state fragment — graft this onto your kernel
::
::    store — key=@t -> value=@ (loose, overwrite-on-set)
::
+$  kv-state
  $:  store=(map @t @)
  ==
::
::  +new-state: fresh empty graft state
::
++  new-state
  ^-  kv-state
  :*  store=*(map @t @)
  ==
::
::  +store-cap: upper bound on the `store` map.
::
::  Mirror of mint/guard/settle's commit/roots/registered caps
::  (AUDIT 2026-04-17 H-02). 10M entries — generous for any
::  legitimate KV deployment, restrictive enough that an unbounded
::  poke caller can't brick kernel memory. Overwrite of an existing
::  key does not grow the map and bypasses the cap.
::
++  store-cap  ^~((mul 10.000 1.000))
::
::  +$kv-effect: effects the Graft can produce
::
+$  kv-effect
  $%  [%kv-stored key=@t]
      [%kv-deleted key=@t]
      [%kv-error msg=@t]
  ==
::
::  +$kv-cause: tagged pokes the Graft handles
::
+$  kv-cause
  $%  [%kv-set key=@t value=@]
      [%kv-delete key=@t]
  ==
::
::  +kv-poke: dispatch a kv cause against kv state
::
++  kv-poke
  |=  [state=kv-state cause=kv-cause]
  ^-  [(list kv-effect) kv-state]
  ?-  -.cause
    ::
    ::  %kv-set — overwrite-on-existing (loose store semantics)
    ::
      %kv-set
    ::  Capacity check: only on insertion of a NEW key.
    ::
    ?:  ?&  !(~(has by store.state) key.cause)
            (gte ~(wyt by store.state) store-cap)
        ==
      :_  state
      ~[[%kv-error 'kv-graft: store map at capacity']]
    =/  new-store  (~(put by store.state) key.cause value.cause)
    :_  state(store new-store)
    ~[[%kv-stored key.cause]]
    ::
    ::  %kv-delete — noop on missing key (idempotent)
    ::
      %kv-delete
    =/  new-store  (~(del by store.state) key.cause)
    :_  state(store new-store)
    ~[[%kv-deleted key.cause]]
  ==
::
::  +kv-peek: query kv state by path
::
::  Returns ~ for unrecognized paths (pass through to your kernel's peek).
::
++  kv-peek
  |=  [state=kv-state =path]
  ^-  (unit (unit *))
  ?+  path  ~
    [%kv-value key=@t ~]
      =/  k  +<.path
      ``(~(get by store.state) k)
  ==
--
