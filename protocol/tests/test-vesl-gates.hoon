::  protocol/tests/test-vesl-gates.hoon: vesl-gates Tier 1a coverage.
::
::  Each gate (sig-verify-ed25519, manifest-verify, set-membership-
::  verify) exercised across positive (valid proof), negative
::  (tampered / wrong-key), and hostile (malformed `data=*`) cases.
::  Compilation success = all `?>` / `?<` claims hold.
::
::  Compile: hoonc --arbitrary --new protocol/tests/test-vesl-gates.hoon hoon/
::
::    ?>  pred   asserts pred is %.y (positive case)
::    ?<  pred   asserts pred is %.n (negative + hostile cases)
::
::
/+  *vesl-merkle
/+  *vesl-gates
/=  *  /common/zose
::
::  ============================================
::  Shared merkle fixture: 4-leaf tree
::    leaves a/b/c/d  ->  h0/h1/h2/h3
::    pairs           ->  h01 h23
::    root            ->  h0123
::  ============================================
::
=/  a=@  'alice'
=/  b=@  'bob'
=/  c=@  'carol'
=/  d=@  'dave'
=/  h0  (hash-leaf a)
=/  h1  (hash-leaf b)
=/  h2  (hash-leaf c)
=/  h3  (hash-leaf d)
=/  h01  (hash-pair h0 h1)
=/  h23  (hash-pair h2 h3)
=/  root  (hash-pair h01 h23)
::
=/  proof-a=(list [hash=@ side=?])
  ~[[hash=h1 side=%.n] [hash=h23 side=%.n]]
=/  proof-c=(list [hash=@ side=?])
  ~[[hash=h3 side=%.n] [hash=h01 side=%.y]]
=/  proof-bogus=(list [hash=@ side=?])
  ~[[hash=h2 side=%.n] [hash=h01 side=%.y]]
::
::  ============================================
::  TEST: set-membership-verify
::  ============================================
::
::  Positive: a is in the tree under proof-a
::
?>  %-  set-membership-verify
    [note-id=0 data=[elem=a proof=proof-a] expected-root=root]
::
::  Positive: c is in the tree under proof-c
::
?>  %-  set-membership-verify
    [note-id=0 data=[elem=c proof=proof-c] expected-root=root]
::
::  Negative: a's leaf doesn't bind under proof-c
::
?<  %-  set-membership-verify
    [note-id=0 data=[elem=a proof=proof-c] expected-root=root]
::
::  Negative: bogus hashes don't reach root
::
?<  %-  set-membership-verify
    [note-id=0 data=[elem=a proof=proof-bogus] expected-root=root]
::
::  Hostile: data is a bare atom, not the [elem proof] cell
::
?<  (set-membership-verify note-id=0 data=42 expected-root=root)
::
::  Hostile: data is a 2-cell of cells where atoms expected
::
?<  (set-membership-verify note-id=0 data=[[1 2] [3 4]] expected-root=root)
::
::  ============================================
::  TEST: manifest-verify
::  ============================================
::
::  Positive: 2-field manifest with valid (value, proof) pairs
::
=/  manifest-pos=[fields=(list [name=@t value=@]) proofs=(list (list [hash=@ side=?]))]
  :-  ~[[name='subject' value=a] [name='reviewer' value=c]]
  ~[proof-a proof-c]
?>  %-  manifest-verify
    [note-id=0 data=manifest-pos expected-root=root]
