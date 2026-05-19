::  lib/rbac-graft.hoon: pubkey-keyed permission table
::
::  The Graft is a library, not a kernel. It provides:
::    1. A state fragment (rbac-state) you graft onto your kernel state
::    2. A poke dispatcher for %rbac-grant / %rbac-revoke
::    3. Peek helpers for permission counts and individual perm checks
::
::  Causes carry a `(list @t)` of perms — Hoon `(silt list)` builds
::  the internal `(set @t)` on the way in. List rather than set on
::  the wire keeps Rust callers from having to construct treap-shaped
::  nouns: a slice-of-cords lowers to a flat list trivially.
::
::  Two-level capacity:
::    - `roles-cap` (10M) on the outer `roles` map
::    - `perms-per-role-cap` (1000) on each pubkey's `(set @t)`
::  Without the inner cap, a single attacker entry can fan out
::  unbounded permissions inside one row, defeating the outer cap
::  (AUDIT 2026-04-19 H-02 carryover).
::
::  Auto-clear: when a revoke leaves a pubkey with zero perms, the
::  pubkey is removed from `roles` so `~(wyt by roles)` keeps an
::  honest "users with any perms" count.
::
::  Usage:
::    /+  *rbac-graft
::    ...your kernel...
::    +$  my-state  [rbac=rbac-state ...your-fields...]
::    ...in poke arm...
::    ?+  -.cause  [~ state]
::      %rbac-grant   (rbac-poke rbac.state cause)
::      %rbac-revoke  (rbac-poke rbac.state cause)
::    ==
::
|%
::  +$rbac-state: the state fragment — graft this onto your kernel
::
::    roles — pubkey=@ -> permissions=(set @t)
::
+$  rbac-state
  $:  roles=(map @ (set @t))
  ==
::
::  +new-state: fresh empty graft state
::
++  new-state
  ^-  rbac-state
  :*  roles=*(map @ (set @t))
  ==
::
::  +roles-cap: outer cap on the `roles` map.
::
++  roles-cap  ^~((mul 10.000 1.000))
::
::  +perms-per-role-cap: inner cap on the `(set @t)` per pubkey.
::
::  Without this an attacker who owns one pubkey can fan out perms
::  inside a single entry and bypass the outer cap.
::
++  perms-per-role-cap  `@ud`1.000
::
::  +$rbac-effect: effects the Graft can produce
::
::  Grant/revoke surfaces only the diff (set difference / set
::  intersection respectively) rather than the full perms set —
::  callers wanting the post-state can peek.
::
+$  rbac-effect
  $%  [%rbac-granted pubkey=@ added=(list @t)]
      [%rbac-revoked pubkey=@ removed=(list @t)]
      [%rbac-error msg=@t]
  ==
::
::  +$rbac-cause: tagged pokes the Graft handles
::
::  Perms arrive as `(list @t)` rather than `(set @t)` so Rust
::  callers can hand a flat slice without constructing a treap.
::
+$  rbac-cause
  $%  [%rbac-grant pubkey=@ perms=(list @t)]
      [%rbac-revoke pubkey=@ perms=(list @t)]
  ==
::
::  +rbac-poke: dispatch an rbac cause against rbac state
::
++  rbac-poke
  |=  [state=rbac-state cause=rbac-cause]
  ^-  [(list rbac-effect) rbac-state]
  ?-  -.cause
    ::
    ::  %rbac-grant — union with held; surface added (set diff).
    ::
      %rbac-grant
    =/  asked=(set @t)  (silt perms.cause)
    =/  held=(set @t)   (~(gut by roles.state) pubkey.cause ~)
    =/  added=(set @t)  (~(dif in asked) held)
    =/  union=(set @t)  (~(uni in held) asked)
    ::  Outer cap: only relevant when registering a NEW pubkey.
    ::
    ?:  ?&  !(~(has by roles.state) pubkey.cause)
            (gte ~(wyt by roles.state) roles-cap)
        ==
      :_  state
      ~[[%rbac-error 'rbac-graft: roles map at capacity']]
    ::  Inner cap: applies to every put, even pure overwrites.
    ::
    ?:  (gth ~(wyt in union) perms-per-role-cap)
      :_  state
      ~[[%rbac-error 'rbac-graft: perms-per-role at capacity']]
    =/  new-roles  (~(put by roles.state) pubkey.cause union)
    :_  state(roles new-roles)
    ~[[%rbac-granted pubkey.cause ~(tap in added)]]
    ::
    ::  %rbac-revoke — intersect with held; auto-clear when empty.
    ::
    ::  Why removed is computed via skim instead of `(~(int in asked) held)`:
    ::  the stdlib `int:in` allocates unboundedly under interpretation when
    ::  the two sets share elements — confirmed by R3/02 §B bisect 2026-05-01.
    ::  `removed` is only used as a list (the effect's `removed` field), so we
    ::  build it directly via `skim ~(tap in asked)` filtered by `has:in held`.
    ::  Set-theoretically identical to asked ∩ held; avoids the int:in path.
    ::
      %rbac-revoke
    =/  asked=(set @t)      (silt perms.cause)
    =/  held=(set @t)       (~(gut by roles.state) pubkey.cause ~)
    =/  remaining=(set @t)  (~(dif in held) asked)
    =/  removed=(list @t)
      %+  skim  ~(tap in asked)
      |=(p=@t (~(has in held) p))
    =/  new-roles
      ?~  remaining
        (~(del by roles.state) pubkey.cause)
      (~(put by roles.state) pubkey.cause remaining)
    :_  state(roles new-roles)
    ~[[%rbac-revoked pubkey.cause removed]]
  ==
::
::  +rbac-peek: query rbac state by path
::
::  - [%rbac-perm-count pubkey=@] returns Some(count) of held perms;
::    0 for unregistered pubkeys (the auto-clear invariant means
::    "0 perms" and "no entry" are the same observable state).
::  - [%rbac-has-perm pubkey=@ perm=@t] returns Some(?), with
::    %.y if the pubkey holds the perm, %.n otherwise (including
::    when the pubkey is unregistered).
::
++  rbac-peek
  |=  [state=rbac-state =path]
  ^-  (unit (unit *))
  ?+  path  ~
    [%rbac-perm-count pubkey=@ ~]
      =/  pk  +<.path
      =/  held=(set @t)  (~(gut by roles.state) pk ~)
      ``[~ ~(wyt in held)]
    [%rbac-has-perm pubkey=@ perm=@t ~]
      =/  pk    +<.path
      =/  perm  +<.+.path
      =/  held=(set @t)  (~(gut by roles.state) pk ~)
      ``[~ (~(has in held) perm)]
  ==
--
