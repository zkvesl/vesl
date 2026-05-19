# H-04 Follow-Up — Schnorr Message-Uniqueness Call-Site Audit

Companion to `docs/AUDIT_REPORT.md` §3.H-04. Vesl's Schnorr-over-
Cheetah signing layer is deterministic: the nonce is derived as
`trunc_g_order(hash_varlen(pk.x | pk.y | message | sk))`. This is
correct deterministic Schnorr and matches the Hoon reference. The
security argument requires every signing call for a given key to use
a **distinct `message`** value. The signing layer adds no randomness
on the caller's behalf — that's documented at
`crates/vesl-core/src/signing.rs:219-235`.

This doc enumerates every production `sign()` call site across the
vesl-core / vesl-nockup / hull-llm / x402-nockchain ecosystem,
identifies what guarantees freshness for each, and flags any sites
where the contract is not obviously satisfied.

The deliverable is the inventory in §2 plus the per-site action
list in §3. Implementation work (annotations, freshness fixes) flows
from what the inventory surfaces.

## 1. Why this is an audit doc, not a design doc

The other two H-finding docs (`AUDIT_H01_TEST_MODE.md`,
`AUDIT_H03_HASH_LEAF.md`) present design options and recommend one.
H-04 is different: there is no design choice. The fix per call site
is either "annotate the freshness source" or "add a freshness
source" — both decided at the per-site level after inspection.

What this doc does is the inspection.

## 2. Call-site inventory

Source: `grep -rn "signing::sign\|vesl_signing::sign\|schnorr_sign"`
across vesl-core, vesl-nockup, hull-llm, x402-nockchain. Test-only
sites (anything under `#[cfg(test)]`, `tests/`, `examples/`) are
excluded — the audit deliverable is the production surface.

| # | Site | Message source | Freshness guarantee | Disposition |
|---|------|----------------|---------------------|-------------|
| 1 | `vesl-core/src/settle.rs:253` (`sign_tx`) | `msg_belts` derived from kernel-computed `sig_hash` over `(seeds, fee)` via the Hoon `kernel_sig_hash` arm | `seeds` carries the per-transaction `parent_hash`, distinct per settlement; the kernel asserts non-collision at the boundary | **Annotate.** Add `// freshness: parent_hash in seeds (per-settlement unique)` immediately above the `sign()` call. |
| 2 | `hull-llm/src/tx_builder.rs:117` | `msg_belts` derived from settlement payload; calls `vesl_core::signing::sign` directly | Payload includes note-id; note-id uniqueness enforced by the settle kernel's `settled` replay set | **Annotate + verify.** Confirm in `tx_builder.rs` caller that note-id is freshly generated per call (not reused across retries); add `// freshness: note-id (settle-kernel replay-checked)` annotation. |
| 3 | `vesl-nockup/crates/vesl-signing/src/caip122.rs:194` (`SiwnSigner::sign`) | `tip5_with_domain(SIWN, message_body)` where `message_body` includes a `Nonce` field per CAIP-122 | Replay cache enforces nonce-uniqueness within the configured window; the `Nonce` field is explicitly random per the SIWN spec | **Annotate + cross-link.** `// freshness: SIWN Nonce field, replay-cache-enforced (see M-07)`. Cross-reference the M-07 server-side window cap so the freshness window is bounded. |
| 4 | `vesl-nockup/crates/vesl-wallet/src/wallet.rs:106` (`sign_intent`) | Intent payload — shape controlled by the caller of `sign_intent` | **Unknown until verified.** The function signature accepts arbitrary intent bytes; freshness depends on the caller's intent-construction discipline | **ACTION REQUIRED.** Inspect callers of `sign_intent` (likely in `hull-llm` and any x402 facilitator that signs intents). For each: identify the freshness source in the intent payload (timestamp, counter, nonce). If no freshness source exists, propose one — either add a required `intent_id` field or document the contract that callers must supply uniqueness. Annotate the `sign_intent` body afterward. |
| 5 | `x402-nockchain/crates/x402-nockchain-crypto/src/signer.rs:83` (inside `sign_authorization`) | `schnorr_sign(&self.sk, &digest)` where `digest` is the x402 authorization message digest | x402 spec mandates authorization messages include a timestamp + nonce; both are part of the pre-image | **Annotate.** `// freshness: x402 authorization (timestamp + nonce per spec §...)`. Cite the relevant x402 spec section in the comment. |
| 6 | `x402-nockchain/crates/x402-nockchain-wallet-client/src/lib.rs:370` (`vesl_signing::sign` chain settlement) | `sig_msg` over the chain payload | Per-payment unique by construction (amount + recipient + nonce in the payload) | **Annotate.** `// freshness: payment fields (amount + recipient + nonce) make sig_msg per-payment unique`. |
| 7 | `x402-nockchain/crates/x402-nockchain-wallet-client/src/lib.rs:432` (`schnorr_sign` envelope) | Envelope message; constructed at line ~430 | **Unknown until verified.** The envelope construction path is not obvious from the call site alone | **ACTION REQUIRED.** Read the envelope-construction code immediately above line 432. Identify what makes the envelope per-invocation unique. If unclear, add a `nonce` field to the envelope structure and include it in the pre-image. Annotate afterward. |

## 3. Per-site action list

Three categories: pure-annotation, annotate-plus-verify, and
action-required.

### 3.1 Pure annotation (sites 1, 3, 5, 6)

Add a one-line comment above each `sign(...)` call naming the
freshness source. Format:

```rust
// freshness: <source> (<why-unique-per-call>)
let sig = signing::sign(&sk, &msg)?;
```

These four sites have obvious, documented freshness. The annotation
is forensic: future maintainers can grep `freshness:` to find every
signing call without re-deriving the contract.

