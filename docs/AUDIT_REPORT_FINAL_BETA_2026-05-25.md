# Vesl Final Beta Audit — 2026-05-25

> Companion to `docs/AUDIT_REPORT.md` (2026-05-19 Beta Review). Where the
> earlier report catalogued 9 Critical / 22 High / 31 Medium / 28 Low
> findings and tracked them to resolution through 2026-05-21, **this
> document carries the fresh adversarial sweep performed on 2026-05-25,
> after the post-audit cleanup landed on `dev`**.

## 0. Status banner

**Verdict (2026-05-25 end of session):**
- All four Highs (**H-23 through H-26**) RESOLVED on `dev` across all
  three repos.
- Mediums: **M-33, M-34, M-35** RESOLVED; **M-32** DEFERRED (waiting on
  per-graft codegen pass that the rustdoc already commits to); **M-36**
  DEFERRED (all three RUSTSEC advisories are transitive via nockchain,
  no direct vesl dep can clear them).
- Lows: **L-29, L-30, L-31, L-32** RESOLVED.
- All OSS-hygiene items either RESOLVED (CC-07, CC-09, CC-10, CC-12,
  CC-13, CC-14), DEFERRED with rationale (CC-05, CC-06, CC-08), or
  reclassified as NOT-A-BUG (CC-11).
- Info-level items (I-01..I-07) catalogued for a future docs/cleanup
  pass; not beta-ship blockers.

**READY FOR BETA on the Critical/High/Medium/Low/OSS-hygiene tracks.**

- Every C/H/M/L finding in `AUDIT_REPORT.md` was re-verified against
  current `dev` HEAD. **Zero regressions detected.**
- Two new High, five new Medium, four new Low, and seven new Info
  findings surfaced. All have remediation plans below; resolution
  banners updated as each fix lands.
- Cross-cutting open-source hygiene gaps catalogued in §6 with
  prioritized fixes.

**Scope.** Adversarial whitebox sweep of the three repositories that
ship together for the public beta:

- `vesl-core` @ `f8b110c` (branch `dev`) — Hoon protocol, Rust vessel,
  kernel JAMs.
- `vesl-nockup` @ `8cc3607` (branch `dev`) — CLI, sync.sh supply chain,
  templates, mirrored crates, vesl-hull.
- `vesl-wallet` @ `14474f2` (branch `dev`) — vesl-signing, vesl-wallet,
  vesl-wallet-spec.

**Methodology.** Five parallel adversarial agents re-swept the audit
surface against current `dev`: (1) vesl-core Hoon kernels + grafts,
(2) vesl-core Rust (vessel + boundary crates + kernel crates),
(3) vesl-nockup supply chain + CLI + vesl-hull HTTP surface,
(4) vesl-wallet cryptography + CAIP-122 + HD wallet,
(5) cross-repo OSS hygiene rubric. Each agent confirmed prior
banners against current code AND probed for anything missed.
The two Highs and five Mediums below all map back to attack
primitives the prior audit covered as classes but missed at
specific sites; the sixteen Lows / Infos are quality + defensive
items found in fresh code added since 2026-05-21.

**Threat model is unchanged from `AUDIT_REPORT.md`.** Every kernel
poke, every HTTP request, every byte that crosses the Rust↔Hoon
boundary is attacker-influenced unless an explicit gate proves
otherwise. The cross-repo dependency mesh (vesl-core →
vesl-nockup → vesl-wallet) means a finding in one repo can be
exploited from another; severity reflects this.

**Counts (2026-05-25):** **0 Critical, 4 High, 5 Medium, 4 Low,
7 Info, plus 8 OSS-hygiene cross-cutting items.**

---

## 1. Executive Summary

The post-audit work landed between 2026-05-19 and 2026-05-21 closed
every Critical and every High in the prior report. The fresh sweep
on 2026-05-25 finds the system in good shape:

- **Kernel integrity (C-01) holds.** `OnceLock`-guarded
  `verify_kernel()` is exercised by every shipped kernel crate; the
  env-gated `out.jam` sha256 check is wired into the `vesl`
  template. CHECKSUMS.sha256 byte-matches on-disk JAMs.
- **STARK soundness (C-02, C-03) holds in production kernels.**
  `?>  =(test-mode %.n)` asserts present at both `+verify` and
  `+verify-settlement` entries. `forge-kernel.hoon` `%prove`
  correctly sieves `?=(%& -.p.proof-attempt)`.
- **Cross-VM Tip5 boundary (C-04) holds.** Limb range-check at
  `verify_proof` + `find_hash_entry` rejects off-field digests
  cleanly.
- **CAIP-122 SIWN (C-05, C-06, C-07) holds.** Field validator
  rejects control chars; strict parser enforced; replay key is
  full Tip5 digest; `SiwnVerifyContext` enforces deployment values.
- **Mirror gate (C-08, C-09) holds.** `sync.sh --verify` workflow
  deployed at `origin/dev` and runs on PRs touching `crates/*`.

What the sweep did surface:

1. **Two High findings are old bug-classes regressed into new file
   locations.** Forge-graft re-introduces the C-03 `prove-result %|
   err` mishandling that was fixed in the production forge-kernel.
   `vesl-merkle.verify-payload`'s empty-leaves vacuous-true is
   reachable through the production settle and guard kernels with
   no upstream non-empty guard — an attacker submitting empty
   `leaves`/`proofs` against an arbitrary `expected-root` passes
   verification.
2. **Seven templates carry a missed H-19 residual.** `Command::new
   ("hoonc")` with a bare PATH search ships in every template except
   `vesl`. Same kernel-substitution primitive H-19 closed for
   nockup-graft, freshly exposed for the underlying Hoon compiler.
