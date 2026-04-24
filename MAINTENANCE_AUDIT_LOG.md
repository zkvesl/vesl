# MAINTENANCE AUDIT LOG — vesl-core / vesl-nockup / hull-llm

Scope: Rust execution engine, ZK-circuit/STARK glue, Hoon kernels + grafts.
Audit date: 2026-04-24. Tool baseline: `cargo clippy --workspace --all-targets` on all three repos.
Findings are advisory. No code was modified. Numbers in the TL;DR are issue counts, not severities.

## TL;DR

| Category                 | Issues |
|--------------------------|:------:|
| Orphans / Dead Code      | 7      |
| Duplication              | 8      |
| Overly Complex Code      | 4      |
| Comment Bloat            | 2      |
| Efficiency / Maintenance | 6      |
| Clippy warnings (total)  | 85+    |

One glaring red flag worth highlighting up front (not a security review, but loud):

- `vesl-core` tests invoke `Guard::register_root` / `Settle::register_root` without handling the `Result` in **~20 places** (`#[warn(unused_must_use)]`). A silent `Err(CapacityExceeded)` in a test fixture would mask the precondition, and the same pattern is copied verbatim into `vesl-nockup` and into `hull-llm/tests/e2e_core.rs:23`. Not a prod bug today, but it is latent — and clippy has been telling us for a while.

---

## 1. Orphans / Dead Code

### 1.1 `Forge` — empty speculative struct re-exported as public API
- **Path:** `vesl-core/crates/vesl-core/src/forge.rs:168`
- **Also exported at:** `vesl-core/crates/vesl-core/src/lib.rs:29` (`pub use forge::Forge;`)
- **Snippet:**
  ```rust
  /// Placeholder struct for future full STARK prover integration.
  ///
  /// When the STARK prover is wired in, this struct will hold the
  /// hot state (zkvm-jetpack prover context). For now, the hull
  /// handles kernel boot with prover jets directly.
  pub struct Forge;
  ```
- **Why flagged:** Zero fields, zero impl, zero callers across all three repos (verified by `grep`). A top-level `pub use` advertises it as part of the SDK. Violates CLAUDE.md §9 ("No flexibility or configurability that wasn't requested … don't design for hypothetical future requirements").
- **Recommendation:** Delete the struct and the `pub use forge::Forge;` re-export. Reintroduce when the prover state actually has a home.

### 1.2 `build_register_poke` in `settle.rs` — dead duplicate
- **Path:** `vesl-core/crates/vesl-core/src/settle.rs:380-395`
- **Snippet:**
  ```rust
  /// Build a [%register hull=@ root=@] poke in NounSlab.
  ///
  /// Mirrors hull/src/noun_builder.rs build_register_poke.
  /// Public for cross-runtime alignment testing.
  pub fn build_register_poke(hull_id: u64, root: &Tip5Hash) -> NounSlab { ... }
  ```
- **Why flagged:** Only referenced by its own test module. `vesl-core::noun_builder::build_register_poke` (same signature, same body) is the live implementation that hulls actually call. The comment even admits it "mirrors" the other one.
- **Recommendation:** Delete. The noun_builder version is the single source of truth.

### 1.3 `intent-graft.hoon` — placeholder library that crashes on invocation
- **Path:** `vesl-core/protocol/lib/intent-graft.hoon:1-107`
- **Snippet:**
  ```hoon
  ::  lib/intent-graft.hoon — FAMILY 5 PLACEHOLDER (crashes on invocation)
  ::
  ::  Reserves the family-5 intent-coordination slot in vesl's 5-family
  ::  graft catalog. Every cause arm bangs with %intent-graft-placeholder.
  ...
  ++  intent-poke
    |=  [state=intent-state cause=intent-cause]
    ^-  [(list intent-effect) intent-state]
    ?-  -.cause
        %intent-declare
      ~|  %intent-graft-placeholder
      !!
  ...
  ```
- **Why flagged:** 107 lines of types, state, peek, and a `?-` dispatcher whose every arm `!!`'s. Explicit slot-reservation. Exactly the "design for hypothetical future requirements" pattern CLAUDE.md §9 warns against.
- **Recommendation:** Either land the real primitive or remove the file and add a one-paragraph note in `docs/graft-manifest.md` reserving the `%intent-*` cause-tag namespace. The 107-line stub earns its keep only when upstream publishes the shape and this gets filled in.

