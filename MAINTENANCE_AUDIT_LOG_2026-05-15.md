# MAINTENANCE AUDIT LOG — vesl-core / vesl-wallet / vesl-nockup

Scope: vesl-core (Rust workspace + Hoon protocol + templates), vesl-wallet (the new upstream wallet workspace at `~/projects/nockchain/vesl-wallet/`), and vesl-nockup (Rust workspace + `sync.sh` seam + bundled templates). User explicitly asked this cycle to expand from the two-repo scope last cycle covered to a three-repo audit including vesl-wallet.

Audit date: 2026-05-15. Prior logs preserved at `MAINTENANCE_AUDIT_LOG_2026-05-14.md`, `_2026-05-13.md`, `_2026-05-11.md`, `_2026-04-24.md`.

Tool baseline:
- `cargo clippy --workspace --all-targets` from each of `~/projects/nockchain/vesl-core/`, `~/projects/nockchain/vesl-wallet/`, `~/projects/nockchain/vesl-nockup/` — all clean (0 own-code warnings). Sibling `nockchain/crates/*` upstream warnings (stable `cold_path`, unused `slice_pattern` feature flag) are unfixable from any of the three workspaces.
- `cargo check --workspace --all-targets` from each — all clean.
- `diff -rq --exclude=target vesl-core/crates vesl-nockup/crates` — clean. The five mirrored crates (`nock-noun-rs`, `nockchain-tip5-rs`, `nockchain-client-rs`, `vesl-core`, `vesl-checkpoint`) are byte-identical.
- `diff -rq --exclude=target vesl-wallet/crates vesl-nockup/crates` — clean on the three mirrored wallet crates (`vesl-signing`, `vesl-wallet-spec`, `vesl-wallet`). vesl-wallet does not mirror examples/tests (sync.sh's `cp -rL` covers them, and they reach the same content in the destination).
- `sync.sh` Hoon-copy list vs `vesl-core/protocol/lib/*.{hoon,toml}` — every shipped graft is mirrored; the kernel-private skip list (sync.sh:130-142) correctly excludes `kernel-arms.hoon`, `vesl-stark.hoon`, `vesl-stark-verifier.hoon`, `vesl-verifier.hoon`, `vesl-mint.hoon`, `vesl-entrypoint.hoon`, `rag-logic.hoon`, `vesl-test.hoon`, and the five `*-kernel.hoon` files.
- `scripts/check-template-buildrs-drift.sh` — **finds real drift across six templates** (§5.1 below). The auto-discovery fix from 2026-05-14 §5.1 landed correctly (commit `048afa2`) but the reconciliation work the script was designed to surface is unfinished.
- `diff -rq --exclude=target vesl-core/templates vesl-nockup/templates` — every `Cargo.toml` + `build.rs` differs as `sync.sh:295` (path→git rewrite) and `sync.sh:306` (`graft-inject` → `nockup-graft`) intend. `Only in vesl-nockup: templates/app.hoon`, `templates/WALLET_CONFIG.md` (kept-canonical there, preserved by sync.sh:346-351's verify-mode list).
- Manual code review across:
  - vesl-core: `crates/vesl-core/src/{config,settle,signing,peek,guard,types,noun_builder}.rs`, `crates/vesl-core/src/graft_pokes/{settle,mint,guard,…}.rs`, `hull/src/{api,config,signing,verify,main,lib}.rs`, `kernels/{guard,mint,settle}/src/lib.rs`, `protocol/lib/{vesl-kernel,kv-graft,counter-graft}.hoon`, `scripts/check-template-buildrs-drift.sh`, all `templates/*/build.rs`.
  - vesl-wallet: `crates/vesl-signing/src/{lib,domain,schnorr,replay_cache,caip122}.rs`, `crates/vesl-signing/src/math/{mod,belt,bpoly,cheetah,tip5}.rs`, `crates/vesl-wallet/src/{lib,wallet,hd,error}.rs`, `crates/vesl-wallet-spec/src/lib.rs`.
  - vesl-nockup: `sync.sh`, `tools/graft-inject/src/{lib,cli,inject,lint,codegen,manifest,gates,marker,util,test_support}.rs`, `test/vesl-test/src/{lib,watch}.rs`. (Mirrored vesl-core / vesl-wallet crates audited under the upstream scope per the sync-seam rule.)

Findings are advisory. No code was modified. Per-repo tags:
- `[vesl-core]` — finding local to this repo.
- `[vesl-wallet]` — finding local to the new upstream wallet workspace.
- `[vesl-nockup]` — finding local to the sibling distribution (incl. its `templates/*`, `tools/`, `test/`, `sync.sh`).
- `[cross-repo]` — finding that spans the seam.

## TL;DR

| Category                 | New | Carried | Resolved this cycle | Open |
|--------------------------|:---:|:-------:|:-------------------:|:----:|
| Orphans / Dead Code      | 2   | 0       | All 2026-05-14 §1.* | 2    |
| Duplication              | 6   | 0       | All 2026-05-14 §2.* | 6    |
| Overly Complex Code      | 1   | 0       | All 2026-05-14 §3.* | 1    |
| Comment Bloat            | 1   | 0       | 2026-05-14 §4.1, §4.2 (vesl-wallet half) — see §4.1 below for the residual OD#11 leak | 1 |
| Efficiency / Maintenance | 3   | 1       | All 2026-05-14 §5.* except §5.5 (still carried) | 4 |
| File-Level Consolidation | 0   | 2       | 2026-05-14 §6.1 deferred | 2    |
| Clippy warnings (vesl-core / vesl-wallet / vesl-nockup) | 0 / 0 / 0 | | | |

Net delta since 2026-05-14: every prior-cycle finding (§1.1 `.data.*/` gitignore, §2.1 `find_banner_pair_indices`, §3.1 per-mode resolver split, §3.2 `NoSeedPhrase` variant, §4.1 stacked-AUDIT collapse, §4.2 OD#1 strip on vesl-wallet-spec, §5.1 drift-script auto-discovery, §5.2 `trim_trailing_zeros` returns `&[u8]`, §5.4 sync.sh untracked detection) landed and verifies clean. The 2026-05-14 cycle closed every actionable item it logged.

This cycle's findings concentrate on **older duplication patterns** that survived prior audits because each looks small in isolation but together represent ~150 LOC of mirror-only code:

1. **§2.1 `HullWalletToml` mirror** — `hull/config.rs` re-declares `WalletToml` + `WalletRoleToml` for serde derive, but vesl-core's Cargo.toml already pulls in `serde`. The "no serde in vesl-core" rationale that motivated the split is stale.
2. **§2.2 `intent_key_to_belts8` duplicates `vesl_belts8_to_nock`** — `config.rs:465-468` reimplements `signing.rs:291-293` to avoid widening `pub(crate)`. The reimplementation is byte-identical.
3. **§2.3 `resolve_dumbnet` inlines `derive_role_belts`** — same wallet-from-config + intent-key derivation, expressed twice, with different return types (`Result<Self, String>` vs `Result<[Belt; 8], SigningError>`).
4. **§2.4 vesl-wallet `serialize_point` duplicated** — `hd.rs::serialize_point` and `wallet.rs::serialize_point_for_address` have byte-identical bodies; the wallet.rs copy has an explicit "to avoid widening the HD module's API" comment.
5. **§5.1 build.rs drift** — the auto-discovery fix landed but the actual reconciliation hasn't. **Six** template build.rs files diverge from `graft-mint` canonical in two distinct ways (extra "Keeps the `fs` import live" comment, missing docblock + truncated warning message).
6. **§4.1 OD#11 leaks into public rustdoc** — `vesl-wallet-spec/src/lib.rs:69` carries an internal task ID that should have been dropped by the same fix that removed OD#1 last cycle.

Three findings cluster around the same underlying anti-pattern: "I'll re-implement this thin helper rather than widen `pub(crate)`." Each one is small (~5 lines), but the cumulative cost is one duplicated identity-conversion per type-system seam.

Loud things worth surfacing up front (not security; the kind of thing a reader would want to know without reading the full log):

- **§5.1 — `scripts/check-template-buildrs-drift.sh` runs cleanly (auto-discovers 6 sibling templates correctly) and reports **all six** as drifted.** The 2026-05-14 §5.1 fix made the script honest. Nothing reconciled the drift it now surfaces. Counter/data-registry/settle-report added a 2-line comment; graft-hash-gate/graft-intent/graft-settle dropped the doc block and truncated the cargo:warning text. None of the divergences are semantically meaningful — they're just commentary drift — but the script's purpose was to catch this and the response was to merge the script, not to merge the drift fix.
- **§4.1 — `OD#11` survives in `vesl-wallet-spec/src/lib.rs:69` rustdoc.** Last cycle's §4.2 stripped `OD#1` (vesl-wallet commit `9c22b17`) but left `OD#11` for `SLIP-44 coin_type registration`. Same rationale applies: docs.rs / IDE hover readers won't be able to look up what `OD#11` is. The `OD#11` markers in `SPEC.md` are fine — that file IS the decision log — but the rustdoc reference is fresh leakage.
- **vesl-wallet is freshly in audit scope this cycle.** The repo is at ~3.5k LOC across three crates (`vesl-signing` 2.4k, `vesl-wallet` 580, `vesl-wallet-spec` 130). Half the code is verbatim-port math under `vesl-signing/src/math/` (lint-suppressed by design at `math/mod.rs:22`), which is correctly left alone. Findings concentrate in the high-level wallet API (`vesl-wallet/src/wallet.rs`, `hd.rs`) where the duplication patterns described above live.

---

## 1. Orphans / Dead Code

### 1.1 `vesl-nockup/tools/graft-inject/src/manifest.rs:104-110` — `Block::sentinel` field carries `#[allow(dead_code)]` while docs say "retained for documentation"

- **Scope:** `[vesl-nockup]`
- **Path:** `tools/graft-inject/src/manifest.rs:104-110`
- **Snippet:**
  ```rust
  /// Free-form text the manifest author may include to document the
  /// graft block's intent. Not consumed by idempotence logic (per the
  /// banner-comment switch in AUDIT 2026-04-19 H-11..H-14); retained for
  /// manifest authors to document intent.
  #[allow(dead_code)]
  pub(crate) sentinel: String,
  ```
- **Why flagged:** The field is parsed from manifest TOML but never read by codegen. The post-H-11..H-14 idempotence path keys on banner comments + manifest sha256 (R5/A2), not on `sentinel`. The `#[allow(dead_code)]` annotation buries a real "this field has no readers" signal. The doc comment positions it as "retained for documentation," but that documentation never reaches a user — it lives in the parsed `Block` struct, not in the surfaced output.
- **Fix:** Option (a) — drop the field entirely; the manifest schema today permits the key (TOML deserialization is permissive on extra fields by default) so dropping the struct field doesn't break existing manifests. Option (b) — if downstream manifest authors actually use the field, plumb it through to the codegen output (banner header line, or a generated rustdoc on the emitted ?- arm). Option (c) — accept the field as a no-op and re-document it as `// Reserved: parsed from manifest, never read; future use TBD.` Option (a) is the surgical fix.

### 1.2 `vesl-nockup/tools/graft-inject/src/marker.rs:71-86` — `Marker::parse()` is `#[cfg(test)]`-gated and unused

- **Scope:** `[vesl-nockup]`
- **Path:** `tools/graft-inject/src/marker.rs:71-86`
- **Snippet:**
  ```rust
  #[cfg(test)]
  fn parse(name: &str) -> Option<Self> {
      match name {
          "imports" => Some(Self::Imports),
          "state-payload" => Some(Self::StatePayload),
          // ...
          _ => None,
      }
  }
  ```
- **Why flagged:** `rg "Marker::parse|\.parse\(" tools/graft-inject/src/marker.rs` returns the definition only — no caller, in tests or production. Test-only dead code, gated by `#[cfg(test)]` so it doesn't bloat the release binary but does bloat reader cognitive load (you'd assume a `parse` method is used somewhere).
- **Fix:** Remove the function. Trivial deletion; if a future test wants the parse helper, it can be re-added at that point.

---

## 2. Duplication

### 2.1 `vesl-core/hull/src/config.rs:43-74` — `HullWalletToml` / `HullWalletRoleToml` mirror vesl-core's `WalletToml` for a now-stale reason

- **Scope:** `[vesl-core]`
- **Paths:**
  - `hull/src/config.rs:43-74` (mirror structs + `From` impls)
  - `crates/vesl-core/src/config.rs:97-112` (`WalletToml` + `WalletRoleToml`)
- **Snippet (the mirror, lines 41-56):**
  ```rust
  /// Hull-side mirror of `vesl_core::config::WalletToml`. Held separately
  /// so HullConfig can derive `Deserialize` without forcing serde into
  /// vesl-core; the conversion to the generic `WalletToml` is mechanical.
  #[derive(Debug, Default, Clone, Deserialize)]
  pub struct HullWalletToml {
      pub seed_phrase: Option<String>,
      pub coin_type: Option<u32>,
      pub account: Option<u32>,
      pub intent: Option<HullWalletRoleToml>,
      pub payment: Option<HullWalletRoleToml>,
  }

  #[derive(Debug, Default, Clone, Copy, Deserialize)]
  pub struct HullWalletRoleToml {
      pub role: Option<u32>,
      pub index: Option<u32>,
  }
  ```
  Plus 30 lines of `From<&HullWalletRoleToml> for WalletRoleToml`, `From<&HullWalletToml> for WalletToml`, and `From<&HullConfig> for SettlementToml` impls.
- **Why flagged:** The rationale in the doc comment — "without forcing serde into vesl-core" — is no longer true. `vesl-core/Cargo.toml:51` has `serde = { version = "1", features = ["derive"] }` and `crates/vesl-core/src/types.rs:24` already imports `use serde::{Deserialize, Serialize};` for the `Chunk` / `Manifest` / `Note` / `NockZkp` mirrors. Adding `#[derive(Deserialize)]` to the canonical `WalletToml` and `WalletRoleToml` in `config.rs` would be no new dependency in this crate. Cost of the mirror: every new wallet TOML field requires (1) adding it in vesl-core's `WalletToml`, (2) adding it in hull's `HullWalletToml`, (3) extending the `From` impl. Three sites instead of one.
- **Fix:** Add `#[derive(Deserialize)]` (gated behind a feature if backward-compat with serde-free vesl-core consumers matters) to `WalletToml` and `WalletRoleToml` in `crates/vesl-core/src/config.rs`. Delete `HullWalletToml`, `HullWalletRoleToml`, and the two `From` impls in `hull/src/config.rs`. Replace `HullConfig.wallet: Option<HullWalletToml>` with `Option<vesl_core::config::WalletToml>`. Net: -32 LOC and -2 future-edit sites per wallet field. Risk: the canonical struct becomes serde-coupled, which may matter for non-hull consumers — feature-gate if so.

### 2.2 `vesl-core/crates/vesl-core/src/config.rs:465-468` — `intent_key_to_belts8` is byte-identical to `vesl_belts8_to_nock`

- **Scope:** `[vesl-core]`
- **Paths:**
  - `crates/vesl-core/src/config.rs:462-468`
  - `crates/vesl-core/src/signing.rs:290-293`
- **Snippet (config.rs:462-468, the duplicate):**
  ```rust
  /// Convert a vesl-signing `SchnorrPrivateKey` to nockchain-math `[Belt; 8]`.
  /// Mirrors `signing::vesl_belts8_to_nock` but stays here to avoid widening
  /// that module's pub(crate) surface.
  fn intent_key_to_belts8(key: &vesl_signing::schnorr::SchnorrPrivateKey) -> [Belt; 8] {
      let vesl_belts = key.to_belts();
      std::array::from_fn(|i| Belt(vesl_belts[i].0))
  }
  ```
  vs `signing.rs:290-293`:
  ```rust
  fn vesl_belts8_to_nock(belts: &[VeslBelt; 8]) -> [Belt; 8] {
      std::array::from_fn(|i| Belt(belts[i].0))
  }
  ```
- **Why flagged:** The comment is honest about the duplication and names the reason: "to avoid widening that module's pub(crate) surface." That's the wrong tradeoff for two reasons: (1) the file already lives in the same crate, so widening to `pub(crate)` is essentially free (no new public API, no compile-time impact); (2) the duplicate has a different signature (takes `&SchnorrPrivateKey` instead of `&[VeslBelt; 8]`) but `key.to_belts()` is a one-liner, so the call site difference is `vesl_belts8_to_nock(&key.to_belts())` — eight characters more.
- **Fix:** Make `vesl_belts8_to_nock` `pub(crate)` in `signing.rs` (delete the `fn` modifier or leave it unmarked under the existing module-private scope and import with `use crate::signing::vesl_belts8_to_nock;`). Replace both call sites (`config.rs:363`, `config.rs:441`) with `vesl_belts8_to_nock(&key.to_belts())`. Delete `intent_key_to_belts8`. Net: -7 LOC.

### 2.3 `vesl-core/crates/vesl-core/src/config.rs:354-367` — `resolve_dumbnet` duplicates `derive_role_belts`

- **Scope:** `[vesl-core]`
- **Paths:**
  - `crates/vesl-core/src/config.rs:354-367` (the duplicate path in `resolve_dumbnet`)
  - `crates/vesl-core/src/config.rs:422-442` (`derive_role_belts`, the canonical)
- **Snippet (config.rs:354-367):**
  ```rust
  let sk = match wallet_cfg.as_ref() {
      Some(w) => match w.seed_phrase.as_deref() {
          None => None,
          Some(phrase) => {
              let wallet = VeslWallet::from_seed_phrase(phrase, "", w.coin_type)
                  .map_err(|e| format!("invalid seed phrase: {e:?}"))?;
              let key = wallet
                  .intent_signer(w.account, w.intent.index)
                  .map_err(|e| format!("intent_signer derivation failed: {e:?}"))?;
              Some(intent_key_to_belts8(&key))
          }
      },
      None => None,
  };
  ```
  vs `derive_role_belts` (config.rs:422-442) which does the same `wallet_cfg.build_wallet()? → wallet.derive(path)? → intent_key_to_belts8(&derived.private_key)` chain.
- **Why flagged:** Both branches solve the same problem: "given a `WalletConfig`, produce the intent role's `[Belt; 8]`." The difference is mechanical — `resolve_dumbnet` runs before `SettlementConfig` is constructed, so it can't call `self.intent_signer_belts()`. But the **derivation** logic is identical, and now lives in two places. Future changes (e.g., switching from `intent_signer` to `derive(DerivationPath::new(...))` to support a non-intent default role, or threading a passphrase through) require edits in both spots. Error-type asymmetry (`Result<_, String>` vs `Result<_, SigningError>`) further compounds the divergence risk.
- **Fix:** Extract a free function `fn intent_belts_for_wallet(cfg: &WalletConfig) -> Result<Option<[Belt; 8]>, SigningError>` (or a `WalletConfig` method) that encapsulates the "wallet config → maybe-signing-key" chain. `resolve_dumbnet` then calls it via `intent_belts_for_wallet(w).map_err(|e| format!(...))?`, and `derive_role_belts` reduces to a single call. Net: ~10 LOC, one canonical derivation site.

### 2.4 `vesl-wallet/crates/vesl-wallet/src/wallet.rs:175-185` — `serialize_point_for_address` is byte-identical to `hd.rs::serialize_point`

- **Scope:** `[vesl-wallet]` (and mirrored to `[vesl-nockup]`'s copy at `crates/vesl-wallet/src/wallet.rs:175-185` — fix lands upstream and propagates via sync.sh)
- **Paths:**
  - `crates/vesl-wallet/src/wallet.rs:175-185`
  - `crates/vesl-wallet/src/hd.rs:203-213`
- **Snippet (wallet.rs:173-185 — note the explicit duplication-justification comment):**
  ```rust
  /// Same byte layout as the HD module's `serialize_point` (kept private
  /// there). Re-implemented here to avoid widening the HD module's API.
  fn serialize_point_for_address(p: &CheetahPoint) -> [u8; 97] {
      let mut out = [0u8; 97];
      for (i, b) in p.x.0.iter().enumerate() {
          out[i * 8..(i + 1) * 8].copy_from_slice(&b.0.to_le_bytes());
      }
      for (i, b) in p.y.0.iter().enumerate() {
          out[48 + i * 8..48 + (i + 1) * 8].copy_from_slice(&b.0.to_le_bytes());
      }
      out[96] = u8::from(p.inf);
      out
  }
  ```
  `hd.rs:199-213` is byte-identical except for the function name. Both produce the same 97-byte little-endian-coords + inf-flag layout.
- **Why flagged:** Same anti-pattern as §2.2 — re-implementation to avoid widening crate-internal visibility. Both functions live in the same crate (`vesl-wallet`). Making `hd::serialize_point` `pub(crate)` is a no-cost change inside the crate (`mod hd;` is already private to the crate at `lib.rs:47`). The "avoid widening the HD module's API" justification doesn't apply because the API in question is `pub(crate)`, not `pub` — there's no semver / external-consumer concern.
- **Fix:** Mark `hd::serialize_point` `pub(crate)` and `use crate::hd::serialize_point;` from `wallet.rs`. Delete `serialize_point_for_address`. Replace the one call site (`wallet.rs:132`'s `serialize_point_for_address(&pk)`) with `serialize_point(&pk)`. Net: -13 LOC, one canonical impl. Sync seam: vesl-nockup's copy is byte-mirrored, so the fix propagates on next `sync.sh` run with the `VESL_WALLET` pin bumped.

### 2.5 `vesl-core/crates/vesl-core/src/settle.rs:329-374` — `build_settle_poke` / `build_prove_poke` differ only in the tag string

- **Scope:** `[vesl-core]`
- **Paths:**
  - `crates/vesl-core/src/settle.rs:329-349` (`build_settle_poke`)
  - `crates/vesl-core/src/settle.rs:354-374` (`build_prove_poke`)
- **Snippet (settle.rs:329-349 — the first poker):**
  ```rust
  pub fn build_settle_poke(
      note: &Note,
      manifest: &Manifest,
      expected_root: &Tip5Hash,
  ) -> NounSlab {
      use nock_noun_rs::*;

      let mut slab = NounSlab::new();

      let tag = make_tag_in(&mut slab, "settle");
      let payload = build_settlement_payload_in(&mut slab, note, manifest, expected_root);
      let payload_bytes = {
          let mut stack = new_stack();
          jam_to_bytes(&mut stack, payload)
      };
      let jammed = make_atom_in(&mut slab, &payload_bytes);

      let poke = nockvm::noun::T(&mut slab, &[tag, jammed]);
      slab.set_root(poke);
      slab
  }
  ```
  `build_prove_poke` is byte-identical except `"settle"` → `"prove"` on the tag line.
- **Why flagged:** Two 20-line functions, 19 identical lines, one differing string. `crate::graft_pokes::settle::build_settle_payload_poke` (`graft_pokes/settle.rs:317-339`) already demonstrates the right factor — it accepts the verb as a parameter:
  ```rust
  fn build_settle_payload_poke<F>(verb: &str, note_id: u64, hull: u64, root: &Tip5Hash, build_data: F) -> NounSlab
  ```
  The RAG-flavored pair could adopt the same shape with a `(note, manifest, expected_root)` triple instead of `(note_id, hull, root, F)`.
- **Fix:** Extract `fn build_settlement_poke_with_verb(verb: &str, note: &Note, manifest: &Manifest, expected_root: &Tip5Hash) -> NounSlab`. Keep `build_settle_poke` and `build_prove_poke` as one-line wrappers over it (matches the existing one-line wrappers in `graft_pokes/settle.rs`). Net: -20 LOC; future-edit sites for the payload-jam wiring drop from 2 to 1.

### 2.6 `vesl-core/hull/src/api.rs:347-372` and `:407-431` — `commit_handler` and `settle_handler` repeat the same poke+timeout+error scaffolding

- **Scope:** `[vesl-core]`
- **Paths:**
  - `hull/src/api.rs:347-372` (`commit_handler`'s poke dispatch)
  - `hull/src/api.rs:407-431` (`settle_handler`'s poke dispatch)
- **Snippet (api.rs:347-372 — both blocks share this shape):**
  ```rust
  let register_poke = vesl_core::noun_builder::build_register_poke(st.hull_id, &root);
  let _effects = tokio::time::timeout(
      std::time::Duration::from_secs(30),
      st.app.poke(SystemWire.to_wire(), register_poke),
  )
  .await
  .map_err(|_| {
      eprintln!("kernel register poke timed out");
      (
          StatusCode::GATEWAY_TIMEOUT,
          Json(ErrorBody {
              error: "kernel operation timed out".into(),
          }),
      )
  })?
  .map_err(|e| {
      eprintln!("kernel register poke failed: {e}");
      (
          StatusCode::INTERNAL_SERVER_ERROR,
          Json(ErrorBody {
              error: "internal error".into(),
          }),
      )
  })?;
  ```
  `settle_handler` (lines 407-431) is structurally identical: build poke → 30s timeout → 504 on timeout, 500 on error.
- **Why flagged:** Two 25-line blocks differing in (a) the poke they construct, (b) the log-prefix string, (c) whether the resulting `effects` count is used (commit drops it, settle reads `.len()`). Adding a third kernel-poking endpoint would triple the boilerplate; any change to the timeout policy (e.g., per-endpoint timeouts, switching to circuit-breaker) requires editing both.
- **Fix:** Extract `async fn poke_kernel_with_timeout(app: &mut NockApp, poke: NounSlab, log_prefix: &str) -> Result<Vec<NounSlab>, (StatusCode, Json<ErrorBody>)>` (or similar). Each handler then calls `let effects = poke_kernel_with_timeout(&mut st.app, register_poke, "register").await?;`. Net: -40 LOC; the per-call site is 1 line instead of 25, and future endpoints get the timeout policy for free. Risk: low — both handlers use the same timeout value, same error responses, same logging shape.

---

## 3. Overly Complex Code

### 3.1 `vesl-nockup/test/vesl-test/src/watch.rs:584-594` — `write_event` has 9 positional parameters

- **Scope:** `[vesl-nockup]`
- **Path:** `test/vesl-test/src/watch.rs:584-594`
- **Snippet:**
  ```rust
  async fn write_event<W>(
      opts: &WatchOpts,
      writer: &mut W,
      event_num: u64,
      cause_tag: &str,
      ack: Option<&str>,
      err: Option<&str>,
      effect_tags: &[String],
      slogs: &[SlogWarning],
      peek_repr: Option<&str>,
  ) -> Result<()>
  ```
- **Why flagged:** Nine parameters. The first two are config + I/O (legitimate). The seven that follow are all data fields describing a single "event row": event number, cause tag, ack, err, effect tags, slogs, peek output. Call sites at lines 414-425 and 448-459 spell out all seven in order, with `None` placeholders for the slots the call doesn't populate — which is exactly the failure mode positional parameters cause (a transposed `None` between `ack` and `err` would silently swap which slot gets the value).
- **Why kept in scope despite the watch.rs deferral:** Prior cycles deferred splitting `watch.rs` because its 800 lines hang together as a single REPL contract. That argument doesn't apply to a 9-parameter function inside that file — the function is locally too wide, regardless of the surrounding module's size. The fix is a struct extraction, not a file split.
- **Fix:** Introduce `struct EventRow<'a> { event_num: u64, cause_tag: &'a str, ack: Option<&'a str>, err: Option<&'a str>, effect_tags: &'a [String], slogs: &'a [SlogWarning], peek_repr: Option<&'a str> }`. Change `write_event` to `(opts: &WatchOpts, writer: &mut W, row: &EventRow<'_>) -> Result<()>`. Call sites become `write_event(opts, writer, &EventRow { event_num, cause_tag, ack, err: None, effect_tags: &tags, slogs: &slogs, peek_repr: None }).await?;` — field-keyed, transposition-resistant. Net: ~0 LOC delta; readability + safety win.

---

## 4. Comment Bloat

### 4.1 `vesl-wallet/crates/vesl-wallet-spec/src/lib.rs:69` — `OD#11` task ID leaks into public rustdoc

- **Scope:** `[vesl-wallet]` (and mirrored to `[vesl-nockup]`'s copy at `crates/vesl-wallet-spec/src/lib.rs:69`)
- **Path:** `crates/vesl-wallet-spec/src/lib.rs:69`
- **Snippet:**
  ```rust
  pub struct DerivationPath {
      /// SLIP-44 coin_type (TBD upstream — see `SPEC.md §4` and OD#11).
      pub coin_type: u32,
      ...
  }
  ```
- **Why flagged:** Same anti-pattern that 2026-05-14 §4.2 flagged for `OD#1`. That cycle's fix landed in vesl-wallet commit `9c22b17` ("vesl-wallet-spec: drop internal OD#1 task IDs from public rustdoc") and dropped the OD#1 references from the role rustdoc table and `ROLE_X402`'s doc comment. But `OD#11` at line 69 of the same file was missed — same problem (`docs.rs` / IDE hover tooltip readers can't look up `OD#11`), same fix shape (drop the parenthetical or replace it with the canonical reference).
- **Fix:** `/// SLIP-44 coin_type (TBD upstream — see SPEC.md §4).` — drop the trailing `and OD#11`. The SPEC.md reference is the load-bearing breadcrumb; the OD ticket number is internal-only and lives at `SPEC.md:113` already. Two-character edit upstream (in vesl-wallet); propagates to vesl-nockup on next sync.

  Note: the `OD#1` / `OD#11` references in `vesl-wallet-spec/SPEC.md` (the canonical decision log) are correctly retained — they belong in a decision-log document; they don't belong in rendered rustdoc.

---

## 5. Efficiency & Maintenance

### 5.1 `vesl-core/scripts/check-template-buildrs-drift.sh` reports **six templates** drifted from canonical — the auto-discover fix from 2026-05-14 §5.1 made the script honest, but the underlying drift hasn't been reconciled

- **Scope:** `[vesl-core]`
- **Paths involved:**
  - `scripts/check-template-buildrs-drift.sh` (the gating script, exit-code 0 informational only)
  - `templates/graft-mint/build.rs` (canonical)
  - Drifted: `templates/counter/build.rs`, `templates/data-registry/build.rs`, `templates/settle-report/build.rs`, `templates/graft-hash-gate/build.rs`, `templates/graft-intent/build.rs`, `templates/graft-settle/build.rs`
- **Snippet (representative drift, counter vs canonical):**
  Canonical `templates/graft-mint/build.rs:88-89`:
  ```rust
      let _ = fs::metadata(out_dir);
  }
  ```
  Counter `templates/counter/build.rs:79-82` adds two lines:
  ```rust
      // Keeps the `fs` import live for future codegen targets that write
      // structured output here; suppresses the unused-import warning meanwhile.
      let _ = fs::metadata(out_dir);
  }
  ```
  And a structurally different drift on `graft-hash-gate/build.rs`, `graft-intent/build.rs`, `graft-settle/build.rs` (all three drop the 5-line docblock at the top of `emit_kernel_cause_tags` AND truncate the `cargo:warning` text):
  ```rust
              "cargo:warning=Could not run graft-inject: {}. Skipping cause-tag codegen.",
  ```
  vs canonical's longer message:
  ```rust
              "cargo:warning=Could not run graft-inject: {}. Skipping cause-tag codegen — \
               driver `assert_kernel_cause_tag!` invocations will fail to expand.",
  ```
- **Why flagged:** The 2026-05-13 §2.3 + 2026-05-14 §5.1 commits (`10790ca` then `048afa2`) built the drift-detection scaffolding correctly. The script now finds drift in six templates, but no follow-up commit reconciled the divergences. None of them are semantically meaningful — the `fs::metadata` no-op comment is purely editorial, the `cargo:warning` text truncation is a clarity regression rather than a behavioral one — but the whole point of the audit-fix chain was to eliminate this kind of editorial drift across templates.
- **Fix:** Run the canonical fold for each drifted file. Easiest mechanical path: `cp templates/graft-mint/build.rs templates/$T/build.rs` for each $T in {counter, data-registry, settle-report, graft-hash-gate, graft-intent, graft-settle}, then patch the per-template `cargo:rerun-if-changed=hoon/lib/...` list back into each (those legitimately differ). Or write a one-shot Python/awk script that splices the canonical `emit_kernel_cause_tags + docblock` into each sibling, mirroring the script's diff output. Verify with `./scripts/check-template-buildrs-drift.sh` returning "all template build.rs codegen helpers match canonical". Sync seam: all six templates are mirrored by `sync.sh`, so the reconciliation propagates downstream automatically.

### 5.2 `vesl-core/crates/vesl-core/src/peek.rs:92-98, 124-129, 196-205` — triple-unit envelope walk repeated three times

- **Scope:** `[vesl-core]`
- **Paths:**
  - `crates/vesl-core/src/peek.rs:92-98` (`unwrap_triple_unit_atom`)
  - `crates/vesl-core/src/peek.rs:124-129` (`peek_loobean`)
  - `crates/vesl-core/src/peek.rs:196-205` (`peek_unit_list`)
- **Snippet (peek.rs:92-98 — the pattern):**
  ```rust
  pub fn unwrap_triple_unit_atom(result: &NounSlab) -> Option<Vec<u8>> {
      // SAFETY: copy the Noun out immediately; the slab outlives this scope.
      let noun = unsafe { *result.root() };

      let outer = noun.as_cell().ok()?;
      let inner_cell = outer.tail().as_cell().ok()?;
      let maybe_value = inner_cell.tail();
      // ... function-specific tail-walk here ...
  ```
  Identical 4-line preamble appears in `peek_loobean:124-129` and `peek_unit_list:196-205`.
- **Why flagged:** Three peek decoders that share the **same** "strip `[~ [~ value]]` envelope, hand me the inner Noun" preamble. The decoders then diverge on what they do with `maybe_value`: loobean check, atom unwrap, list walk. The preamble is exactly the kind of pattern a helper consolidates well.
- **Fix:** Extract `fn strip_triple_unit_envelope(result: &NounSlab) -> Option<Noun>` returning `maybe_value`. Each decoder becomes `let maybe_value = strip_triple_unit_envelope(result)?;` followed by its per-decoder tail-walk. Net: -8 LOC; SAFETY-pin documentation centralized to one site instead of three. Risk: low — the helper's contract is documented at one point, and all three callers ingest a single `Noun` regardless.

### 5.3 `vesl-core/crates/vesl-core/src/hd.rs::serialize_point` referenced from `wallet.rs::serialize_point_for_address` — also tracked at §2.4

  Cross-reference; same finding from the efficiency angle. The duplicate produces a 97-byte allocation on every receiving-address fingerprint, which is fine (warm-path receive flow), but the maintenance cost is what matters here — see §2.4 for the fix.

### 5.4 Carried — vesl-kernel JAM triplet consolidation (2026-05-14 §5.5, 2026-05-13 §5.5)

Reason for carry is unchanged: the three kernel JAMs (`assets/guard.jam`, `assets/mint.jam`, `assets/settle.jam`) are independently consumed by their host crates via `include_bytes!`; merging them into a single artifact would couple their rebuild cycles unnecessarily. Retain as documented intentional split. Mentioned here so the carried item doesn't disappear from the audit chain.

---

## 6. File-Level Consolidation

### 6.1 Carried — `tools/graft-inject/src/util.rs` (2026-05-14 §6.1)

Re-evaluated this cycle. Status unchanged: the module is 132 lines containing three CLI-entry helpers, all consumed by `cli.rs`. The 2026-05-14 audit concluded "win is real but small — apply only if a `cli.rs` reorganization is already on the table." `cli.rs` has not been reorganized (HEAD `6a03e71` shows no commits touching `cli.rs` since the prior cycle). Defer.

### 6.2 Carried — `vesl-kernel-jam` macro crate (2026-05-13 §6.1)

Unchanged. The three kernel host crates (`kernels/guard`, `kernels/mint`, `kernels/settle`) each ship a 23-line `lib.rs` that calls `include_bytes!` with a kernel-specific path + asserts a sha256. A macro crate would save ~50 LOC at the cost of a new dep edge. Bar (measurable efficiency win) does not clear.

---

## Previously flagged (2026-05-14), now resolved

Verified closed against `parametize-3` HEAD `6090499` (vesl-core), `main` HEAD `9c22b17` (vesl-wallet), `graft-inject-split` HEAD `6a03e71` (vesl-nockup):

- **2026-05-14 §1.1** `.data.*/` gitignore gap — commit `334f133` (vesl-core) and `a9a4c1e` (vesl-nockup). Verified: `.data.vesl-test/`-style dirs no longer surface in `git status`.
- **2026-05-14 §2.1** `find_banner_pair_indices` extraction in `tools/graft-inject/src/codegen.rs` — commit `6e62bd4` (vesl-nockup). Verified via the helper's three call sites.
- **2026-05-14 §3.1** `Config::resolve_checked` per-mode resolver split — commit `fb71337` (vesl-core). Verified at `crates/vesl-core/src/config.rs:244-385`: 6-line dispatch + `resolve_local` / `resolve_fakenet` / `resolve_dumbnet` factors landed cleanly.
- **2026-05-14 §3.2** `derive_role_belts` `Result<Option<...>>` collapse → `SigningError::NoSeedPhrase` — commit `e3e3e20` (vesl-core). Verified at `signing.rs:63` (variant) and `config.rs:422-442` (call site).
- **2026-05-14 §4.1** stacked AUDIT references in `inject.rs:880, :1079` collapsed — commit `ef4182d` (vesl-nockup). Verified at `tools/graft-inject/src/inject.rs:881` ("Design: R5/A2 §2.1 (extends AUDIT 2026-04-19 H-11..H-14)." — one-line breadcrumb).
- **2026-05-14 §4.2** `OD#1` strip from `vesl-wallet-spec/src/lib.rs` — commit `9c22b17` (vesl-wallet) + propagated via vesl-nockup sync. Verified. **But §4.1 above flags the residual OD#11 leak** — same anti-pattern, missed by the prior fix.
- **2026-05-14 §5.1** `scripts/check-template-buildrs-drift.sh` SIBLINGS auto-discovery — commit `048afa2` (vesl-core). Verified: the `mapfile -t SIBLINGS < <(grep -l ...)` line at `scripts/check-template-buildrs-drift.sh:27-29` correctly picks up all six sibling templates. **§5.1 in this cycle flags that the drift the script now exposes was never reconciled** — that's a separate, downstream finding from this one.
- **2026-05-14 §5.2** `trim_trailing_zeros` returns `&[u8]` — commit `636b09a` (vesl-core). Verified at `crates/vesl-core/src/peek.rs:315-318`.
- **2026-05-14 §5.3** `.clone()` chains in fallback resolution — closed as a side-effect of §3.1's per-mode resolver split (prior cycle correctly predicted: "If §3.1's per-mode resolver refactor lands, each clone chain ends up in its own ~20-line function and the repetition disappears naturally"). Verified.
- **2026-05-14 §5.4** sync.sh untracked-file detection — commit `5eb1313` (vesl-nockup). Verified at `vesl-nockup/sync.sh:78-83`: the new `[[ -n "$(git -C "$vesl" ls-files --others --exclude-standard 2>/dev/null)" ]]` check is in place.
- **2026-05-14 §6.1** `tools/graft-inject/src/util.rs` consolidation — deferred per prior cycle's recommendation; retained as §6.1 above.

## Previously flagged (2026-05-14), retained intentionally

Same retention reasons as prior cycles; recorded so future audits don't re-litigate:

- **`intent-graft.hoon`** — STAGED placeholder, `++intent-poke` arms crash with `%intent-graft-placeholder`. Retain.
- **`build_vesl_*_poke` deprecated aliases** in `graft_pokes/settle.rs:283-315` and `lib.rs:84-87` — retained for one more release cycle.
- **`IntentVerifier` alias** at `lib.rs:42` and `types.rs:109-110` — retained for hull-llm's `FieldVerifier` impl.
- **`%diag-cue` / `%diag-sieve` / `%diag-hash` arms** in `vesl-kernel.hoon` (now `handle-diag-*` at lines 157-206) — H-08 audit trail diagnostics.
- **`templates/graft-intent`** — family-5 placeholder; template compiles, graft crashes on invocation by design.
- **`templates/graft-scaffold/Cargo.toml`** `../../nockchain/…` path-deps — intentionally non-compiling at shipped depth; ci.yml skip marker covers it.
- **`vesl-stark-verifier.hoon`** (980 lines) — large but not bloated; 3 public arms (`verify`, `verify-settlement`, `verify-door`) over polynomial-evaluation math that is inherently dense.
- **`vesl-nockup/test/vesl-test/src/watch.rs`** (801 lines) — splitting deferred; this cycle's §3.1 finding (`write_event` parameter list) is a local fix inside the file, not a split.
- **`vesl-wallet/crates/vesl-signing/src/math/*`** — verbatim port of `nockchain-math` primitives with explicit `#![allow(dead_code, clippy::wrong_self_convention)]` at `math/mod.rs:22`. The lint suppression and the verbatim nature are by design (see comment block at `math/mod.rs:1-22`); dead-code findings in this subtree are out of scope.
- **`vesl-wallet/crates/vesl-wallet/src/wallet.rs::intent_signer` / `payment_signer`** (wallet.rs:150-168) — same body modulo the role constant, but they're the public surface the README documents and downstream callers reach for. Combine-into-`role_signer(role: u32, …)` would force callers through an int constant instead of a named method. Retain.

## Out of scope for this audit

- `hull-llm/` — user did not name it in the expanded scope. No re-verification.
- Security review beyond glaring red flags (prompt §15). None observed this cycle. Note: `vesl-core/hull/src/api.rs::poke` calls share a 30-second timeout — that's a policy choice, not a security gap; flagged under §2.6 as duplication, not vulnerability.
- Branches other than `parametize-3` (vesl-core, HEAD `6090499`), `main` (vesl-wallet, HEAD `9c22b17`), and `graft-inject-split` (vesl-nockup, HEAD `6a03e71`). No probes against `origin/main` or `origin/dev`.
- Performance benchmarking — no `cargo bench` runs, no STARK proving-time measurements. The §5.2 peek triple-unit envelope finding is a code-shape observation, not a measured regression.
- vesl-wallet's `examples/mock_trust_anchor.rs`, `tests/api_smoke.rs`, `tests/parity_with_nockchain_math.rs`, `tests/round_trip.rs` — read but no findings worth logging (the parity-vector test fixtures are the load-bearing thing here; they verify the verbatim math port stays in sync with `nockchain-math`).
- vesl-wallet's `Cargo.lock`, `deny.toml`, `CHANGELOG.md`, `CONTRIBUTING.md` — surface review only; no findings.
- vesl-core's uncommitted `templates/vesl/Cargo.toml` change (adds `vesl-checkpoint` to `[dev-dependencies]`) and vesl-nockup's matching uncommitted edit + README addition — in-progress work; not flagged because it's not yet a committed state for the audit to operate on.
