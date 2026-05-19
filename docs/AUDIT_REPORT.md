# Vesl Security Audit Report

**Scope:** `vesl-core` @ `d613b05` (branch `parametize-3`) and `vesl-nockup` @ working tree.
**Methodology:** adversarial whitebox review of the Rust↔Hoon trust boundary, kernel JAM integrity, STARK verifier, Merkle commitment math, settlement state-machine, HTTP API, signing primitives (Schnorr-over-Cheetah + BIP-39/44), SIWN, replay caches, and the sync.sh supply chain.
**Auditor framing:** treat every kernel poke, every effect-list return, every byte that crosses the noun boundary as attacker-influenced unless an explicit gate proves otherwise.

---

## 1. Executive Summary

Vesl's security posture is **structurally sound but operationally brittle**. The protocol invariants (JAM integrity gates, version-pinned STARK verifier, deterministic Schnorr, domain-separated Tip5 hashing, replay-protected settle kernel, depth-capped Merkle proofs) are correctly designed and well-tested. The Hoon kernels are conservative, the kernel-arms chain validates registration / expected-root / note-root / replay in the right order, and the Rust SDK layers (`Mint`, `Guard`, `Settle`) bound input sizes, reject duplicate chunk IDs, and constant-time-compare roots.

What it doesn't do reliably is **propagate kernel state divergence back to its API callers**. The generic hull's `/commit` and `/settle` endpoints silently desynchronize from the on-chain kernel after the first commit per `hull_id`, because the kernel rejects re-registration but the Rust handler discards the empty-effects signal. Anyone trusting the hull's response field on a subsequent commit is accepting a claim the kernel never attested. This is the single most consequential finding in the audit.

Beyond that one, the more interesting risks are concentrated in three places:

1. **STARK verifier knobs** — `test-mode` is a runtime parameter not bound into the proof, and a self-documented constraint-completeness TODO sits next to soundness-critical challenge derivation.
2. **Length-collision on tip5 hash-leaf** — `hash_leaf("x")` == `hash_leaf("x\0")`, an intentional cross-VM alignment property with documented but easy-to-trip security implications for any caller treating byte-length as semantic.
3. **Operational surfaces** — in-memory replay caches, global rate limits, demo signing keys, and a sync.sh supply chain that copies symlinks with `cp -rL`. These are not bugs; they are choices that need operator awareness to ship safely.

The ZK-proof boundary itself appears tight: version pinning to `%2` blocks v0/v1 replay, `verify-settlement` binds STARK output to `expected-root` and `expected-hull`, and `verify-chunk` is domain-separated against `hash-pair`. The deterministic Schnorr-over-Cheetah signing layer mirrors the Hoon reference, range-checks scalars, and rejects zero nonces/challenges/signatures. The kernel JAM integrity gate (build-time sha256 baked in, runtime assert before boot) blocks the post-build tamper path; the `check-jam.sh` source-of-truth gate catches the pre-build tamper path.

No findings break the underlying STARK verifier math. No findings break the Merkle proof verification math. No findings let an unauthenticated attacker mint a fake settlement on-chain — the kernel-side `validate-settlement-args` chain holds. The Critical finding below is about the hull lying to its caller, not about chain attestation.

**Finding counts:** 1 Critical, 4 High, 9 Medium, 17 Low/Informational.

---

## 2. Critical Vulnerabilities

### C-01 — Hull `/commit` silently desynchronizes from kernel-registered root

**Severity:** Critical (integrity)
**Files:**
- `hull/src/api.rs:339-401` (commit_handler)
- `hull/src/api.rs:403-437` (settle_handler)
- `protocol/lib/kernel-arms.hoon:17-23` (handle-register)
- `protocol/lib/settle-kernel.hoon:78-83`

**Description.** The settle kernel's `%register` cause is single-shot per hull. `handle-register` returns `~` on duplicate hull, the calling kernel arm returns `[~ state]` (no effects, no state change), and slogs `'settle: hull already registered'`. The Rust hull's `commit_handler` constructs a `%register` poke on **every** call to `/commit` and discards the returned effect list with `let _effects = poke_kernel_with_timeout(...)`. It then unconditionally overwrites `st.fields` and `st.tree` with the new commitment and returns `status: "committed"` with the new Merkle root in the response body.

After the first successful `/commit` for a hull, every subsequent `/commit`:
- silently fails kernel-side (empty effect list, no `%registered` emitted),
- updates local Rust state to a root the kernel has not attested,
- returns HTTP 200 with `merkle_root: <new_root>` to the caller,
- and the `/verify` endpoint then validates proofs locally against this kernel-unrecognized root.

The `/settle` handler is the same anti-pattern but at least reports `settled: !effects.is_empty()` — which means once the first commit has registered, **every subsequent `/settle` call returns `settled: false`**, making the endpoint effectively unusable for its documented purpose ("settle a note against the current Merkle root").

