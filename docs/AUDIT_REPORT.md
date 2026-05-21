# Vesl Security Audit Report — 2026-05-19 Beta Review

> **Status update — 2026-05-20.** All nine Critical findings are remediated in code.
> **C-01–C-07 and C-09** are fixed and verified on `dev` (see the per-finding banners in
> §2). **C-08**'s remediation — the `vesl-core-sync.yml` workflow — is committed on `dev`
> and deploys to `origin` with the pending batch push; confirm post-push with
> `git show origin/main:.github/workflows/vesl-core-sync.yml`.
>
> This banner and the §2 per-finding banners supersede the "NOT READY FOR BETA" verdict in
> §1 and items 1–9 of §9 with respect to the Critical findings. The **22 High findings are
> likewise remediated** as of 2026-05-20 — see the per-finding banners in §3.

**Scope.** Adversarial whitebox audit of the three repositories that ship together for the Vesl beta release:

- `vesl-core` @ `e509c86` (branch `dev`) — Hoon protocol, Rust Vessel, kernel JAMs.
- `vesl-nockup` @ `3d25925` (branch `dev`) — CLI, sync.sh supply chain, templates, mirrored crates, vesl-hull.
- `vesl-wallet` @ `e270b00` (branch `dev`) — vesl-signing, vesl-wallet, vesl-wallet-spec.

**Methodology.** Six parallel adversarial agents probed: (1) Hoon kernels + grafts, (2) STARK prover/verifier soundness, (3) Rust Vessel panic/async surface, (4) Rust↔Hoon boundary crates (nock-noun-rs, nockchain-tip5-rs, nockchain-client-rs, vesl-checkpoint), (5) vesl-wallet HD/Schnorr/CAIP-122, (6) vesl-nockup supply chain. Cross-checked against `stark-proof-stash` (additive-only WIP, currently behind tree on security fixes). Verified key claims via independent grep / file inspection.

**Threat model.** Every kernel poke, every effect, every byte that crosses the Rust↔Hoon boundary is attacker-influenced unless an explicit gate proves otherwise. Where the previous audit (`AUDIT_REPORT.md` pre-2026-05-19) treated a finding as deferred, this report verifies the current code state — multiple "DEFERRED" items from the prior audit remain unfixed in `dev` and are restated below at higher severity for beta-readiness purposes.

---

## 1. Executive Summary

**2026-05-19 architectural cleanup (post-audit).** As a precondition for landing the C-02/C-03 fixes against the right repo, this audit triggered a structural refactor that extracted all RAG-specific code from vesl-core into hull-llm. Vesl-core is now genuinely domain-agnostic infrastructure: the shipped guard/mint/settle/forge kernels do not import `rag-logic`, the `Manifest`/`Retrieval`/`Chunk` Rust types and the `RagVerifier` impl live in hull-llm, and `vesl-stark.hoon`/`vesl-kernel.hoon`/`vesl-entrypoint.hoon` (all of which depend on the RAG `manifest` type) moved to hull-llm too. Hull-llm gained its own Hoon source tree (`protocol/{lib,sur}/`, `hoon/`, `scripts/check-jam.sh`, JAM-determinism CI), a `vendor-libs.sh` script that pulls vesl-core's generic libs one-way at a pinned rev, and full ownership of its kernel JAM build pipeline. Forge kernel + JAM relocated from hull-llm into vesl-core to correct an earlier source-of-truth inversion (forge is generic). C-02 and C-03 vulnerability fixes are deferred to a follow-up session against this new topology.

**Post-cleanup file map.** Findings below cite pre-cleanup file paths; use this table to translate to the post-cleanup layout (vesl-core@284a20a / hull-llm@2757b1b):

| Pre-cleanup path | Post-cleanup location |
|---|---|
| `vesl-core/protocol/lib/rag-logic.hoon` | `hull-llm/protocol/lib/rag-logic.hoon` |
| `vesl-core/protocol/lib/vesl-kernel.hoon` | `hull-llm/protocol/lib/vesl-kernel.hoon` |
| `vesl-core/protocol/lib/vesl-entrypoint.hoon` | `hull-llm/protocol/lib/vesl-entrypoint.hoon` |
| `vesl-core/protocol/lib/vesl-stark.hoon` | `hull-llm/protocol/lib/vesl-stark.hoon` |
| `vesl-core/protocol/sur/vesl.hoon` (manifest, retrieval types) | `hull-llm/protocol/sur/rag.hoon` |
| `vesl-core/crates/vesl-core/src/types.rs` (Chunk, Manifest, Retrieval) | `hull-llm/src/manifest.rs` |
| `vesl-core/crates/vesl-core/src/settle.rs` (RagVerifier impl) | `hull-llm/src/rag_verifier.rs` |
| `vesl-core/crates/vesl-core/src/settle.rs` (build_settle_poke, build_prove_poke) | `hull-llm/src/manifest_pokes.rs` |
| `vesl-core/crates/vesl-core/src/graft_pokes/settle.rs` (build_settle_note_manifest_poke) | `hull-llm/src/manifest_pokes.rs` |
| `vesl-core/crates/vesl-core/src/guard.rs` (check_manifest, validate_manifest) | DELETED — RAG-specific verification logic moved into `hull-llm/src/rag_verifier.rs::RagVerifier::verify` |
| `hull-llm/kernels/forge/` + `hull-llm/assets/forge.jam` | `vesl-core/kernels/forge/` + `vesl-core/assets/forge.jam` |

Findings whose remediation cuts across both repos (e.g. C-03) will land as paired commits.

**Verdict: NOT READY FOR BETA.** Three independent classes of critical findings would each, on their own, justify holding the release.

1. **Kernel-integrity gate is disconnected from the production code path.** `kernels-{guard,mint,settle,forge}::verify_kernel()` (vesl-core) and `kernels_vesl::verify_kernel()` (hull-llm) exist, sha256-hash the embedded JAM, panic on mismatch — and are **never called by any caller in vesl-core, hull-llm, vesl-nockup, or any of the nine templates**. The actual production path is `let kernel = fs::read("out.jam")?` across every shipped template. An attacker who can replace `out.jam` at deploy time (directory write, supply-chain compromise, careless overwrite) boots a swapped kernel with no integrity check. C-01 (Rust Vessel).

2. **The STARK soundness boundary is currently bypassed in two independent ways.** First, the `test-mode` parameter on `+verify` and `+verify-settlement` (`AUDIT_H01_TEST_MODE.md` Option B; tracked since 2026-04-19) **is still not asserted closed** — any caller that passes `%.y` silently disables Merkle-opening verification. Second, the `forge-kernel.hoon` (vesl-core) and `vesl-kernel.hoon` (now in hull-llm after the architectural cleanup) `%prove` arms check only the *outer mule head* of `prove-computation`, not the inner `each %& %|` discriminator — a prover error noun (`[%| %too-big ...]`) is treated as a valid proof, the note is permanently settled, and a structurally-shaped "proof" is emitted. **Deferred to follow-up session.** C-02, C-03 (Hoon protocol).

3. **The cross-VM Tip5 boundary admits chainsplit-class divergence in release builds.** `nockchain-math`'s `based!` macro is `debug_assert!` (release-mode no-op). `nockchain-tip5-rs` constructs `Tip5Hash` limbs (`[u64; 5]`) at the Rust API surface without validating that each limb is below the Goldilocks prime. The Hoon verifier normalizes inputs via `atom-to-digest`'s modular reduction; Rust does not. Off-field digests produce *different* digests on each side. Anywhere a Rust off-chain verification result feeds a Hoon-verified state (settlement effect, receipt bridge, future on-chain submission) creates a chainsplit primitive. C-04 (Boundary).

Additionally:

4. **The CAIP-122 SIWN signer is field-injectable.** `build_caip122_message` interpolates `params.uri`, `params.nonce`, `params.chain_id`, etc. via `format!` with no newline/control-char filter. A signer routing user-influenced bytes into `uri` produces a body whose later lines (Chain ID, Nonce, Issued At, Expiration Time) the parser reads from the injected content, not from the signer's intended values. One legitimate victim signature mints a multi-decade impersonation token. The verifier compounds this by failing to enforce `chain_id`, `uri`, or `version` against any expected value — cross-chain replay is wide open. C-05, C-06, C-07 (Wallet).

5. **The vesl-nockup ↔ vesl-core mirror gate is undeployed.** `.github/workflows/vesl-core-sync.yml` exists on local `dev` but is absent from `origin/dev` and `origin/main` — verified by `git show origin/dev:...`. The supply-chain integrity contract (CLAUDE.md §7) that prevents "fixed in vesl-core, forgot to run sync.sh" drift is paper-only. Compounded by C4: even if deployed, the workflow's diff command would always fail (vesl-nockup carries 4 crates that don't exist in vesl-core, and `diff -rq` returns non-zero on "Only in" entries). And CI's `VESL_WALLET_PIN` env var points to a SHA that does not exist in `vesl-wallet`. C-08, C-09 (Nockup).

Beyond the criticals, the report catalogs 22 High, 31 Medium, and 28 Low/Informational findings spread across all three repos. The **prior audit's prior findings (`AUDIT_REPORT.md` pre-this-cycle) are partially fixed**:

| Prior | Status today | Notes |
|---|---|---|
| C-01 (hull commit desync) | **Migrated** — hull is now `vesl-nockup/crates/vesl-hull` library, prior C-01 surface re-shaped. C-01 *of this report* is independent. |
| H-01 (STARK `test-mode`) | **Unfixed** — planning doc landed, code change did not. Promoted to C-02 here. |
| H-03 (hash-leaf trailing-zero) | **Unfixed** — `hash-leaf` still untouched, no `hash-leaf-v2-domain` arm. Restated as M-09. |
| H-04 (Schnorr message-uniqueness) | **Partially audited, not fixed** — annotations not landed; depends on H-03. |
| M-03 (rejam_atom Result) | **Unfixed** — still `.expect("rejam_atom: input is not valid jam")`. Restated as H-12. |
| M-07 (SIWN window cap) | **Unfixed** — still uses raw `expiration_time - issued_at`. Restated as H-13. |
| M-08 (Schnorr `from_belts` overflow) | **Fixed in vesl-wallet@e270b00** — `if v > u32::MAX as u64 { return Err(ChunkOverflow(v)) }` present at `schnorr.rs:163`. **NOT fixed in the shim path** at `crates/vesl-signing/src/schnorr.rs:119-122` if a caller uses the legacy `from_belts(&[Belt;8])` constructor; restated as H-04. |
| M-09 (demo signing key) | **Unfixed** — `is_demo_key` exists, exported, but invoked nowhere. Restated as H-15. |

**Beta-ship gate:** at minimum, C-01 through C-09 must be fixed before a public beta. Several are one-line fixes; none should take more than a focused day.

**Finding counts (2026-05-19):** **9 Critical, 22 High, 31 Medium, 28 Low / Informational, 4 cross-cutting hardening recommendations.**

---

## 2. Critical Vulnerabilities

### C-01 — Kernel-integrity check is opt-in and never invoked; templates load `out.jam` from disk with zero verification

> **RESOLVED — 2026-05-20 (`37ca1da`).** Kernels expose an `OnceLock`-guarded `kernel()` that runs `verify_kernel()` once; templates gained an env-gated (`VESL_KERNEL_SHA256`) sha256 check on `out.jam`.

**Severity:** Critical (kernel-substitution attack — silent integrity bypass)
**Repo:** vesl-core (kernel crates) + vesl-nockup (templates)
**Files:**
- `vesl-core/kernels/guard/src/lib.rs:9,13`
- `vesl-core/kernels/mint/src/lib.rs:9,13`
- `vesl-core/kernels/settle/src/lib.rs:9,13`
- `vesl-nockup/templates/{counter,data-registry,graft-hash-gate,graft-intent,graft-mint,graft-scaffold,graft-settle,settle-report,vesl}/src/main.rs` — every template loads via `fs::read("out.jam")`
- `vesl-core/templates/*/src/main.rs` — same pattern in the canonical-source templates

