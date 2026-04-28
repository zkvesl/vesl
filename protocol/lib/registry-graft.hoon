::  lib/registry-graft.hoon: strict structured registry
::
::  The Graft is a library, not a kernel. It provides:
::    1. A state fragment (registry-state) you graft onto your kernel state
::    2. A poke dispatcher for %registry-put / %registry-update /
::       %registry-del
::    3. A peek helper for retrieving stored records by key
::
::  Registry is the *strict* counterpart to kv-graft:
::    - %registry-put on an existing key errors (one-shot).
::    - %registry-update on a missing key errors (must put first).
::    - %registry-del on a missing key errors.
::    - %registry-update surfaces old + new in the effect so callers
::      don't need a peek round-trip to capture the prior record.
::
::  This is the heaviest C1 surface in Phase 02: both put and update
::  cue caller-supplied record bytes inside the poke. Each arm wraps
::  cue in a mule and emits %registry-error on malformed jam rather
::  than crashing the kernel (AUDIT 2026-04-19 H-08 pattern).
::
::  Records are typed `*` (any noun) on the Hoon side. Domain-
::  specific schema validation belongs in a Phase 03 validate-graft.
::
::  Usage:
::    /+  *registry-graft
::    ...your kernel...
::    +$  my-state  [registry=registry-state ...your-fields...]
::    ...in poke arm...
::    ?+  -.cause  [~ state]
::      %registry-put     (registry-poke registry.state cause)
::      %registry-update  (registry-poke registry.state cause)
::      %registry-del     (registry-poke registry.state cause)
::    ==
::
|%
::  +$registry-state: the state fragment — graft this onto your kernel
::
::    entries — key=@ -> record=* (opaque)
::
+$  registry-state
  $:  entries=(map @ *)
  ==
::
::  +new-state: fresh empty graft state
::
++  new-state
  ^-  registry-state
  :*  entries=*(map @ *)
  ==
::
::  +entries-cap: upper bound on the `entries` map.
::
++  entries-cap  ^~((mul 10.000 1.000))
::
::  +$registry-effect: effects the Graft can produce
::
::  Update surfaces old + new so the common audit-style use case
::  (record diff after a write) doesn't need a follow-up peek.
::
+$  registry-effect
  $%  [%registry-stored key=@]
      [%registry-updated key=@ old=* new=*]
      [%registry-deleted key=@]
      [%registry-error msg=@t]
  ==
::
::  +$registry-cause: tagged pokes the Graft handles
::
::  payload=@ on put / update is a jammed record the kernel cue's
::  inside the poke arm under a mule guard.
::
+$  registry-cause
  $%  [%registry-put key=@ payload=@]
      [%registry-update key=@ payload=@]
      [%registry-del key=@]
  ==
::
::  +registry-poke: dispatch a registry cause against registry state
::
++  registry-poke
  |=  [state=registry-state cause=registry-cause]
  ^-  [(list registry-effect) registry-state]
  ?-  -.cause
    ::
    ::  %registry-put — strict create. Error on existing key.
    ::
    ::  C1: mule-wrap cue. record=* accepts any shape; the wrap
    ::  defends against truncated/malformed jam atoms.
    ::
      %registry-put
    ?:  (~(has by entries.state) key.cause)
      :_  state
      ~[[%registry-error 'registry-graft: key already present']]
    ?:  (gte ~(wyt by entries.state) entries-cap)
      :_  state
      ~[[%registry-error 'registry-graft: entries map at capacity']]
    =/  parsed
      %-  mule  |.
      (cue payload.cause)
    ?:  ?=(%| -.parsed)
      :_  state
      ~[[%registry-error 'registry-graft: malformed payload']]
    =/  record=*  p.parsed
    =/  new-entries  (~(put by entries.state) key.cause record)
    :_  state(entries new-entries)
    ~[[%registry-stored key.cause]]
    ::
    ::  %registry-update — strict modify. Error on missing key.
    ::  Surfaces old + new in the effect.
    ::
    ::  Second C1 site of the graft.
    ::
      %registry-update
    ?.  (~(has by entries.state) key.cause)
      :_  state
      ~[[%registry-error 'registry-graft: key not present; use put']]
    =/  parsed
      %-  mule  |.
      (cue payload.cause)
    ?:  ?=(%| -.parsed)
      :_  state
      ~[[%registry-error 'registry-graft: malformed payload']]
    =/  new-record=*  p.parsed
    =/  old-record=*  (~(got by entries.state) key.cause)
    =/  new-entries  (~(put by entries.state) key.cause new-record)
    :_  state(entries new-entries)
    ~[[%registry-updated key.cause old-record new-record]]
    ::
    ::  %registry-del — strict remove. Error on missing key.
    ::
      %registry-del
    ?.  (~(has by entries.state) key.cause)
      :_  state
      ~[[%registry-error 'registry-graft: key not present']]
    =/  new-entries  (~(del by entries.state) key.cause)
    :_  state(entries new-entries)
    ~[[%registry-deleted key.cause]]
  ==
::
::  +registry-peek: query registry state by path
::
::  Records are returned as opaque nouns. Callers wanting a typed
::  shape should `;;` against their schema after the peek.
::
++  registry-peek
  |=  [state=registry-state =path]
  ^-  (unit (unit *))
  ?+  path  ~
    [%registry-entry key=@ ~]
      =/  k  +<.path
      ``(~(get by entries.state) k)
  ==
--