### 3.2 Annotate + verify (site 2)

Inspect the `tx_builder.rs` caller chain to confirm note-id is
freshly minted per `sign_tx` invocation. The note-id is supposed to
be unique-per-settlement, but a retry-on-error path that re-uses the
same note-id would silently break the contract (re-signing the same
note-id with the same key under deterministic Schnorr produces the
same signature — safe in isolation, but means "same signature" can
no longer be used as a replay-detection signal upstream).

Add the annotation only after the inspection confirms the caller
discipline.

### 3.3 Action required (sites 4, 7)

These two sites need real work:

- **Site 4 (`sign_intent`).** The function signature is generic over
  intent bytes; freshness is the caller's responsibility. Inspect
  every caller of `sign_intent`:
  - Identify the freshness source per caller.
  - If a caller has no freshness source, either fix the caller or
    add a required `intent_id` parameter to `sign_intent` itself.
  - Document the contract in the `sign_intent` rustdoc.
- **Site 7 (envelope sign).** Read the envelope-construction code at
  `x402-nockchain-wallet-client/src/lib.rs:425-435`. Identify what
  makes the envelope per-invocation unique. If unclear, the envelope
  needs a nonce field added to the pre-image.

Both sites are escalations: the audit's job is to flag the unknown;
the implementation session that picks up this doc decides the fix.

## 4. Interaction with H-03

Site #2 (`hull-llm/src/tx_builder.rs:117`) signs a digest that today
flows through `vesl-core/src/signing.rs:206`
(`schnorr_message_digest_for_data`), which uses raw `hash_leaf`.
That helper inherits the H-03 trailing-zero collision: two `data`
values differing only in trailing zeros produce the same digest and
therefore the same signature.

Once H-03 lands and `schnorr_message_digest_for_data` migrates to
`hash_leaf_v2_domain`, the side channel closes. The H-04 site #2
annotation should cite the v2-domain primitive once it exists, not
the legacy primitive.

This creates a sequencing constraint: **H-03 lands before H-04
annotations are merged.** Annotations written against the legacy
primitive go stale immediately when H-03 lands.

Sites that don't flow through `schnorr_message_digest_for_data`
(sites 1, 3, 4, 5, 6, 7) are independent of H-03 and can be
annotated whenever.

## 5. Inspection checklist for site 4 and site 7

For each `ACTION REQUIRED` site, the implementer should:

1. Read the function body and the message construction code.
2. List every field that contributes to the pre-image.
3. For each field, answer: is this guaranteed unique per logical
   document? If yes, name the guarantee (timestamp, counter, ID
   field, derived from a randomized input). If no, propose where to
   inject a fresh source.
4. If multiple fields are required to be jointly unique (a
   `(user_id, action_id)` pair, say), document the joint
   uniqueness invariant — and add a property test if one doesn't
   exist.
5. Annotate the `sign(...)` call once the inspection passes.

The inspection criteria above are not novel — they're the standard
deterministic-signature contract restated. The point of writing
them down is that the inspection is auditable: a reviewer can walk
the checklist against the call site and confirm the answer.

## 6. Stash coordination

A grep across all Hoon and Rust files in
`~/projects/nockchain/stark-proof-stash` found **zero new signing
call sites**. The stash's `vesl-kernel.hoon` rewrite and the new
`vesl-prover.hoon` arm carry no signing logic; the
`rag-logic-{standalone,provable}.hoon` libraries are pure manifest
structuring.

The call-site inventory in §2 is complete relative to the stash. No
rework needed at stash re-apply.

## 7. Sequencing relative to other follow-ups

H-04 is coupled to H-03 (per §4): annotations should land after H-03
so they can cite the collision-safe primitive. H-04 is independent
of H-01.

Within H-04, the three categories can land in any order:
- Pure annotations (sites 1, 3, 5, 6) — trivial, can batch.
- Annotate + verify (site 2) — depends on `tx_builder.rs` reading.
- Action required (sites 4, 7) — separate sessions per site.

The `ACTION REQUIRED` sites are the highest-priority within H-04
because they carry the real risk; the annotations are forensic.

## 8. Out of scope

- Test-only `sign()` calls. Tests construct synthetic messages with
  known properties; the freshness contract doesn't apply at the same
  granularity.
- The `from_belts` overflow in `vesl-nockup/crates/vesl-signing/
  src/schnorr.rs:119` — that's M-08, separate ticket.
- Replay cache persistence (M-05) and window cap (M-07). The
  cross-reference from site #3 to M-07 in the inventory is for
  context; the M-07 fix itself is a separate cycle.
- Removing the deterministic-nonce property in favor of randomized
  Schnorr. The Hoon reference is deterministic; changing that would
  ripple through the entire signing surface — out of scope here.

## 9. Links

- Audit report: `docs/AUDIT_REPORT.md`
- Umbrella index: `docs/AUDIT_FOLLOWUP_INDEX.md`
- Companion H-finding docs: `docs/AUDIT_H01_TEST_MODE.md`,
  `docs/AUDIT_H03_HASH_LEAF.md`
- Schnorr signing source: `crates/vesl-core/src/signing.rs:200-260`
- Hoon reference: `~/projects/nockchain/nockchain/hoon/...three.hoon`
  (lines 1628-1661, `sign:affine:belt-schnorr:cheetah`)
- Determinism contract: `crates/vesl-core/src/signing.rs:219-235`
- SIWN replay cache: `vesl-nockup/crates/vesl-signing/src/replay_cache.rs`
- M-07 (SIWN window cap): tracked in umbrella index
- x402 spec: `~/projects/nockchain/x402-nockchain/docs/` (locate at
  inspection time)