**Description.** The kernels-* crates expose `pub static KERNEL: &[u8] = include_bytes!(env!("KERNEL_JAM_PATH"))` and `pub fn verify_kernel()` that sha256-checks the embedded bytes against `KERNEL_JAM_SHA256_HEX` (baked in at build time from the same file the include sees). The integrity gate exists. **`verify_kernel()` is never called anywhere in either repo.** Verified by `grep -rIn 'verify_kernel|kernels_guard|kernels_mint|kernels_settle' --include='*.rs' --exclude-dir=target` — returns only the definitions; no callers. The kernels-* crates themselves have no other consumers in any Cargo.toml in either repo.

The actual production code path: every shipped template loads its kernel via `let kernel = fs::read("out.jam")?; let app = boot::setup(&kernel, ...).await?;`. There is no integrity check, no signature verification, no sha256 comparison. The kernel JAM is whatever bytes happen to be at `out.jam` at process start.

**Impact.** An attacker who can write to the deployment's working directory (filesystem misconfiguration, supply-chain compromise of a build artifact, careless `cp` overwrite, malicious CI step that replaces `out.jam` before `cargo run`, hostile docker-build layer) can swap in a kernel of their choosing. The application boots without complaint. From that point every poke is interpreted by attacker-controlled Hoon — including signing-key derivation arms, settlement guards, replay sets, RBAC checks.

The build.rs trust model (which the prior audit noted as L-01) is amplified: the build path's `KERNEL_JAM_PATH` env var trusts the build host; the *runtime* path trusts the filesystem at deploy time. Two trust assumptions, both unsecured.

**Reproduction.**
```bash
cd ~/projects/nockchain/vesl-nockup/templates/vesl
# (Assuming a built artifact)
cp /tmp/evil.jam out.jam  # arbitrary attacker-controlled JAM
cargo run -- demo
# Kernel boots from evil.jam with no error
```

**Remediation.**

1. **Make `verify_kernel()` non-opt-in.** Remove the `pub static KERNEL` API. Replace with a lazy accessor that runs the sha256 check exactly once via `OnceLock` and aborts on mismatch:
   ```rust
   pub fn kernel() -> &'static [u8] {
       static CHECKED: std::sync::OnceLock<&[u8]> = std::sync::OnceLock::new();
       CHECKED.get_or_init(|| { verify_kernel(); KERNEL }).copy_from_slice_inplace_or_whatever()
   }
   ```
2. **Make every template consume the kernel through `kernels-{guard,mint,settle}::kernel()`** instead of `fs::read("out.jam")`. The JAM bytes ship in the binary; no disk read needed. This collapses both the disk-tamper and the build-time `KERNEL_JAM_PATH` env attack surfaces.
3. **For templates that must accept an external JAM** (development scaffold path), require a `--expected-sha256 <hex>` CLI argument and verify before boot. The bare `fs::read("out.jam")` path must die.
4. **Add a `KERNEL_JAM_SHA256_EXPECTED` build-time env var** for the kernel crates so release builds pin the expected sha256 out-of-band from the JAM file itself. CI's `jam-determinism.yml` already enforces this at PR time; baking it into build.rs is defense-in-depth.

This is the single highest-leverage fix in the audit. Estimated effort: half a day across all templates and kernel crates.

---

### C-02 — STARK verifier `test-mode` parameter still flippable at production boundary (H-01 unfixed)

> **RESOLVED — 2026-05-20 (`15f979b`; JAMs `ecf33b9`).** `?>  =(test-mode %.n)` hard-asserts added at the `+verify` and `+verify-settlement` outer gates.

**Severity:** Critical (soundness bypass on one boolean parameter)
**Repo:** vesl-core
**Files:** `protocol/lib/vesl-stark-verifier.hoon:16,46,73,510`

**Description.** Both `+verify` and `+verify-settlement` declare `=|  test-mode=_|` (default `%.n`) as a free parameter on the verifier door. The conditional at line 510:
```hoon
?:  &(=(test-mode %.n) !(verify-merk-proofs merk-proofs verifier-eny))
  ~&  %failed-to-verify-merk-proofs  !!
```
means **Merk-proof verification is skipped when `test-mode = %.y`**. The parameter is not absorbed into the Fiat-Shamir transcript. The fix (Option B from `docs/AUDIT_H01_TEST_MODE.md`) is two `?>  =(test-mode %.n)` asserts — one at line 17, one at line 47.

**Verification.** `grep -nE 'test-mode' protocol/lib/vesl-stark-verifier.hoon` shows 9 occurrences, none of which are the planned hard-assert. The remediation was documented 30+ days ago and is not in `dev`.

**Impact.** A single-bit slip at any future call site reduces the STARK to "well-formed transcript" with no commitment to the actual evaluation domain. Any caller that accidentally constructs the verifier door with `test-mode=%.y` (codegen pass, copy-paste, downstream wiring error) silently accepts arbitrary `proof.merk-data`.

**Remediation.** Land Option B from `AUDIT_H01_TEST_MODE.md` verbatim. Two lines:
```hoon
++  verify
  =|  test-mode=_|
  |=  [=proof override=(unit (list term)) verifier-eny=@ s=* f=*]
  ^-  ?
  ?>  =(test-mode %.n)                          :: ADD
  ?>  ?=(%2 version.proof)
  ...

++  verify-settlement
  =|  test-mode=_|
  |=  [=proof override=(unit (list term)) verifier-eny=@ s=* f=* expected-root=@ expected-hull=@]
  ^-  ?
  ?>  =(test-mode %.n)                          :: ADD
  ?>  ?=(%2 version.proof)
  ...
```

Then regenerate `assets/{guard,mint,settle}.jam` and `assets/CHECKSUMS.sha256` per CLAUDE.md §3.

---

### C-03 — `forge-kernel.hoon` and `vesl-kernel.hoon` `%prove` treat `prove-result %| err` as success; permanently settle on prover error

> **RESOLVED — 2026-05-20 (`77ce58a`; JAMs `ecf33b9`).** `%prove` now sieves the inner `each` discriminator (`?=(%& -.p.proof-attempt)`) in `forge-kernel.hoon`; hull-llm `vesl-kernel.hoon` mirrors it.

**Severity:** Critical (fake settlement via prover error path)
**Repo:** vesl-core (forge-kernel) + hull-llm (vesl-kernel, post-cleanup)
**Files:**
- `vesl-core/protocol/lib/forge-kernel.hoon:256-272`
- `hull-llm/protocol/lib/vesl-kernel.hoon` (handle-prove arm; line numbers shifted after the Phase 4 import refactor)