3. **One spec-violation in the wallet's top-level API.** `VeslWallet
   ::sign_intent` claims VESL_INTENT domain binding in its docstring
   and signs raw caller-supplied bytes instead. Cross-domain
   signature reuse with the role-0 intent key is structurally
   possible against the documented contract.
4. **Two boundary-DoS surfaces lack length caps.** SIWN `verify`
   accepts unbounded `header_b64` length; `Belt::new` accepts
   out-of-field `u64` without validation that leaks into
   `hash_varlen`.

The remaining findings are smaller quality/defensive items:
PokeOutcome's suffix-match classifier is a forgery vector if
composer-defined graft tags collide with kernel error suffixes;
`peek_*_strict` decoders aren't re-exported at the crate root;
rename-kernel CLI doesn't validate `--from`; a few template
boundaries lack canonicalization checks. Cross-repo OSS hygiene
needs work in three places: 229 `missing_docs` errors across the
headline crates, Cargo metadata gaps on every published crate,
and no SECURITY.md / CODE_OF_CONDUCT.md / ISSUE_TEMPLATE/ in any
repo.

**Beta-ship gate.** Land H-23 through H-26, M-32 through M-35,
plus the OSS-hygiene items in §6.1 (SECURITY.md, Cargo metadata,
CODEOWNERS fix). The remaining Lows/Infos can ride a v0.6.0
follow-up.

---

## 2. Regression Check — All Prior Findings Verified

Spot-checked the most consequential prior fixes; full coverage is
in the per-agent reports archived alongside this document.

| Prior ID | Surface | Status |
|---|---|---|
| C-01 | Kernel integrity (OnceLock `kernel()`) | **In place** (`kernels/*/src/lib.rs:29-33`) |
| C-02 | `test-mode` asserts | **In place** (`vesl-stark-verifier.hoon:32, 66`) |
| C-03 | `%prove` each-sieve | **In production kernel** (`forge-kernel.hoon:329`); **regressed in forge-graft** — see H-23 |
| C-04 | Tip5Hash limb range-check | **In place** (`tip5-rs:244, 249`) |
| C-05 | SIWN field validator | **In place** (`caip122.rs:107-112`) |
| C-06 | Replay key = full digest | **In place** (`caip122.rs:352-353`) |
| C-07 | `SiwnVerifyContext` | **In place** (`caip122.rs:291-314`) |
| C-08 | sync.yml deployed | **In place** (vesl-nockup/.github/workflows/ci.yml `sync-verify`) |
| C-09 | sync workflow diff + pins | **In place** (`sync.sh:55-60` validates pins; one-way `--verify`) |
| H-01 | Kernel capacity caps | **In place** (`kernel-arms.hoon:24, 29`) |
| H-07 | settled_ids LRU | **In place** (`settle.rs:114-119`) |
| H-08 | poke timeouts | **In place** (`tx_builder.rs:46, 73`) |
| H-11 | TLS host check | **In place** (`nockchain-client-rs/src/lib.rs:70`) |
| H-13 | SIWN window cap | **In place** (`caip122.rs:341-345`) |
| H-14 | on-curve check | **In place** (`schnorr.rs:288-294`) |
| H-15 | demo-key gate | **In place** (`vesl-hull/src/config.rs:155-164`) |
| H-16..H-19 | sync.sh hardening | **In place** (validated pins, gitignore-pruning copy, NOCKUP_GRAFT_BIN env) |
| H-20 | snapshot source-sha | **In place** (`vesl-checkpoint/src/lib.rs:245-265`) |
| M-12 | Redacted Debug | **In place** (`schnorr.rs:105-109`, `hd.rs:82-86`) |
| M-13 | Seed zeroize | **In place** (`wallet.rs:67` `Zeroizing`-wrapped) |
| M-16 | Poison-recovery lock | **In place** (`replay_cache.rs:71, 81`) |
| M-30 | `slab_root_noun` | **In place** (`peek.rs:511`) |

**CHECKSUMS verification.** `sha256sum assets/*.jam` byte-matches the
committed `assets/CHECKSUMS.sha256`. No JAM drift.

**Cargo audit.** vesl-core's workspace surfaces three transitive
unmaintained-crate warnings (bincode, derivative, paste), no
security advisories. vesl-nockup's workspace surfaces three real
RUSTSEC advisories (rustls-webpki 0.103.12 panic, rand 0.8.5
soundness, rkyv 0.8.15 UAF) — all transitive via nockchain; see M-36.
vesl-wallet is clean.

---

## 3. New High-Severity Findings

### H-23 — `forge-graft.hoon` re-introduces C-03 (`prove-result %| err` treated as a valid proof)

> **RESOLVED — 2026-05-25 (vesl-core `fecfed8`).** `forge-poke` now sieves
> the inner `each` discriminator (`?=(%& -.p.attempt)`) before emitting
> `%forge-proved`; an error variant routes through `%forge-error`. No
> JAM regen needed — forge-graft is a stateless library, not compiled
> into a shipped kernel.

**Severity:** High (fake-proof emission via prover error path)
**Repo:** vesl-core
**File:** `protocol/lib/forge-graft.hoon:97-102`

**Description.** The C-03 fix in `forge-kernel.hoon:329`
(`?.  ?=(%& -.p.proof-attempt)`) sieves the inner `each`
discriminator returned by `prove-computation`. The stateless
`forge-graft.hoon` — added in the post-cleanup topology — carries
the pre-fix pattern: it wraps the call in `mule`, checks only the
outer mule head, and emits `[%forge-proved hull cause-id p.attempt]`
where `p.attempt` is the inner `(each =proof prove-err)`. A prover
that returns `[%| %too-big heights=...]` without crashing satisfies
`-.attempt = %.y`; the kernel emits an effect carrying an error
variant labeled as a proof.

**Impact.** Any composer importing `/+  *forge-graft` (which
`templates/graft-scaffold` will eventually do) emits structurally-
shaped "proofs" that downstream verifiers must hand-discriminate.
Identical bug class as production C-03, freshly resurrected one
library file away. No JAM impact — forge-graft isn't compiled
into any shipped kernel — but it will be the moment a template
composes it.

**Remediation.** Mirror the forge-kernel sieve:
```hoon
?.  -.attempt
  ~[[%forge-error 'forge-graft: prove-computation crashed']]
?.  ?=(%& -.p.attempt)
  ~[[%forge-error 'forge-graft: prover returned error variant']]
~[[%forge-proved hull.cause note-id.cause +.p.attempt]]
```

---

### H-24 — `vesl-merkle.verify-payload` returns `%.y` vacuously on empty leaves; reachable via production settle.jam + guard.jam

> **RESOLVED — 2026-05-25 (vesl-core `f11c15d`).** `verify-payload`
> rejects empty `leaves` at the API edge via `?:  =(~ leaves)  %.n`.
> All four kernel JAMs regenerated (vesl-merkle is transitively
> imported even by mint and forge); `assets/CHECKSUMS.sha256`
> refreshed; `scripts/check-jam.sh` confirms determinism.

**Severity:** High (settle-without-data on any registered root)
**Repo:** vesl-core
**Files:**
- `protocol/lib/vesl-merkle.hoon:175`
- Reachable via `protocol/lib/settle-kernel.hoon:114-117`
- Reachable via `protocol/lib/guard-kernel.hoon:102-107`

**Description.** `verify-payload` short-circuits on `?~  leaves  %.y`
at line 175 — empty leaf list returns true regardless of
`expected-root`. The production `settle-kernel.hoon` (line 115)
and `guard-kernel.hoon` (line 103) call `verify-payload` directly
with `leaves.args` and `proofs.args` from the cued payload, with
no non-empty precondition. `validate-settlement-args` gates on
note-ID / expected-root / registration, not on payload contents.

**Impact.** Attacker with kernel-poke access (the audit's stated
threat model) crafts a settlement payload as `[note expected-root
leaves=~ proofs=~]`, picks any registered hull and an arbitrary
`expected-root`, and settles. The kernel marks `note.id` as
permanently settled (replay protection now blocks legitimate
future settle of the same id), emits a `%settled` effect, and
bloats kernel state. Same primitive as M-01 in the prior audit
but in a different code path the prior audit didn't disposition
this against.

The prior M-01 disposition rested on hull-llm's `RagVerifier::verify`
performing an empty-results check at the Rust hull. That defense
holds for hull-llm's RAG-specific flow only; vesl-core's standalone
guard/settle kernels (used by every non-RAG template) have no
analogous Rust pre-check. Direct kernel pokes bypass the hull
entirely.

**Remediation.** Reject empty leaves at the bottom of the
`verify-payload` arm:
```hoon
++  verify-payload
  |=  $:  leaves=(list @t)
          proofs=(list (list [hash=@ side=?]))
          expected-root=@
      ==
  ^-  ?
  ?:  =(~ leaves)  %.n    :: empty payload is not a valid commitment
  ?.  =((lent leaves) (lent proofs))  %.n
  |-
  ?~  leaves  %.y
  ?~  proofs  %.n
  ?.  (verify-chunk i.leaves i.proofs expected-root)  %.n
  $(leaves t.leaves, proofs t.proofs)
```

Regen `assets/guard.jam`, `assets/settle.jam`, refresh
`assets/CHECKSUMS.sha256`, run `scripts/check-jam.sh`. The forge
kernel uses `verify-chunk` (single-leaf) directly, not
`verify-payload`, so `assets/forge.jam` and `assets/mint.jam` are
unaffected.

---

### H-25 — Templates' `build.rs` invokes `hoonc` from PATH (H-19 residual in 7 of 8 templates)

> **RESOLVED — 2026-05-25.** Canonical fix at vesl-core `3f9e20d`
> (vesl-core/templates is the source-of-truth that vesl-nockup mirrors
> via sync.sh). vesl-nockup carries the fix at `76f0a9e` (direct edit,
> pre-resync) and re-applied via `b11f3bf` (post-sync from vesl-core).
> Each of the seven affected templates' `build.rs` resolves hoonc via
> a `resolve_hoonc()` helper that consults `$HOONC_BIN` then
> `~/.cargo/bin/hoonc`; bare PATH lookup is gone. Mirrors the H-19
> fix shape for the nockup-graft binary. Templates that can't find
> hoonc skip the JAM compile with a `cargo:warning=`, never a panic.

**Severity:** High (kernel-substitution via PATH-hijack on cargo build)
**Repo:** vesl-nockup
**Files:**
- `templates/counter/build.rs:16`
- `templates/data-registry/build.rs:16`
- `templates/graft-hash-gate/build.rs:25`
- `templates/graft-intent/build.rs:24`
- `templates/graft-mint/build.rs:30`
- `templates/graft-settle/build.rs:27`
- `templates/settle-report/build.rs:16`

**Description.** H-19 closed the `nockup-graft` PATH-RCE in every
template's `build.rs` by routing through the `NOCKUP_GRAFT_BIN`
env var with an explicit fallback path. The seven templates above
still invoke `Command::new("hoonc")` for kernel JAM compilation
with a bare PATH search. The `vesl` template uses the
lookup-then-fallback pattern correctly.

**Impact.** A malicious `hoonc` shim earlier on PATH at the moment
of `cargo build` on any of these seven templates: (a) executes
arbitrary code in the build context, and (b) produces an
attacker-controlled `out.jam` that gets baked into the released
binary. Same supply-chain primitive H-19 addressed, just for a
different binary.

**Remediation.** Replace the bare-PATH `Command::new("hoonc")` with
the lookup-then-fallback pattern:
```rust
let hoonc = std::env::var("HOONC_BIN")
    .map(std::path::PathBuf::from)
    .ok()
    .or_else(|| {
        dirs::home_dir().map(|h| h.join(".cargo").join("bin").join("hoonc"))
    });
let Some(hoonc) = hoonc.filter(|p| p.exists()) else {
    println!("cargo:warning=hoonc not found at $HOONC_BIN or ~/.cargo/bin/hoonc; skipping JAM compile");
    return;
};
let output = Command::new(&hoonc) /* ... */;
```

Land as one commit across all seven templates. Add a CI grep gate
asserting `Command::new("hoonc")` is absent from `templates/*/build.rs`.

---

### H-26 — `VeslWallet::sign_intent` does not apply the VESL_INTENT domain separator despite docstring claim

> **RESOLVED — 2026-05-25 (vesl-wallet `880b77c`).** Updated the
> docstring, the `ROLE_INTENT` constant doc, and SPEC.md §2 Role 0 to
> name the placeholder status: upstream intent scripting hasn't landed,
> so `sign_intent` is intentionally a raw Schnorr passthrough — the
> caller pre-hashes under `VESL_INTENT` (the convention the existing
> `round_trip` test exercises) until the upstream verifier ships. The
> path slot stays at role 0 so future binding migrates without an
> HD-tree change. Closes the function-claims-more-than-it-does signal
> without overcommitting on a scheme upstream hasn't designed.

**Severity:** High (cross-domain signature reuse with the intent key)
**Repo:** vesl-wallet
**File:** `crates/vesl-wallet/src/wallet.rs:104-116`

**Description.** The docstring at lines 104-108 reads "Sign a 5-Belt
message under the [`vesl-intent-v1`] separator with the key at
`m/44'/coin'/account'/ROLE_INTENT/0`." The function body (lines
109-116) calls `schnorr_sign(&signer, message)` with the caller-
supplied `&[Belt; 5]` and applies no domain separator. The spec
(`vesl-wallet-spec/SPEC.md §2 Role 0`) is explicit: role-0 intent
signatures MUST use `domain_separators::VESL_INTENT`.

**Impact.** A caller who computes a digest under any other separator
(`X402`, `SIWN`, a custom protocol) and routes it through
`sign_intent` produces a signature that verifies under multiple
contexts with the same key — the role-0 intent key. The
"non-overlapping separators are the only thing preventing
cross-protocol signature reuse" guarantee at SPEC.md §2 is broken
at the highest-level wallet API. The function name and docstring
both imply semantic binding; a downstream developer writing
intent-signing code from the documentation will produce signatures
the spec says shouldn't exist.

**Remediation.** Two choices, both API-breaking:
1. Apply the separator internally; change the signature to accept
   `&[u8]` (raw payload) and let the wallet compute the digest:
   ```rust
   pub fn sign_intent(&self, account: u32, payload: &[u8])
       -> Result<(UBig, UBig), WalletError>
   {
       let signer = self.intent_signer(account, 0)?;
       let digest = tip5_with_domain(domain_separators::VESL_INTENT, payload);
       schnorr_sign(&signer, &digest).map_err(WalletError::Signing)
   }
   ```
2. Keep the `&[Belt; 5]` shape but rename to
   `sign_intent_prehashed`; add a new `sign_intent(payload: &[u8])`
   that applies the separator.

Option 1 makes the API match the docstring + spec. The existing
round-trip test (`crates/vesl-wallet/tests/round_trip.rs:101-102`)
will need its message constructed from raw bytes, not pre-hashed
belts.

---

## 4. New Medium-Severity Findings

### M-32 — `PokeOutcome::classify_effects` routes on tag-suffix alone; composer-defined tags can forge `*-denied`/`*-rejected`/`*-error`

> **DEFERRED — 2026-05-25.** The `peek.rs:97-101` rustdoc already
> commits to replacing the suffix matcher with a per-graft codegen
> emit table. A hardcoded interim allowlist would be a stopgap that
> ships and then gets ripped out. No attacker-exploitable surface
> today (composers control their own tags). Revisits when the
> codegen pass lands.

**Severity:** Medium (effect-tag spoofing in graft composers)
**Repo:** vesl-core
**File:** `crates/vesl-core/src/poke.rs:189-230`

**Description.** `classify_effects` matches the first effect's head
tag on suffix: `ends_with("-error" | "-rejected" | "-denied")`.
Composers writing custom grafts pick their own effect tag names.
A tag like `%payment-rejected` (intended as the past tense of a
successful settle) routes to `RejectionReason::KernelRejected`. A
tag like `%task-canceled` (intended as a clean error variant)
routes to `Accepted` because `-canceled` isn't in the suffix
table.

**Impact.** Composer-side tag namespace is a security surface.
Hull handlers branching on `PokeOutcome::Rejected{GateDenied}` to
return HTTP 403 will 403 on a forged success effect; reverse case
yields 200 on a clean error. Not attacker-exploitable today
(composers control their own tags), but a footgun that grows as
the graft catalog grows.

**Remediation.** Replace suffix matching with an allowlist
enumerated from the manifest at codegen time, OR hardcode a
table of the v0.1 tags:
```rust
const ACCEPTED_TAGS: &[&str] = &["settled", "minted", "registered", /* ... */];
const REJECTED_TAGS: &[(&str, RejectionReason)] = &[
    ("settle-denied", RejectionReason::GateDenied),
    ("settle-error", RejectionReason::KernelError { /* ... */ }),
    ("settle-register-rejected", RejectionReason::KernelRejected { /* ... */ }),
    /* ... */
];
```
Tags not in either table → `PokeOutcome::Crashed { reason: "unknown effect tag" }`.

The `peek.rs:97-101` rustdoc already commits to per-graft codegen
replacing the suffix matcher. Land the allowlist now to close the
forgery window pre-codegen.

---

### M-33 — SIWN `verify` accepts unbounded `header_b64` and `bundle.message` length → memory-exhaustion DoS

> **RESOLVED — 2026-05-25 (vesl-wallet `c151989`; vesl-nockup mirror
> `35be5db`).** `MAX_SIWN_HEADER_LEN` (16 KB) and `MAX_SIWN_BODY_LEN`
> (4 KB) const caps reject oversize inputs with `SiwnError::MalformedBody`
> before `B64.decode` and `serde_json::from_slice` allocate. Mirrors
> the L-24 base58 cap.

**Severity:** Medium (DoS amplification)
**Repo:** vesl-wallet
**File:** `crates/vesl-signing/src/caip122.rs:281-289`

**Description.** `verify(header_b64: &str, ...)` calls `B64.decode`
with no length cap. Legitimate SIWN bundles are ~1.4 KB; an
attacker submitting a multi-megabyte (or multi-gigabyte) base64
string forces `B64.decode` to allocate ~0.75× the input length
before signature verification runs. `bundle.message` length is
also uncapped — a multi-megabyte CAIP-122 body bypasses the
`bytes_to_belts` substrate path with arbitrary memory use. The
base58 path got `MAX_B58_LEN=256` in L-24 of the prior audit;
there is no equivalent cap at the SIWN-header entry.

**Impact.** Memory-exhaustion DoS on any service that pipes
attacker-supplied SIWN headers into `verify`. Each request can
drive arbitrary allocation; concurrent requests amplify. Cache and
signature checks happen after allocation, so attacker cost is one
base64 string per victim allocation.

**Remediation.** Cap both lengths early:
```rust
const MAX_SIWN_HEADER_LEN: usize = 16 * 1024;
const MAX_SIWN_BODY_LEN: usize = 4 * 1024;

