::  protocol/lib/kernel-arms.hoon: shared dispatch arms for vesl kernels
::
::  Centralizes the %register dup-check, the mule-wrap cue+sieve
::  preamble, and the settlement-guard chain duplicated across
::  guard/mint/settle/vesl kernels.
::
::  Consumed via /+  *kernel-arms in the kernel libraries.
::
/-  *vesl
|%
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
  `(~(put by registered) hull root)
::  +parse-payload: shared mule-wrap cue + sieve preamble.
::    Returns ~ on parse failure (caller emits its own slog + effect),
::    [~ settlement-payload] on success.  Each kernel site differs only
::    in slog message and failure-effect shape (typed [%verb-error msg]
::    in mutate mode, [%verified %.n] in read-only mode), so the helper
::    owns just the parse step.
::
++  parse-payload
  |=  payload=@
  ^-  (unit settlement-payload)
  =/  parsed
    %-  mule  |.
    =/  raw=*  (cue payload)
    ;;(settlement-payload raw)
  ?:  ?=(%| -.parsed)  ~
  `p.parsed
::  +validate-settlement-args: shared settlement-guard chain.
::    Chain order: root-registered, expected-root match, note-root
::    match, replay (mutate mode only — verify mode preserves legacy
::    behaviour by skipping the replay check).
::    %mutate slogs '<label> ...' on the failing check.
::    %verify is silent; the caller emits [%verified %.n].
::    Returns [%.y args] on success (args echoed for caller convenience),
::    [%.n err] otherwise.
::
++  validate-settlement-args
  |=  $:  args=settlement-payload
          registered=(map @ @)
          settled=(set @)
          mode=?(%mutate %verify)
          label=@t
      ==
  ^-  $%  [%.y args=settlement-payload]
          [%.n err=?(%root-not-registered %root-mismatch %note-root-mismatch %replay)]
      ==
  ?.  (~(has by registered) hull.note.args)
    ?.  ?=(%mutate mode)
      [%.n %root-not-registered]
    ~>  %slog.[3 (rap 3 ~[label ' root not registered'])]
    [%.n %root-not-registered]
  ?.  =(expected-root.args (~(got by registered) hull.note.args))
    ?.  ?=(%mutate mode)
      [%.n %root-mismatch]
    ~>  %slog.[3 (rap 3 ~[label ' root mismatch'])]
    [%.n %root-mismatch]
  ?.  =(root.note.args expected-root.args)
    ?.  ?=(%mutate mode)
      [%.n %note-root-mismatch]
    ~>  %slog.[3 (rap 3 ~[label ' note root does not match expected root'])]
    [%.n %note-root-mismatch]
  ?.  ?=(%mutate mode)
    [%.y args]
  ?:  (~(has in settled) id.note.args)
    ~>  %slog.[3 (rap 3 ~[label ' note already settled (replay rejected)'])]
    [%.n %replay]
  [%.y args]
--