::
::  Negative: tampered field value (a's proof but value is b)
::
=/  manifest-tamper=[fields=(list [name=@t value=@]) proofs=(list (list [hash=@ side=?]))]
  :-  ~[[name='subject' value=b]]
  ~[proof-a]
?<  %-  manifest-verify
    [note-id=0 data=manifest-tamper expected-root=root]
::
::  Negative: length mismatch (2 fields, 1 proof)
::
=/  manifest-mismatch=[fields=(list [name=@t value=@]) proofs=(list (list [hash=@ side=?]))]
  :-  ~[[name='x' value=a] [name='y' value=c]]
  ~[proof-a]
?<  %-  manifest-verify
    [note-id=0 data=manifest-mismatch expected-root=root]
::
::  Hostile: data is a bare atom
::
?<  (manifest-verify note-id=0 data=0xdead expected-root=root)
::
::  Hostile: cell with wrong shape
::
?<  (manifest-verify note-id=0 data=[~[1] ~] expected-root=root)
::
::  ============================================
::  TEST: sig-verify-ed25519
::  ============================================
::
::  Real keypair + signature.  sk kept short (4 bytes) for fixture
::  determinism -- a longer atom literal triggers a hoonc edge case
::  in the test wrapper that doesn't reproduce in production code
::  (settle-graft passing the gate via a parameterized closure).
::
=/  ed-sk=@  0xabad.f00d
=/  ed-pk  (puck:ed:crypto ed-sk)
=/  ed-msg  'attest: revenue Q3 = $47M'
=/  ed-sig  (sign:ed:crypto ed-msg ed-sk)
=/  ed-root  (hash-leaf ed-pk)
::
::  Positive
::
?>  %-  sig-verify-ed25519
    :*  note-id=0
        data=[data=ed-msg sig=ed-sig pubkey=ed-pk]
        expected-root=ed-root
    ==
::
::  Negative: tampered signature
::
?<  %-  sig-verify-ed25519
    :*  note-id=0
        data=[data=ed-msg sig=(mix ed-sig 1) pubkey=ed-pk]
        expected-root=ed-root
    ==
::
::  Negative: wrong pubkey (different sk derives different key)
::
=/  ed-pk-other  (puck:ed:crypto +(ed-sk))
?<  %-  sig-verify-ed25519
    :*  note-id=0
        data=[data=ed-msg sig=ed-sig pubkey=ed-pk-other]
        expected-root=ed-root
    ==
::
::  Negative: root commits to a different pubkey (sig valid, root
::  binding fails)
::
?<  %-  sig-verify-ed25519
    :*  note-id=0
        data=[data=ed-msg sig=ed-sig pubkey=ed-pk]
        expected-root=(hash-leaf ed-pk-other)
    ==
::
::  Hostile: data is a bare atom
::
?<  (sig-verify-ed25519 note-id=0 data=0xdead expected-root=ed-root)
::
::  Hostile: data is a 2-tuple (gate expects 3)
::
?<  (sig-verify-ed25519 note-id=0 data=[1 2] expected-root=ed-root)
::
::  ============================================
::  TEST: sig-verify-schnorr (cheetah)
::  ============================================
::
::  Cheetah schnorr signs from a list of 32-bit-belt limbs (matches
::  the wallet's belt-schnorr wrapper); verify-side accepts a flat
::  sig atom packed as (chal << 256) | s.  Pubkey is the ser-a-pt
::  affine-point serialization (the wallet-export shape).  Each
::  belt in the sk-list must be < 2^32 (sign asserts this); short
::  fixtures sit comfortably inside that bound.
::
=/  sch-sk-belts=(list belt)  ~[0xabad.f00d 0x0 0x0 0x0 0x0]
=/  sch-sk=@                  (rep 5 sch-sk-belts)
=/  sch-pk-pt=a-pt:curve:cheetah
  (ch-scal:affine:curve:cheetah sch-sk a-gen:curve:cheetah)
=/  sch-pk=@ux                (ser-a-pt:cheetah sch-pk-pt)
=/  sch-msg                   'attest: revenue Q3 = $47M'
=/  sch-digest=noun-digest:tip5
  (hash-leaf-digest sch-msg)
=/  sch-cs=[chal=@ux s=@ux]
  (sign:affine:schnorr:cheetah sch-sk-belts sch-digest)
=/  sch-sig=@                 (cat 8 s.sch-cs chal.sch-cs)
=/  sch-root                  (hash-leaf sch-pk)
::
::  Positive
::
?>  %-  sig-verify-schnorr
    :*  note-id=0
        data=[data=sch-msg sig=sch-sig pubkey=sch-pk]
        expected-root=sch-root
    ==
::
::  Negative: tampered signature (flip 1 bit in the s half)
::
?<  %-  sig-verify-schnorr
    :*  note-id=0
        data=[data=sch-msg sig=(mix sch-sig 1) pubkey=sch-pk]
        expected-root=sch-root
    ==
::
::  Negative: wrong pubkey (re-derive from a different sk)
::
=/  sch-sk-belts-other=(list belt)  ~[0xdead.beef 0x0 0x0 0x0 0x0]
=/  sch-sk-other=@                  (rep 5 sch-sk-belts-other)
=/  sch-pk-pt-other=a-pt:curve:cheetah
  (ch-scal:affine:curve:cheetah sch-sk-other a-gen:curve:cheetah)
=/  sch-pk-other=@ux  (ser-a-pt:cheetah sch-pk-pt-other)
?<  %-  sig-verify-schnorr
    :*  note-id=0
        data=[data=sch-msg sig=sch-sig pubkey=sch-pk-other]
        expected-root=sch-root
    ==
::
::  Negative: root commits to a different pubkey (sig valid, root
::  binding fails)
::
?<  %-  sig-verify-schnorr
    :*  note-id=0
        data=[data=sch-msg sig=sch-sig pubkey=sch-pk]
        expected-root=(hash-leaf sch-pk-other)
    ==
::
::  Hostile: data is a bare atom (not a 3-tuple)
::
?<  (sig-verify-schnorr note-id=0 data=0xdead expected-root=sch-root)
::
::  Hostile: pubkey atom is not a valid serialized affine point
::           (de-a-pt's in-g:affine:curve check fires inside the mule)
::
?<  %-  sig-verify-schnorr
    :*  note-id=0
        data=[data=sch-msg sig=sch-sig pubkey=0xdead.beef]
        expected-root=(hash-leaf 0xdead.beef)
    ==
::
::  ============================================
::  TEST: bounded-value-verify
::  ============================================
::
::  Dedicated 4-leaf fixture.  Leaves are jam([value bounds]) atoms,
::  not raw atoms -- the top-of-file fixture hashes raw atoms and
::  cannot serve this gate's leaf shape.  Three of the four leaves
::  carry the same bounds [10, 100] for boundary-value tests; the
::  fourth carries different bounds as a sibling-only entry.
::
=/  bv-bounds=[lo=@ hi=@]      [lo=10 hi=100]
=/  bv-other=[lo=@ hi=@]       [lo=1 hi=99]
=/  bv-jam-mid=@               (jam [42 bv-bounds])
=/  bv-jam-lo=@                (jam [10 bv-bounds])
=/  bv-jam-hi=@                (jam [100 bv-bounds])
=/  bv-jam-other=@             (jam [7 bv-other])
=/  bv-h0                      (hash-leaf bv-jam-mid)
=/  bv-h1                      (hash-leaf bv-jam-lo)
=/  bv-h2                      (hash-leaf bv-jam-hi)
=/  bv-h3                      (hash-leaf bv-jam-other)
=/  bv-h01                     (hash-pair bv-h0 bv-h1)
=/  bv-h23                     (hash-pair bv-h2 bv-h3)
=/  bv-root                    (hash-pair bv-h01 bv-h23)
::
=/  bv-proof-mid=(list [hash=@ side=?])
  ~[[hash=bv-h1 side=%.n] [hash=bv-h23 side=%.n]]
=/  bv-proof-lo=(list [hash=@ side=?])
  ~[[hash=bv-h0 side=%.y] [hash=bv-h23 side=%.n]]
=/  bv-proof-hi=(list [hash=@ side=?])
  ~[[hash=bv-h3 side=%.n] [hash=bv-h01 side=%.y]]
::
::  Positive: 42 in [10, 100] under valid proof
::
?>  %-  bounded-value-verify
    :*  note-id=0
        data=[value=42 bounds=bv-bounds proof=bv-proof-mid]
        expected-root=bv-root
    ==
::
::  Positive boundary: lower edge (value == lo)
::
?>  %-  bounded-value-verify
    :*  note-id=0
        data=[value=10 bounds=bv-bounds proof=bv-proof-lo]
        expected-root=bv-root
    ==
::
::  Positive boundary: upper edge (value == hi)
::
?>  %-  bounded-value-verify
    :*  note-id=0
        data=[value=100 bounds=bv-bounds proof=bv-proof-hi]
        expected-root=bv-root
    ==
::
::  Negative: out-of-range (value=5 < lo=10).  Bounds check
::  short-circuits before the merkle proof is consulted.
::
?<  %-  bounded-value-verify
    :*  note-id=0
        data=[value=5 bounds=bv-bounds proof=bv-proof-mid]
        expected-root=bv-root
    ==
::
::  Negative: tampered bounds.  Caller substitutes [5 50] for the
::  committed [10 100]; bounds check passes (42 in [5 50]), but
::  hash-leaf(jam([42 [5 50]])) differs from the committed leaf,
::  so verify-chunk rejects.
::
?<  %-  bounded-value-verify
    :*  note-id=0
        data=[value=42 bounds=[lo=5 hi=50] proof=bv-proof-mid]
        expected-root=bv-root
    ==
::
::  Negative: vacuous bounds (lo > hi).  gte short-circuits %.n
::  for any value, no special-casing required.
::
?<  %-  bounded-value-verify
    :*  note-id=0
        data=[value=42 bounds=[lo=100 hi=10] proof=bv-proof-mid]
        expected-root=bv-root
    ==
::
::  Hostile: data is a bare atom (mule catches the ;; failure)
::
?<  (bounded-value-verify note-id=0 data=42 expected-root=bv-root)
::
::  Hostile: bounds slot is an atom instead of [lo=@ hi=@]
::           (well-formed top-level 3-cell, but inner shape wrong)
::
?<  (bounded-value-verify note-id=0 data=[1 2 ~] expected-root=bv-root)
::
%pass
