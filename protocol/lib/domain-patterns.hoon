::  lib/domain-patterns.hoon: helpers for recurring domain Hoon shapes
::
::  Library-shaped (no manifest, no graft-inject involvement). Import
::  with `/+  *domain-patterns` from your `app.hoon`. Helpers operate
::  inside the kernel; no Rust seam.
::
::  v0.1 ships:
::    ++  apply-<graft>   one per shipped data/behavior graft. Threads
::                        state by the convention that <graft>-graft
::                        state lives at the field named <graft> on
::                        versioned-state.
::    ++  audit-write     bundles delegate-to-storage + log-append.
::
::  Convention: each apply-<graft> arm assumes the graft's state lives
::  at the field named <graft> on the kernel's versioned-state. This
::  matches the usage example in every shipped graft's header — see
::  e.g. counter-graft.hoon:18, log-graft.hoon:36.
::
::  Wet-gate (|*) polymorphism is required because versioned-state is
::  defined by the kernel, not by this library. Type-checking is
::  deferred to the call site. Convention violations surface as
::  `find . <graft>` errors at the call site, not internal hoonc
::  traces. Acceptable failure mode.
::
::  Out of scope: kernel-composite grafts (settle, mint, guard, forge,
::  intent). settle-poke takes a 3rd verify-gate arg; forge-poke is
::  stateless. The other three mechanically fit the 2-arg shape but are
::  kernel composites, not modular state shards. See commit-1 audit
::  notes in the git log for the full rationale.
::
::  Namespace: helpers emit %domain-patterns-* effect tags on internal
::  errors (none in v0.1). Avoid declaring effect tags with that prefix
::  in your domain-effect to prevent collisions.
::
::  See vesl-nockup/.dev/03G_DOMAIN_PATTERN_HELPERS.md for design notes.
::
/+  *counter-graft
/+  *kv-graft
/+  *queue-graft
/+  *rbac-graft
/+  *registry-graft
/+  *log-graft
/+  *clock-graft
/+  *validate-graft
/+  *batch-graft
::
|%
::  +apply-counter: thread counter-graft poke through versioned-state.
::  Returns [counter-effects new-state] suitable for =^ binding.
::  Convention: counter-graft state lives at counter.state.
::
++  apply-counter
  |*  [c=counter-cause state=*]
  =/  pair  (counter-poke counter.state c)
  [-.pair state(counter +.pair)]
::
::  +apply-kv: thread kv-graft poke through versioned-state.
::  Convention: kv-graft state lives at kv.state.
::
++  apply-kv
  |*  [c=kv-cause state=*]
  =/  pair  (kv-poke kv.state c)
  [-.pair state(kv +.pair)]
::
::  +apply-log: thread log-graft poke through versioned-state.
::  Convention: log-graft state lives at log.state.
::
++  apply-log
  |*  [c=log-cause state=*]
  =/  pair  (log-poke log.state c)
  [-.pair state(log +.pair)]
::
::  +audit-write: write to a kv-graft target then append a log entry.
::
::  Stub: commit-1 ships kv-only dispatch. Commit 4 broadens to
::  registry/queue + factors out the dispatch shape.
::
::  Returns [combined-effects new-state]. Effects are kv-effects then
::  log-effect, in that order. Caller welds in their own domain-effect
::  after if applicable.
::
++  audit-write
  |*  $:  state=*
          target=kv-cause
          log-tag=@ta
          log-body=@
      ==
  =/  kv-pair  (kv-poke kv.state target)
  =/  log-pair
    (log-poke log.state [%log-append log-tag log-body])
  =/  st1  state(kv +.kv-pair)
  =/  st2  st1(log +.log-pair)
  [(weld -.kv-pair -.log-pair) st2]
--
