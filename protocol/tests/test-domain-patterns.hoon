::  protocol/tests/test-domain-patterns.hoon
::
::  Tests every shipped apply-<graft> arm against a single multi-graft
::  state. Counter, kv, log, audit-write are covered in the commit-1
::  smoke fixture; this file extends coverage to queue, rbac, registry,
::  clock, validate, batch.
::
::  Compile success = all assertions passed. The wet-gate convention
::  means each apply-<graft> call is type-checked against the call-site
::  state — this file is the primary proof that all 9 arms compose
::  into one kernel.
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
/+  *domain-patterns
::
=>
|%
::  Versioned-state shape exercising all 9 grafts at once.
::  Field names follow the convention each graft documents in its
::  Usage block.
::
+$  full-state
  $:  counter=counter-state
      kv=kv-state
      queue=queue-state
      rbac=rbac-state
      registry=registry-state
      log=log-state
      clock=clock-state
      validate=validate-state
      batch=batch-state
  ==
--
::
=/  st=full-state
  :*  counter=*counter-state
      kv=*kv-state
      queue=*queue-state
      rbac=*rbac-state
      registry=*registry-state
      log=*log-state
      clock=*clock-state
      validate=`validate-state`*(map @ta (list rule))
      batch=*batch-state
  ==
::
::  ============================================
::  apply-counter (re-cover here for parity)
::  ============================================
::
=^  efx-c  st  (apply-counter [%counter-increment 'n'] st)
?>  ?=([%counter-incremented *] i.efx-c)
?>  =(1 (~(got by counters.counter.st) 'n'))
::
::  ============================================
::  apply-kv
::  ============================================
::
=^  efx-k  st  (apply-kv [%kv-set 'a' `@`1] st)
?>  ?=([%kv-stored *] i.efx-k)
?>  =(`@`1 (~(got by store.kv.st) 'a'))
::
::  ============================================
::  apply-queue
::  ============================================
::
=^  efx-q  st  (apply-queue [%queue-push (jam 'job1')] st)
?>  ?=([%queue-pushed *] i.efx-q)
?>  =(1 id.i.efx-q)
::
::  ============================================
::  apply-rbac
::  ============================================
::
=^  efx-r  st  (apply-rbac [%rbac-grant `@`0xdead ~['read' 'write']] st)
?>  ?=([%rbac-granted *] i.efx-r)
?>  =(`@`0xdead pubkey.i.efx-r)
?>  =(2 (lent added.i.efx-r))
::
::  ============================================
::  apply-registry
::  ============================================
::
=^  efx-rg  st  (apply-registry [%registry-put `@`0xbeef (jam 'rec')] st)
?>  ?=([%registry-stored *] i.efx-rg)
?>  =(`@`0xbeef key.i.efx-rg)
::
::  ============================================
::  apply-log
::  ============================================
::
=^  efx-l  st  (apply-log [%log-append %step (jam 'first')] st)
?>  ?=([%log-appended *] i.efx-l)
?>  =(1 seq.i.efx-l)
::
::  ============================================
::  apply-clock
::  ============================================
::
=^  efx-cl  st  (apply-clock [%clock-tick ~] st)
?>  ?=([%clock-ticked *] i.efx-cl)
?>  =(1 ticks.clock.st)
::
::  ============================================
::  apply-validate
::  ============================================
::
=^  efx-v  st  (apply-validate [%validate-init %demo ~[[%non-empty ~]]] st)
?>  ?=([%validate-rules-installed *] i.efx-v)
?>  =(%demo cause-tag.i.efx-v)
?>  =(1 count.i.efx-v)
::
::  ============================================
::  apply-batch
::  ============================================
::
=^  efx-bi  st  (apply-batch [%batch-init 5] st)
?>  ?=([%batch-initialized *] i.efx-bi)
?>  =(5 threshold.batch.st)
=^  efx-ba  st  (apply-batch [%batch-add (jam 'item1')] st)
?>  ?=([%batch-added *] i.efx-ba)
?>  =(1 id.i.efx-ba)
::
::  ============================================
::  Multi-arm =^ chain across three different grafts threads cleanly
::  ============================================
::
=^  efx1  st  (apply-counter [%counter-increment 'n'] st)
=^  efx2  st  (apply-kv [%kv-set 'b' `@`2] st)
=^  efx3  st  (apply-log [%log-append %multi (jam 'x')] st)
?>  =(2 (~(got by counters.counter.st) 'n'))
?>  =(`@`2 (~(got by store.kv.st) 'b'))
?>  =(2 next-seq.log.st)
::
%test-domain-patterns-passed