**Description.** `prove-computation` returns `prove-result = (each =proof err=prove-err)` where `prove-err` includes `[%too-big heights=(list @)]` (defined in `nockchain/hoon/common/stark/prover.hoon:39-40`). The kernel wraps the call in `mule` and checks only `-.proof-attempt` — the *outer* mule head (`%&` = mule didn't crash). It does NOT check `-.p.proof-attempt` — the *inner* `each` head distinguishing `[%& proof]` from `[%| err]`.

In `forge-kernel.hoon`:
```hoon
=/  proof-attempt
  %-  mule  |.
  (prove-computation belt-digest fs-formula expected-root.args hull.note.args)
?.  -.proof-attempt              :: only checks mule outer head
  ~>  %slog.[3 'forge: prove-computation crashed']
  ~[[%prove-failed (jam p.proof-attempt)]]
=/  new-settled  (~(put in settled.state) id.note.args)
:_  state(settled new-settled)
~[[result-note p.proof-attempt]]  :: p.proof-attempt may be [%| %too-big ...]
```

When `prove-computation` returns `[%| %too-big heights=...]` without crashing, the outer mule head is `%&`, the kernel falls through to the "settled" branch, marks `note.id` as settled permanently (replay protection now blocks any future legitimate settle of the same id), and emits `[result-note (%| %too-big ...)]` as the proof effect.

**Impact.** Attacker submits a payload structured to trigger `prove-computation`'s `[%| %too-big ...]` return path (any path inside `generate-proof` that yields the error variant without crashing). Result:

1. `note.id` is permanently in the settled set — the legitimate party cannot settle the same note ever.
2. The emitted effect contains a noun that is structurally `(proof, err-payload)`, which downstream Rust callers may cast as a proof (especially if they accept the head without sieving the `each` variant) and either crash on unexpected shape or accept the err-noun as "proof bytes."

The state corruption is silent: the kernel slog says nothing.

**Verification.** Confirmed by reading `forge-kernel.hoon:256-271` (vesl-core), `vesl-kernel.hoon` `handle-prove` (now in hull-llm), and `nockchain/hoon/common/stark/prover.hoon:39-40`. The `prove-result` shape is genuinely `(each proof err)`. The mule check is genuinely only on the outer head.

**Remediation.** Lands across two repos (`forge-kernel.hoon` in vesl-core, `vesl-kernel.hoon` in hull-llm). Each kernel applies the same shape:

```hoon
=/  proof-attempt
  %-  mule  |.
  (prove-computation belt-digest fs-formula expected-root.args hull.note.args)
?.  -.proof-attempt
  ~>  %slog.[3 'forge: prove-computation crashed']
  :_  state
  ~[[%prove-failed (jam p.proof-attempt)]]
?.  ?=(%& -.p.proof-attempt)                    :: sieve the each variant
  ~>  %slog.[3 'forge: prover returned error variant']
  :_  state
  ~[[%prove-failed (jam p.proof-attempt)]]
=/  the-proof  +.p.proof-attempt                :: cast through %&
=/  new-settled  (~(put in settled.state) id.note.args)
:_  state(settled new-settled)
~[[result-note the-proof]]
```

Mirror in `hull-llm/protocol/lib/vesl-kernel.hoon` `handle-prove`, substituting the slog tag.  Each fix lands as a dedicated commit in its own repo with a paired JAM regen.

---

### C-04 — `Tip5Hash` limbs are unconstrained at the Rust API surface; release builds bypass field-membership checks → chainsplit primitive

> **RESOLVED — 2026-05-20 (`8486bd7`).** `check_tip5_limbs()` range-checks every limb against the Goldilocks prime at the wire boundary (`verify_proof`, `find_hash_entry`).

**Severity:** Critical (cross-VM divergence — Rust and Hoon disagree on identical bytes)
**Repo:** vesl-core
**Files:**
- `crates/nockchain-tip5-rs/src/lib.rs:48` (type alias `Tip5Hash = [u64; 5]`)
- `crates/nockchain-tip5-rs/src/lib.rs:166,179,190` (`hash_leaf`, `hash_pair`, `verify_proof`)
- `crates/nockchain-client-rs/src/note_data.rs:147-169` (`find_hash_entry`)
- `crates/nockchain-client-rs/src/types.rs:76-84` (`chain_hash_from_pb`)
- Upstream: `nockchain/crates/nockchain-math/src/belt.rs:87` (`based!` macro = `debug_assert!`)

**Description.** `nockchain-math`'s `based!` macro is `debug_assert!`:
```rust
macro_rules! based {
    ($x:expr) => {
        debug_assert!($crate::belt::based_check($x), "element must be inside the field\r");
    };
}
```
In release builds, `debug_assert!` compiles to nothing. Every field operation in nockchain-math (`mont_reduction`, `add_mod`, `mul_mod`, etc.) skips the range check.

`nockchain-tip5-rs::hash_pair` constructs `Belt(v)` for each limb of its input arrays and calls `hash_10` without verifying `v < PRIME`. `verify_proof` constructs `node.hash` and `cur` from the proof's `ProofNode` structures, which carry raw `[u64; 5]` limbs. The optional `serde::Deserialize` derive (line 61) accepts any `u64` per limb. Externally-controlled paths to `Tip5Hash`:
- `find_hash_entry` (`note_data.rs:147-169`) — reads u64 limbs from `NoteData` entries off the wire.
- `chain_hash_from_pb` (`types.rs:76-84`) — converts protobuf bytes to limbs.
- Direct API consumers calling `hash_pair` / `verify_proof` with caller-constructed arrays.

The Hoon side normalizes inputs via `atom-to-digest` which uses `dvr buffer p` (modular reduction). So the same `(u64 limbs ≥ PRIME)` input produces different digests on each side:
- Rust release build: limbs ≥ PRIME flow through `montify` and `mont_reduction` without reduction, producing a deterministic-but-wrong result.
- Hoon: limbs ≥ PRIME are reduced mod p first, producing the "canonical" result.

**Impact.** Anywhere a Rust off-chain verification result is treated as authoritative — settlement effects, off-chain receipts, anything bridging to a Hoon-verified state — Rust and Hoon disagree on identical inputs. An attacker who can post a digest with off-field limbs on-chain (via any `NoteData` write path, or via direct gRPC interaction with the chain client) creates a state where the two VMs reach different conclusions about the same bytes. **This is a chainsplit primitive.**

In debug builds the assert fires and the issue is loud. In release (the only build that ships to production) it is silent.

**Verification.** Confirmed `based!` is `debug_assert!` at `nockchain/crates/nockchain-math/src/belt.rs:87`. Confirmed Rust API construction paths at `find_hash_entry:163-165` (just calls `as_u64()` with no range check) and `chain_hash_from_pb` (no range check). Confirmed `Tip5Hash` is a raw type alias with no constructor invariant.

**Remediation.**

1. **At every entry point that materializes `Tip5Hash` from external bytes, range-check each limb.** Wrap the type:
   ```rust
   #[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
   pub struct Tip5Hash([Belt; 5]);
   impl Tip5Hash {
       pub fn from_limbs(limbs: [u64; 5]) -> Result<Self, FieldRangeError> {
           for &l in &limbs { if l >= PRIME { return Err(FieldRangeError(l)); } }
           Ok(Self(limbs.map(Belt)))
       }
       pub fn from_limbs_unchecked(limbs: [u64; 5]) -> Self {
           Self(limbs.map(Belt))
       }
   }
   ```
   Route every external entry through `from_limbs`; only internal hash-output paths use `_unchecked`.

2. **Audit every existing call site** that builds a `Tip5Hash` from `u64`s, including: `note_data.rs:163-165`, `types.rs:76-84`, every test, and every downstream consumer in vesl-core / vesl-nockup / vesl-wallet that constructs limbs from non-hash sources.

3. **Add a release-mode integration test** that posts an off-field digest and asserts the verifier rejects (rather than computing a different digest).

4. **File an upstream issue** at nockchain to promote `based!` from `debug_assert!` to `assert!`, or document explicitly that downstream callers MUST range-check before invoking any belt arithmetic. Don't wait on upstream — fix it at the vesl-core boundary now.

---

### C-05 — CAIP-122 SIWN message body is field-injectable via unsanitized `params.uri` / `params.nonce` / etc.

> **RESOLVED — 2026-05-20 (vesl-wallet `43d8b8d`).** `validate_field()` rejects control chars before `format!`; `parse_caip122_message` rejects `\r`, asserts the blank line empty, asserts the line iterator exhausted.

**Severity:** Critical (single victim signature mints attacker-impersonation token)
**Repo:** vesl-wallet
**Files:**
- `crates/vesl-signing/src/caip122.rs:95-119` (`build_caip122_message`)
- `crates/vesl-signing/src/caip122.rs:123-163` (`parse_caip122_message`)
- `crates/vesl-signing/src/caip122.rs:222-278` (`verify`)

**Description.** `build_caip122_message` constructs the SIWN body via plain `format!` interpolation. None of `p.uri`, `p.nonce`, `p.chain_id`, `p.version`, `p.domain` are scrubbed for `\n` / `\r` / control bytes before splicing. The parser at `parse_caip122_message` is line-based via `str::lines()` and reads exactly 8 fields in order.

An attacker who can shape any one of those fields — most plausibly `uri`, but `nonce` and `chain_id` are also caller-influenced in many login flows — can embed:
```
"\nVersion: 1\nChain ID: attacker-chain\nNonce: attacker-nonce\nIssued At: 2026-01-01T00:00:00Z\nExpiration Time: 2099-01-01T00:00:00Z"
```
inside the URI value. The parser reads the legitimate `Version`/`Chain ID`/`Nonce`/`Issued At`/`Expiration Time` lines from the *attacker-controlled* injected content; the signer's intended values land on lines the parser never reaches.

The signature covers the full body, so it verifies. `params.address` (line 2 of body) is untouched by the injection. The replay cache stores the attacker-controlled nonce. Net effect: one legitimate victim signature → an SIWN bundle that the verifier accepts as authenticating the victim's address, bound to an arbitrary chain_id, with an expiration 80+ years in the future.

**Verification.** Confirmed by reading `build_caip122_message:95-119` (no sanitization) and `parse_caip122_message:123-163` (line-based, reads exactly 8 fields, ignores trailing content).

**Remediation.**

1. **Reject control characters in every field at build time.** Add a `validate_field(name, value)` helper that returns `Err` on any character `< 0x20` or `== 0x7F`. Call it for `domain`, `address`, `uri`, `version`, `chain_id`, `nonce`, and the formatted timestamps before `format!`.
2. **Make the parser strict.** Assert `_blank.is_empty()`. Assert `lines.next().is_none()` after `Expiration Time`. Reject any body that doesn't round-trip through `build → parse → build`.
3. **Add a property test** that fuzzes arbitrary unicode into every `SiwnParams` field and verifies `build → parse → build` is the identity OR rejects at build.

---

### C-06 — SIWN replay cache key is `(nonce)` only; no binding to `chain_id`, `address`, `uri`, or message digest

> **RESOLVED — 2026-05-20 (vesl-wallet `43d8b8d`).** The SIWN replay-cache key is now the full Tip5 message digest — binding domain, chain_id, address, uri, and nonce.

**Severity:** Critical (cross-chain / cross-resource replay)
**Repo:** vesl-wallet
**File:** `crates/vesl-signing/src/caip122.rs:267`

**Description.** `verify` builds the replay key as `prefixed(replay_domains::SIWN, params.nonce.as_bytes())`. The cache key is just the SIWN domain prefix + the nonce string. Nothing in the key binds to:
- `chain_id` (so a mainnet signature replays against testnet),
- `address` (so a captured signature replays against another address using the same nonce, if one exists),
- `uri` (so a `/login` signature replays against `/admin/payouts`),
- the message digest itself.

Per CAIP-122 §3.2 and SIWN spec, replay protection MUST bind the signature to all four. The current implementation provides per-nonce uniqueness only.

**Impact.** Combined with C-05 (which lets the attacker shape the nonce) and C-07 (which doesn't enforce `chain_id`/`uri`/`version`), this is the second leg of full SIWN bypass. Even without C-05, an attacker who captures a bundle on `api.example.com:mainnet` can present it to `api-testnet.example.com:testnet` if both share the `domain` string (or to a future-shared-cache deployment where the nonce is what's deduplicated, not the binding context).

**Remediation.** Key the cache on a hash of the full signed body or, equivalently, the Tip5 digest already computed at line 258:
```rust
let digest = tip5_with_domain(SIWN_DOMAIN_SEPARATOR, bundle.message.as_bytes());
schnorr_verify(&pk, &digest, &chal, &sig).map_err(|_| SiwnError::BadSignature)?;
// ...
let key = prefixed(replay_domains::SIWN, &tip5_to_bytes(&digest));
if cache.seen(&key, window) { return Err(SiwnError::Replay); }
```
Either format works; the point is the cache key includes everything the signature binds to.

---

### C-07 — `verify` does not validate `chain_id`, `uri`, or `version` against expected deployment values

> **RESOLVED — 2026-05-20 (vesl-wallet `43d8b8d`).** `verify` takes a `SiwnVerifyContext` and enforces domain/chain_id/uri/version with explicit `ChainIdMismatch` / `UriMismatch` / `VersionMismatch` errors.

**Severity:** Critical (cross-chain replay; spec-required defense missing)
**Repo:** vesl-wallet
**File:** `crates/vesl-signing/src/caip122.rs:222-278`

**Description.** `verify(header, expected_domain, cache, now)` checks only `params.domain == expected_domain` and the timestamp window. `params.chain_id`, `params.uri`, and `params.version` are parsed into `SiwnParams` but never compared against any expected value. A signature legitimately produced for `chain_id=nockchain:mainnet, uri=https://api.example.com/login, version=1` is accepted unchanged by a verifier deployed at `chain_id=nockchain:testnet, uri=https://api.example.com/admin/payouts, version=2` — provided both verifiers share the `domain` string.

Per CAIP-122 §3.2, the verifier MUST validate the chain_id matches its expected chain. This is the spec's primary cross-chain replay defense.

**Remediation.** Add expected-value parameters to `verify`:
```rust
pub struct SiwnVerifyContext<'a> {
    pub expected_domain: &'a str,
    pub expected_chain_id: &'a str,
    pub expected_uri: &'a str,
    pub expected_version: &'a str,
}
pub fn verify<C: ReplayCache>(
    header_b64: &str,
    ctx: &SiwnVerifyContext<'_>,
    cache: &C,
    now: DateTime<Utc>,
) -> Result<VerifiedIdentity, SiwnError> { ... }
```
Reject mismatches with explicit `ChainIdMismatch` / `UriMismatch` / `VersionMismatch` errors. Audit every call site of `verify` across vesl-core, vesl-nockup, and any downstream consumer and supply the per-deployment expected values.

---

### C-08 — `vesl-core-sync.yml` workflow is not deployed on `origin/dev` or `origin/main` — supply-chain mirror gate is paper-only

> **COMMITTED — DEPLOY-PENDING — 2026-05-20.** The `vesl-core-sync.yml` workflow is committed on `dev`; it goes live on `origin` with the pending batch push. Confirm post-push: `git show origin/main:.github/workflows/vesl-core-sync.yml`.

**Severity:** Critical (CI gate that prevents downstream-template drift is not active)
**Repo:** vesl-core
**File:** `.github/workflows/vesl-core-sync.yml`

**Description.** The workflow file exists on local `dev` but is absent from both `origin/dev` and `origin/main`. Verified:
```bash
$ git show origin/dev:.github/workflows/vesl-core-sync.yml
fatal: path '.github/workflows/vesl-core-sync.yml' exists on disk, but not in 'origin/dev'
$ git show origin/main:.github/workflows/vesl-core-sync.yml
fatal: path '.github/workflows/vesl-core-sync.yml' exists on disk, but not in 'origin/main'
```
Per CLAUDE.md §7 and `AUDIT_FOLLOWUP_INDEX.md`, this workflow is the gate that prevents "fixed in vesl-core, forgot to run sync.sh in vesl-nockup" drift. With the gate undeployed, any vesl-core PR landing changes to `crates/*` reaches `main` without verifying that vesl-nockup has been re-synced. Downstream users pulling vesl-nockup templates get stale or hand-edited crate code that doesn't match what vesl-core says shipped.

**Remediation.** Push the workflow to `origin/dev` and `origin/main`. After push, run `gh workflow list` to confirm the workflow is registered. Trigger a manual PR to verify it runs and the diff command works (see C-09).

---

### C-09 — Even if deployed, `vesl-core-sync.yml`'s diff command is structurally broken (always fails); CI pins disagree with sync.sh, one is non-existent

> **RESOLVED — 2026-05-20 (`a439d53`).** Workflow rewritten to one-way `sync.sh --verify`; `NOCK_PIN` / `VESL_CORE_PIN` / `VESL_WALLET_PIN` aligned across `ci.yml` and `sync.sh`; the non-existent `VESL_WALLET_PIN` replaced with a real SHA.

**Severity:** Critical (CI gate, if deployed, would either always fail or check the wrong SHAs)
**Repo:** vesl-core + vesl-nockup
**Files:**
- `vesl-core/.github/workflows/vesl-core-sync.yml:42` (broken diff)
- `vesl-nockup/.github/workflows/ci.yml:17-18` (CI pins)
- `vesl-nockup/sync.sh:43,49` (sync.sh pins)

**Description.** Two compounding issues:

1. **Diff command is asymmetric-incompatible.** The vesl-core sync workflow uses `diff -rq vesl-core/crates vesl-nockup/crates`. But vesl-nockup contains 4 crates (`vesl-hull`, `vesl-signing`, `vesl-wallet`, `vesl-wallet-spec`) that do not exist in vesl-core. `diff -rq` returns exit 1 on "Only in" entries, so the gate would always fail — masking the actual drift signal in noise. The semantic the gate needs is: every file in `vesl-core/crates` must exist byte-identical under `vesl-nockup/crates/`; extra files in vesl-nockup are OK.

2. **CI pins are wrong.** Vesl-nockup's CI declares:
   - `VESL_CORE_PIN=9e527a947860d66782fb7b3ede3b42ee085559f0` (5 days behind sync.sh's `e141265b...`)
   - `VESL_WALLET_PIN=12c2e447e95a96bd99c39ed81b8bf6a8b07cb0d8` — verified via `git cat-file -t`: this SHA does not exist in the vesl-wallet repo.

   So the `sync-verify` job either fails on `actions/checkout` ("could not find ref") or, if the ref happens to exist somewhere, hits `sync.sh`'s `check_sibling_pin` tripwire and aborts before verifying anything.

**Remediation.**

1. **One-way diff:** rewrite the gate's diff loop to walk `vesl-core/crates` and assert each file matches its counterpart under `vesl-nockup/crates/`. Or simpler: run `vesl-nockup/sync.sh --verify` against the PR's vesl-core HEAD — that's the canonical contract anyway.
2. **Align pins:** update `vesl-nockup/.github/workflows/ci.yml`'s `VESL_CORE_PIN` and `VESL_WALLET_PIN` to match `vesl-nockup/sync.sh`. Add a fast pre-flight `git ls-remote` step in the workflow to catch non-existent SHAs before checkout fails opaquely.

---

## 3. High Severity

### H-01 — Production Hoon kernels lack capacity caps on `registered` and `settled` maps

> **RESOLVED — 2026-05-20 (`0433502`; JAMs `066dc29`; hull-llm `8d4f43d`).** A 10M `registered` cap and settle-graft-style epoch-rotation of the `settled` set landed in `kernel-arms.hoon` + `forge-kernel.hoon` and hull-llm's `vesl-kernel.hoon`.

**Repo:** vesl-core (kernel-arms, guard, mint, settle, forge) + hull-llm (vesl-kernel, post-cleanup)
**Files:**
- `vesl-core/protocol/lib/kernel-arms.hoon:17-23` (`handle-register`)
- `vesl-core/protocol/lib/settle-kernel.hoon:30-32, 99-101`
- `hull-llm/protocol/lib/vesl-kernel.hoon` (versioned-state `+$` block; lines shifted post-Phase-4 import refactor)
- `vesl-core/protocol/lib/forge-kernel.hoon:22-27, 269`

The audit comments labeled `AUDIT 2026-04-17 H-02` added 10M caps to every graft library (`mint-graft`, `guard-graft`, `settle-graft`, `kv-graft`, etc.) — but `kernel-arms.hoon`'s `+handle-register` and the production kernels themselves have NO cap. The shipped guard/mint/settle/forge kernels (vesl-core) and vesl-kernel (hull-llm) are what compile to JAM artifacts. The grafts protect downstream app composers; the production kernels are exposed.

Production `settled` set never rotates. `settle-graft.hoon` rotates at 1M settles; production `settle-kernel.hoon`, `vesl-kernel.hoon`, `forge-kernel.hoon` have unbounded `set @`. Each successful settle grows kernel state permanently.

**Attack:** Adversary with poke access calls `%register` with distinct `hull` IDs 10⁶ times; the registered map grows linearly, eventually exhausting Nock stack.

**Fix:** Lift caps from grafts into `kernel-arms.hoon` and the production kernels. See Hoon audit body for sketch.

---

### H-02 — `vesl-entrypoint.hoon` bypasses all settlement guards (registration, root match, replay)

> **RESOLVED — 2026-05-20 (hull-llm `f3821a1`).** The STAGED `vesl-entrypoint` arm is now `?>  %.n` (crashes unconditionally if a kernel composes it); confirmed imported by no shipped kernel.

**Repo:** hull-llm (post-cleanup; was vesl-core pre-2026-05-19)
**File:** `hull-llm/protocol/lib/vesl-entrypoint.hoon`

The "STAGED" entrypoint arm directly calls `settle-note` with `expected-root.args` and the manifest, both attacker-controlled. No `registered` check, no `expected-root` cross-check, no replay set, no `note.root == expected-root` check. The arm produces a `[id=@ hull=@ root=@ state=[%settled ~]]` for any hull/id the attacker chooses, indistinguishable at the type level from a legitimate settlement.

Latent today (no shipped kernel composes `vesl-entrypoint`), but one `/+` import away from production. The `:: STAGED:` header tag is documentation, not a guard.

The file moved to hull-llm in the architectural cleanup (it imports `rag-logic` and operates on the RAG manifest type). The finding semantics are unchanged — the staged code path is just as risky in hull-llm as it was in vesl-core, since vesl-kernel.hoon (also in hull-llm) is one `/+` import away from composing it.

**Fix:** Move to `hull-llm/protocol/tests/`, or make the arm bang (`!!`) with a STAGED trace, or wire in the full `validate-settlement-args` check via kernel-arms.

---

### H-03 — `forge-kernel.hoon` `%settle`/`%prove` `verify-chunk` depth-cap crashes the kernel poke instead of emitting a typed error

> **RESOLVED — 2026-05-20 (`5582129`; JAMs `066dc29`).** `%settle`/`%prove` bind the leaf-verify result and emit a typed `%settle-error`/`%prove-error` effect instead of crashing the poke via `?>`.

**Repo:** vesl-core
**Files:** `protocol/lib/forge-kernel.hoon:128-133, 219-224`; `protocol/lib/vesl-merkle.hoon:119-121`

`verify-chunk` returns `%.n` on >64-depth proofs (depth-cap). In `forge-kernel.hoon`'s %settle/%prove arms, this `%.n` is consumed inside `?>` — converting "verify failed" into `!!`. The kernel poke crashes; the operator sees a panic indistinguishable from a real bug.

**Fix:** Replace the inline `?>` verify-loop with a mule-wrapped variant emitting `%settle-error 'forge: leaf verify failed'`.

---

### H-04 — vesl-core's shim `from_belts([Belt; 8])` silently truncates high bits (M-08 fixed in vesl-wallet, NOT in vesl-core)

> **RESOLVED — 2026-05-20 (`61870e7`).** `nock_belts8_to_vesl` range-checks each t8 chunk against `u32::MAX`, and `derive_pubkey` returns `Result` — out-of-range belts no longer panic the caller.

**Repo:** vesl-core
**File:** `crates/vesl-signing/...` — but vesl-core consumes vesl-signing via patch. The actual fix at `vesl-wallet/crates/vesl-signing/src/schnorr.rs:163` (rejects `v > u32::MAX`) is correct. However: vesl-core has its own `signing.rs::nock_belts8_to_vesl` (`crates/vesl-core/src/signing.rs:121`) that constructs the belts vector before passing to `SchnorrPrivateKey::from_belts`. If a caller routes attacker-influenced `[Belt; 8]` through `derive_pubkey`, the per-belt range is not checked at the vesl-core boundary — the check happens in vesl-signing, but only catches `v > u32::MAX`, not arbitrary out-of-G_ORDER scalars.

**Fix:** Verify each `Belt(v)` is `v <= u32::MAX` in `nock_belts8_to_vesl`. Audit all callers that derive their `[Belt; 8]` from non-wallet sources (HMAC outputs, manually constructed test fixtures, anything via the FFI).

---

### H-05 — `RagVerifier::verify` ignores `note_id` despite the trait being audited specifically to add it

> **RESOLVED — 2026-05-20 (hull-llm `612884b`).** `RagVerifier::verify` enforces `note_id == expected_root[0]`, binding the settled note to the manifest's Merkle root and closing the pre-commit race.

**Repo:** hull-llm (post-cleanup; was vesl-core pre-2026-05-19)
**File:** `hull-llm/src/rag_verifier.rs`

The `CommitmentVerifier::verify` trait was updated to take `note_id: u64` (per `types.rs:95-99` comment — "AUDIT 2026-04-17 H-03: `verify` takes `note_id` so domain verifiers can enforce `note_id == deterministic_fn(data)`, closing the pre-commit race"). The shipped `RagVerifier` impl ignores the argument:
```rust
fn verify(&self, _note_id: u64, data: &[u8], expected_root: &Tip5Hash) -> bool {
```
Every `Settle<RagVerifier>` consumer is vulnerable to the pre-commit race the trait change was designed to close. The `MockVerifier` in tests also ignores `note_id`, so coverage doesn't catch this.

**Fix:** Have `RagVerifier::verify` compute `expected_note_id = hash_leaf_digest(data)` (or whatever the kernel's `validate-settlement-args` uses) and `return false` if `note_id != expected_note_id`.

---

### H-06 — `RagVerifier::verify` and `build_settle_poke` allocate before bounding manifest size → OOM-class DoS

> **RESOLVED — 2026-05-20 (hull-llm `612884b`).** A `MAX_MANIFEST_JSON_BYTES` (64 MiB) length check runs before `serde_json::from_slice` in both `RagVerifier::verify` and `build_settle_poke`.

**Repo:** hull-llm (post-cleanup; was vesl-core pre-2026-05-19)
**Files:** `hull-llm/src/rag_verifier.rs` (verify body); `hull-llm/src/manifest_pokes.rs` (build_settle_poke body)

`serde_json::from_slice(data)?` runs against caller-supplied bytes; the `manifest.results.len() > 10_000` / `total_bytes > 10_000_000` checks happen after deserialization. An attacker submitting 1 GB of well-formed JSON allocates the full graph before bound check fires.

The companion `Guard::check_manifest` / `Guard::validate_manifest` methods in `vesl-core/crates/vesl-core/src/guard.rs:118-133` were deleted in the architectural cleanup (Guard is now generic). The semantic check moved entirely into hull-llm's `RagVerifier::verify`; the size-check ordering issue moved with it.

**Fix:** Add `if data.len() > MAX_MANIFEST_BYTES { return false; }` (or equivalent) **before** the `from_slice` in `RagVerifier::verify`.

---

### H-07 — `Settle::settled_ids` grows unbounded; long-running hull leaks memory

> **RESOLVED — 2026-05-20 (`489d3ac`, `1327286`).** `Settle::settled_ids` is FIFO-capped at 10⁶ entries (the kernel `settled` set remains the authoritative replay defense).

**Repo:** vesl-core
**File:** `crates/vesl-core/src/settle.rs:88, 164`

`settled_ids: HashSet<u64>` accumulates every settled note ID forever. No eviction, no LRU, no flush. 10⁸ settles → ~3 GB of dead replay-state. (The kernel-side `settled-set` in `settle-kernel.hoon` is the authoritative replay defense; the SDK cache is a pre-flight diagnostic and can be lossy.)

**Fix:** LRU-cap at 10⁶ entries.

---

### H-08 — Kernel pokes (`tx_builder::kernel_sig_hash`, `kernel_tx_id`) have no timeout

> **RESOLVED — 2026-05-20 (`978c441`).** `kernel_sig_hash` and `kernel_tx_id` wrap the `app.poke` await in a 30s `tokio::time::timeout`.

**Repo:** vesl-core
**File:** `crates/vesl-core/src/tx_builder.rs:24-44, 46-68`

Both functions `await app.poke(...)` against a `NockApp` handle with no `tokio::time::timeout` wrapper. A kernel hang (panic in a graft arm, infinite loop, slow STARK proof) leaves the calling task hung indefinitely.

**Fix:** Wrap pokes in `tokio::time::timeout`. The hull's `poke_kernel_with_timeout` already implements this — vesl-core just needs to match.

---

### H-09 — `D(amount_nicks)` / `D(fee_nicks)` / `D(key_index)` panic the wallet client on values ≥ 2^63

> **RESOLVED — 2026-05-20 (`ac343b6`).** `wallet.rs` builds tx amount / fee / key-index atoms via `u64_to_noun` (picks `D()` vs indirect atom by size) — no `D()` panic above 2^63.

**Repo:** vesl-core
**File:** `crates/nockchain-client-rs/src/wallet.rs:236, 277, 282`

`build_sign_hash_poke` / `build_create_tx_poke` accept `u64` parameters and pass them through `D(...)` which calls `DirectAtom::new_panic`. A transaction touching > 9.2×10^18 Nicks crashes the calling process.

**Fix:** Use `nock_noun_rs::atom_from_u64` (which picks `D()` vs indirect atom by size) at every site that passes `u64` to `D()`.

---

### H-10 — `cue_into` blob size in `find_*_entry` is unbounded → memory DoS

> **RESOLVED — 2026-05-20 (`e3ec565`).** `find_*_entry` routes through a `cue_entry_blob` helper that rejects a `NoteDataEntry` blob over `MAX_BLOB_LEN` (1 MiB) before `cue_into`.

**Repo:** vesl-core
**File:** `crates/nockchain-client-rs/src/note_data.rs:131, 150, 178`

Every `find_*_entry` accepts the full `entry.blob: Bytes` and feeds it to `cue_into` with no application-level size check. Inside `cue` the slab grows by doubling; on attacker-crafted blobs, allocator overhead can be 4× the input size. Aggregate across concurrent peeks/pokes = DoS.

**Fix:** Add `const MAX_BLOB_LEN: usize = 1 << 20` check at top of each `find_*_entry`. Add `Server::max_decoding_message_size(...)` on grpc construction.

---

### H-11 — gRPC clients default to plaintext `http://...`; no TLS path; no host pinning

> **RESOLVED — 2026-05-20 (`ac3e6e0`).** `ChainClient`/`WalletClient` `connect()` reject a plaintext `http://` endpoint to a non-loopback host; `https://` (tonic webpki TLS) and loopback pass.

**Repo:** vesl-core
**Files:** `crates/nockchain-client-rs/src/chain.rs:46,57`; `crates/nockchain-client-rs/src/wallet.rs:54`

`ChainConfig::default()` and `WalletConfig::default()` return `http://localhost:...`. tonic with `tls-webpki-roots` is in Cargo.toml but never invoked. Any operator following the README and pointing at a remote node over `http://` exposes balance queries, tx submission, and (worse) signing requests to passive MITM.

**Fix:** Reject non-loopback hosts without TLS at `connect()`. Surface a `ClientTlsConfig` option. Document the wallet endpoint as security-critical.

---

### H-12 — `rejam_atom` panics on attacker-controlled bytes (M-03 from prior audit, still unfixed)

> **RESOLVED — 2026-05-20 (`e10ab1c`).** `rejam_atom` returns `Result<Vec<u8>, RejamError>` instead of `.expect()`-panicking on malformed jam.

**Repo:** vesl-core
**File:** `crates/nock-noun-rs/src/lib.rs:200-206`

```rust
pub fn rejam_atom(bytes: &[u8]) -> Vec<u8> {
    let noun = cue_from_bytes(bytes)
        .expect("rejam_atom: input is not valid jam");
    jam_to_bytes(noun)
}
```
On the cross-graft cue-then-jam canonicalization path. A graft emitting malformed bytes crashes the runtime via the next graft's `rejam_atom` call.

**Fix:** Change signature to `Result<Vec<u8>, RejamError>`. Audit every call site.

---

### H-13 — SIWN replay-cache TTL is attacker-controlled (M-07 from prior audit, still unfixed)

> **RESOLVED — 2026-05-20 (vesl-wallet `21ccb6a`).** The SIWN replay-cache window is clamped to `MAX_SIWN_WINDOW` (1h) — an attacker-set expiration can no longer pin a cache entry for decades.

**Repo:** vesl-wallet
**File:** `crates/vesl-signing/src/caip122.rs:261-263`

`(params.expiration_time - params.issued_at)` is fed to `cache.seen(&key, window)` as-is. Attacker sets `issued_at = 1970-01-01, expiration_time = 2099-01-01` → cache entry lives ~130 years. Compounded by the in-memory HashMap implementation = unbounded memory growth.

**Fix:** `let window = (params.expiration_time - params.issued_at).to_std().unwrap_or(...).min(MAX_SIWN_WINDOW)` where `MAX_SIWN_WINDOW = Duration::from_secs(3600)`.

---

### H-14 — `schnorr_verify` does not require the pubkey to be on-curve

> **RESOLVED — 2026-05-20 (vesl-wallet `a6a870c`).** `schnorr_verify` rejects an off-curve `pubkey` at entry, before any curve arithmetic.

**Repo:** vesl-wallet
**File:** `crates/vesl-signing/src/schnorr.rs:261-296`

`schnorr_verify(pubkey: &CheetahPoint, ...)` accepts a `CheetahPoint` by reference. Any consumer that constructs `CheetahPoint { x, y, inf: false }` from raw F6 coordinates and calls `schnorr_verify` directly bypasses the `in_curve()` check that `decode_signature` performs. With an off-curve point, `ch_scal_big` still produces an affine-arithmetic result; the soundness argument (proves knowledge of discrete log w.r.t. A_GEN) collapses.

The `vesl-core/crates/vesl-core/src/signing.rs::nock_point_to_vesl` shim is exactly such a consumer.

**Fix:** First line of `schnorr_verify`: `if !pubkey.in_curve() { return Err(SchnorrError::BadSignature); }`. Or take `&VerifiedPublicKey` newtype.

---

### H-15 — Demo signing key gate (`is_demo_key`) exists but is never invoked (M-09 from prior audit, still unfixed)

> **RESOLVED — 2026-05-20 (vesl-nockup `d3c4f39`).** vesl-hull's `resolve_with_demo_key_checked` invokes `is_demo_key` and refuses the public demo key on the dumbnet path. (vesl-core's `resolve_dumbnet` never takes a demo key — no surface there.)

**Repo:** vesl-nockup (the hull lib that uses demo keys)
**Files:** `vesl-nockup/crates/vesl-hull/src/signing.rs:31`; `vesl-nockup/crates/vesl-hull/src/config.rs:117`

`is_demo_key()` is defined and exported. `grep -rn 'is_demo_key' vesl-nockup/crates/` shows two hits: the definition and the re-export. Nothing invokes it as a runtime gate. `resolve_with_demo_key_checked` passes `signing::demo_signing_key()` directly into `SettlementConfig::resolve_checked` without ever asking "is this a demo key, and are we in a mode that allows it?"

A developer who copies the fakenet config to dumbnet by mistake signs every transaction with the publicly-known key `[Belt(12345), Belt(67890), ...]`.

**Fix:** In `SettlementConfig::resolve_dumbnet` (vesl-core/crates/vesl-core/src/config.rs) and any dumbnet-or-better path in vesl-hull, refuse if `is_demo_key(&sk)`.

---

### H-16 — sync.sh sed-pattern injection via `$NOCK_PIN` allows arbitrary Cargo.toml rewrite

> **RESOLVED — 2026-05-20 (vesl-nockup `574e2d4`).** `sync.sh` validates `NOCK_PIN` / `VESL_CORE_PIN` / `VESL_WALLET_PIN` against `^[0-9a-f]{40}$` before any sed rewrite.

**Repo:** vesl-nockup
**File:** `sync.sh:320-322`

```bash
sed -i -E \
    's|path = "\.\./\.\./\.\./nockchain/crates/[^"]*"|git = "https://github.com/nockchain/nockchain.git", rev = "'"$NOCK_PIN"'"|g' \
    "$toml"
```
`$NOCK_PIN` is interpolated verbatim into a sed replacement pattern with zero validation. An override `NOCK_PIN='abc", branch = "main'` produces `rev = "abc", branch = "main"` — Cargo will resolve the mutable branch instead of the immutable SHA. `&` is sed's "entire matched text" sigil; `NOCK_PIN='deadbeef&'` interpolates the full match back into the output, corrupting Cargo.toml.

**Fix:** Validate `$NOCK_PIN` matches `^[0-9a-f]{40}$` at the top of sync.sh before any rewrite. Same for `$VESL_CORE_PIN`, `$VESL_WALLET_PIN`. Migrate from `sed` to `toml_edit` for structured-format rewrites.

---

### H-17 — `cp -rL` in sync.sh ingests upstream maintainer's untracked working-tree state

> **RESOLVED — 2026-05-20 (vesl-nockup `574e2d4`).** `sync.sh` copies crates/templates via a `copy_tree` helper that prunes gitignored paths, and now refuses a dirty or untracked source tree.

**Repo:** vesl-nockup
**File:** `sync.sh:208,216,226,264,277,309`

`cp -rL` ignores `.gitignore`. vesl-core's working tree has untracked artifacts: `.data.vesl-checkpoint-test/{event-log.sqlite3, pma/0.pma, ...}`, `templates/*/app.nock`, `templates/*/out.jam`. Verified present. Running sync.sh today drags all of them into the vesl-nockup bundle. Downstream users receive surprise binary content (potentially including stale-test database state).

**Fix:** Replace `cp -rL` with `rsync -aL --exclude-from=<(git -C "$vesl" ls-files --others --ignored --exclude-standard --directory)` so gitignored files are skipped. Strengthen the existing dirty-tree warning to a hard refusal.

---

### H-18 — sync.sh follows arbitrary symlinks; nockchain working-tree silently joins the trust boundary

> **RESOLVED — 2026-05-20 (vesl-nockup `574e2d4`).** `sync.sh` asserts `hoon/common`, `hoon/dat`, `hoon/jams` each resolve into a `nockchain/hoon` tree before the symlink-dereferencing copy.

**Repo:** vesl-nockup
**File:** `sync.sh:208-216, 262-266`

`cp -rL` follows symlinks. `vesl-core/hoon/common`, `hoon/dat`, `hoon/jams`, `hoon/trivial.hoon` are symlinks into `../nockchain/hoon/*`. So "trust vesl-core" is actually "trust the union of vesl-core AND nockchain working trees as of the sync moment."

**Fix:** Before each `cp -rL`, assert every symlink target is within an expected tree.

---

### H-19 — Templates' `build.rs` invokes `nockup-graft` from PATH (RCE surface)

> **RESOLVED — 2026-05-20 (`7522fc5`).** Templates' `build.rs` resolves the codegen binary from an explicit `NOCKUP_GRAFT_BIN` path (skip-with-warning if unset) — never a bare PATH search. (sha256-pinning was impractical: the binary is built fresh per repo.)

**Repo:** vesl-nockup
**Files:** `templates/{counter,data-registry,graft-hash-gate,graft-intent,graft-mint,graft-settle,settle-report}/build.rs`

Standard `build.rs` PATH risk. A malicious `nockup-graft` shim earlier on PATH triggers arbitrary code execution on every `cargo build`.

**Fix:** Either verify the `nockup-graft` binary by sha256 before invoking, or wire the codegen pass into the graft-inject library directly so `build.rs` doesn't shell out.

---

### H-20 — Snapshot SHA-256 recorded but never verified on resume

> **RESOLVED — 2026-05-20 (`36c61f3`).** `resume_with_data_dir` takes an optional source-hoon path; when supplied it re-hashes the source and warns on a `source_sha256` mismatch.

**Repo:** vesl-core
**File:** `crates/vesl-checkpoint/src/lib.rs:50-61, 188-232`

`Snapshot::source_sha256` is captured at snapshot time and persisted. `resume()` reads `meta.toml` (via `Snapshot::load`) but does NOT re-hash the new kernel's source and compare. The rustdoc claims "mismatches are warnings, not errors" — but there is no comparison code anywhere.

**Fix:** Add an optional `&Path` parameter to `resume_with_data_dir` for the new kernel's source hoon; if provided, hash it and warn (or error) on mismatch with `snapshot.source_sha256`.

---

### H-21 — Dockerfile clones nockchain from `zorp-corp/nockchain` (likely outdated/wrong org) at outdated SHA

> **RESOLVED — 2026-05-20 (`e6ea1ec`).** The tracked `docker/NOCKCHAIN_COMMIT` (the gitignored Dockerfile's pin-of-record) is bumped to `NOCK_PIN` with the `nockchain/nockchain` org; `check-pins.sh` and `bump-pin.sh` now validate/write that tracked file instead of the absent Dockerfile.

**Repo:** vesl-core
**File:** `Dockerfile:64-66`

The Dockerfile uses `git clone https://github.com/zorp-corp/nockchain.git` at SHA `505c3ea`. All other references (workflows, sync.sh, docker README) use `nockchain/nockchain` at SHA `fe46f4e`. Whoever uses `docker build` gets a different (and outdated) nockchain than CI ships. Either `zorp-corp` is wrong, or `nockchain/nockchain` is wrong — they cannot both be canonical.

**Fix:** Pick one canonical org, update consistently across Dockerfile, workflows, sync.sh, docs. Bump NOCKCHAIN_COMMIT in Dockerfile to match CI's NOCK_PIN.

---

### H-22 — `vesl-core` `ci.yml` is documented-broken (workflow runs but cargo cannot resolve deps without sibling nockchain checkout)

> **RESOLVED — 2026-05-20 (`4b06acf`).** `ci.yml`'s test / audit / clippy jobs check out sibling `nockchain/nockchain` at `NOCK_PIN`, mirroring `jam-determinism.yml`.

**Repo:** vesl-core
**File:** `.github/workflows/ci.yml`

The workflow's own comment: "Full CI requires either (a) a checkout step that clones nockchain to the expected relative path, or (b) publishing nockchain crates to a registry. Until then, this workflow is useful for local `act` runs and as a template." `cargo test`, `cargo audit`, `cargo clippy` all need a sibling `../nockchain/` checkout that the workflow never creates. So none of these gates actually run.

**Fix:** Mirror the `jam-determinism.yml` pattern (which DOES check out nockchain at NOCK_PIN). Add an explicit `actions/checkout@v4` step for nockchain at `NOCK_PIN`.

---

## 4. Medium Severity

### M-01 — Empty `results` list bypasses `verify-manifest` in Hoon kernel

> **OPEN — flagged for security review (2026-05-20).** Assessed as likely-not-a-bug: the empty-`results` path still binds via the `built == prompt.mani` comparison, so no behavioral change was made. A reviewer should confirm before adding the `?>  !=(~ results.mani)` guard — that guard would also reject legitimately-empty manifests.

**Repo:** hull-llm (post-cleanup)
**File:** `hull-llm/protocol/lib/rag-logic.hoon` (`+verify-manifest`)

`verify-manifest` returns `%.y` for `(results=~, prompt==query)` — no Merkle verification runs. The companion Rust check (formerly in vesl-core's `guard.rs:142-144`) was lifted into hull-llm's `RagVerifier::verify`, which catches the empty-results case — but direct kernel pokes still don't go through the Rust hull. Combined with H-01 (unsigned register), an attacker with kernel poke access can mint "settled" notes for arbitrary (id, hull) with zero data binding.

**Fix:** `?>  !=(~ results.mani)` at the top of `verify-manifest`.

### M-02 — Hoon `verify-manifest` doesn't enforce dup-id or null-byte chunk rules that Rust enforces

> **RESOLVED — 2026-05-20 (hull-llm `9e3827c`; JAM `1ab09fc`).** `verify-manifest` now rejects duplicate chunk-ids (via an accumulated `(set @)`) and NUL-byte chunks — parity with the Rust `RagVerifier`.

**Repo:** hull-llm (post-cleanup)
**File:** `hull-llm/protocol/lib/rag-logic.hoon` (`+verify-manifest`) vs `hull-llm/src/rag_verifier.rs` (`RagVerifier::verify`)

Rust rejects duplicate chunk IDs and chunks containing null bytes. Hoon doesn't. Strictly weaker on the direct-kernel-poke path. (Both files now live in hull-llm; the divergence is internal to the verified-RAG vertical.)

### M-03 — `verify-chunk` crashes (not %.n) on out-of-range sibling atoms

> **RESOLVED — 2026-05-20 (`24586ee`; JAMs `f6b1580`).** `verify-chunk` range-guards each sibling hash against `p^5` and returns soft `%.n` instead of crashing `hash-pair` on an out-of-field atom.

**Repo:** vesl-core
**File:** `protocol/lib/vesl-merkle.hoon:96-130`

Sibling atom ≥ p^5 → `hash-ten-cell:tip5` asserts → kernel poke crash, not `%.n` return.

**Fix:** `?:  (gth hash.i.proof max-tip5-atom)  %.n` at top of each loop iteration.

### M-04 — `read-index` field in submitted proof is unvalidated

> **RESOLVED — 2026-05-20 (`eca210a`; JAMs `f6b1580`).** `verify-inner` asserts `?>  =(0 read-index.proof)` immediately after the `hashes` check.

**Repo:** vesl-core
**File:** `protocol/lib/vesl-stark-verifier.hoon:79-86`

Verifier asserts `?>  =(~ hashes.proof)` but not `?>  =(0 read-index.proof)`. Not a direct soundness break today; future callers could be confused.

**Fix:** One-line assert `?>  =(0 read-index.proof)` after the hashes check.

### M-05 — Caller-supplied `[s, f]` with non-Belt atoms crash `build-tree-data`

> **RESOLVED — 2026-05-20 (`20128c5`; JAMs `f6b1580`).** `verify-inner` guards `?>  (based-noun s)` and `?>  (based-noun f)` before the `build-tree-data:fock` calls.

**Repo:** vesl-core
**File:** `protocol/lib/vesl-stark-verifier.hoon:179-184`

`pelt-lift` asserts `based`. Caller with non-Belt subject crashes inside `build-tree-data`. Verify-side mule catches it; prover side doesn't. Diagnostic collapse.

**Fix:** `?>  (based-noun s)` and `?>  (based-noun f)` at top of `verify-inner` and `prove-computation`.

### M-06 — `split-and-fold` Horner fold is non-injective across manifest segments

> **DEFERRED — 2026-05-20.** A length-prefix fix changes every STARK fold output — a breaking cross-VM digest-format change. Tracked as a separate v1→v2 format-version workstream, outside the medium-fix batch.

**Repo:** vesl-core
**File:** `protocol/lib/vesl-stark.hoon:26-52`

Folds `qb ++ ob ++ pb ++ chunk-belts` without separators. Two manifests with different `query`/`output` split-points but same concatenation produce the same fold output. The data-binding from "STARK verified" to "manifest verified" is non-injective. (Mitigated today by `settle-note`'s separate Merkle verification — but the README must not claim the STARK binds manifest content.)

**Fix:** Prepend length prefixes to the fold-belts list before Horner.

### M-07 — `prove-computation` doesn't lower formula before `fink:fock`

> **RESOLVED — 2026-05-20 (`50cc7b7`; JAMs `f6b1580`).** `prove-computation` lowers the formula to the Nock 0-8 subset (`/+  *vesl-lower`) before `fink:fock`.

**Repo:** vesl-core
**File:** `protocol/lib/vesl-prover.hoon:51-92`

`fink:fock` crashes on opcodes 9/10/11. Production caller passes only safe opcodes 0/4, but the public arm signature suggests arbitrary formulas are supported.

**Fix:** Call `(lower formula)` inside `prove-computation` (`vesl-lower` already exists). Or hard-assert via `?>  (only-0-8 formula)`.

### M-08 — Hoon `validate-settlement-args` in `%verify` mode bypasses the replay check

> **RESOLVED — 2026-05-20 (`ce7e778`; JAMs `f6b1580`).** `validate-settlement-args` documents that a `%verify` `[%.y ~]` is not a settle-safety guarantee — replay rejection is a `%mutate`-time outcome.

**Repo:** vesl-core
**File:** `protocol/lib/kernel-arms.hoon:74-79`

`%verify` mode skips replay; verify returns `%.y` for already-settled notes. UX trap for callers using `%verify` as a "can I settle this?" preflight.

**Fix:** Add an opt-in `%can-settle` query that includes replay, or document the limitation prominently.

### M-09 — `hash-leaf` trailing-zero collisions (H-03 from prior audit, unfixed)

> **DEFERRED — 2026-05-20.** `hash-leaf-v2-domain` is a breaking cross-VM digest-format change (alters every Merkle leaf hash; needs fixture regen). Tracked as a separate v1→v2 workstream — design doc `docs/AUDIT_H03_HASH_LEAF.md`.

**Repo:** vesl-core
**Files:** `protocol/lib/vesl-merkle.hoon:38-52`; `crates/nockchain-tip5-rs/src/lib.rs:131-161`

Both Rust and Hoon strip trailing zero bytes when chunking into belts. Documented; planning doc landed (`docs/AUDIT_H03_HASH_LEAF.md`); fix not in `dev`. Still: `hash_leaf("x") == hash_leaf("x\0")`.

**Fix:** Land `hash-leaf-v2-domain(tag, data)` per the planning doc.

### M-10 — `bytes_to_belts` (vesl-signing) trailing-NUL collisions

> **DEFERRED — 2026-05-20.** A length-prefix changes every `tip5_with_domain` output — a breaking digest-format change; grouped with the M-09 v1→v2 workstream.

**Repo:** vesl-wallet
**File:** `crates/vesl-signing/src/domain.rs:129-143`

`bytes_to_belts(b"") == bytes_to_belts(b"\0")`. Different bytes hash to the same `tip5_with_domain` digest if their tails differ only in trailing NULs aligned to a 7-byte boundary. Public `tip5_with_domain` consumers hashing arbitrary byte tails can construct collisions.

**Fix:** Length-prefix in `bytes_to_belts` (emit `Belt(bytes.len() as u64)` first).

### M-11 — Non-constant-time scalar multiplication leaks the Schnorr nonce

> **DEFERRED — 2026-05-20.** `ch_scal_big` is left unchanged and flagged for a reviewer fluent in constant-time EC arithmetic — a constant-time rewrite is expert work, not a mechanical fix.

**Repo:** vesl-wallet
**Files:** `crates/vesl-signing/src/math/cheetah.rs:333-346` (`ch_scal_big`), `:304-318` (`ch_add`), `:272-280` (`ch_double`)

Textbook double-and-add: iteration count = scalar bit-length; `ch_add` has multiple data-dependent branches. Timing side-channel on `schnorr_sign` recovers bits of the nonce `k`; from `(k, chal, sig)` the verifier formula yields `sk` directly. Threat model: multi-tenant facilitator, co-located serverless, any remote observer.

**Fix:** Replace `ch_scal_big` with a Montgomery-ladder constant-time impl. Or nonce-blind via `k' = k + r·G_ORDER`.

### M-12 — `SchnorrPrivateKey` derives `Debug`; raw scalar leaks via `{:?}`

> **RESOLVED — 2026-05-20 (vesl-wallet `c0b4277`).** `SchnorrPrivateKey` and `ExtKey` drop the derived `Debug` for a hand-written `<redacted>` impl. (`DerivedKey` already had no `Debug` derive.)

**Repo:** vesl-wallet
**File:** `crates/vesl-signing/src/schnorr.rs:93-95`

`#[derive(Debug)] pub struct SchnorrPrivateKey(UBig)`. `UBig`'s Debug prints the integer in decimal. Any `tracing::debug!("sk={:?}", sk)` dumps the key to logs.

**Fix:** Manual `Debug` impl printing `<redacted>`. Same for `ExtKey`, `DerivedKey`.

### M-13 — Secrets never zeroized despite `zeroize` dependency

> **RESOLVED — 2026-05-20 (vesl-wallet `f1354c6`).** The 64-byte BIP-39 seed is `Zeroizing`-wrapped and `bip39/zeroize` is enabled. The `ibig::UBig` scalar residual is documented in-source — a byte-backed-key refactor was scoped out by decision.

**Repo:** vesl-wallet
**Files:** `crates/vesl-wallet/Cargo.toml:27-28`; `crates/vesl-signing/src/schnorr.rs:94`; `crates/vesl-wallet/src/hd.rs:68-78`; `crates/vesl-wallet/src/wallet.rs:21-27`

`zeroize` is declared with comment `# Zeroize key material on drop.`. `grep -rn 'Zeroize\|ZeroizeOnDrop\|impl Drop'` returns nothing. Secrets (private keys, chain codes, master seed, mnemonic) outlive their `Drop` in freed heap/stack memory.

**Fix:** Add `#[derive(ZeroizeOnDrop)]` (with custom `Zeroize` for `UBig`-containing types). Enable `bip39/zeroize` feature. Zeroize the 64-byte seed local in `from_seed_phrase`.

### M-14 — Replay cache is in-memory only; restart = empty cache (M-05 from prior audit)

> **DEFERRED — 2026-05-20.** A persistent replay-cache backend is an infrastructure addition; out of the medium-fix batch (the ADR-0010 deferral stands).

**Repo:** vesl-wallet
**File:** `crates/vesl-signing/src/replay_cache.rs:55-86`

ADR-0010 deferred. For a load-balanced fleet, an attacker presents the same bundle to N instances rapidly. No persistent backend exists.

**Fix:** Either ship a Redis backend behind a feature flag, or document loudly that this implementation requires sticky sessions.

### M-15 — `parse_caip122_message` accepts CRLF, doesn't assert blank-line empty, doesn't reject trailing junk

> **RESOLVED — already remediated by C-05 (vesl-wallet `43d8b8d`); verified 2026-05-20.** `parse_caip122_message` rejects `\r`, asserts the blank line empty, and rejects trailing content past the last field.

**Repo:** vesl-wallet
**File:** `crates/vesl-signing/src/caip122.rs:124, 136-138, 144`

Parser laxity compounds with C-05 (field injection). `_blank` is read but content unchecked; `lines.next().is_none()` is never asserted after `Expiration Time`; `str::lines()` silently strips `\r`.

**Fix:** Assert blank line is empty, assert iterator exhausted, reject any `\r` in body.

### M-16 — `verify` panics on poisoned replay-cache mutex

> **RESOLVED — 2026-05-20 (vesl-wallet `7db4e51`).** The replay-cache locks recover from a poisoned mutex (`lock().unwrap_or_else(|e| e.into_inner())`) instead of panicking.

**Repo:** vesl-wallet
**File:** `crates/vesl-signing/src/replay_cache.rs:68, 77`

`lock().expect("replay cache poisoned")`. One panic → service permanently dead.

**Fix:** `lock().unwrap_or_else(|p| p.into_inner())` or `parking_lot::Mutex`.

### M-17 — `make_tas(slab, hash_b58)` constructs Hoon `@tas` from base58 strings (contains uppercase)

> **RESOLVED — 2026-05-20 (`5816c5f`).** base58 args build through a `make_cord` helper (a plain byte-atom), not `make_tas` — no constructor now mislabels base58 data as `@tas`.

**Repo:** vesl-core
**File:** `crates/nockchain-client-rs/src/wallet.rs:235, 271, 272, 278, 289`

Hoon `@tas` requires lowercase + digits + hyphen. Base58 contains uppercase. The noun is a valid atom but the kernel-side `@tas` ascription is wrong.

**Fix:** Use `make_atom_in(slab, b58.as_bytes())`.

### M-18 — `mont_reduction` precondition not enforced at the Rust API (sub-finding of C-04)

> **RESOLVED — already remediated by C-04 (`8486bd7`); verified 2026-05-20.** `check_tip5_limbs` range-checks limbs at the `verify_proof` / `find_hash_entry` boundary — this sub-finding closes with C-04.

**Repo:** vesl-core
**File:** `crates/nockchain-tip5-rs/src/lib.rs` (consumed via nockchain-math)

`mont_reduction` debug-asserts `a < RP`. With limbs at `u64::MAX`, the inputs are out of documented range. Tied to C-04; closes when C-04 closes.

### M-19 — `verify_proof`'s `ct_eq` is misleading

> **RESOLVED — 2026-05-20 (`396bc84`).** The misleading "constant-time" comment on `verify_proof` is corrected — only the final `ct_eq` is constant-time; the `hash_pair` recompute above it is not (and proof contents are public anyway).

**Repo:** vesl-core
**File:** `crates/nockchain-tip5-rs/src/lib.rs:213-216`

The byte-level `ct_eq` is correct but the recomputation loop has data-dependent branches everywhere. Function is not constant-time in any meaningful sense.

**Fix:** Drop the `ct_eq` and the surrounding "constant-time" comment, or document precisely which path is constant-time.

### M-20 — `peek_atom_u64` collapses absent-path with zero-value

> **RESOLVED — 2026-05-20 (`5514f8c`).** Added `peek_atom_u64_strict` + a `PeekError` type — a depth-aware decoder distinguishing `Ok(None)` (absent path) from `Ok(Some(0))` (real zero). `peek_atom_u64` is kept for non-security callers.

**Repo:** vesl-core
**File:** `crates/vesl-core/src/peek.rs:150-165`

Returns `Some(0)` for both "path didn't bind" and "path bound to zero." Critical when the absence has security meaning (e.g., RBAC permission check).

**Fix:** Add a `peek_atom_u64_strict` variant returning `Result<Option<u64>, PeekError>`.

### M-21 — `build_settle_note_manifest_poke` silently coerces non-UTF8 field names to empty string

> **RESOLVED — 2026-05-20 (hull-llm `7b0ced9`).** `build_settle_note_manifest_poke` builds the field-name cord from raw bytes (`make_atom_in`) — no lossy `from_utf8(...).unwrap_or("")`.

**Repo:** hull-llm (post-cleanup; was vesl-core pre-2026-05-19)
**File:** `hull-llm/src/manifest_pokes.rs` (`build_settle_note_manifest_poke`)

`std::str::from_utf8(name).unwrap_or("")`. A field name that's not valid UTF-8 silently becomes `""`. Manifest binds wrong name; verification fails opaquely.

**Fix:** Change signature to `fields: &[(&str, &[u8])]`. Or expose `_raw` variant for binary names.

### M-22 — u64 → usize truncation in `build_seeds` on 32-bit targets

> **RESOLVED — 2026-05-20 (`9bbdfbe`).** `build_seeds` converts the gift amount with `usize::try_from`, returning an error on 32-bit overflow instead of silently truncating.

**Repo:** vesl-core
**File:** `crates/vesl-core/src/settle.rs:238`

`Nicks(output_amount as usize)`. WASM (32-bit) targets silently truncate. Vesl-core officially supports 64-bit, but `Cargo.toml` declares no constraint.

**Fix:** `usize::try_from(output_amount).map_err(...)?` or `compile_error!` for 32-bit targets.

### M-23 — `templates/vesl/Cargo.toml` pins inconsistent older nockchain SHA

> **RESOLVED — 2026-05-20 (vesl-nockup `23c288e`).** The `vesl` template's three nockchain git-rev pins are bumped to `NOCK_PIN` (`fe46f4e3`).

**Repo:** vesl-nockup
**File:** `templates/vesl/Cargo.toml:13-15`

Other templates use `NOCK_PIN=fe46f4e3...`. vesl template uses `1a23ccdab...` (11 days older). End-users scaffolding from vesl template get older nockchain than the rest of the catalog.

**Fix:** Either sync vesl template's pin to NOCK_PIN, or refactor sync.sh to rewrite this template's git-deps too.

### M-24 — Manifest body strings spliced verbatim into compiled Hoon; `--lib-dir` warn-only

> **RESOLVED — 2026-05-20 (vesl-nockup `94fae22`).** An out-of-tree `--lib-dir` (no `nockapp.toml` ancestor) is refused unless `--accept-untrusted-libs` is passed; `select_grafts` — the inject/list splice path — enforces it.

**Repo:** vesl-nockup
**Files:** `tools/graft-inject/src/inject.rs:288-294, 337-341`; `tools/graft-inject/src/util.rs:108-121`

`graft-inject --lib-dir /tmp/evil_graft_pack` splices arbitrary attacker-controlled Hoon into the user's kernel. Warning is opt-out, not refusal.

**Fix:** Refuse without `--accept-untrusted-libs`. Print per-manifest sha256 before splicing.

### M-25 — `tools/test-registry/run-init.sh:56` reuses the sed-injection antipattern

> **RESOLVED — 2026-05-20 (vesl-nockup `75bfb76`).** `run-init.sh` substitutes via a bash `${//}` parameter-expansion loop — no `sed` delimiter for a path char (`|`, `&`, `\`) to corrupt.

**Repo:** vesl-nockup
**File:** `tools/test-registry/run-init.sh:56`

`sed "s|__VESL_NOCKUP_PATH__|${VESL_NOCKUP}|g"`. Same hazard as H-16, scoped to test infrastructure. Compounds if the pattern spreads.

**Fix:** Use a delimiter that's quoted-out-of `${VESL_NOCKUP}`, or migrate to here-doc templating.

### M-26 — `vesl-checkpoint` schema-extension resume resets per-graft state to type defaults

> **DEFERRED — 2026-05-20.** A checkpoint state-migration helper (or a `--strict-state-shape` flag) is an infrastructure addition; out of the medium-fix batch.

**Repo:** vesl-core
**File:** `crates/vesl-checkpoint/src/lib.rs:173-187`

Documented behavior: v0.2 resets per-graft state on schema-extension resume. Operators needing data preservation re-poke after resume. Worth restating because it means snapshot/resume across kernel rewrites silently drops state — surprising for users.

**Fix:** Add a migration helper or at minimum a `--strict-state-shape` flag that errors instead of resetting.

### M-27 — Templates' `Cargo.lock` excluded from sync.sh `--verify` diff

> **RESOLVED — 2026-05-20 (vesl-nockup `7be20e1`).** Verified obsolete: no template `Cargo.lock` is tracked (blanket-gitignored), so the `--verify` exclusion is correct, not a drift gap. The intent is now documented in `.gitignore`.

**Repo:** vesl-nockup
**File:** `sync.sh:447`

`diff -ruN --exclude=target --exclude=Cargo.lock`. Templates' Cargo.lock files ARE committed (`templates/counter/Cargo.lock`, etc.). Drift in transitive dep versions is invisible to verify.

**Fix:** Either commit Cargo.lock canonically and include in verify, or gitignore Cargo.lock from templates.

### M-28 — `templates/*/app.nock` and `out.jam` artifacts ship via sync.sh

> **RESOLVED — already remediated by H-17 (vesl-nockup `574e2d4`); verified 2026-05-20.** `sync.sh`'s `copy_tree` prunes gitignored `app.nock` / `out.jam` artifacts.

**Repo:** vesl-nockup (via vesl-core)
**Files:** `vesl-core/templates/{counter,data-registry,graft-intent,settle-report}/app.nock`, `out.jam`

Stale compiled-kernel binaries from maintainer's local builds. `cp -rL` ingests them. End-user scaffolding may pick up stale `out.jam` over freshly-built.

**Fix:** Add `rm -f "$here/templates/$t/app.nock" "$here/templates/$t/out.jam"` to sync.sh.

### M-29 — `vesl-checkpoint/.data.vesl-checkpoint-test/` SQLite + PMA files leak via sync

> **RESOLVED — already remediated by H-17 (vesl-nockup `574e2d4`); verified 2026-05-20.** `sync.sh`'s `copy_tree` prunes the gitignored `.data.*` directories.

**Repo:** vesl-nockup (via vesl-core)
**Files:** `vesl-core/crates/vesl-checkpoint/.data.vesl-checkpoint-test/*`

Same root cause as M-28. `cp -rL` slurps maintainer runtime test data, including arbitrary SQLite content.

**Fix:** `--exclude='.data.*'` in sync.sh's copy step.

### M-30 — Repeated `unsafe { *slab.root() }` not encapsulated

> **RESOLVED — 2026-05-20 (`1035e8b`).** The eight `unsafe { *slab.root() }` sites route through one `slab_root_noun` helper carrying the single `SAFETY:` comment.

**Repo:** vesl-core
**File:** `crates/vesl-core/src/peek.rs:151, 242, 274, 307, 348, 361, 377, 389`

Eight call sites duplicate the same `unsafe` dereference with the same SAFETY argument. A future refactor of `root()` semantics requires re-auditing every site.

**Fix:** Single `pub(crate) fn slab_root_noun(slab: &NounSlab) -> Noun` helper.

### M-31 — `accept_timeout_secs: 0` in `SettlementConfig::local` is structurally fine but foot-shape

> **RESOLVED — 2026-05-20 (`edc40b3`).** Local-mode `accept_timeout_secs` is the `u64::MAX` "never waits" sentinel, not `0`, in both `local()` and `resolve_local()`.

**Repo:** vesl-core
**File:** `crates/vesl-core/src/config.rs:228, 294`

Local mode sets timeout to 0. A misrouted `submit_and_wait` returns immediately. Today protected by `can_submit()` gate; brittle.

**Fix:** Use `u64::MAX` as sentinel or panic in `chain_config()` for local mode.

---

## 5. Low / Informational

### L-01 — `tx_builder.rs:34` `D(fee.0 as u64)` panics if fee exceeds `DIRECT_MAX`

vesl-core. Practically near-zero risk (fee comes from config, default 256), but the panic is reachable. Use `atom_from_u64`.

### L-02 — `signing.rs:124, 144` use `.expect(...)` in `derive_pubkey` and `pubkey_hash`

vesl-core. Documented invariants; callers must range-check inputs. Could be `Result`-returning.

### L-03 — `verify_tx.rs:140, 150` use `unreachable!()` on enum branches assumed eliminated upstream

vesl-core. Fragile if upstream code refactors.

### L-04 — `peek.rs:99-100` `unwrap_triple_unit_atom` collapses absent/zero in byte-vec path

vesl-core. Same trap as M-20 for the byte path.

### L-05 — `Settle::poke_bytes` no upper bound on payload size

vesl-core. Memory amplification when paired with H-06.

### L-06 — No zeroization for `Mint::tree` / `Guard::roots`

vesl-core. Defense-in-depth; not a primary vector. Add `ZeroizeOnDrop`.

### L-07 — `CommitmentVerifier` lacks domain tag

vesl-core. A caller wiring `RagVerifier` against a non-RAG flow gets silent "verified" answer.

### L-08 — `vesl-stark-verifier.hoon:510` `&(=(test-mode %.n) !(verify-merk-proofs ...))` is logic-readable but fragile

vesl-core. Single-character refactor away from disaster. After C-02 lands, simplify.

### L-09 — `guard-graft.hoon:117-123` peek returns `(unit (unit (unit @)))` — three-level unwrap

vesl-core. API shape footgun.

### L-10 — `kv-graft.hoon` `%kv-delete` is idempotent; `registry-graft` `%registry-del` errors on missing

vesl-core. Composer trap — different semantics between graft families.

### L-11 — `forge-graft.hoon` is stateless and does NOT check registered roots

vesl-core. Documented; composer must pair with stateful graft. Worth a runtime guard.

### L-12 — `validate-graft.hoon` `%non-empty` rule treats `body=~` as empty but accepts `[~ ~]`

vesl-core. Rule semantics loose. Future "length" / "in-set" rules will amplify.

### L-13 — `vesl-gates.hoon:138-156` catalog "shorthand" comment hints at unimplemented `proof=@` path

vesl-core. Docs drift; not exploitable.

### L-14 — `vesl-mint.hoon` is a no-op re-export shell

vesl-core. Cosmetic / documentation. The `/+  *vesl-merkle` chain transitively exposes arms but the file reads as a placeholder.

### L-15 — `verify-chunk` allows depth-0 proofs against any chunk if root = hash-leaf(chunk)

vesl-core. Mathematically correct for single-leaf trees. Combined with H-02 (arbitrary roots) widens pollution surface.

### L-16 — `verifier-eny` has no derivation guidance; tests pass `0`

vesl-core. With `eny=0`, Merkle-proof ordering is deterministic; the DDOS-resistance guard is lost.

### L-17 — `build-fs-formula` is hardcoded with no version tag

vesl-core. Already C-lead-1; flagged for FS-transcript inclusion when the formula stops being hardcoded.

### L-18 — `kernel-arms.hoon:31-39` `parse-payload` collapses cue + sieve failures

vesl-core. Diagnostic gap.

### L-19 — `wait_for_acceptance` prints errors to stderr, doesn't propagate

vesl-core. UX trap; convert to `tracing::warn!`.

### L-20 — `WalletClient::pid_counter: i32` wraps after 2^31 - 1 calls

vesl-core. Long-running daemon collision. Use `u64`.

### L-21 — `MerkleTree::build` panics on empty leaves; `proof()` panics OOB

vesl-core. Documented preconditions.

### L-22 — `tip5_to_atom_le_bytes` returns `vec![0]` for all-zero digest, not `vec![]`

vesl-core. Convention mismatch. Either return `vec![]` or document the non-empty representation.

### L-23 — `ubig_to_be_32` panics on `n >= 2^256`

vesl-wallet. Today only called with G_ORDER-bounded scalars; defensive.

### L-24 — `bs58::decode` allocates unbounded for malicious input

vesl-wallet. Cap at `MAX_B58_LEN` before decode.

### L-25 — `CheetahPoint::in_curve` panics rather than returning false on `ch_scal_big` error

vesl-wallet. Edge-case off-curve points cause `in_curve()` to crash instead of cleanly rejecting.

### L-26 — `SchnorrPrivateKey::public_key` panics on "healthy curve" assumption

vesl-wallet. Brittle if curve constants change.

### L-27 — `t8_to_scalar` error type leaks chunk content

vesl-wallet. Use `BadChunk(usize)` (index) not `BadChunk(String)`.

### L-28 — `.sync-pins.toml` documented "auto-generated" but committed as if canonical

vesl-nockup. Reviewer confusion.

---

## 6. Cross-Cutting Recommendations

### CC-01 — Promote `based!` from `debug_assert!` to `assert!` upstream, OR enforce range-check at every vesl-core boundary

This is the upstream lever for C-04. File an issue against nockchain. Until landed, every Tip5Hash construction at the vesl-core boundary must explicitly range-check.

### CC-02 — Audit the rest of `nockchain-math` for similar `debug_assert!` patterns

`grep -rn 'debug_assert' nockchain/crates/nockchain-math/` shows multiple. Each is a potential cross-VM divergence vector in release builds. Document the contract: "downstream callers MUST validate inputs before invoking any nockchain-math primitive."

### CC-03 — Add a cargo-deny config to vesl-core matching vesl-wallet's

vesl-wallet has a solid `deny.toml` (pins MIT/Apache-2.0/BSD, bans `openssl-sys`, denies wildcards/yanked/unknown-registries). vesl-core has none. CI runs `cargo audit` only. Adding `cargo deny check` is a one-line CI addition with high ROI.

### CC-04 — Land a release-mode integration test suite that fuzzes cross-VM boundaries

The hardest class of bug in this audit (C-04) only manifests in release builds. The test suite should:
- Run in release mode.
- Post off-field digests, malformed nouns, oversized jam blobs, CRLF-injected SIWN bodies, prove-error-returning %prove pokes, and assert each is *rejected*, not accepted-with-wrong-result.

---

## 7. Items Reviewed With No Findings

For audit completeness, the following files were inspected and produced no actionable findings:

- `vesl-core/protocol/lib/intent-graft.hoon` — intentional placeholder per project memory.
- `vesl-core/protocol/lib/clock-graft.hoon` (modulo M-06 doc note).
- `vesl-core/protocol/lib/log-graft.hoon` — append-only, retention-capped, mule-wrapped.
- `vesl-core/protocol/lib/counter-graft.hoon` — saturation guards in place.
- `vesl-core/protocol/lib/queue-graft.hoon`, `registry-graft.hoon`, `kv-graft.hoon`, `batch-graft.hoon`, `rbac-graft.hoon` — capped, mule-wrapped, clean.
- `vesl-core/protocol/sur/vesl.hoon` — type definitions only.
- `vesl-core/protocol/tests/red-team.hoon` — existing red team covers fake-sibling, path-swap, context-padding, prompt-injection. Does NOT cover any of C-01 through C-09. Suggest extending.
- `vesl-core/protocol/lib/vesl-verifier.hoon` — C-lead-4 pin in place.
- `vesl-core/assets/CHECKSUMS.sha256` — verified matches `sha256sum assets/*.jam`.
- `vesl-wallet/crates/vesl-wallet-spec/src/lib.rs` — spec doc; no impl logic.
- `vesl-wallet/deny.toml` — solid policy (CC-03 above).

---

## 8. Cross-Reference to Prior Audit (`AUDIT_REPORT.md` pre-2026-05-19)

| Prior ID | Description | Status @ 2026-05-19 | This audit's ID |
|---|---|---|---|
| C-01 | Hull /commit silent desync | **Migrated** — hull moved to vesl-nockup/crates/vesl-hull as library. Prior C-01 surface re-shaped. This audit's C-01 is independent (kernel-integrity gate). | C-01 (new context) |
| H-01 | STARK verifier `test-mode` | **Unfixed** | C-02 |
| H-02 | C-lead-2 verifier completeness | Deferred per prior §7; not re-evaluated here. | — |
| H-03 | hash_leaf trailing-zero | **Unfixed** | M-09 |
| H-04 | Schnorr message-uniqueness | **Annotations not landed** | — (see H-04 here for shim path) |
| M-01 | Global rate limit | Migrated to vesl-hull; not re-audited in this slice. | — |
| M-02 | poke_kernel_with_timeout discards effects | Covered by C-01 surgical fix per prior §6. | — |
| M-03 | rejam_atom panic | **Unfixed** | H-12 |
| M-04 | Settled set unbounded | **Unfixed** | H-01 (Hoon side) / H-07 (Rust side) |
| M-05 | Replay cache in-memory | **Unfixed** | M-14 |
| M-06 | Replay cache no cap | **Unfixed** | (subset of M-14) |
| M-07 | SIWN window cap | **Unfixed** | H-13 |
| M-08 | Schnorr from_belts overflow | **Fixed in vesl-wallet only**; shim path needs verification | H-04 |
| M-09 | Demo signing key gate | **Unfixed** | H-15 |
| L-01..L-17 | Various | Mostly informational; flagged again where promoted to higher severity. | Various |

---

## 9. Recommended Beta-Ship Order

In priority order. **Items 1-9 are non-negotiable for a public beta release.**

1. **C-01** — Make `verify_kernel()` non-opt-in; templates load via `kernels-*` crates, not `fs::read("out.jam")`.
2. **C-02** — Land `?>  =(test-mode %.n)` per `AUDIT_H01_TEST_MODE.md` Option B. Regenerate JAMs.
3. **C-03** — Sieve `each %& %|` in `vesl-core/protocol/lib/forge-kernel.hoon` and `hull-llm/protocol/lib/vesl-kernel.hoon` `%prove` arms (cross-repo; paired commits + JAM regens in each repo).
4. **C-04** — `Tip5Hash` newtype with `from_limbs` range-check; audit every construction site. File upstream `based!` issue.
5. **C-05** — Sanitize SIWN message-body fields against `\n`/`\r`/control chars. Strict parser.
6. **C-06** — Replay-cache key includes message digest (or `(domain, chain_id, address, nonce)` tuple).
7. **C-07** — `verify` enforces `chain_id`, `uri`, `version` against expected deployment values.
8. **C-08** — Push `vesl-core-sync.yml` to `origin/dev` and `origin/main`.
9. **C-09** — Fix sync workflow diff command; align CI pins with sync.sh; add `git ls-remote` pre-flight.

After 1-9:

10. **H-04, H-13, H-14, H-15** — Schnorr shim range-check, SIWN window cap, curve-membership check, demo-key gate.
11. **H-01, H-02, H-03** — Kernel caps, vesl-entrypoint disposition, forge-kernel verify-chunk crash.
12. **H-05, H-06, H-07, H-08** — RagVerifier note_id binding, manifest size cap, settled_ids LRU, kernel-poke timeouts.
13. **H-09, H-10, H-11, H-12** — Boundary panics + DoS + TLS defaults.
14. **H-16, H-17, H-18** — sync.sh injection / cp-rL / symlink trust.
15. **H-19, H-20, H-21, H-22** — Template build.rs PATH-RCE, checkpoint resume verification, Dockerfile alignment, CI nockchain checkout.
16. **CC-03, CC-04** — cargo-deny in CI, release-mode boundary fuzz suite.
17. Medium tier — schedule for v0.2 / first post-beta point release.
18. Low / informational — opportunistic cleanup.

The math holds. The kernel state machine is conservative where it shipped fixes. The Schnorr layer is mostly sound. **What needs work is the gap between what the audits documented and what the code actually does.** A startling number of prior-cycle items are documented-fixed but code-unfixed. Closing that gap is what beta-readiness looks like.

---

**End of report.**