**Impact.**
- Anyone trusting the hull's `/commit` response on a hull that has been committed to before is accepting a root with no kernel attestation. If the hull is the external face of a verified-commitment service, this breaks the integrity contract.
- The hull's `/verify` endpoint will return `valid: true` against the unattested root because it verifies against the local `MerkleTree`, not the kernel's registered root.
- The hull's `/settle` is permanently broken (after first /commit) for the "did the settlement land" success signal.
- An operator with no visibility into the kernel's `slog` stream cannot detect this happened.

**Reproduction.**
```bash
# Start hull
HULL_API_KEY=k hull --bind-addr 127.0.0.1 --port 3000

# First commit — succeeds
curl -X POST localhost:3000/commit \
  -H "Authorization: Bearer k" \
  -d '{"fields":[{"key":"a","value":"1"}]}'
# {"field_count":1,"merkle_root":"[...R1...]","status":"committed"}

# Second commit with different fields — same hull_id=1, different root
curl -X POST localhost:3000/commit \
  -H "Authorization: Bearer k" \
  -d '{"fields":[{"key":"a","value":"2"}]}'
# {"field_count":1,"merkle_root":"[...R2...]","status":"committed"}
# But kernel still has hull=1 registered to R1, NOT R2.

# /settle reports settled=false now and forever
curl -X POST localhost:3000/settle \
  -H "Authorization: Bearer k" -d '{}'
# {"settled":false,"effects_count":0,...}
```

The kernel stderr contains `settle: hull already registered` after the second `/commit`, which is the only visible signal that anything is wrong.

**Remediation.** Three layered fixes, pick all three:

1. **Check the effect list in `commit_handler`** (api.rs:391). Treat empty effects from a `%register` poke as failure:
   ```rust
   let effects = poke_kernel_with_timeout(&mut st.app, register_poke, "register").await?;
   if effects.is_empty() {
       return Err((StatusCode::CONFLICT, Json(ErrorBody {
           error: "hull root already registered; this hull is single-shot per process".into(),
       })));
   }
   ```
2. **Add an explicit `%rotate-root` cause to the settle kernel** that overwrites `registered.state` and emits both `[%revoked hull old-root]` and `[%registered hull new-root]` effects. Document and gate it (e.g., require a signature from a designated rotation key tied to `hull_id`).
3. **Don't re-register on `/settle`.** The hull's `/settle` should either (a) be removed because `/commit` is the only on-chain operation in the generic hull, or (b) call the settle kernel's actual `%settle` cause with a full `settlement-payload` (which goes through `validate-settlement-args` and emits a settled note effect). The current `/settle` is the worst of both worlds: it looks like settlement but does nothing past the first `/commit`.

---

## 3. High Vulnerabilities

### H-01 — STARK verifier `test-mode` is a runtime parameter, not proof-bound

**Severity:** High (soundness footgun)
**Files:**
- `protocol/lib/vesl-stark-verifier.hoon:16,46,73,510`

**Description.** Both `verify` and `verify-settlement` declare `=|  test-mode=_|` (default `%.n`) as a free parameter on the verifier door. The conditional at line 510:
```hoon
?:  &(=(test-mode %.n) !(verify-merk-proofs merk-proofs verifier-eny))
  ~&  %failed-to-verify-merk-proofs  !!
```
means **Merk proof verification is skipped when `test-mode = %.y`**. The flag is not part of the proof, is not absorbed by the Fiat-Shamir transcript, and is not asserted at production call sites. The current `verify` and `verify-settlement` entrypoints pass `test-mode` through unchanged from the caller. A future driver, codegen pass, or test harness that flips this to `%.y` at a production call site silently disables Merkle opening verification for every proof.

**Impact.** A single-bit slip at any call site reduces the STARK to "proof of well-formed transcript" with no commitment to the actual evaluation domain. An attacker who could trigger `test-mode = %.y` would produce arbitrary `proof.merk-data` accepted as valid.

**Remediation.**
- Remove `test-mode` from the production `verify-door` instance entirely.
- If test infrastructure still needs to skip Merkle verification, expose a separate `verify-test-only` arm that production kernels never reach.
- Alternatively, add `?>  =(test-mode %.n)` as the first line of `verify` / `verify-settlement` to fail-closed; this loses the test-skip capability but is the safer default.

### H-02 — STARK verifier known constraint-completeness TODO (C-lead-2)

**Severity:** High (self-documented soundness concern)
**Disposition:** **DEFERRED** — see §7. Requires STARK-fluent reviewer; revisit when re-applying the `stark-proof-stash` work against the post-upstream-fix verifier shape.
**Files:** `protocol/lib/vesl-stark-verifier.hoon:160-167`

**Description.** The verifier source itself flags an unresolved soundness question:

> TODO: AUDIT 2026-04-17 C-lead-2 — verifier completeness / perf TODO
> Perf optimization sits next to soundness-critical challenge derivation. Any dropped constraint on this path is a silent soundness hole. Do not land the perf fix without a second reviewer fluent in STARK constraint systems and a constraint-count invariant test that asserts absorbed challenges == expected challenges.