### 1.4 Deprecated `build_vesl_*_poke` aliases — keep, but schedule removal
- **Path:** `vesl-core/crates/vesl-core/src/graft_pokes/settle.rs:74-110` and `vesl-core/crates/vesl-core/src/lib.rs:57-60`
- **Snippet:**
  ```rust
  #[deprecated(since = "0.6.0", note = "renamed in Phase 12A; use build_settle_register_poke")]
  pub fn build_vesl_register_poke(hull: u64, root: &Tip5Hash) -> NounSlab {
      build_settle_register_poke(hull, root)
  }
  // ... plus build_vesl_settle_poke, build_vesl_verify_poke, all one-line shims
  ```
- **Why flagged:** Only callers are the file's own `deprecated_aliases_match_canonical_output` test. No external consumer in vesl-core, vesl-nockup, or hull-llm uses them.
- **Recommendation:** Keep for the documented one-release cycle, then schedule `/schedule` a cleanup task for next minor bump. Don't re-ship the `pub use` in `lib.rs` after the cycle.

### 1.5 Deprecated `IntentVerifier` alias — blocked by hull crate
- **Path:** `vesl-core/crates/vesl-core/src/types.rs:121-122`, alias target, and `vesl-core/hull/src/verify.rs:11,43`
- **Snippet (vesl-core):**
  ```rust
  #[deprecated(note = "renamed to CommitmentVerifier; IntentVerifier will be removed in the next minor release")]
  pub use self::CommitmentVerifier as IntentVerifier;
  ```
- **Snippet (hull — still on the old name):**
  ```rust
  use vesl_core::types::{GraftPayload, IntentVerifier, ProofNode, Tip5Hash};
  ...
  impl IntentVerifier for FieldVerifier { ... }
  ```
- **Why flagged:** The alias is a migration shim, but the in-tree consumer (`hull/src/verify.rs`) hasn't migrated — so the deprecation cycle can't actually close. Every `cargo build` on hull silently uses the deprecated path (via `#[allow(deprecated)]` on the re-export in lib.rs:40).
- **Recommendation:** Migrate `hull/src/verify.rs` to `CommitmentVerifier` now. It's two identifier renames and the rest is mechanical.

### 1.6 `build_prove_poke_generic` — thin orphan, superseded by `build_forge_prove_poke`
- **Path:** `vesl-core/crates/vesl-core/src/forge.rs:68-75`
- **Snippet:**
  ```rust
  pub fn build_prove_poke_generic(jammed_payload: &[u8]) -> NounSlab {
      let mut slab = NounSlab::new();
      let tag = make_atom_in(&mut slab, b"prove");
      let payload = make_atom_in(&mut slab, jammed_payload);
      let poke = T(&mut slab, &[tag, payload]);
      slab.set_root(poke);
      slab
  }
  ```
- **Why flagged:** Only caller across all three repos is its own test. `build_forge_prove_poke(&ForgePayload)` is the caller-friendly wrapper actually used by hull-llm integration tests.
- **Recommendation:** Drop it, or downgrade to `pub(crate)` and inline at the single test site. The current shape is a public API surface that nobody asks for.

### 1.7 Diagnostic arms shipped in production kernel
- **Path:** `vesl-core/protocol/lib/vesl-kernel.hoon:312-364` (arms `%diag-cue`, `%diag-sieve`, `%diag-hash`)
- **Snippet:**
  ```hoon
  [%diag-cue seeds-jam=@]
  [%diag-sieve seeds-jam=@]
  [%diag-hash seeds-jam=@ fee=@]
  ```
- **Why flagged:** These are three debug-only poke causes baked into the canonical kernel. Each arm is ~15 lines of logic plus a comment block. They're not test-gated; any caller with a poke handle can invoke them.
- **Recommendation:** Move to a `vesl-kernel-dev.hoon` variant built only for local/test, or gate behind a compile-time flag. At minimum, document in the kernel header that these exist and are safe to keep enabled. Right now a reader has to reach line 312 to even know about them.

---

## 2. Duplication