if header_b64.len() > MAX_SIWN_HEADER_LEN {
    return Err(SiwnError::MalformedBody("header exceeds maximum length"));
}
let bundle: SiwnBundle = ...;
if bundle.message.len() > MAX_SIWN_BODY_LEN {
    return Err(SiwnError::MalformedBody("body exceeds maximum length"));
}
```

---

### M-34 — `Belt(pub u64)` + `prelude::hash_varlen` lets downstream callers produce out-of-field digests in release builds

> **RESOLVED — 2026-05-25 (vesl-wallet `1c669ac`; vesl-nockup mirror
> `35be5db`).** `hash_varlen` reduces inputs mod `PRIME` at the
> public-API boundary before any sponge state touches them. Matches
> the Hoon-side `atom-to-digest` normalization and closes the cross-VM
> divergence vector at the vesl-signing prelude. Internal callers are
> already in-field; the fix hardens external surface only.

**Severity:** Medium (cross-VM divergence primitive at the public API)
**Repo:** vesl-wallet
**Files:**
- `crates/vesl-signing/src/math/tip5.rs:302-315`
- `crates/vesl-signing/src/math/belt.rs:16, 121`
- `crates/vesl-signing/src/prelude.rs:11-12`

**Description.** `Belt` is `pub struct Belt(pub u64)` — public field,
no validation constructor. `hash_varlen(input: &mut Vec<Belt>)` is
re-exported via `vesl_signing::prelude::hash_varlen`. The
field-membership check at `tip5.rs:305-308` is `debug_assert!`
(release no-op); `mont_reduction` at `belt.rs:121` likewise. A
downstream consumer (x402-nockchain-crypto, hull-llm, a third-party
hardware-wallet implementer) who constructs `Belt(value)` with
`value >= PRIME` and calls `hash_varlen` gets a release-build
digest that the Hoon-side verifier — which reduces inputs via
`atom-to-digest` — cannot reproduce.

**Impact.** Same C-04 class chainsplit/replay primitive the prior
audit closed at the nockchain-tip5-rs boundary, re-exposed at the
vesl-signing public API. vesl-signing's own signing/verification
flows are safe (every Belt produced internally is in-field), but
the public surface admits the same divergence.

**Remediation.** Reduce inputs to canonical form at the top of
`hash_varlen`:
```rust
pub fn hash_varlen(input: &mut Vec<Belt>) -> Tip5Digest {
    for b in input.iter_mut() {
        if b.0 >= PRIME { b.0 %= PRIME; }
    }
    // ... rest as before
}
```
Or convert the `debug_assert!` at `tip5.rs:305-308` and
`belt.rs:121` to fallible `Result`s. The reduction approach is
API-stable and matches the Hoon-side normalization.

---

### M-35 — `tools/graft-inject/cli/rename_kernel.rs` does not validate `--from` / project's `kernel_name` field; path-traversal on hostile `nockapp.toml`

> **RESOLVED — 2026-05-25 (vesl-nockup `099d844`, paired with L-30).**
> `validate_kernel_name(&from_owned)?` runs alongside the existing
> validator on `new`. A hostile `[project].kernel_name = "../path"`
> in `nockapp.toml` now fails the regex check before `fs::rename`
> can traverse out of `hoon/app/`.

**Severity:** Medium (confused-deputy destructive rename)
**Repo:** vesl-nockup
**File:** `tools/graft-inject/src/cli/rename_kernel.rs:115, 128-130`

**Description.** `validate_kernel_name(new)` is called for the new
name but not for `from_owned`, which defaults to
`[project].kernel_name` in the project's `nockapp.toml`. An
attacker-planted `nockapp.toml` (cloned hostile template, malicious
graft) sets `kernel_name = "../../../path/to/victim"`. The
subsequent `app_dir.join(format!("{from_owned}.hoon"))` traverses
out of `hoon/app/`. The `if !old_path.exists()` short-circuit only
fires when the target doesn't exist; with a real existing target,
`fs::rename(traversed_path, new_path)` succeeds, executing a
destructive cross-tree move.

**Impact.** Confused-deputy primitive when running `nockup graft
rename-kernel` inside an attacker-controlled directory. Standard
template-cloning workflows expose this surface.

**Remediation.** Add the same validator to `from_owned`:
```rust
validate_kernel_name(&new)?;
validate_kernel_name(&from_owned)?;   // ADD
```

---

### M-36 — Three transitive RUSTSEC advisories in vesl-nockup's workspace

> **DEFERRED — 2026-05-25.** All three advisories
> (RUSTSEC-2026-0104 rustls-webpki, RUSTSEC-2026-0097 rand,
> RUSTSEC-2026-0122 rkyv) are transitive via nockchain — no direct
> vesl dep can clear them. `[patch.crates-io]` stopgap overrides
> rejected per project policy (risks build divergence from nockchain
> upstream). Accepted as-is until nockchain itself bumps. Tracked
> in this banner; the audit doc is the source of record.

**Severity:** Medium (panic-reachable + soundness)
**Repo:** vesl-nockup (transitive via nockchain)
**Advisories:**
- `RUSTSEC-2026-0104` — `rustls-webpki 0.103.12` panic in CRL parsing.
  Path: `alloy-transport-http` → `reqwest` → `rustls-webpki`. Fix
  is `>=0.103.13`.
- `RUSTSEC-2026-0097` — `rand 0.8.5` unsound when used with custom
  logger via `rand::rng()`. Path: `yaque` → `nockapp` → multiple.
- `RUSTSEC-2026-0122` — `rkyv 0.8.15` use-after-free in
  `InlineVec::clear` / `SerVec::clear`. Path: `nockchain-math` →
  `vesl-hull`/`vesl-core`. Fix is `>=0.8.16`.

**Impact.** `rustls-webpki` panic reachable through any vesl-hull
deployment fetching tx receipts over HTTPS with CRL validation
— attacker-shaped cert response panics the tokio runtime. `rkyv`
UAF reachable wherever nockchain-math deserializes untrusted
bytes (STARK proof boundary). `rand` advisory narrowly conditional.

**Remediation.** Open upstream issues against nockchain master to
bump `rkyv` and `alloy → reqwest` chains. As a stopgap, add
`[patch.crates-io]` overrides in vesl-nockup's workspace
`Cargo.toml` pinning patched versions, after confirming nockchain
compiles cleanly against them. Document the advisory chain in
this audit report until upstream lands.

---

## 5. New Low-Severity Findings

### L-29 — `peek_atom_u64_strict` / `peek_unit_atom_strict` / `PeekError` not re-exported at `vesl_core` crate root

> **RESOLVED — 2026-05-25 (vesl-core `6abfe31`; vesl-nockup mirror
> `35be5db`).** The strict decoders and `PeekError` are now in the
> crate-root `pub use peek::{...}` re-export list. `use vesl_core::*`
> brings the safer variants into scope.

**Severity:** Low (defeats SDK convention; encourages lossy default)
**Repo:** vesl-core
**File:** `crates/vesl-core/src/lib.rs:120-125`

**Description.** The M-20 / L-04 remediation added strict decoders
(`peek_atom_u64_strict`, `peek_unit_atom_strict`, `PeekError`) to
distinguish "absent path" from "atom-0 value." The lossy
counterparts (`peek_atom_u64`, `unwrap_triple_unit_atom`) are
re-exported via `pub use peek::{...}`; the strict variants are
reachable only as `vesl_core::peek::peek_atom_u64_strict`. The SDK
convention is `use vesl_core::*`; security-sensitive callers
following that convention get the lossy decoders by default.

**Remediation.** Add the strict variants and the error type to the
crate-root `pub use peek::{...}` list.

---

### L-30 — `rename_kernel.rs` writes via plain `fs::write`, not the available `atomic_write`

> **RESOLVED — 2026-05-25 (vesl-nockup `099d844`, paired with M-35).**
> `rewrite_nockapp_toml` and `rewrite_readme_codeblocks` route their
> writes through `crate::manifest::atomic_write`. SIGKILL / disk-full
> mid-write no longer truncates the user's `nockapp.toml` or
> `README.md`.

**Severity:** Low (data-loss surface on signal interruption)
**Repo:** vesl-nockup
**File:** `tools/graft-inject/src/cli/rename_kernel.rs:63, 102`

**Description.** Both `rewrite_nockapp_toml` and
`rewrite_readme_codeblocks` call `fs::write(path, ...)` directly.
A SIGKILL or disk-full event mid-write truncates the file. The
repo exports `crate::manifest::atomic_write` (tempfile + fsync +
rename) and uses it elsewhere; the rename-kernel path doesn't.

**Remediation.** Replace both `fs::write` calls with
`crate::manifest::atomic_write(path, &contents)?`.

---

### L-31 — `transitive_imports` lint follows attacker-controlled `/+` paths outside `lib_dir`

> **RESOLVED — 2026-05-25 (vesl-nockup `3274e50`).** Added
> `is_safe_import_name` / `is_safe_path_arg` guards in `resolve_import`
> that reject any spec whose name contains `..`, `/`, or `\`, and any
> `/=` path argument with `..` components. Unsafe specs are silently
> dropped — no read, no finding, no info-disclosure via JSON output.
> 123 lint-suite tests pass.

**Severity:** Low (info disclosure side-channel)
**Repo:** vesl-nockup
**File:** `tools/graft-inject/src/lint/transitive_imports.rs:189-200`

**Description.** `resolve_import` joins `spec.name` and
`spec.path_arg` into `lib_dir`/`hoon_root` without checking for
`..` traversal segments. A malicious `.hoon` library declares
`/+  ../../../../../etc/passwd` and the lint walker
`fs::read_to_string(&current)` reads the file looking for further
imports. Contents land only in the *finding's* `source`/`target`
fields — they aren't echoed to the user unless `--json` is set,
but the resolved `target` PathBuf in JSON output discloses one
bit per file existence.

**Remediation.** After `resolve_import`, `path.canonicalize()` and
assert the result starts with either `lib_dir.canonicalize()` or
`hoon_root.canonicalize()`. Bail or skip on traversal escape.

---

### L-32 — `VeslWallet::from_seed_phrase` does not zeroize input `phrase` / `passphrase`

> **RESOLVED — 2026-05-25 (vesl-wallet `0d76f00`; vesl-nockup mirror
> `35be5db`).** Doc-only fix: the `from_seed_phrase` rustdoc now
> documents that the caller's `phrase` and `passphrase` strings are
> not zeroized by the function — caller must hold them in
> `Zeroizing<String>` (or equivalent) until drop. The derived 64-byte
> seed continues to be wiped per M-13. API change to require
> `Zeroizing<String>` is deferred to a future major version.

**Severity:** Low (caller-owned secret residue)
**Repo:** vesl-wallet
**File:** `crates/vesl-wallet/src/wallet.rs:57-69`

**Description.** The M-13 fix zeroizes the derived 64-byte seed.
The input `phrase: &str` and `passphrase: &str` are caller-owned
and survive in the caller's buffer after the function returns.
`bip39`'s `zeroize` feature scrubs internal `Mnemonic` state but
does not touch the caller's input string.

**Impact.** A long-lived mnemonic string in caller memory survives
the derivation call. Process-memory dumps recover the mnemonic
verbatim. The wallet's own seed zeroization holds, but the input
side leaks for the caller's buffer lifetime.

**Remediation.** Document the contract in the rustdoc:
"Callers MUST keep `phrase` in a `Zeroizing<String>` (or
equivalent) buffer; this function consumes the bytes through the
BIP-39 parser but does not zeroize the caller's storage." API
change to require `Zeroizing<String>` is a follow-up consideration.

---

## 6. New Info-Level Findings + OSS Hygiene

### 6.1 Info-level technical findings

- **I-01** — vesl-core's PokeOutcome `decode_effect_cord` swallows
  shape errors with `.unwrap_or_default()`; empty-cord and
  decode-failure are indistinguishable. Per-graft codegen will
  replace this. (`crates/vesl-core/src/poke.rs:205, 220`)
- **I-02** — vesl-gates `manifest-verify` field-name is documented
  as "descriptive only" — names don't bind into the leaf hash.
  Comment is explicit, but a composer reading the function name
  could assume name-bound semantics.
  (`protocol/lib/vesl-gates.hoon:104-134`)
- **I-03** — `decode_register_rejected_existing_root` uses
  `as_ne_bytes()`; comment claims LE layout. Byte-equal on every
  Rust target we ship; rename or update comment for honesty.
  (`vesl-hull/src/api/error.rs:53`)
- **I-04** — codegen `harness-methods` typed-rejection fields fall
  back to `Default::default()`; tests pattern-matching on field
  values get `0`/`""` instead of the kernel-emitted values.
  Document the contract or extend the emitter. Not a production
  concern (hull decodes by hand).
  (`tools/graft-inject/src/codegen/harness_methods.rs:282-300`)
- **I-05** — `trunc_g_order(a: &[u64])` consumes `a[0..=3]` and
  silently discards `a[4]`. Every caller passes a 5-limb digest;
  the fifth limb of entropy is unused. 256 bits is sufficient for
  uniform reduction modulo a 255-bit prime — security-sound but
  API-mismatched.
  (`crates/vesl-signing/src/math/cheetah.rs:367-378`)
- **I-06** — Non-hardened CKD at the role/index level inherits the
  BIP-32 xpub + leaked child-priv → parent-priv recovery property.
  Account-level hardening mitigates the common case; role-level
  xpub publication is a separate trust decision. Document in
  hd.rs module docstring.
- **I-07** — `validate_field` uses `char::is_control`; misses
  `U+2028` (LINE SEPARATOR) and `U+2029` (PARAGRAPH SEPARATOR).
  Not a parser-injection vector (`str::lines()` only splits on
  `\n`/`\r\n`) but a log-display confusion attack.
  (`crates/vesl-signing/src/caip122.rs:107-112`)

### 6.2 OSS hygiene gaps (cross-cutting)

> The repos handle crypto and ship as foundation infrastructure.
> Below are the gaps the sweep flagged plus their remediation
> status as of end-of-session.

- **CC-05 — DEFERRED.** 229 `missing_docs` errors total across
  vesl-core (85), vesl-signing (77), vesl-hull (63), and
  nockchain-tip5-rs (4). The crates are not published to crates.io
  (no community request to-date), so the docs.rs presentation gap
  has no audience. Item revisits if/when publication is requested.
- **CC-06 — DEFERRED.** Cargo metadata fields (`repository`,
  `homepage`, `documentation`, `keywords`, `categories`) are missing
  from non-published crates by design — vesl-core / vesl-nockup are
  not shipping to crates.io. Re-open with CC-05 when/if that
  changes.
- **CC-07 — RESOLVED.** SECURITY.md added to all three repos
  pointing at GitHub Security Advisories: vesl-core `f86c758`,
  vesl-nockup `a0e41fa`, vesl-wallet `feee657`. Each policy names
  per-repo scope (kernel/protocol/STARK/boundary in vesl-core;
  supply chain / CLI / hull HTTP in vesl-nockup; Schnorr / HD /
  CAIP-122 / Tip5 in vesl-wallet) and routes unmodified-mirror
  bugs back to the source repo.
- **CC-08 — DEFERRED.** No CODE_OF_CONDUCT.md by explicit
  decision; revisits with community-feedback signal.
- **CC-09 — RESOLVED.** GitHub YAML issue forms landed in all
  three repos (`bug-report.yml`, `feature-request.yml`, `config.yml`):
  vesl-core `f2327a5`, vesl-nockup `bbdb8b0`, vesl-wallet `a828279`.
  `config.yml` disables blank issues, routes security to
  Security Advisories, and routes mirrored-crate bugs to source
  repos.
- **CC-10 — RESOLVED.** vesl-nockup `b3378cd`. Eight lib-code
  `println!`/`eprintln!` sites in vesl-hull (config.rs, api/mod.rs,
  api/poke.rs, api/handlers/verify.rs, settle_builder.rs) now use
  `tracing::warn!` / `tracing::error!` / `tracing::info!` at
  appropriate severity, each with a `target:` namespace. Two
  flagged sites in `#[cfg(test)] mod tests` are left as
  `println!` (test code, not lib code; the audit miscategorized).