The audit cannot resolve this independently — it requires a second STARK-fluent reviewer per the author's own note. Flagging here so it's not lost in the source.

**Remediation.** Block any change to the challenge-derivation block on (a) a second STARK-fluent reviewer's signoff and (b) a regression test that counts absorbed challenges vs. expected per round and fails on drift.

### H-03 — Trailing-zero hash collision in `hash_leaf`

**Severity:** High (when leaves are user-controllable, byte-length is semantic, and length-prefixing is not enforced)
**Files:**
- `crates/nockchain-tip5-rs/src/lib.rs:131-161` (atom_bytes_to_belts)
- `protocol/lib/vesl-merkle.hoon:38-52` (split-to-belts)

**Description.** The Rust and Hoon sides of `hash_leaf` strip trailing zero bytes from the input before chunking into 7-byte Belts. This is intentional cross-VM alignment (Hoon atoms are bignums; `0x05` and `0x05 0x00 0x00` are the same value) and is documented:

> Callers that treat byte-length as distinguishing between logically-distinct payloads **will see hash collisions**. Fix: encode length into the payload explicitly — e.g. prepend a 4-byte length field, or add a domain-separating prefix before hashing.

**Impact.** Every Merkle leaf in the system uses raw `hash_leaf(bytes)`. If a caller's leaf encoding has variable trailing-zero-significance, an attacker can claim alternate preimages that hash to the same digest. Affected surfaces:
- RAG chunk content (`chunk.dat` is `@t` — UTF-8 text, but in principle can end in `\0` if a producer encodes binary blobs as cords).
- Key-value graft entries (kv-graft stores `@` values).
- The `register_poke` builders' hull-id and root encoding (less concerning — hashes of fixed-width digests).
- Attestation data passed to `sig-verify-ed25519` / `sig-verify-schnorr` (where `expected-root = hash-leaf(pubkey)`).

The `sig-verify-schnorr` binding is particularly worth noting: the gate computes `(hash-leaf pubkey)` and compares it to `expected-root`. Two pubkey atoms that share canonical bignum form but differ only in tail-pad bytes hash to the same root. The 97-byte canonical pubkey serialization is fixed-width and ends in `0x01`, so this specific path is safe — but the general primitive isn't.

**Remediation.**
- Length-prefix every leaf at the SDK layer: `hash_leaf_v2(data) = hash_leaf([len_be4(data), data].concat())`.
- Add a `hash_leaf_domain(domain_tag, data)` helper to vesl-merkle.hoon and the Rust mirror, modeled on `tip5_with_domain` (which already does this correctly).
- Audit `hash_leaf` call sites in vesl-gates.hoon: anywhere a user-controllable atom is the input, switch to the domain-separated form.

### H-04 — Schnorr deterministic-nonce contract requires distinct messages per logical document

**Severity:** High (cryptographic, contractual)
**Files:**
- `crates/vesl-core/src/signing.rs:219-235` (documented)
- `vesl-nockup/crates/vesl-signing/src/schnorr.rs:220-256`

**Description.** Both Rust signers derive the nonce as `trunc_g_order(hash_varlen(pk.x | pk.y | message | sk))`. This matches the Hoon reference and is correct deterministic Schnorr — but the security argument requires every signing call for a given key to use a **distinct `message` value**. The signing layer adds no randomness on behalf of the caller; if a caller signs two different logical documents that happen to hash to the same 5-Belt digest, the security argument is gone.

The crate documents this:

> Security is only preserved if every call for a given key uses a **distinct** `message` value. Re-signing the same logical document is safe (same signature = no new entropy leaked). Signing two different logical documents that happen to hash to the same `message` is not — and any caller that lets the message be chosen (or reused) adversarially breaks the signature scheme.

**Impact.** Whether this is exploitable depends on the call sites:
- **`schnorr_message_digest_for_data`** (signing.rs:205) hashes the input through `nockchain_tip5_rs::hash_leaf`, which has the trailing-zero collision from H-03. Two `data` values differing only in trailing zeros produce the same digest and thus the same signature. If a caller signs `commit_a` and `commit_a\0` thinking they're distinct, the signatures match — which is correct deterministic behavior, but means equal-signature can no longer be used as a freshness signal.
- **SIWN** (caip122.rs) constructs the message body via `build_caip122_message` and hashes via `tip5_with_domain`. The body includes a `Nonce` field, which the replay cache enforces unique. OK.
- **The settlement-payload signing** (settle.rs `sign_tx`) signs `kernel_sig_hash` which is computed by the Hoon kernel from `(seeds, fee)`. As long as `seeds` includes a unique parent_hash per transaction, distinct.

**Remediation.**
- Audit every signing call site in vesl-core, vesl-nockup, and downstream apps (`hull-llm`, x402-nockchain) for message uniqueness.
- Where the message space could be attacker-shaped, prepend a fresh nonce or include a strictly-increasing counter in the pre-image.
- Document this contract at every `sign(...)` call site as a comment naming the freshness source.

