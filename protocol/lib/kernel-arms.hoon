::  protocol/lib/kernel-arms.hoon: shared dispatch arms for vesl kernels
::
::  Centralizes the %register dup-check and the settlement-guard chain
::  duplicated across guard/mint/settle kernels (and across vesl-kernel
::  in hull-llm).
::
::  Domain-agnostic.  Each kernel parses its own payload type via inline
::  cue+sieve mule (each kernel knows what payload shape it expects).
::  This arm only operates on `note` + `expected-root`, both of which
::  are generic.
::
::  Consumed via /+  *kernel-arms in the kernel libraries.
::
/-  *vesl
|%
::  AUDIT 2026-05-19 H-01: capacity caps for the production kernels,
::  mirroring settle-graft.hoon. guard/mint/settle import these via
::  /+  *kernel-arms; forge-kernel defines its own copies.
::
::  +registered-cap: static upper bound on the `registered` map. Large
::  enough that no legitimate deployment hits it, small enough that a
::  %register spammer cannot exhaust kernel memory.
::
++  registered-cap  ^~((mul 10.000 1.000))
::  +epoch-cap: rotation threshold for the `settled` set — at this many
::  settles a kernel rotates (prior-settled := settled, settled := ~)
::  instead of growing without bound.
::
++  epoch-cap  ^~((mul 1.000 1.000))
::
::  +handle-register: insert hull->root mapping, reject re-registration.
::    Returns ~ when the hull already has a registered root and slogs
::    '<label> hull already registered'.  Returns [~ new-map] on success.
::    The caller emits the %registered effect on success and returns
::    [~ state] on duplicate.
::
++  handle-register
  |=  [registered=(map @ @) hull=@ root=@ label=@t]
  ^-  (unit (map @ @))
  ?:  (~(has by registered) hull)
    ~>  %slog.[3 (rap 3 ~[label ' hull already registered'])]
    ~
  ::  AUDIT 2026-05-19 H-01: reject once the map is at capacity so a
  ::  %register spammer cannot grow kernel state without bound.
  ::
  ?:  (gte ~(wyt by registered) registered-cap)
    ~>  %slog.[3 (rap 3 ~[label ' registered map at capacity'])]
    ~
  `(~(put by registered) hull root)
::
::  +validate-settlement-args: shared settlement-guard chain.
::    Chain order: root-registered, expected-root match, note-root
::    match, replay against the current and prior epoch (mutate mode
::    only — verify mode preserves legacy behaviour by skipping replay).
::    %mutate slogs '<label> ...' on the failing check.
::    %verify is silent; the caller emits [%verified %.n].
::    Takes individual fields (note + expected-root) so it does not
::    depend on any specific settlement-payload type; each kernel
::    extracts these from its own (domain-specific) payload shape.
::
++  validate-settlement-args
  |=  $:  note=[id=@ hull=@ root=@ state=[%pending ~]]
          expected-root=@
          registered=(map @ @)
          settled=(set @)
          prior-settled=(set @)
          mode=?(%mutate %verify)
          label=@t
      ==
  ^-  $%  [%.y ~]
          [%.n err=?(%root-not-registered %root-mismatch %note-root-mismatch %replay)]
      ==
  ?.  (~(has by registered) hull.note)
    ?.  ?=(%mutate mode)
      [%.n %root-not-registered]
    ~>  %slog.[3 (rap 3 ~[label ' root not registered'])]
    [%.n %root-not-registered]
  ?.  =(expected-root (~(got by registered) hull.note))
    ?.  ?=(%mutate mode)
      [%.n %root-mismatch]
    ~>  %slog.[3 (rap 3 ~[label ' root mismatch'])]
    [%.n %root-mismatch]
  ?.  =(root.note expected-root)
    ?.  ?=(%mutate mode)
      [%.n %note-root-mismatch]
    ~>  %slog.[3 (rap 3 ~[label ' note root does not match expected root'])]
    [%.n %note-root-mismatch]
  ::  AUDIT 2026-05-20 M-08: %verify mode returns here, BEFORE the
  ::  replay check below.  A %verify result of [%.y ~] therefore means
  ::  only "registered, roots match" — it is NOT a settle-safety
  ::  guarantee: an already-settled note still yields [%.y ~] under
  ::  %verify.  A caller using %verify as a "can I settle this?"
  ::  preflight must treat replay rejection as a %mutate-time outcome.
  ::
  ?.  ?=(%mutate mode)
    [%.y ~]
  ?:  (~(has in settled) id.note)
    ~>  %slog.[3 (rap 3 ~[label ' note already settled (replay rejected)'])]
    [%.n %replay]
  ?:  (~(has in prior-settled) id.note)
    ~>  %slog.[3 (rap 3 ~[label ' note already settled (prior epoch, replay rejected)'])]
    [%.n %replay]
  [%.y ~]
--