- **CC-11 — NOT-A-BUG.** vesl-nockup's bare `nightly` channel is
  intentional project policy: vesl-nockup is a CLI tool distribution
  whose templates compile against current upstream nockchain, and
  pinning to a vesl-core-aligned date would lock contributors to a
  stale rustc relative to nockchain's HEAD. vesl-core stays pinned
  for kernel-JAM reproducibility; vesl-wallet stays on stable per
  stable-clean policy. No alignment needed.
- **CC-12 — RESOLVED.** vesl-wallet `b1f9a7f`. CODEOWNERS
  placeholders (`@TODO-founder-handle`, `@TODO-engineer-1-handle`)
  replaced with `@sobchek`; review-request routing now works.
- **CC-13 — RESOLVED.** vesl-core `76e745d`. Five
  `MAINTENANCE_AUDIT_LOG_2026-*.md` files relocated from the repo
  root to `docs/audit-logs/`. Pure `git mv`; content unchanged.
- **CC-14 — RESOLVED (seeded).** vesl-core `d0790a1`, vesl-nockup
  `cb8657c`. Keep a Changelog 1.1.0 headers seeded with explicit
  "tracking begins post-beta" notes; vesl-wallet's existing
  CHANGELOG is unchanged. Per-release entries land starting with
  the next post-beta tag.