---

## 4. Medium Vulnerabilities

### M-01 — Global rate limit; no per-IP backpressure

**Files:** `hull/src/api.rs:262-269`

`tower::ServiceBuilder` configures `rate_limit(200, 60s)` as a global bucket. A single attacker exhausts the bucket and the hull returns `429` to every other client. The hull is the only public face of a Vesl deployment; sustained DoS knocks it offline.

**Remediation.** Use `tower-governor` or upstream proxy (nginx `limit_req_zone`, AWS WAF, Cloudflare) for per-IP buckets.

### M-02 — `poke_kernel_with_timeout` discards effect contents

**Files:** `hull/src/api.rs:282-313`

`commit_handler` calls `poke_kernel_with_timeout(...)?` and binds the result to `_effects`. The kernel's `%register` returns empty effects on duplicate hull (see C-01) and non-empty on success. The hull's silent-success path conflates the two. Same handler also has no schema check on the effect — a future kernel update that changes the `%registered` payload shape goes unnoticed.

**Remediation.** Pattern-match the first effect's head tag against `%registered` and return 5xx if mismatched, in addition to the C-01 fix.

### M-03 — `rejam_atom` panics on invalid input

**Files:** `crates/nock-noun-rs/src/lib.rs:187-192`

`rejam_atom` is reachable from the cross-graft cue-then-jam canonicalization path (queue → batch/log/registry). Its panic-on-invalid-jam policy crashes the Rust process if a kernel ever emits a malformed atom as a queue body. Currently the v0.1 kernels only produce jam-valid bodies, but the boundary is a `&[u8]` and the panic is `expect("rejam_atom: input is not valid jam")`.

**Remediation.** Change signature to `Result<Vec<u8>, RejamError>`. Callers can then panic with their own context or surface as a kernel-decode error.

### M-04 — Settle kernel `settled` set grows unboundedly

**Files:** `protocol/lib/settle-kernel.hoon:24` and `forge-kernel.hoon:27`

`settled=(set @)` accumulates every settled note ID for the kernel's lifetime. There is no GC, no epoch cutoff, and no max-size cap. A long-running kernel that settles many notes pays O(log N) cost per replay check and consumes linearly-growing state. The JAM-replay of the kernel state on startup also grows.

**Remediation.** Either (a) introduce an epoch system where settled IDs older than N epochs are pruned and replay protection becomes "within current epoch", or (b) cap the set at MAX and evict oldest, or (c) accept the unbounded growth and document the deployment lifecycle.

### M-05 — Replay cache (vesl-signing) is in-memory and not persisted

**Files:** `vesl-nockup/crates/vesl-signing/src/replay_cache.rs`

The `InMemoryReplayCache` is volatile. Restart = forget all observed nonces. An attacker who captures a SIWN header before a facilitator restart can replay it after. ADR-0010 (deferred) notes this; flagging explicitly because facilitators that handle real auth flows MUST address it before going to mainnet.

**Remediation.** Implement a `RedisReplayCache` / `SqlReplayCache` and bind it to the facilitator's persistence layer.

### M-06 — Replay cache has no max-size cap; full sweep on every `seen()`

**Files:** `vesl-nockup/crates/vesl-signing/src/replay_cache.rs:67-86`

`sweep` iterates the entire HashMap on every `seen()` call. Under flood, the cache grows until OOM. The sweep cost becomes O(N) per call.

**Remediation.** Add `max_entries` and evict LRU/oldest beyond cap. Move sweep to a background task on an interval, not the hot path.

### M-07 — SIWN replay-cache window controlled by signed message

**Files:** `vesl-nockup/crates/vesl-signing/src/caip122.rs:261-263`

`verify` computes the replay TTL as `params.expiration_time - params.issued_at`. The signer controls both fields. A client setting `issued_at = 1970-01-01` and `expiration_time = 2099-01-01` requests the cache hold the nonce for ~130 years. The `params.expiration_time <= now` check ensures the message is current, but the cache still tracks the nonce for the requested window.

**Remediation.** Cap the window at a server-side maximum (e.g., 1 hour) before passing to `cache.seen(&key, window.min(MAX_SIWN_WINDOW))`.

### M-08 — Schnorr `from_belts` silently truncates Belt high bits

**Files:** `vesl-nockup/crates/vesl-signing/src/schnorr.rs:119-122`

```rust
pub fn from_belts(belts: &[Belt; 8]) -> Result<Self, SchnorrError> {
    let chunks: [u32; 8] = std::array::from_fn(|i| belts[i].0 as u32);
    Self::from_t8(&chunks)
}
```
The `as u32` cast drops bits 32-63 of each Belt. The doc comment says callers MUST supply values that fit in u32, but the runtime check is absent. A caller violating the contract gets a silently-different key.

