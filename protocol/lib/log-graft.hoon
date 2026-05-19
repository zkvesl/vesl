::  lib/log-graft.hoon: append-only audit trail with monotonic seq
::
::  The Graft is a library, not a kernel. It provides:
::    1. A state fragment (log-state) you graft onto your kernel state
::    2. A poke dispatcher for %log-append
::    3. Peek helpers: lookup by seq, tail-N
::
::  Append-only by design. The only mutation is "prepend an entry; if
::  retention is exceeded, drop the oldest tail." There is no
::  %log-clear, no %log-delete — an audit log that callers can rewrite
::  is not an audit log. If you need a queue, use queue-graft. If you
::  need a kv, use kv-graft. log-graft is for things you want to
::  remember whether or not the writer wants you to.
::
::  C1 site: %log-append cues a caller-supplied jammed atom for the
::  entry's `data=*` payload. Wrap is the canonical mule pattern from
::  queue-graft / registry-graft.
::
::  Retention: hardcoded at 100k entries for v0.1. The .dev/03 doc
::  plans `[log-graft] retention = N` as manifest config; the
::  graft-inject manifest-config templating that would propagate a
::  TOML number into the .hoon body is not yet implemented (sub-phase
::  03b will land prelude/postlude markers; manifest-driven constants
::  are a separate question to decide later). 100k is generous for
::  development workloads and protects against unbounded memory
::  growth via a malicious poke caller.
::
::  Order: newest entries are at the head of the list. `peek-tail` is
::  cheap (`scag`); `peek-by-seq` is O(retention) — bounded — by
::  walking the list. An indexed lookup adds map overhead that the
::  audit-trail use case rarely justifies.
::
::  Usage:
::    /+  *log-graft
::    ...your kernel...
::    +$  my-state  [log=log-state ...your-fields...]
::    ...in poke arm...
::    ?+  -.cause  [~ state]
::      %log-append  (log-poke log.state cause)
::    ==
::
|%
::  +$log-entry: a single audit-log entry
::
::    seq — monotonic sequence number assigned at append
::    tag — caller-supplied @ta tag (e.g. %settle, %registry-put)
::    data — opaque noun decoded from caller's jammed payload
::
+$  log-entry
  $:  seq=@ud
      tag=@ta
      data=*
  ==
::
::  +$log-state: the state fragment — graft this onto your kernel
::
::    entries — newest-first list of recorded entries
::    next-seq — monotonic id assigned to the next appended entry
::
+$  log-state
  $:  entries=(list log-entry)
      next-seq=@ud
  ==
::
::  +new-state: fresh empty graft state
::
++  new-state
  ^-  log-state
  :*  entries=*(list log-entry)
      next-seq=`@ud`1
  ==
::
::  +retention-cap: upper bound on the entries list length.
::
::  100k entries — see the header for why this is hardcoded today.
::  Mirror of mint/guard/settle/kv/counter/queue caps in shape; the
::  number is smaller because each entry is unbounded data, not a
::  fixed-shape value.
::
++  retention-cap  ^~((mul 100 1.000))
::
::  +$log-effect: effects the Graft can produce
::
+$  log-effect
  $%  [%log-appended seq=@ud]
      [%log-error msg=@t]
  ==
::
::  +$log-cause: tagged pokes the Graft handles
::
::  payload=@ on %log-append is a jammed entry-data atom the kernel
::  cue's inside the poke arm. Same C1 inner-jam pattern as
::  queue-graft: gives the graft an explicit decode boundary so
::  malformed input surfaces as %log-error rather than a kernel panic.
::
+$  log-cause
  $%  [%log-append tag=@ta payload=@]
  ==
::
::  +log-poke: dispatch a log cause against log state
::
++  log-poke
  |=  [state=log-state cause=log-cause]
  ^-  [(list log-effect) log-state]
  ?-  -.cause
    ::
    ::  %log-append — prepend an entry; evict oldest past retention.
    ::
    ::  C1: wrap cue in mule. data=* accepts any noun shape, so no
    ::  ;; cast follows; the wrap defends against truncated or
    ::  malformed jam atoms that crash inside cue itself.
    ::
      %log-append
    =/  parsed
      %-  mule  |.
      (cue payload.cause)
    ?:  ?=(%| -.parsed)
      :_  state
      ~[[%log-error 'log-graft: malformed payload']]
    =/  data=*  p.parsed
    =/  seq=@ud  next-seq.state
    =/  entry=log-entry  [seq tag.cause data]
    =/  prepended=(list log-entry)  [entry entries.state]
    =/  trimmed=(list log-entry)
      ?:  (gth (lent prepended) retention-cap)
        (scag retention-cap prepended)
      prepended
    :_  state(entries trimmed, next-seq +(seq))
    ~[[%log-appended seq]]
  ==
::
::  +log-peek: query log state by path
::
::  Returns ~ for unrecognized paths (pass through to your kernel's peek).
::
::  [%log-by-seq seq=@ud ~] — returns Some(entry) if present, None
::    if not. Walks the entries list (O(retention), bounded).
::  [%log-tail count=@ud ~] — returns the first N entries (newest
::    first); always Some, possibly empty list.
::  [%log-len ~] — returns current entry count; always Some.
::
++  log-peek
  |=  [state=log-state =path]
  ^-  (unit (unit *))
  ?+  path  ~
      [%log-by-seq seq=@ud ~]
    =/  s  +<.path
    =/  found=(list log-entry)
      (skim entries.state |=(e=log-entry =(seq.e s)))
    ``?~(found ~ `i.found)
  ::
      [%log-tail count=@ud ~]
    =/  c  +<.path
    ``[~ (scag c entries.state)]
  ::
      [%log-len ~]
    ``[~ (lent entries.state)]
  ==
--