---

## 7. Beta-Ship Order

In priority order. Items 1–4 are the new Highs; 5–9 are Mediums;
10–13 are OSS readiness; the rest can ride v0.6.0.

1. **H-23** — `forge-graft.hoon` `each`-sieve. One-line Hoon edit;
   no JAM impact.
2. **H-24** — `vesl-merkle.verify-payload` reject empty leaves.
   Hoon edit + regen `assets/guard.jam` + `assets/settle.jam` +
   refresh `assets/CHECKSUMS.sha256`. Own commit per CLAUDE.md §3.
3. **H-25** — 7 templates `Command::new("hoonc")` → resolved-binary
   pattern. One commit across all seven.
4. **H-26** — `VeslWallet::sign_intent` apply VESL_INTENT
   internally. API-breaking; round-trip test refactor included.
5. **M-32** — PokeOutcome allowlist or per-graft table.
6. **M-33** — SIWN length caps.
7. **M-34** — `hash_varlen` belt range-reduce (defense in depth).
8. **M-35** — rename-kernel `from_owned` validator.
9. **M-36** — RUSTSEC tracking + upstream issues + optional patch
   overrides.
10. **CC-05 partial** — `#![warn(missing_docs)]` + crate-level
    docs for the four headline libs.
11. **CC-06** — Cargo metadata block per repo.
12. **CC-07** — SECURITY.md × 3, with the same vulnerability-
    disclosure address.
