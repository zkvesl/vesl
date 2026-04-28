::  lib/validate-graft.hoon: pre-flight rule checks on poke causes
::
::  The Graft is a library, not a kernel. It provides:
::    1. A state fragment (validate-state) you graft onto your kernel state
::    2. A poke dispatcher for %validate-init / %validate-clear (rules
::       are caller-installed at boot or runtime; no manifest codegen)
::    3. A predicate `++check-rules` the prelude block calls
::
::  Phase 03c, behavior-graft band priority 100. Pairs with the new
::  poke-prelude marker landed in 03b. The prelude block runs BEFORE
::  the kernel's ?- switch; on rule failure the prelude short-circuits
::  and emits %validate-rejected, leaving state untouched.
::
::  Scope (v0.1): CAUSE-LEVEL rules only. The .dev/03 doc envisioned
::  field-level rules keyed by name. Field-level rules require graft-
::  inject codegen — a separate pass not yet shipped. v0.1 applies
::  rules to `+.act` (the body of the cause cell, after the tag);
::  useful for single-field causes whose body is one atom. A follow-on
::  codegen pass can layer named-field selection on top later.
::
::  Five rule shapes from the spec:
::    - non-empty   (v0.1 SHIPPED) — body must not be ~
::    - length      (v0.1 deferred — requires field selection)
::    - in-set      (v0.1 deferred — requires field selection)
::    - range       (v0.1 deferred — requires field selection)
::    - unique-in   (v0.1 deferred — requires cross-graft state read)
::
::  Rules install per cause-tag via %validate-init. Multiple rules
::  per cause-tag AND-conjoin; first failure short-circuits.
::
::  Usage:
::    /+  *validate-graft
::    ...your kernel...
::    +$  my-state  [validate=validate-state ...your-fields...]
::    ...in poke arm...
::    ?+  -.cause  [~ state]
::      %validate-init   (validate-poke validate.state cause)
::      %validate-clear  (validate-poke validate.state cause)
::    ==
::
|%
::  +$rule: a single rule applicable to a cause body.
::  v0.1 ships %non-empty only.
::
+$  rule
  $%  [%non-empty ~]
  ==
::
::  +$validate-state: the state fragment.
::  Aliased directly to the rules map — no wrapper struct, since
::  v0.1 only needs one map field.
::
+$  validate-state  (map @ta (list rule))
::
::  +new-state: fresh empty graft state
::
++  new-state
  ^-  validate-state
  *(map @ta (list rule))
::
::  +rules-cap: upper bound on the rules map (10k cause-tags).
::
++  rules-cap  ^~((mul 10 1.000))
::
::  +rules-per-cause-cap: upper bound on rules per cause-tag.
::
++  rules-per-cause-cap  ^~(64)
::
::  +$validate-effect: effects the Graft can produce
::
+$  validate-effect
  $%  [%validate-rules-installed cause-tag=@ta count=@ud]
      [%validate-rules-cleared cause-tag=@ta]
      [%validate-rejected cause-tag=@ta reason=@t]
      [%validate-error msg=@t]
  ==
::
::  +$validate-cause: tagged pokes the Graft handles
::
+$  validate-cause
  $%  [%validate-init cause-tag=@ta rules=(list rule)]
      [%validate-clear cause-tag=@ta]
  ==
::
::  +validate-poke: dispatch a validate cause against validate state
::
++  validate-poke
  |=  [state=validate-state cause=validate-cause]
  ^-  [(list validate-effect) validate-state]
  ?-  -.cause
    ::
    ::  %validate-init — install (or replace) rules for a cause-tag.
    ::
      %validate-init
    ?:  (gth (lent rules.cause) rules-per-cause-cap)
      :_  state
      ~[[%validate-error 'validate-graft: too many rules per cause']]
    ?:  ?&  !(~(has by state) cause-tag.cause)
            (gte ~(wyt by state) rules-cap)
        ==
      :_  state
      ~[[%validate-error 'validate-graft: rules map at capacity']]
    =/  new-state=validate-state
      (~(put by state) cause-tag.cause rules.cause)
    :_  new-state
    ~[[%validate-rules-installed cause-tag.cause (lent rules.cause)]]
    ::
    ::  %validate-clear — drop all rules for a cause-tag. Idempotent.
    ::
      %validate-clear
    =/  new-state=validate-state  (~(del by state) cause-tag.cause)
    :_  new-state
    ~[[%validate-rules-cleared cause-tag.cause]]
  ==
::
::  +check-rules: run installed rules for a cause-tag against the
::  cause body. Returns ~ on pass, [~ reason] on first failure.
::
::  Called from the prelude block:
::    =/  v-failure  (check-rules -.u.act +.u.act validate.state)
::    ?:  ?=(^ v-failure)
::      :_  state
::      ~[[%validate-rejected -.u.act u.v-failure]]
::
++  check-rules
  |=  [cause-tag=@ta body=* rules-by-cause=validate-state]
  ^-  (unit @t)
  =/  rs=(list rule)  (~(gut by rules-by-cause) cause-tag ~)
  |-
  ^-  (unit @t)
  ?~  rs  ~
  =/  here=(unit @t)  (apply-rule i.rs body)
  ?~  here
    $(rs t.rs)
  here
::
::  +apply-rule: evaluate a single rule against a cause body.
::  Returns ~ on pass, [~ reason] on fail.
::
++  apply-rule
  |=  [r=rule body=*]
  ^-  (unit @t)
  ?-  -.r
      %non-empty
    ?:  =(~ body)
      [~ 'validate: body is empty (rule: non-empty)']
    ~
  ==
::
::  +validate-peek: query validate state by path
::
::  [%validate-rules cause-tag=@ta] — the (list rule) for that
::  cause-tag, or ~ if none. Useful for debugging which rules are
::  active.
::
++  validate-peek
  |=  [state=validate-state =path]
  ^-  (unit (unit *))
  ?+  path  ~
      [%validate-rules cause-tag=@ta ~]
    =/  c  +<.path
    ``(~(get by state) c)
  ==
--
