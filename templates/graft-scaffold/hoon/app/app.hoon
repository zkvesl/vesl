::  nockup basic scaffold + vesl graft markers.
::
::  Copy this file over your nockup project's hoon/app/app.hoon,
::  then run `nockup graft inject hoon/app/app.hoon` to wire in the graft.
::  The `::  nockup:*` comments are injection anchors — don't delete them
::  until after you run `nockup graft inject`.
::
/+  lib
::  nockup:imports
/=  *  /common/wrapper
::
=>
|%
+$  versioned-state
  $:  %v1
      ::  nockup:state
  ==
::
::  domain-effect is your app's effect union. Add variants here as
::  your app emits them. The codegen-generated `+$ effect` below
::  splats domain-effect into a typed union with all graft effects.
::
::  nockup:domain-effect
+$  domain-effect
  $%  [%domain-placeholder ~]
  ==
::
::  `nockup graft inject` replaces the open `+$ effect *` below with a
::  typed union via codegen. Do not edit the codegen banner block by hand.
::
::  nockup:effect-union
+$  effect  *
::
+$  cause
  $%  [%cause ~]
      ::  nockup:cause
  ==
--
|%
++  moat  (keep versioned-state)
::
++  inner
  |_  state=versioned-state
  ::
  ++  load
    |=  old-state=versioned-state
    ^-  _state
    ::  `nockup graft inject` replaces the placeholder below via codegen with a
    ::  `=/  defaults  ^*(versioned-state)` + `%_  defaults  ...  ==`
    ::  overlay so resumed snapshots with a smaller noun shape get the
    ::  current kernel's per-graft defaults instead of garbage at the
    ::  new axes. See README "State checkpoints" for the schema-extension
    ::  migration semantics.
    ::
    ::  nockup:load-defaults
    old-state
  ::
  ++  peek
    |=  =path
    ^-  (unit (unit *))
    ::  nockup:peek
    ~
  ::
  ++  poke
    |=  =ovum:moat
    ^-  [(list effect) _state]
    =/  act  ((soft cause) cause.input.ovum)
    ?~  act
      ::  Soft-cast can fail on atom-typed input as well as cells with
      ::  unknown heads, so guard both before reading the tag.
      =/  tag=@tas
        ?@  cause.input.ovum  `@tas`cause.input.ovum
        ?@  -.cause.input.ovum  `@tas`-.cause.input.ovum
        %unknown
      ~>  %slog.[1 (crip "invalid cause [{<tag>} ...] (full: {<cause.input.ovum>})")]
      [~ state]
    ::  nockup:poke-prelude
    =/  out=[efx=(list effect) new=_state]
      ?-    -.u.act
          %cause
        ~>  %slog.[1 'poked']
        [~ state]
        ::  nockup:poke
      ==
    ::  nockup:poke-postlude
    out
  --
--
((moat |) inner)