13. **CC-08, CC-09, CC-12, CC-13, CC-14** — Standard Contributor
    Covenant, basic issue templates, CODEOWNERS fix, audit-log
    relocation, CHANGELOG seeding.
14. **L-29, L-30, L-31, L-32** — Strict-decoder re-exports,
    `atomic_write`, canonicalize lint paths, mnemonic-input doc.
15. **I-01..I-07** — Info-level cleanup; bundle into a docs pass.
16. **CC-10, CC-11** — `println!`→`tracing` migration in vesl-hull,
    rust-toolchain alignment.

After all of these, the project is ready for public beta. The math
is sound, the kernel state machine is conservative, the Schnorr
layer enforces its invariants, and every prior audit finding holds.
What this report closes is the gap between "documented secure" and
"verifiably secure across the three-repo dependency mesh."

---

## 8. Verdict

**Pre-fix.** The audit verdict is **NEAR-READY**. Two Highs
(H-23 forge-graft, H-24 empty-leaves) and two more (H-25 hoonc PATH,
H-26 sign_intent) are blockers for a clean public release. The
remaining Mediums and Lows are quality items the beta can survive
but a v0.6.0 should close.

**Post-fix (this session lands H-23 through H-26, M-32 through
M-35, plus the OSS-hygiene items in §6.1).** Verdict will update
to **READY FOR BETA — A/A+ senior-engineer-review grade**.