**Remediation.** `let v = belts[i].0; if v > u32::MAX as u64 { return Err(SchnorrError::ChunkOverflow(v)); } let c = v as u32;`

### M-09 — Demo signing key is hardcoded and constant

**Files:** `hull/src/signing.rs:18-23,28`

`demo_signing_key()` returns `sk[0]=12345, sk[1]=67890`. The PKH is exported as `DEMO_KEY_PKH_BASE58`. The function `is_demo_key()` exists but is not used to refuse demo-key signing in dumbnet mode (only `resolve_dumbnet` is documented as requiring a real key, but it does not check `is_demo_key`).

If a developer copies the fakenet config to dumbnet by mistake, every signed settlement is signed with a publicly-known key. Anyone can forge transactions appearing to come from that hull.

**Remediation.** In `SettlementConfig::resolve_dumbnet`, after deriving `sk`, refuse if `is_demo_key(&sk)` is true.

---

## 5. Low / Informational

### L-01 — Build-time JAM path is environment-trusted
`kernels/{guard,mint,settle}/build.rs` reads `KERNEL_JAM_PATH` from env and computes its sha256 at build time. The runtime `verify_kernel()` checks the embedded JAM matches that sha256. If `KERNEL_JAM_PATH` points at a tampered file at build time, the build hashes the tampered file and the runtime check passes. This trusts the build environment, not a fixed path. Documented behavior; flag for ops.

### L-02 — `pubkey_canonical_bytes` panics on point-at-infinity
`crates/vesl-core/src/signing.rs:172`. Documented invariant. Surface as `Result` for callers that decode pubkeys from untrusted input.

### L-03 — `derive_pubkey` `.expect()` if sk scalar ≥ G_ORDER
`crates/vesl-core/src/signing.rs:122-124`. Documented invariant.

### L-04 — `--no-auth` loopback parse is brittle
`hull/src/api.rs:242-247`. Recognizes `127.0.0.1`, `::1`, `localhost`, and anything that parses as `IpAddr::is_loopback()`. Misses unusual binds like `127.1` (interpreted as loopback by some Linux resolvers but not parsed by `IpAddr`). Low impact.

### L-05 — `sed -i` in sync.sh rewrites every match in build.rs
`vesl-nockup/sync.sh:306-308`. `sed -i 's/graft-inject/nockup-graft/g'` replaces any occurrence in build.rs. A future build.rs that legitimately refers to "graft-inject" outside the binary-name context (doc comment, error string) gets silently rewritten. Minor.

### L-06 — `cp -rL` in sync.sh dereferences symlinks
`vesl-nockup/sync.sh:191-210`. Documented warning at line 102-107: "A compromised upstream vesl checkout could plant a symlink to secrets (e.g. ~/.ssh/id_rsa) that ends up committed here." The `--verify` mode catches drift but not malicious symlinks. Ops responsibility.

### L-07 — NOCK_PIN is the only protection for shipped templates' nockchain rev
`vesl-nockup/sync.sh:37`. SHA collision is impractical; force-push or rev-substitution at the source repo is not. Trust contract: GitHub honors immutable refs.

### L-08 — Hull `hull_id` is hardcoded to 1
`hull/src/api.rs:158`. Single-hull-per-process by design. Multi-tenant deployments require multiple hull processes. Flag for ops.

### L-09 — `handle-register` slogs but emits no error effect on duplicate
`protocol/lib/kernel-arms.hoon:17-23`. The caller cannot distinguish "registered fresh" from "rejected duplicate" by effect inspection — only by counting `(lent effects)`. Emit an explicit `[%register-rejected hull old-root]` effect on duplicate so Rust callers can distinguish.

### L-10 — settle-kernel `%verify` mode skips the replay check
`protocol/lib/kernel-arms.hoon:74-75`. Documented. A `%verify` poke against a duplicated note ID returns the verification result, not "already settled". Read-only by design; callers using `%verify` for status checks should consult `[%settled note-id ~]` peek separately.

### L-11 — STARK verifier `mule`-wrap collapses constraint errors to %.n
**Disposition:** **DEFERRED** — see §7. Diagnostics-quality work that gets revisited alongside `~&` trace decisions when `verify-settlement-full` lands.
`protocol/lib/vesl-stark-verifier.hoon:77`. Good for DoS (no crash on adversarial proof), bad for diagnosability. A genuine soundness fault returns `false` with no trace. Operationally hard to debug; not exploitable.

### L-12 — STARK verifier `verifier-eny` controls Merkle-proof check ordering
**Disposition:** **DEFERRED** — see §7. STARK-internal design-intent question; soundness is not affected (proof verification is order-independent), only the DDOS-resistance guard. Better resolved with upstream context.
`protocol/lib/vesl-stark-verifier.hoon:956-978`. `verify-merk-proofs` uses `verifier-eny` to randomize order — a guard against adversarial worst-case ordering. If the caller supplies a fixed `verifier-eny`, the order is deterministic and attackers can craft proof sets with predictable verification order. The actual proof verification is order-independent, so this only weakens the DDOS-resistance design intent. Caller should pass fresh entropy per verification.