### 2.1 `kernels/{guard,mint,settle}/` — three near-identical crates
- **Paths:** `vesl-core/kernels/guard/src/lib.rs`, `vesl-core/kernels/mint/src/lib.rs`, `vesl-core/kernels/settle/src/lib.rs` (plus matching `build.rs` at each)
- **Snippet (identical across all three, modulo label):**
  ```rust
  // lib.rs
  pub static KERNEL: &[u8] = include_bytes!(env!("KERNEL_JAM_PATH"));
  pub const KERNEL_SHA256_HEX: &str = env!("KERNEL_JAM_SHA256");
  pub fn verify_kernel() {
      let digest = Sha256::digest(KERNEL);
      let actual: String = digest.iter().map(|b| format!("{b:02x}")).collect();
      assert_eq!(actual, KERNEL_SHA256_HEX, "kernels-guard: ...");
  }
  ```
- **Why flagged:** Six files (~150 lines combined) where the only differences are the JAM filename (`guard.jam` / `mint.jam` / `settle.jam`) and a label string in the panic message. This is classic N-copy refactor bait.
- **Recommendation:** Extract to a single `kernel-jam` crate that exposes a `embed_kernel!(name, jam_path)` macro (or an `fn new(name: &'static str, jam: &'static [u8], sha: &'static str)` helper). The per-kernel crates become 3-line wrappers that invoke the macro. Alternatively, a single `vesl-kernels` crate with three features, one per kernel.

### 2.2 Register-poke builders — five near-identical functions
- **Paths:**
  - `vesl-core/crates/vesl-core/src/noun_builder.rs:104` (`build_register_poke`)
  - `vesl-core/crates/vesl-core/src/settle.rs:380` (`build_register_poke` — see §1.2, dead)
  - `vesl-core/crates/vesl-core/src/graft_pokes/settle.rs:33` (`build_settle_register_poke`)
  - `vesl-core/crates/vesl-core/src/graft_pokes/guard.rs:18` (`build_guard_register_poke`)
  - `vesl-core/crates/vesl-core/src/graft_pokes/mint.rs:16` (`build_mint_commit_poke`)
- **Snippet (representative):**
  ```rust
  let mut slab = NounSlab::new();
  let tag = make_tag_in(&mut slab, "TAG");
  let hull_noun = atom_from_u64(&mut slab, hull);
  let root_bytes = tip5_to_atom_le_bytes(root);
  let root_noun = make_atom_in(&mut slab, &root_bytes);
  let poke = T(&mut slab, &[tag, hull_noun, root_noun]);
  slab.set_root(poke);
  slab
  ```
- **Why flagged:** All five produce a `[tag hull root]` cell — only the tag string changes. The same pattern also appears inline in `build_settle_poke`, `build_prove_poke`, `build_forge_poke` (with a jammed payload instead of a root), so the deeper shape is `[tag hull <payload>]`.
- **Recommendation:** Introduce a private helper `build_hull_root_poke(tag: &str, hull: u64, root: &Tip5Hash) -> NounSlab` in `nock-noun-rs` or `graft_pokes/mod.rs`. Each caller becomes a one-liner. Bonus: any future bug fix (e.g., "hull must be LE-encoded") applies everywhere automatically.

### 2.3 Hoon `%register` arms — four copies
- **Paths:**
  - `vesl-core/protocol/lib/guard-kernel.hoon:70-79`
  - `vesl-core/protocol/lib/mint-kernel.hoon:64-73`
  - `vesl-core/protocol/lib/settle-kernel.hoon:78-87`
  - `vesl-core/protocol/lib/vesl-kernel.hoon:88-97`
- **Snippet (shared, differing only in slog label):**
  ```hoon
    %register
  ?:  (~(has by registered.state) hull.u.act)
    ~>  %slog.[3 'guard: hull already registered']
    [~ state]
  =/  new-reg  (~(put by registered.state) hull.u.act root.u.act)
  :_  state(registered new-reg)
  ^-  (list effect)
  ~[[%registered hull.u.act root.u.act]]
  ```