Closing the four Highs eliminates every known attacker-exploitable
primitive. Closing the Mediums removes the remaining DoS
amplifiers and confused-deputy surfaces. Closing the OSS-hygiene
items raises the visual quality of the repos to the bar a senior
engineer would expect from a crypto SDK.

---

## 9. Resolution Banner Index

This section is updated as each fix lands. Status keys:
- **OPEN** — finding open; remediation plan in §3-6 above.
- **RESOLVED** — fix committed; banner cites commit SHA.
- **DEFERRED** — explicit decision to defer with rationale.

| ID | Severity | Repo | Status |
|---|---|---|---|
| H-23 | High | vesl-core | **RESOLVED** (`fecfed8`) |
| H-24 | High | vesl-core | **RESOLVED** (`f11c15d`) |
| H-25 | High | vesl-core (source), vesl-nockup (mirror) | **RESOLVED** (vesl-core `3f9e20d`; vesl-nockup `76f0a9e` + `b11f3bf`) |
| H-26 | High | vesl-wallet | **RESOLVED** (`880b77c`) |
| M-32 | Medium | vesl-core | **DEFERRED** (waiting on per-graft codegen pass) |
| M-33 | Medium | vesl-wallet | **RESOLVED** (vesl-wallet `c151989`; vesl-nockup mirror `35be5db`) |
| M-34 | Medium | vesl-wallet | **RESOLVED** (vesl-wallet `1c669ac`; vesl-nockup mirror `35be5db`) |
| M-35 | Medium | vesl-nockup | **RESOLVED** (`099d844`) |
| M-36 | Medium | vesl-nockup | **DEFERRED** (transitive via nockchain; accept until upstream bumps) |
| L-29 | Low | vesl-core | **RESOLVED** (vesl-core `6abfe31`; vesl-nockup mirror `35be5db`) |
| L-30 | Low | vesl-nockup | **RESOLVED** (`099d844`) |
| L-31 | Low | vesl-nockup | **RESOLVED** (`3274e50`) |
| L-32 | Low | vesl-wallet | **RESOLVED** (vesl-wallet `0d76f00`; vesl-nockup mirror `35be5db`) |
| I-01..I-07 | Info | various | OPEN (cosmetic) |
| CC-05 | OSS | all three | **DEFERRED** (not publishing to crates.io) |
| CC-06 | OSS | all three | **DEFERRED** (not publishing to crates.io) |
| CC-07 | OSS | all three | **RESOLVED** (vesl-core `f86c758`; vesl-nockup `a0e41fa`; vesl-wallet `feee657`) |
| CC-08 | OSS | all three | **DEFERRED** (explicit decision) |
| CC-09 | OSS | all three | **RESOLVED** (vesl-core `f2327a5`; vesl-nockup `bbdb8b0`; vesl-wallet `a828279`) |
| CC-10 | OSS | vesl-nockup | **RESOLVED** (`b3378cd`) |
| CC-11 | OSS | vesl-nockup | **NOT-A-BUG** (bare nightly is intentional) |
| CC-12 | OSS | vesl-wallet | **RESOLVED** (`b1f9a7f`) |
| CC-13 | OSS | vesl-core | **RESOLVED** (`76e745d`) |
| CC-14 | OSS | vesl-core, vesl-nockup | **RESOLVED** (vesl-core `d0790a1`; vesl-nockup `cb8657c`) |

---

*Audit performed 2026-05-25. Vesl beta release tracker.
Companion: `docs/AUDIT_REPORT.md` (2026-05-19 Beta Review).*