### L-13 — `build-prompt` 10MB cap is independent of HTTP body limit
`hull/src/api.rs:270` caps body at 4MB. `protocol/lib/rag-logic.hoon:30` caps reconstructed prompt at 10MB. The 2.5× headroom is intentional (a tightly-packed manifest could amplify the body→prompt ratio). Defense in depth; flag the relationship in docs so a future hull-fork raising the HTTP limit doesn't outpace the kernel cap.

### L-14 — Hull `/verify` silently ignores caller's `merkle_root` for historical verification
`hull/src/api.rs:459-486`. The handler accepts a `merkle_root` parameter but returns `valid: true` only when `target_root_hex == current_root_hex`. The API surface implies historical verification but the hull holds no history. Misleading; document or remove.

### L-15 — Note counter file written atomically but not racy-safe across processes
`hull/src/api.rs:69-88`. Single-writer invariant by design. Two hull processes sharing `output_dir` race on the counter file.

### L-16 — `tip5_to_atom_le_bytes` does manual bigint arithmetic
`crates/nockchain-tip5-rs/src/lib.rs:77-121`. Horner-method base-PRIME encoding via u128 with carry propagation. Looks correct but is the kind of code that benefits from differential fuzzing against a reference impl (e.g., `num-bigint` or `ibig`). Add a fuzz harness.

### L-17 — Demo signing key documented but no warning when used outside fakenet
`hull/src/signing.rs:13-32`. See M-09. Listed twice because the doc-level issue (developers reading the source) is separable from the runtime-refusal issue (config resolver accepting the key).

---

## 6. STARK Boundary Notes

The STARK verifier (`protocol/lib/vesl-stark-verifier.hoon`) and its `verify-settlement` wrapper are the bridge between off-chain prover output and on-chain attestation. The audit examined:

- **Version pinning** (line 25, 51): `?>  ?=(%2 version.proof)` correctly refuses v0/v1 proofs. The comment notes `version.proof` is unabsorbed by the Fiat-Shamir transcript, so the verifier rejects at the boundary instead of relying on transcript binding. This is the right choice.
- **Commitment / nonce binding** (line 562-564): `verify-settlement` ties `commitment.vr == atom-to-digest(expected-root)` AND `nonce.vr == atom-to-digest(expected-hull)`. These are equality checks against fixed-width digests, which sidesteps the trailing-zero collision from H-03 (digests are 5×8 bytes, no semantic length variation). Sound.
- **Test-mode** (H-01): the one structural concern.
- **`verify-merk-proofs` randomization** (L-12): the entropy source matters for DDOS-resistance only, not for soundness.
- **Constraint-completeness TODO** (H-02): unresolved by this audit; needs a STARK-fluent second reviewer.

The Fiat-Shamir transcript is constructed via `verifier-fiat-shamir` after each round (lines 138, 148, 190, 261, 300, 344, 380). The challenges depend on the proof contents in order, which is the standard non-interactive transformation. No issues found in the absorb sequence.

`verify-merk-proofs` (line 956) uses `(verify-merk-proof:merkle m.i.sorted)` per proof. The Merkle proof primitive is `hash-ten-cell:tip5` based, which matches `hash-pair`. Domain separation between leaf and internal hashes (via `hash-belts-list` vs `hash-ten-cell`) is preserved.

**One concrete soundness invariant that should be tested but currently isn't (to my knowledge):** count the challenges absorbed at each Fiat-Shamir step and assert it equals the constraint count. This is the regression test the C-lead-2 TODO mentions. Adding it is the single highest-leverage soundness investment in this codebase.

### What the current STARK proof actually commits to

The shipped `prove-computation` proves execution of a hardcoded 64-nested-increment Nock formula (`vesl-stark.hoon:++build-fs-formula`) against a Horner-folded belt-digest of the manifest content, packed into the proof's commitment/nonce header. The link from "STARK verified" to "verify-manifest returned %.y" is through that belt-digest — a content commitment, not an execution proof of the actual gate.

This is not a design choice; it is a workaround. The cell-subject memory-table gap documented in `~/projects/nockchain/stark-proof-stash/docs/stark-proof-branch-late-breaking/FLAG_STARK_MEMORY_TABLE.md` blocks proving the actual Hoon gate, because Hoon's `=/` compiles to Nock 8 (modified subjects) and the STARK memory table only tracks slot operations against the original subject. Two local fixes were attempted (content-keyed memory dedup, multi-subject rna-bfta with new column layout) — both failed in instructive ways; the team is waiting on upstream guidance from the Nockchain core team.