- **Why flagged:** Identical logic, identical guard semantics, identical effect shape. Only the slog string changes — and that's a diagnostic, not a behavior.
- **Recommendation:** Extract to a `++handle-register` arm in a shared `lib/common-arms.hoon` (or widen `rag-logic.hoon` if that's closer to the library layer). Every kernel's poke arm reduces to `(handle-register registered.state hull root)`.

### 2.4 Hoon `%settle` and `%prove` arms in `vesl-kernel.hoon` — ~30 lines of copy-paste guards
- **Path:** `vesl-core/protocol/lib/vesl-kernel.hoon:102-141` (settle) vs `148-180` (prove-prelude)
- **Snippet (guard block appears twice):**
  ```hoon
  ?.  (~(has by registered.state) hull.note.args)
    ~>  %slog.[3 'vesl: root not registered']
    [~ state]
  ?.  =(expected-root.args (~(got by registered.state) hull.note.args))
    ~>  %slog.[3 'vesl: root mismatch']
    [~ state]
  ?.  =(root.note.args expected-root.args)
    ~>  %slog.[3 'vesl: note root does not match expected root']
    [~ state]
  ?:  (~(has in settled.state) id.note.args)
    ~>  %slog.[3 'vesl: note already settled (replay rejected)']
    [~ state]
  ```
- **Why flagged:** This block of four guards is copy-pasted between the `%settle` and `%prove` arms, and appears again in attenuated form in `settle-kernel.hoon:108-125` and `guard-kernel.hoon:101-116`.
- **Recommendation:** Factor into a `++validate-settlement-args` helper returning `[%.y args=settlement-payload]` | `[%.n err=@tas]`. Each poke arm becomes: parse → validate → act. This is the kind of refactor that makes a later security audit actually tractable.

### 2.5 Hoon graft-state boilerplate — `mint-graft` vs `guard-graft`
- **Paths:** `vesl-core/protocol/lib/mint-graft.hoon` and `vesl-core/protocol/lib/guard-graft.hoon`
- **Snippet (the differences are nominal):**
  ```hoon
  +$  mint-state   $:  commits=(map @ @)  ==      :: mint
  +$  guard-state  $:  roots=(map @ @)    ==      :: guard
  ++  commits-cap  ^~((mul 10.000 1.000))          :: mint
  ++  roots-cap    ^~((mul 10.000 1.000))          :: guard
  ```
- **Why flagged:** Same state shape (one `(map @ @)`), same cap value, same `new-state` ceremony, same append-only register logic. Only the field name and the effect tag differ.
- **Recommendation:** Optional but worthwhile: introduce a `++hull-root-map` utility arm in a shared lib that exposes `new-state`, `register`, `get`, and `cap-check`. Each graft imports and wraps it with its own effect tags. Cuts ~80 lines and prevents the caps from drifting.

### 2.6 `hull-llm/src/chain.rs` duplicates `nockchain-client-rs`
- **Path:** `hull-llm/src/chain.rs:216-401` and `hull-llm/src/chain.rs:641-861`
- **Snippet:** Functions `jam_u64_entry` (216), `jam_tip5_entry` (230), `u64_to_noun` (244), `find_u64_entry` (265), `find_hash_entry` (282), `jam_opaque_bytes_entry` (311), `find_opaque_bytes_entry` (341), `find_entry` (381), `extract_note_data` (641), `extract_spendable_utxos` (762), `chain_hash_from_pb` (848), plus `SpendableUtxo` struct (729) are all re-implemented verbatim from `nockchain-client-rs::{note_data,types}` — which already re-exports them at the crate root.
- **Why flagged:** ~600 lines of duplicated helpers. The Cargo.toml dep graph already pulls in `nockchain-client-rs` transitively through `vesl-core`; importing from the canonical crate costs one `use` line per call site.
- **Recommendation:** Replace the duplicates with `use nockchain_client_rs::{jam_u64_entry, find_hash_entry, extract_spendable_utxos, ...};`. Keeps `hull-llm/src/chain.rs` focused on the truly domain-specific bits (settlement-data encoding, vesl-prefixed keys, high-level `ChainClient` wrappers).

### 2.7 `hull-llm/src/signing.rs` is a verbatim copy of `vesl-core/hull/src/signing.rs`
- **Paths:** `hull-llm/src/signing.rs` vs `vesl-core/hull/src/signing.rs`
- **Snippet:** Both files define `demo_signing_key()`, `DEMO_KEY_PKH_BASE58`, `is_demo_key()` with byte-identical bodies. `diff` returns nothing.
- **Why flagged:** Two copies of the same demo key and encoded PKH, re-exporting the same `vesl_core::signing::*`. Any rotation to the demo key requires editing both files.
- **Recommendation:** Promote the three symbols into `vesl-core::signing::demo` (feature-gated as `demo-key`, or plain). Both hulls re-export from there.

### 2.8 `hull-llm` query_handler vs prove_handler — Phase-1 retrieval logic
- **Path:** `hull-llm/src/api.rs:599-674` (query_handler phase 1) vs `928-1017` (prove_handler phase 1)
- **Snippet:** Both handlers open with ~75 lines of identical code: acquire lock → check tree exists → pick top-k → retrieve → validate indices → build `RetrievalInfo`, `retrievals`, and `retrieval_digest` → build prompt → drop lock.
- **Why flagged:** Textbook extract-method duplication. The only prove-side addition is the stack-size precheck at line 933.
- **Recommendation:** Extract `async fn build_retrieval_phase(st: ..., req: &QueryRequest) -> Result<RetrievalPhase, ApiError>` that returns the tuple. Both handlers call it after their own preflights. Drops hull-llm LOC by ~150 and keeps the two handlers aligned on TOCTOU invariants.

---

## 3. Overly Complex Code

### 3.1 `SettlementConfig::resolve{,_checked}` — 9-argument gauntlets
- **Path:** `vesl-core/crates/vesl-core/src/config.rs:111-157`, with sibling wrappers `hull/src/config.rs:66-113`
- **Snippet:**
  ```rust
  pub fn resolve_checked(
      cli_mode: Option<SettlementMode>,
      cli_chain_endpoint: Option<String>,
      cli_submit: bool,
      cli_tx_fee: Option<u64>,
      cli_coinbase_timelock_min: Option<u64>,
      cli_accept_timeout: Option<u64>,
      cli_seed_phrase: Option<String>,
      toml: &SettlementToml,
      default_signing_key: Option<[Belt; 8]>,
  ) -> Result<Self, String> { ... }
  ```
- **Clippy:** `clippy::too_many_arguments (9/7)` x4 (one per function across vesl-core + hull).
- **Why flagged:** Every CLI override is a `Option<T>` positional argument. Adding a new CLI flag is a breaking change at every call site. Violates CLAUDE.md §9: the flexibility isn't abstract — it's already painful.
- **Recommendation:** Introduce `SettlementCliOverrides { mode, chain_endpoint, submit, tx_fee, coinbase_timelock_min, accept_timeout, seed_phrase }` as a single struct, and pass `&overrides`. The legacy `resolve()` (non-checked) wrapper can be dropped outright — its doc says "Preserved for tests and legacy callers" and every call site in-tree would migrate in five minutes.

### 3.2 `vesl-kernel.hoon ++poke` — a 280-line dispatcher
- **Path:** `vesl-core/protocol/lib/vesl-kernel.hoon:77-364`
- **Why flagged:** One `?-` switch covering 8 cause tags (`%register`, `%settle`, `%prove`, `%sig-hash`, `%tx-id`, `%diag-cue`, `%diag-sieve`, `%diag-hash`). The arms average 35 lines each with copious guard duplication (see §2.4) and a TODO block from 228-246 calling out the STARK-formula hardcoding lead.
- **Why it's hard to reason about in a ZK context:** the STARK-relevant logic (belt folding, Horner polynomial, prove-computation call) is embedded mid-arm inside the `%prove` branch, sharing lexical scope with the validation guards. The formula (64-nested-increment) is reconstructed inline each time rather than pulled from a named gate. A translator to a ZK circuit has to thread through all eight arms to understand which state is relevant.
- **Recommendation:** Split the dispatcher: promote each arm body to a named arm (`++handle-register`, `++handle-settle`, `++handle-prove`, `++handle-sig-hash`, …). Factor the STARK-specific bits (belt fold, formula builder, prove-computation wiring) into a dedicated `vesl-stark.hoon` library. The poke arm becomes a one-line dispatcher. This is the same refactor §2.4 recommends, one altitude higher.

### 3.3 `hull-llm/src/api.rs::query_handler` — six-level settlement pyramid
- **Path:** `hull-llm/src/api.rs:769-828`
- **Snippet:**
  ```rust
  if let (Some(_), Some(sk)) = (&st.settlement.chain_endpoint, &st.settlement.signing_key) {
      if st.settlement.can_submit() {
          ...
          if let Some(chain_config) = st.settlement.chain_config() {
              if let Ok(mut client) = chain::ChainClient::connect(chain_config.into()).await {
                  ...
                  if let Ok(ref bal) = balance {
                      let utxos = chain::extract_spendable_utxos(bal);
                      if let Some(utxo) = utxos.iter().max_by_key(|u| u.amount) {
                          ...
                          if let Ok(raw_tx) = tx_builder::build_settlement_tx(&mut st.app, &params).await {
                              ...
                          }
                      }
                  }
              }
          }
      }
  }
  ```
- **Clippy:** `collapsible_if` at `hull-llm/src/api.rs:1287` flags the outer shape; `useless_conversion` at `1317` flags the `.into()` on an already-typed `ChainConfig`.
- **Why flagged:** Six nested `if let`/`if` forms silently swallow every short-circuit. An operator reading `/query` response with `tx_id: None` has no idea which of the six branches bailed. Also, the `.into()` on `chain_config` is a no-op (already `ChainConfig`).
- **Recommendation:** Flatten with `let Some(_) = ... else { return Ok(...); }` early returns, or extract `async fn maybe_submit(st: ..., manifest: &Manifest, note_id: u64) -> Option<(String, bool)>` that logs which step bailed. Same treatment in the duplicate block in `hull-llm/src/api.rs::prove_handler` (same pyramid, starting near line 1287).

### 3.4 `guard::check_manifest` is a trivial wrapper around `validate_manifest`
- **Path:** `vesl-core/crates/vesl-core/src/guard.rs:105-107`
- **Snippet:**
  ```rust
  pub fn check_manifest(&self, manifest: &Manifest, root: &Tip5Hash) -> bool {
      self.validate_manifest(manifest, root).is_ok()
  }
  ```
- **Why flagged:** `validate_manifest` is the real API — it returns `Result<(), String>` with actionable diagnostics. `check_manifest` converts the diagnostic to a bool and is only called in this file's own tests.
- **Recommendation:** Remove `check_manifest` and have the three test sites call `.validate_manifest(...).is_ok()` inline. Drops one method from the public surface and removes the Pygmalion pair where one function narrows another's return type for no reason.

---

## 4. Comment Bloat

CLAUDE.md §"Don't explain WHAT the code does" is the rubric. The following are places where comments cross from "hidden invariant" into "narrating the code."

### 4.1 `vesl-kernel.hoon` — proverbial block comment
- **Path:** `vesl-core/protocol/lib/vesl-kernel.hoon:184-246`
- **Snippet (excerpted):**
  ```hoon
  ::  Phase 3: field-safe STARK execution on manifest data
  ::
  ::  Decompose all text fields to 7-byte belt lists, then
  ::  fold to a single atom < Goldilocks prime (sum mod p).
  ::  Cell subjects crash the STARK memory table — the table
  ::  decomposes the full subject tree and can't represent
  ::  cell nodes as field elements.
  ::
  ::  Root/hull bound via Fiat-Shamir header/nonce (Phase 1).
  ::  Belt digest bound via STARK execution trace.
  ::
  ::  Formula: 64 nested increments (Nock 0/4 only).
  ::  Subject: belt-digest (single atom < p).
  ::  Product: belt-digest + 64.
  ::
  ::  AUDIT 2026-04-19 C-lead-3: Horner polynomial fold. …
  ::
  ::  64 nested increments on [0 1]
  ::  known-working pattern: atom subject + Nock 0/4 only
  ::
  ::  TODO: AUDIT 2026-04-17 C-lead-1 — STARK formula hardcoding
  ::  … (17 more lines of context)
  ```
- **Why flagged:** The *audit-numbered* blocks (C-lead-3, C-lead-1) are legitimately load-bearing — they capture invariants the code can't express. The "Phase 3:", "Subject: belt-digest", "known-working pattern" paragraphs are narration that the code already communicates. Together the block is 62 contiguous comment lines on a ~70-line logic block.
- **Recommendation:** Keep the AUDIT blocks verbatim. Compress the narration down to a ~6-line header. The CLAUDE.md guideline on "explain the traps" applies to the Horner-fold and formula-hardcoding notes, not to a restatement of what `roll` and `bex 56` do.

### 4.2 `graft-inject/src/main.rs` Phase-N TODO comments
- **Path:** `vesl-nockup/tools/graft-inject/src/main.rs:36,80`
- **Snippet:**
  ```rust
  #[allow(dead_code)] // surfaced via --list in Phase 6
  version: String,
  ...
  #[allow(dead_code)] // consumed by the data-driven inject() in Phase 4
  fn block(&self, marker: Marker) -> Option<&Block> { ... }
  ```
- **Why flagged:** Both annotations refer to phases that have already shipped (Phase 4 is the "data-driven inject" that lives in this very file; Phase 6's `--list` exists). The `#[allow(dead_code)]` and the phase-justification comment are both stale.
- **Recommendation:** Either drop the `#[allow]` (and fix whatever clippy then surfaces) or reword to explain *why* the field/method is kept today. A phase label from a completed phase is not a rationale.

---

## 5. Efficiency & Maintenance

### 5.1 Unused `Result` on `register_root` — 19 sites
- **Paths:** `vesl-core/crates/vesl-core/src/settle.rs:{578,600,642,662,685}`, `vesl-core/crates/vesl-core/src/guard.rs:{224,243,253,290,320,349,370,381,422,455,486}`, mirrored verbatim in `vesl-nockup/crates/vesl-core/src/{settle,guard}.rs`, and `hull-llm/tests/e2e_core.rs:23`.
- **Snippet:**
  ```rust
  settler.register_root(root);  // warning: unused `std::result::Result`
  ```
- **Why flagged:** `register_root` returns `Result<(), GuardError>` (can fail with `CapacityExceeded`). Test fixtures ignoring the result silently succeed even if a future refactor lowers the cap below test setup usage.
- **Recommendation:** Two options: (a) `.unwrap()` at each test site (fail-loud), or (b) reflect the cap in the test and assert the result. Prefer (a) — tests should crash when their preconditions break.

### 5.2 Clippy quick wins (suggest `cargo clippy --fix`)
These are low-risk, clippy can auto-fix most of them — listing for completeness:
- `clippy::manual_div_ceil` at `vesl-core/crates/vesl-core/src/signing.rs:178` — `(bytes.len() + 7) / 8` → `bytes.len().div_ceil(8)`.
- `clippy::redundant_closure` at `vesl-core/hull/src/api.rs:338`, `hull/src/verify.rs:{91,118}` — `|f| field_to_leaf_bytes(f)` → `field_to_leaf_bytes`.
- `clippy::useless_vec` at `hull/src/verify.rs:114`, `hull-llm/src/llm.rs:{284,308}`, `hull-llm/src/noun_builder.rs:80`, `hull-llm/tests/e2e_adversarial.rs:462` — `vec![...]` → `[...]` for immutable fixtures.
- `clippy::io_other_error` at `hull-llm/src/ingest.rs:{58,66}` — `std::io::Error::new(ErrorKind::Other, e)` → `std::io::Error::other(e)`.
- `clippy::useless_conversion` at `hull/src/api.rs:1317` and `hull-llm/src/main.rs:577` — `.into()` on `ChainConfig` already typed.
- `clippy::collapsible_if` at `hull-llm/src/api.rs:{1287,866,710}`, `vesl-nockup/test/vesl-test/src/lib.rs:233` — merge nested `if let` chains.
- `clippy::unnecessary_cast` at `hull-llm/src/api.rs:{1479,1516,1518}` and `vesl-nockup/tools/graft-inject/src/main.rs:1798` — `nockvm_macros::tas!(b"ok") as u64` is already `u64`.
- `clippy::cloned_ref_to_slice_refs` at `vesl-nockup/tools/graft-inject/src/main.rs:{1763,1858}` — `&[x.clone()]` → `std::slice::from_ref(&x)`.
- `clippy::useless_format` at `hull-llm/src/api.rs:1192` — `format!("trace(cued): empty list")` → `.to_string()`.
- `clippy::option_as_ref_deref` at `vesl-nockup/tools/graft-inject/tests/{guard_lifecycle.rs:69, mint_lifecycle.rs:{50,56}, integration.rs:{85,115}}` — `.as_ref().map(Vec::as_slice)` → `.as_deref()`.

### 5.3 Three hull implementations, three copies of auth middleware
- **Paths:** `vesl-core/hull/src/api.rs:166-245` and `hull-llm/src/api.rs:340-427`
- **Snippet:** Both hulls reimplement `NO_AUTH` atomic flag, `check_api_key` middleware, `check_auth_config[_with_bind]`, and `is_loopback_bind` with identical logic (the loopback string match, the HULL_API_KEY env-var lookup, the fail-closed logic on non-loopback `--no-auth`).
- **Why flagged:** Any security change (new exempt path, new auth mechanism) requires two edits. The two copies have already started drifting — `hull-llm` uses `HULL_API_KEY` and `hull/` uses `HULL_API_KEY` but the env-var docs aren't aligned across READMEs.
- **Recommendation:** Lift `check_api_key` and companions into a small `hull-common` (or `vesl-core/hull/auth.rs`) module. Every hull registers its own router but reuses the middleware.

### 5.4 Three hull implementations, three copies of note-counter persistence
- **Paths:** `vesl-core/hull/src/api.rs:64-85` and `hull-llm/src/api.rs:179-198`
- **Snippet:** `NOTE_COUNTER_FILE` constant, `load_note_counter`, `save_note_counter` — identical implementations, both carrying the same `AUDIT 2026-04-17 L-05` atomic-write comment.
- **Recommendation:** Same as §5.3 — move into a shared hull-utilities module.

### 5.5 Cross-repo duplication of `crates/{vesl-core,nockchain-client-rs,nockchain-tip5-rs,nock-noun-rs}`
- **Paths:** `vesl-core/crates/*` vs `vesl-nockup/crates/*`
- **Why flagged:** `diff -rq` shows these trees are byte-identical (only `target/` differs). This is intentional per CLAUDE.md §2 ("vesl-nockup's shipped templates get git-deps injected by sync.sh") — vesl-nockup keeps a mirrored checkout so standalone-template builds work. The intent is fine, but in practice **every bug in vesl-core's crate source is silently replicated in vesl-nockup** and needs a sync step.
- **Recommendation:** If `sync.sh` doesn't already do it, lock in vesl-core as the upstream and have CI assert `diff -rq` returns empty on every PR. Prevents the "fixed in vesl-core, forgot to sync" regression class.

### 5.6 `SettlementConfig::resolve` panics on misconfig, `_checked` variant duplicates body
- **Path:** `vesl-core/crates/vesl-core/src/config.rs:111-134`
- **Why flagged:** `resolve` is documented as "preserved for tests and legacy callers" and its body is `resolve_checked(...).unwrap_or_else(|e| panic!(...))`. Tests could call `.resolve_checked(...).expect(...)` instead. Keeping the panic-wrapper alive means every new CLI arg must be added at TWO 9-argument signatures (see §3.1).
- **Recommendation:** Delete `SettlementConfig::resolve` entirely. Same for `hull::config::resolve_with_demo_key` at `vesl-core/hull/src/config.rs:66-88`. Test callers migrate to `_checked().unwrap()` which surfaces nicer error messages on regression.

---

## Appendix A — Clippy summary by crate

| Crate                                 | Warnings | Notable                                         |
|---------------------------------------|:--------:|-------------------------------------------------|
| vesl-core (lib)                       | 3        | 2x too_many_arguments, 1x manual_div_ceil       |
| vesl-core (lib test)                  | 19       | 16x unused_must_use on register_root            |
| hull (lib)                            | 3        | 2x too_many_arguments, 1x redundant_closure     |
| hull (lib test)                       | 6        | redundant_closure + useless_vec                 |
| vesl-nockup vesl-core                 | 22       | same 19 unused_must_use, mirrored               |
| vesl-nockup vesl-test                 | 2        | collapsible_if                                  |
| vesl-nockup graft-inject (tests)      | 5        | option_as_ref_deref                             |
| vesl-nockup graft-inject (bin)        | 4        | cloned_ref_to_slice_refs, unnecessary_cast      |
| hull-llm (lib)                        | 19       | collapsible_if, useless_vec, io_other_error, unnecessary_cast, useless_conversion, useless_format |
| hull-llm (lib test)                   | 20       | most dedupe with lib, +e2e_core unused_must_use |
| hull-llm (bin)                        | 1        | useless_conversion at main.rs:577               |

All warnings are on-by-default clippy lints. `cargo clippy --fix` can automate most of the single-site edits (`div_ceil`, `io_other_error`, redundant closures, useless `vec!`, `useless_format`, `option_as_ref_deref`, `unnecessary_cast`). The `too_many_arguments` and `collapsible_if` items want manual review.

## Appendix B — Files inspected

- Rust: 36 files across `vesl-core/crates/*`, `vesl-core/hull`, `vesl-core/kernels/*`, `vesl-nockup/tools/graft-inject`, `hull-llm/src`, selected tests.
- Hoon: `vesl-core/protocol/lib/{guard,mint,settle,vesl,forge}-kernel.hoon`, all 5 `*-graft.hoon` files, plus `rag-logic.hoon`, `vesl-kernel.hoon` audit block.
- Cross-repo diffs: `diff -rq` on `crates/*` and `protocol/` ↔ `vesl-nockup/hoon`, `templates/*`.

Total audit LOC surveyed: ~14,000 Rust + ~5,000 Hoon across three repos.
