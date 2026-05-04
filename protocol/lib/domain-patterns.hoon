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
::  +$storage-cause: causes accepted by audit-write's target slot.
::  Tagged union of the three storage-graft cause types — well-formed
::  because %kv-* / %registry-* / %queue-* head atoms are non-overlapping
::  by construction.
::
+$  storage-cause
  $%  kv-cause
      registry-cause
      queue-cause
  ==
::
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
::  +apply-queue: thread queue-graft poke through versioned-state.
::  Convention: queue-graft state lives at queue.state.
::
++  apply-queue
  |*  [c=queue-cause state=*]
  =/  pair  (queue-poke queue.state c)
  [-.pair state(queue +.pair)]
::
::  +apply-rbac: thread rbac-graft poke through versioned-state.
::  Convention: rbac-graft state lives at rbac.state.
::
++  apply-rbac
  |*  [c=rbac-cause state=*]
  =/  pair  (rbac-poke rbac.state c)
  [-.pair state(rbac +.pair)]
::
::  +apply-registry: thread registry-graft poke through versioned-state.
::  Convention: registry-graft state lives at registry.state.
::
++  apply-registry
  |*  [c=registry-cause state=*]
  =/  pair  (registry-poke registry.state c)
  [-.pair state(registry +.pair)]
::
::  +apply-log: thread log-graft poke through versioned-state.
::  Convention: log-graft state lives at log.state.
::
++  apply-log
  |*  [c=log-cause state=*]
  =/  pair  (log-poke log.state c)
  [-.pair state(log +.pair)]
::
::  +apply-clock: thread clock-graft poke through versioned-state.
::  Convention: clock-graft state lives at clock.state.
::
++  apply-clock
  |*  [c=clock-cause state=*]
  =/  pair  (clock-poke clock.state c)
  [-.pair state(clock +.pair)]
::
::  +apply-validate: thread validate-graft poke through versioned-state.
::  Convention: validate-graft state lives at validate.state.
::
++  apply-validate
  |*  [c=validate-cause state=*]
  =/  pair  (validate-poke validate.state c)
  [-.pair state(validate +.pair)]
::
::  +apply-batch: thread batch-graft poke through versioned-state.
::  Convention: batch-graft state lives at batch.state.
::
++  apply-batch
  |*  [c=batch-cause state=*]
  =/  pair  (batch-poke batch.state c)
  [-.pair state(batch +.pair)]
::
::  +audit-write: write to a storage graft, then append a log entry.
::
::  Bundles the "delegate-to-storage + log-append" pattern that R3 B,
::  R7 H, and R9 J hand-coded into ~3-4 lines per arm. Static dispatch
::  on -.target picks the storage graft (kv / registry / queue);
::  unknown heads crash at hoonc-time with a clear trace.
::
::  log-tag and log-body are separate so callers can write one shape
::  and log a different one (R3 B's %revoke-license writes a key
::  delete but logs the human-readable name). Pass log-body=jam-of-write
::  if the same.
::
::  Returns [welded-effects new-state] suitable for =^ binding. Effect
::  order: storage first, then log. Caller welds in their own
::  domain-effect after if applicable.
::
++  audit-write
  |*  $:  state=*
          target=storage-cause
          log-tag=@ta
          log-body=@
      ==
  =/  storage-result
    ?-  -.target
        %kv-set           (apply-kv target state)
        %kv-delete        (apply-kv target state)
        %registry-put     (apply-registry target state)
        %registry-update  (apply-registry target state)
        %registry-del     (apply-registry target state)
        %queue-push       (apply-queue target state)
        %queue-pop        (apply-queue target state)
        %queue-clear      (apply-queue target state)
    ==
  =/  storage-effects  -.storage-result
  =/  st1  +.storage-result
  =/  log-pair
    (log-poke log.st1 [%log-append log-tag log-body])
  =/  st2  st1(log +.log-pair)
  [(weld storage-effects -.log-pair) st2]
--