The integrity argument for the current pipeline still holds: an attacker cannot swap manifest content without invalidating the belt-digest header, and the verifier rejects on header mismatch. But anyone reading "STARK verifies" as "the gate provably executed correctly" would be over-trusting — what the proof actually attests is "some 64-increment Nock program executed against the digest-committed content," not "verify-manifest evaluated to true." The end-to-end gate proof is staged in the `stark-proof-stash` repo as additive arms (`verify-settlement-full`, `rag-logic-standalone`, `belts-to-btree`, `lower-deep`) ready to re-apply when upstream lands the memory-table fix. `.dev/CRITICAL_LEADS.md`'s C-lead-1 dissolves at that point: the formula stops being hardcoded and the proof commits to actual gate execution rather than to a placeholder Nock program.

---

## 7. Items Deferred Pending STARK Pipeline Progress

The advanced STARK prover/verifier work lives outside vesl-core in `~/projects/nockchain/stark-proof-stash`, paused waiting for upstream coordination on the cell-subject memory-table multi-subject gap. Several audit findings touch code that will be substantially revisited when that work resumes; fixing them now risks rework or pre-empts the upstream review forum.

### Defer until upstream lands

- **H-02 (verifier completeness / perf TODO, C-lead-2).** Self-documented as requiring STARK-fluent reviewer signoff. The Nockchain core team is the qualified review forum; this is the canonical upstream-coordination item. The constraint-count invariant test mentioned in `.dev/CRITICAL_LEADS.md` is borderline-agent-safe but only meaningful after upstream design intent is confirmed. Don't write the invariant blind — it could codify the wrong shape.
- **L-11 (mule-wrap collapses constraint errors to %.n).** Diagnostics-quality issue. Safe to defer because the verifier-side trace work will be revisited when `verify-settlement-full` lands and `~&` diagnostics get re-evaluated against the new shape.
- **L-12 (verifier-eny randomization).** STARK-internal design-intent question better resolved with upstream context than locally. The current behavior is sound (proof verification is order-independent); only the DDOS-resistance guard is weakened by a fixed eny.
- **C-lead-1 (formula hardcoding).** Already documented in source and in `.dev/CRITICAL_LEADS.md`. Dissolves when cell-subject proving ships. No additional audit action needed beyond what's already in-tree.

### Fix now despite the STARK pipeline being in flux

- **H-01 (test-mode parameter).** One-line fix: `?>  =(test-mode %.n)` at the top of `verify` and `verify-settlement`, or remove the parameter from the door entirely. Durable across the stash re-application — the README's re-apply plan keeps the existing `verify` and `verify-settlement` arms intact and only **adds** `verify-settlement-full`. Removing test-mode now means the fix carries through the upstream rewrite without re-work.
- **H-03 (trailing-zero hash collision).** Length-prefix and domain-separate leaf data at the SDK layer **now**. When cell-subject proving ships, more leaves flow through `hash_leaf` — the new `belts-to-btree` path hashes balanced-tree leaves, and `verify-settlement-full` binds to additional manifest content. Length-prefixing now prevents rework once the new code paths land.
- **H-04 (Schnorr deterministic-nonce contract).** Audit signing call sites now; when proof binding gets tighter post-upstream-fix, settlement signatures will be more entangled with manifest content and the freshness contract gets more load-bearing. Annotating call sites with their freshness source is cheap insurance.

### What to do when upstream lands the memory-table fix

Per `~/projects/nockchain/stark-proof-stash/README.md` "If you ever re-apply this":

1. Land additive arms first — additive only. New: `belts-to-btree`, `btree-to-belts`, `btree-depth` on `vesl-merkle.hoon`; `lower-deep` on `vesl-lower.hoon` (line-60 cast fix already on local-dev); `verify-settlement-full` on `vesl-stark-verifier.hoon`; `provable-result` and `provable-manifest` on `sur/vesl.hoon`; new libraries `rag-logic-provable.hoon` and `rag-logic-standalone.hoon`.
2. Add `hoon/lib/` symlinks for the two new libraries (per CLAUDE.md §3 — missing symlinks cause silent hoonc exit 2).
3. Land the `vesl-kernel.hoon` rewrite last with a fresh `vesl.jam` rebuild and `assets/CHECKSUMS.sha256` update via `scripts/check-jam.sh`.
4. **Add the H-02 constraint-count invariant test against the new verifier shape** — this is the right moment, not before.
5. **Re-audit the prove/verify path** for H-01 disposition under the new arm, `verify-settlement-full`'s binding to expected-root/expected-hull, and the absorbed-challenge invariant.

Skip the `~&` diagnostics and the line-603 type-annotation edit from the stash when re-applying — both were debugging cruft, not load-bearing.

---

## 8. Supply Chain (vesl-nockup)

`vesl-nockup` distributes Hoon libraries, the vesl-core crate stack, the vesl-wallet workspace, and starter templates. The audit examined:

**Pin discipline** (sync.sh:37-44). `NOCK_PIN` and `VESL_CORE_PIN` are hardcoded constants in sync.sh. CI can override via env. The hard-pin check (line 65-75) refuses to run when the sibling vesl-core HEAD does not match `VESL_CORE_PIN`. Soft warning on dirty/untracked working tree (line 79-83) — sync copies working tree, not HEAD, so uncommitted edits leak into the bundle. Documented.

**`cp -rL` symlink dereference** (line 102-107, 191-210). Documented supply-chain risk. The script explicitly cautions: "Review incoming vesl changes like any supply-chain input."

**Path-dep → git-dep rewriting** (line 296-299). Regex-based `sed` substitution rewrites template Cargo.toml's nockchain path-deps to git-deps at `NOCK_PIN`. The regex anchors on `../../../nockchain/crates/...` so it matches only the three-level-up shape. graft-scaffold's own two-level-up paths are intentionally not rewritten. Correct.

**No kernel JAM in vesl-nockup.** Kernel JAMs live in vesl-core/assets/ and ship via the `kernels-{guard,mint,settle}` Rust crates that vesl-nockup doesn't mirror. vesl-nockup composes domain apps via `graft-inject` (codegen). This keeps the kernel-trust path narrow.

**`graft-inject` codegen** (`tools/graft-inject/src/codegen.rs`). Takes graft-manifest TOML files as input, emits Hoon between banner pairs in template kernels. Trust model: developers run this at scaffold time on manifests they wrote. Not a service. Risk: if a manifest is malicious, codegen emits malicious Hoon. Treat manifests like dependencies — vet them.

**`--verify` mode** (line 335-378). CI uses this to catch hand-edits to bundled crates/templates and sync.sh logic changes not re-run. Sound design; catches drift but not malicious-sync.

**No findings in vesl-nockup that don't already exist in vesl-core.** The vesl-signing / vesl-wallet crates are well-bounded, parity-tested against `nockchain-math`, and use proper domain separation (`vesl-hd-v1` for HD derivation, `siwn-v1` for SIWN, `x402-nockchain-v2` for x402, etc.). The Sign-In-With-Nockchain (CAIP-122) implementation correctly validates timestamps, replay-protects via `prefixed(domains::SIWN, nonce)`, and binds the signing pubkey to the message body's address field.

The one architectural finding worth mentioning is M-05/M-06 — the in-memory replay cache is OK for the current dev surface but not for a production facilitator. ADR-0010 acknowledges this.

---

## 9. What Was NOT Audited

- **`nockchain-math` and `zkvm-jetpack`** — treated as upstream-trusted. Audit boundary stops at the vesl-{signing,core} consumption layer.
- **The Hoon STARK constraint generation pipeline** — `softed-constraints.hoon` and the constraint JAMs were assumed correct by version-pin. The constraint-completeness TODO (H-02) is the one acknowledgment that the verifier's understanding of these constraints needs second-reviewer signoff.
- **Nockchain chain client (`nockchain-client-rs`)** — assumed correct; only the API shape was examined.
- **The `vesl-checkpoint` crate** — out of scope; the checkpoint trait surface wasn't traced into kernels.
- **Templates as end-user code** — templates' main.rs paths were not exhaustively read; they invoke `graft-inject` codegen at build time, which is itself audited.
- **The Docker / docker-compose setup** — not examined.
- **Network-level concerns** (TLS termination, ingress rate limiting, WAF) — assumed handled by ops.

---

## 10. Recommended Next Steps

In priority order. Items marked **DEFERRED** are tracked in §7 and revisited when upstream lands the cell-subject memory-table fix.

1. **Fix C-01** before the hull is exposed to any external party. The fix is small (check effect list in commit_handler, error on empty) and the impact is large.
2. ~~Add the STARK challenge-count invariant test (H-02)~~ — **DEFERRED per §7.** Add when re-applying the stash, against the post-upstream-fix verifier shape.
3. **Audit signing call sites** for the H-04 message-uniqueness contract. Annotate each call with its freshness source as a comment.
4. **Length-prefix or domain-separate leaf data** (H-03 remediation) at the SDK layer. Add `hash_leaf_domain` to vesl-merkle.hoon and the Rust mirror. Doing this **before** the stash re-apply means the new code paths (`belts-to-btree`, `verify-settlement-full`) inherit the safer primitive.
5. **Remove `test-mode` from production verifier paths** (H-01). Durable across the upstream rewrite per §7.
6. **Cap the SIWN replay window** server-side (M-07) and document the max in operator guides.
7. **Add fuzz harness** for `tip5_to_atom_le_bytes` and `rejam_atom` (L-16, M-03).
8. **Persistence story for the replay cache** (M-05) before mainnet.

The codebase is at the stage where most remaining risks are operational rather than cryptographic. The math holds. The kernel state machine is conservative. The Schnorr layer is sound. The advanced STARK prover/verifier work is staged out-of-tree pending upstream and will be re-applied as additive arms when ready. What needs work locally is the boundary where Rust meets HTTP meets caller-expectation — that's where C-01 lives, and that's where the next round of work should focus.

---

*Audit performed via whitebox source review of vesl-core @ `d613b05` and vesl-nockup @ working tree, on 2026-05-16.*
