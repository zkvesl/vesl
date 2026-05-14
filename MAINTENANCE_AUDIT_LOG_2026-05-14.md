# MAINTENANCE AUDIT LOG — vesl-core / vesl-nockup

Scope: Rust execution-engine code (vesl-core workspace + vesl-nockup workspace), ZK / STARK glue, Hoon kernels + grafts, vesl-nockup templates, and the `sync.sh` seam. **Focus this cycle: cleanup of messy / bloated code per user direction.**

Audit date: 2026-05-14. Prior logs preserved at `MAINTENANCE_AUDIT_LOG_2026-05-13.md`, `_2026-05-11.md`, `_2026-04-24.md`.

Tool baseline:
- `cargo clippy --workspace --all-targets` from both `~/projects/nockchain/vesl-core/` and `~/projects/nockchain/vesl-nockup/` — both clean (0 own-code warnings). The 3 (vesl-core) / 5 (vesl-nockup) diagnostics are sibling `nockchain/crates/*` upstream warnings neither repo can fix.
- `diff -rq --exclude=target vesl-core/crates vesl-nockup/crates` — clean. Only `vesl-signing`, `vesl-wallet`, `vesl-wallet-spec` appear vesl-nockup-only (by design — sourced from `github.com/zkvesl/vesl-wallet` via `sync.sh:257-260`). The five mirrored crates are byte-identical.
- `diff -rq --exclude=target vesl-core/templates vesl-nockup/templates` — every `Cargo.toml` + `build.rs` differs as `sync.sh:295` (path→git rewrite) and `sync.sh:306` (`graft-inject` → `nockup-graft`) intend. `Only in vesl-nockup: app.hoon, WALLET_CONFIG.md` (kept-canonical there).
- `sync.sh` walk against `vesl-core/protocol/lib/*.{hoon,toml}` — every shipped graft is mirrored; the kernel-private skip list (`sync.sh:130-142`) covers the new `kernel-arms.hoon` and `vesl-stark.hoon` correctly.
- Manual code review across `crates/vesl-core/src/{config,settle,peek,signing,guard}.rs`, `hull/`, `kernels/*`, `protocol/lib/*-kernel.hoon` + `kernel-arms.hoon` + `vesl-stark.hoon`, `vesl-nockup/sync.sh`, `vesl-nockup/test/vesl-test/src/{lib,watch}.rs`, `vesl-nockup/tools/graft-inject/src/*.rs` (9 files, ~6700 LOC), `vesl-nockup/crates/vesl-{signing,wallet,wallet-spec}/src/`, and `templates/*/{Cargo.toml,build.rs,src/main.rs}` in both repos.

Findings are advisory. No code was modified. Per-repo tags:
- `[vesl-core]` — finding local to this repo.
- `[vesl-nockup]` — finding local to the sibling (incl. its `templates/*`, `tools/`, `test/`, `sync.sh`).
- `[cross-repo]` — finding that spans the seam.

## TL;DR

| Category                 | New | Carried | Resolved this cycle | Open |
|--------------------------|:---:|:-------:|:-------------------:|:----:|
| Orphans / Dead Code      | 1   | 0       | All 2026-05-13 §1.* | 1    |
| Duplication              | 1   | 0       | All 2026-05-13 §2.* | 1    |
| Overly Complex Code      | 2   | 0       | All 2026-05-13 §3.* | 2    |
| Comment Bloat            | 2   | 0       | All 2026-05-13 §4.* | 2    |
| Efficiency / Maintenance | 4   | 1       | All 2026-05-13 §5.* except §5.5 (still carried) | 5 |
| File-Level Consolidation | 1   | 1       | 2026-05-13 §6.2     | 2    |
| Clippy warnings (vesl-core / vesl-nockup) | 0 / 0 | | | |

Net delta since 2026-05-13: the prior cycle's §1.1 (forge relocation), §2.1 (vesl-test poke dedupe), §2.2 (mule-wrap factoring), §2.3 (build.rs drift script), §2.4 (graft-settle SDK adoption), §3.1 (vesl-kernel ++poke split), §3.3 (sync.sh skip docs), §4.1 (sync.sh comment trim), §5.1 (CI pin alignment), §5.2 (template doc mirrors), §5.3 (templates-check skip marker), §5.4 (workspace exclude) all landed and verified clean. Hoon side is in particularly good shape — the Hoon deep-dive returned **No findings** across all six categories, the first time this audit chain has logged a zero-finding sub-report.

This cycle's work is small-bore: minor allocation churn, two stacked comment blocks, a `.gitignore` gap, and a coverage gap in last cycle's drift script. The biggest single finding is **§5.1 — `scripts/check-template-buildrs-drift.sh` checks 3 SIBLINGS but the `emit_kernel_cause_tags` helper exists in 7 templates** — last cycle's §2.3 fix is half-cooked.

Loud things worth surfacing up front (not security, but the sort of thing you notice and don't want to forget):

- **`scripts/check-template-buildrs-drift.sh` SIBLINGS array undercounts templates.** Helper exists in 7 templates (counter, data-registry, graft-hash-gate, graft-intent, graft-mint, graft-settle, settle-report) but SIBLINGS lists only 3 (`graft-settle`, `graft-hash-gate`, `graft-intent`, with `graft-mint` as CANONICAL). Drift in counter / data-registry / settle-report would silently pass the check. See §5.1.
- **`templates/vesl/tests/graft_lifecycle.rs` (new, uncommitted) won't surface in `sync.sh`'s "uncommitted changes" warning.** sync.sh's `git diff` + `git diff --cached` check (lines 78-81) covers tracked changes but not new untracked paths. `cp -rL` would still copy the file once committed; the gap is the *warning* not the copy. See §5.4.
- **`scripts/check-template-buildrs-drift.sh` is informational only (`exit 0` regardless).** It documents drift but doesn't gate. Last cycle described it as "wire as a non-gating CI check" — confirming whether CI now consumes it (no workflow runs yet per prior cycle's note) is worth a follow-up.

---

## 1. Orphans / Dead Code

### 1.1 `vesl-nockup/.data.vesl-test/` and `.data.vesl-test-watch/` — empty fixture dirs committed to the repo

- **Scope:** `[vesl-nockup]`
- **Path:** `/.data.vesl-test/checkpoints/`, `/.data.vesl-test-watch/checkpoints/` (each containing nothing but an empty `checkpoints/` subdir)
- **Snippet:** `ls -la .data.vesl-test/` shows `checkpoints/` as a single subdir with no contents. The integration test `test/vesl-test/tests/watch_smoke.rs` does not reference either path.
- **Why flagged:** These look like leftover runtime artifacts from an earlier checkpoint-test iteration. `.gitignore` lists `target/`, `.vesl-target/`, `Cargo.lock`, etc., but **not** `.data.*`. They're harmless but pollute `git status` after any local watch-smoke run, and they imply that any contributor who runs watch-smoke locally will be tempted to `git add` the fresh fixtures.
- **Fix:** Append to `vesl-nockup/.gitignore`:
  ```
  .data.*/
  ```
  Then `git rm -r --cached .data.vesl-test .data.vesl-test-watch` to untrack the empty dirs without deleting them on disk. One-line addition; closes a long-tailed source of dirty trees.

*Note: vesl-core has its own `.gitignore` and its own `.data.*` patterns under `crates/vesl-checkpoint/` (committed `.data.vesl-checkpoint-test*` dirs with no contents); same gap exists there. Logging once here covers both repos because the fix shape is the same — apply to whichever `.gitignore` actually has the empty `.data.*` dirs.*

---

## 2. Duplication

### 2.1 `tools/graft-inject/src/codegen.rs` — banner-pair search loop duplicated across two codegen passes

- **Scope:** `[vesl-nockup]`
- **Paths:**
  - `tools/graft-inject/src/codegen.rs:116-140` (effect-union pass — `emit_effect_union`)
  - `tools/graft-inject/src/codegen.rs:265-289` (load-defaults pass — `emit_load_defaults`)
- **Snippet (first occurrence, lines 116-140):**
  ```rust
  let mut begin_idx: Option<usize> = None;
  let mut end_idx: Option<usize> = None;
  for (i, line) in lines.iter().enumerate().skip(union_idx + 1) {
      let trimmed = line.trim();
      if trimmed == begin_str {
          if begin_idx.is_some() {
              bail!(
                  "duplicate `{}` at line {}; codegen owns one banner pair per kernel",
                  begin_str,
                  i + 1
              );
          }
          begin_idx = Some(i);
      } else if trimmed == end_str {
          if begin_idx.is_none() {
              bail!(
                  "orphan `{}` at line {} (no matching begin banner)",
                  end_str,
                  i + 1
              );
          }
          end_idx = Some(i);
          break;
      }
  }
  ```
  Lines 265-289 are byte-identical except the skip starts at `marker_idx + 1` instead of `union_idx + 1` and the trailing `bail!` (lines 142-148 / 291-296) substitutes `nockup:load-defaults` for `nockup:effect-union`.
- **Why flagged:** Two 24-line loops that find a banner pair (begin/end) in a `&[String]`, with identical duplicate / orphan diagnostics. Any future fix to the loop body (e.g., tightening the trim comparison, swapping to a state-machine model) has to land twice. The fact that `union_idx` and `marker_idx` are both just "the start index" makes this trivially extractable.
- **Fix:** Extract `fn find_banner_pair_indices(lines: &[String], begin_str: &str, end_str: &str, search_start: usize, marker_label: &str) -> Result<(Option<usize>, Option<usize>)>` (or similar) and call it from both passes. Net delta: ~40 LOC removed; future banner-pair logic changes touch one site, not two. Low risk — the diagnostic messages already differ only by the static `marker_label`, which becomes a function arg.

---

## 3. Overly Complex Code

### 3.1 `crates/vesl-core/src/config.rs::resolve_checked` — 115-line nested mode dispatch with one asymmetric fallible arm

- **Scope:** `[vesl-core]`
- **Path:** `crates/vesl-core/src/config.rs:245-360` (`Config::resolve_checked`)
- **Snippet (the asymmetry):**
  ```rust
  match mode {
      SettlementMode::Local   => Ok(Self { /* ~20 lines of field defaults */ }),
      SettlementMode::Fakenet => Ok(Self { /* ~20 lines, similar shape */ }),
      SettlementMode::Dumbnet => {
          // ONLY this arm calls `?` on a required-endpoint check.
          // Asymmetry is invisible from the match arms' tops.
          let endpoint = overrides.chain_endpoint
              .clone()
              .or_else(|| toml.chain_endpoint.clone())
              .ok_or_else(|| "Dumbnet mode requires --chain-endpoint or [chain_endpoint] in vesl.toml".to_string())?;
          Ok(Self { /* ~20 lines */ })
      }
  }
  ```
- **Why flagged:** Three modes × ~20 lines of field-by-field resolution = a 115-line `match`. Each arm independently applies the precedence rule (CLI > env > toml > mode-default) across 6 fields; the only structural difference is that `Dumbnet` has a fallible endpoint check. The asymmetry isn't surfaced in the match arms' headers — a reader has to scan all three to find the one with `?`. Verifying that each mode applies the rule consistently is harder than it should be.
- **Fix:** Extract per-mode resolvers (`fn resolve_local() -> Self`, `fn resolve_fakenet(...) -> Self`, `fn resolve_dumbnet(...) -> Result<Self, String>`). The main `resolve_checked` becomes a 6-line dispatch. The `Result` return type now lives only on `resolve_dumbnet`, making the fallibility explicit at the function signature. Same surgical change applies cleanly because each arm is already a self-contained `Ok(Self { ... })` block. Mechanical refactor; net LOC roughly even but cognitive load drops because each resolver fits on one screen and the consistency check is local.

### 3.2 `crates/vesl-core/src/config.rs::Config::derive_role_belts` — `Result<Option<...>>` return type forces double-unwrap at every caller

- **Scope:** `[vesl-core]`
- **Path:** `crates/vesl-core/src/config.rs:393-414`
- **Snippet:**
  ```rust
  fn derive_role_belts<F>(&self, pick: F) -> Result<Option<[Belt; 8]>, signing::SigningError>
  where
      F: FnOnce(&WalletConfig) -> (u32, u32),
  {
      let wallet_cfg = match self.wallet.as_ref() {
          None => return Ok(None),       // "no wallet configured" — happy path
          Some(w) => w,
      };
      let wallet = match wallet_cfg.build_wallet()? {
          None => return Ok(None),       // "no seed phrase" — happy path
          Some(w) => w,
      };
      // ... actual derivation, returns Ok(Some([...]))
  }
  ```
- **Why flagged:** The return type conflates two "happy path nones" (no wallet, no seed phrase) with one "real error" (signing failure). Every caller (`intent_signer_belts`, `x402_signer_belts`, etc.) has to pattern-match all three states even when they only care about the error path. The double-`return Ok(None)` is the symptom: the function knows the difference between "user didn't configure this" and "we couldn't sign," but the type erases it.
- **Fix:** Split into two return shapes. Option (a): `Result<[Belt; 8], SigningError>` with a `SigningError::NoSeedPhrase` variant — callers that want the no-config-as-error semantics get it for free, callers that don't can `.ok()`-discard. Option (b): keep `Option<[Belt; 8]>` but return it bare (no `Result`); push the genuine error into a separate signature path. Option (a) is closer to the codebase's existing error patterns. Either way, callers stop needing the nested unwrap.

---

## 4. Comment Bloat

### 4.1 `tools/graft-inject/src/inject.rs:880` and `:1079` — stacked AUDIT references mix two audit cycles in the same prose

- **Scope:** `[vesl-nockup]`
- **Path:** `tools/graft-inject/src/inject.rs`
- **Snippet (line 880):**
  ```rust
  // AUDIT 2026-04-19 H-11..H-14's idempotence refactor. R5/A2's sha256 suffix
  // identifies the manifest revision that owns this banner pair; if the manifest
  // changes (new graft, renamed graft, version bump), the suffix drift surfaces
  // as a regenerate-on-next-run, not a silent overwrite.
  ```
  And line 1079:
  ```rust
  // For N=1 the chain (post-AUDIT 2026-04-19 banner refactor) is:
  // {begin-suffix} → block-body → {end-suffix}
  ```
- **Why flagged:** The 2026-05-13 audit explicitly **retained** the AUDIT 2026-04-19 markers (its §4.1 "AUDIT blocks retained, narration trimmed"). That decision was right — the markers are load-bearing for the H-11..H-14 + L-21 + M-22 + M-24 + H-10 + L-19 refactor chain. **However**, the two specific sites above stack a *second* audit reference (R5/A2 in :880; "post-AUDIT … refactor" in :1079) on top of the original. A reader can't tell which lines of the surrounding code closed H-11 vs which respond to R5 without reading 200 lines of context.
- **Fix:** Collapse each to a single intent line, with the design doc as the breadcrumb:
  ```rust
  // Banner-pair idempotence + manifest-sha256 drift detection.
  // Design: R5/A2 §2.1 (extends AUDIT 2026-04-19 H-11..H-14).
  ```
  Eight stacked comment lines drop to two. No code change; the markers stay greppable. Matches CLAUDE.md §10 (surgical, only the prose you're authoring).

### 4.2 `crates/vesl-wallet-spec/src/lib.rs:24` and `:59` — internal "closes OD#X" task IDs leak into public rustdoc

- **Scope:** `[vesl-nockup]` (file is synced from `vesl-wallet` source; the upstream copy carries the same comments)
- **Path:** `crates/vesl-wallet-spec/src/lib.rs`
- **Snippet (line 24, in the module rustdoc role table):**
  ```rust
  //! - [`ROLE_X402`]      (`4`) — x402 spending keys (closes OD#1)
  ```
  And line 59 (in `ROLE_X402`'s rustdoc):
  ```rust
  /// Signs under the `vesl_signing::domain::domain_separators::X402`
  /// (`"x402-nockchain-v2"`) Tip5 domain separator. Closes OD#1.
  ```
- **Why flagged:** `OD#1` is an internal one-day-task tracking ID. The rustdoc renders into `docs.rs` if/when this crate is published, and into IDE hover tooltips today. External consumers of `vesl-wallet-spec` (hardware-wallet vendors, downstream sibling repos) have no way to look up what OD#1 was. The reference adds noise without information.
- **Fix:** Drop the parenthetical and the trailing sentence. The role's purpose ("x402 spending keys") and its domain separator (`"x402-nockchain-v2"`) are the load-bearing facts; OD#1 was the internal ticket that motivated the addition, which belongs in the commit message, not in shipped rustdoc. Since the file is synced from the `vesl-wallet` source repo, the fix needs to land there first to survive a `sync.sh` round-trip. Two-line edit upstream; two-line propagation here on next sync.

*Stale OD-marker count across vesl-nockup: 2. No other OD#X / OD#NN markers in the audited Rust surfaces.*

---

## 5. Efficiency & Maintenance

### 5.1 `scripts/check-template-buildrs-drift.sh` SIBLINGS array undercounts templates with the helper

- **Scope:** `[vesl-core]`
- **Path:** `scripts/check-template-buildrs-drift.sh:25-30`
- **Snippet:**
  ```bash
  CANONICAL="templates/graft-mint/build.rs"
  SIBLINGS=(
      "templates/graft-settle/build.rs"
      "templates/graft-hash-gate/build.rs"
      "templates/graft-intent/build.rs"
  )
  ```
  But `grep -l "emit_kernel_cause_tags" templates/*/build.rs` returns **7** templates: `counter`, `data-registry`, `graft-hash-gate`, `graft-intent`, `graft-mint` (canonical), `graft-settle`, `settle-report`. Three of those (counter, data-registry, settle-report) are not in SIBLINGS, so they're never checked against the canonical.
- **Why flagged:** The 2026-05-13 audit's §2.3 / §6.3 introduced this script (commit `10790ca`) to catch build.rs drift across the graft templates. The header docblock describes it as covering "the four graft templates" but the helper genuinely exists in seven. Drift in `templates/counter/build.rs` would silently pass. That defeats the script's stated purpose.
- **Fix:** Either:
  - **(a) Auto-discover:** replace the hardcoded SIBLINGS with `mapfile -t SIBLINGS < <(grep -l "fn emit_kernel_cause_tags" templates/*/build.rs | grep -v "$CANONICAL")` — never undercount again, no per-template maintenance.
  - **(b) Document the exclusion:** if `counter`, `data-registry`, `settle-report` are intentionally excluded (e.g., their helper has known legitimate drift), add a comment naming why and what part the script still verifies for them.
  
  (a) is the surgical fix unless there's a known reason for (b).

### 5.2 `crates/vesl-core/src/peek.rs::trim_trailing_zeros` — allocates a `Vec<u8>` on every call

- **Scope:** `[vesl-core]`
- **Path:** `crates/vesl-core/src/peek.rs:316-319`
- **Snippet:**
  ```rust
  fn trim_trailing_zeros(bytes: &[u8]) -> Vec<u8> {
      let len = bytes.iter().rposition(|&b| b != 0).map_or(0, |i| i + 1);
      bytes[..len].to_vec()
  }
  ```
- **Why flagged:** Used by peek decoders (`unwrap_triple_unit_atom`, `peek_loobean`, `peek_atom_u64`, `effect_head_tag`, `decode_queue_popped`). Every call allocates a new `Vec<u8>` even when the caller is about to slice / iterate / consume the bytes. For zero-check callers (`decode_queue_popped` checks `result.iter().all(|&b| b == 0)`), the allocation is immediately discarded. Peek is on the read-path for every kernel inspection — not hot in the prover sense, but cheap-to-improve.
- **Fix:** Return a slice instead:
  ```rust
  fn trim_trailing_zeros(bytes: &[u8]) -> &[u8] {
      let len = bytes.iter().rposition(|&b| b != 0).map_or(0, |i| i + 1);
      &bytes[..len]
  }
  ```
  Callers that need owned bytes do `.to_vec()` at the call site; callers that just compare / iterate skip the alloc entirely. Mechanical change. Net: ~5 unnecessary allocations per peek decode removed.

### 5.3 `crates/vesl-core/src/config.rs:268-272, 292-296, 313-316` — `.clone()` chains in fallback resolution

- **Scope:** `[vesl-core]`
- **Path:** `crates/vesl-core/src/config.rs:268-272, 292-296, 313-316`
- **Snippet (seed-phrase resolution, lines 268-272):**
  ```rust
  let seed_phrase = overrides
      .seed_phrase
      .clone()                                              // alloc #1
      .or_else(|| std::env::var("VESL_SEED_PHRASE").ok())  // env-read alloc
      .or_else(|| toml.wallet.as_ref().and_then(|w| w.seed_phrase.clone()));  // alloc #2
  ```
  Same pattern at the `chain_endpoint` resolution in lines 292-296 (Fakenet arm) and lines 313-316 (Dumbnet arm).
- **Why flagged:** This isn't a hot path — config resolution runs once per process — so the perf delta is irrelevant. The reason to flag is **readability**: three `.clone()` calls in a 5-line chain make the resolution look more expensive than it is, and the `Option<String>` shuffle obscures the simpler intent ("first-non-None wins"). The pattern repeats 3× in the same function (lines 268-272, 292-296, 313-316).
- **Fix:** This is **judgment-call cleanup**, not a bug. If §3.1's per-mode resolver refactor lands, each clone chain ends up in its own ~20-line function and the repetition disappears naturally. **Recommendation: defer; close as part of the §3.1 fix or leave alone**. Listed here so a future audit doesn't re-flag it as fresh.

### 5.4 `vesl-nockup/sync.sh:78-81` — untracked-file detection gap

- **Scope:** `[cross-repo]`
- **Path:** `vesl-nockup/sync.sh:78-81`
- **Snippet:**
  ```bash
  if ! git -C "$vesl" diff --quiet 2>/dev/null || \
     ! git -C "$vesl" diff --cached --quiet 2>/dev/null; then
      echo "warning: $vesl has uncommitted changes; sync copies working tree, not HEAD" >&2
  fi
  ```
- **Why flagged:** `git diff` and `git diff --cached` cover tracked-but-modified and staged changes — but **not** untracked files. Today's vesl-core working tree contains untracked `templates/vesl/tests/graft_lifecycle.rs` and a staged `templates/vesl/Cargo.toml` diff (the `anyhow = "1.0"` line — that one IS caught by `git diff` since it's a tracked-file mod). The new test file would be copied by `cp -rL "$vesl/templates/$t" ...` at sync time but the operator gets no heads-up. A new untracked graft library at `protocol/lib/<new-graft>.hoon` would have the same silent-copy behavior.
- **Fix:** Widen the check to include untracked:
  ```bash
  if ! git -C "$vesl" diff --quiet 2>/dev/null || \
     ! git -C "$vesl" diff --cached --quiet 2>/dev/null || \
     [[ -n "$(git -C "$vesl" ls-files --others --exclude-standard 2>/dev/null)" ]]; then
      echo "warning: $vesl has uncommitted or untracked changes; sync copies working tree, not HEAD" >&2
  fi
  ```
  One-line addition. Doesn't change behavior (sync still runs); just makes the warning honest. Low-risk because the soft-warn semantics already imply "review your inputs."

### 5.5 Carried — vesl-kernel JAM triplet consolidation (2026-05-13 §5.5)

Reason for carry is unchanged from prior cycle: the three kernel JAMs (`assets/guard.jam`, `assets/mint.jam`, `assets/settle.jam`) are independently consumed by their host crates via `include_bytes!`; merging them into a single artifact would couple their rebuild cycles unnecessarily. Retain as documented intentional split. Mentioned here so the carried item doesn't disappear from the audit chain.

---

## 6. File-Level Consolidation

### 6.1 `tools/graft-inject/src/util.rs` (132 lines) — narrow scope; cli.rs adjacency suggests inline

- **Scope:** `[vesl-nockup]`
- **Paths involved:**
  - `tools/graft-inject/src/util.rs` (132 lines): `warn_if_stale`, `hash_src_dir`, `warn_if_lib_dir_out_of_tree`
  - `tools/graft-inject/src/cli.rs` (1059 lines): consumer of `warn_if_lib_dir_out_of_tree` and `hash_src_dir`
  - `tools/graft-inject/src/lib.rs` (67 lines): only consumer of `warn_if_stale` outside cli.rs (used at the `run()` entry point, lines 60-67)
- **Proposed target layout:** Inline `warn_if_lib_dir_out_of_tree` and `hash_src_dir` into `cli.rs` next to their callers; leave `warn_if_stale` as a free function in `cli.rs` and have `lib.rs::run` call `cli::warn_if_stale()` instead of `util::warn_if_stale()`. Delete `src/util.rs`. Sync-seam impact: **none** — `tools/graft-inject` is not in any `sync.sh` copy list.
- **Representative coupling snippet (from `tools/graft-inject/src/lib.rs:60-67`):**
  ```rust
  use crate::cli::{Cli, dispatch};
  use crate::util::warn_if_stale;

  pub fn run() -> ExitCode {
      warn_if_stale();
      let cli = Cli::parse();
      let result = dispatch(cli);
      // ...
  ```
  `lib.rs` already imports `dispatch` from `cli`; pulling `warn_if_stale` from the same module removes the only multi-module import in the entry function. The 132-line `util.rs` contains exactly three CLI-entry helpers, none consumed elsewhere.
- **Specific efficiency gained:**
  - Module count: 9 → 8 (`src/util.rs` removed).
  - Import statements: `use crate::util::warn_if_stale;` in `lib.rs` becomes part of the `use crate::cli::{Cli, dispatch, warn_if_stale};` line — net −1 import-line.
  - File-touched-per-CLI-helper-change: 2 → 1 (no more "I tweaked the staleness check, do I touch util or cli?").
  
  **Bar check:** the win is real but small. Apply only if a `cli.rs` reorganization is already on the table; standalone refactor isn't worth the surgical cost.

### 6.2 Carried — `vesl-kernel-jam` macro crate (2026-05-13 §6.1, originally 2026-05-11 §6.1)

Unchanged. The three kernel host crates (`kernels/guard`, `kernels/mint`, `kernels/settle`) each ship a 23-line `lib.rs` that calls `include_bytes!` with a kernel-specific path + asserts a sha256. The 23 lines × 3 crates is the smallest possible footprint for the include-and-verify contract; a macro crate would save ~50 LOC at the cost of a new dep edge. The audit bar (measurable efficiency win) doesn't clear.

---

## Previously flagged (2026-05-13), now resolved

The following 2026-05-13 findings are confirmed closed by the current state of the code (verified against `parametize-3` HEAD `10790ca`):

- **2026-05-13 §1.1** `forge` module relocation to hull-llm — verified via `find . -name forge.rs` returns nothing under `crates/vesl-core/src/`.
- **2026-05-13 §1.2** `noun_builder` public-but-unused — already withdrawn last cycle.
- **2026-05-13 §1.3** `build_forge_prove_poke` name collision — resolved as a side-effect of §1.1.
- **2026-05-13 §1.4** `vesl-entrypoint.hoon` STAGED tag — verified at line 3 of `protocol/lib/vesl-entrypoint.hoon`: `:: STAGED: canonical ABI placeholder.` Commit `9e527a9`.
- **2026-05-13 §2.1** `vesl-test` poke duplicates — verified via `rg "fn build_register_poke" vesl-nockup/test/vesl-test/` returns nothing. Commit `d06b485`.
- **2026-05-13 §2.2** `kernel-arms::parse-payload` extraction + JAM sync — verified all five mule-wrap sites route through `(parse-payload …)`. Commit `28b7b85` (Hoon) + `a2c8d42` (JAMs).
- **2026-05-13 §2.3** Templates' `build.rs` drift check — script landed in `scripts/check-template-buildrs-drift.sh`. **But see §5.1 above — script's SIBLINGS coverage is incomplete.**
- **2026-05-13 §2.4** `graft-settle/src/main.rs` SDK adoption — verified template now imports from `vesl_core` builders, no hand-rolled NounSlab plumbing. Commit `02e878e`.
- **2026-05-13 §3.1** `vesl-kernel.hoon ++poke` 9-line dispatcher — verified.
- **2026-05-13 §3.2** `graft-inject` 6422-line monolith split — verified module map at `lib.rs:11-40`.
- **2026-05-13 §3.3** sync.sh kernel-private skip documentation — verified, see comment block at `vesl-nockup/sync.sh:130-142`.
- **2026-05-13 §4.1** sync.sh AUDIT-2026-04-19 comment compression — verified.
- **2026-05-13 §5.1** CI workflow env pins aligned — verified `vesl-nockup/.github/workflows/ci.yml` matches sync.sh defaults and `.sync-pins.toml`.
- **2026-05-13 §5.2** `templates/README.md` + `templates/GRAFTING.md` synced — verified in `vesl-nockup/sync.sh:225-232`.
- **2026-05-13 §5.3** `templates/graft-scaffold` ci-skip marker — verified.
- **2026-05-13 §5.4** Local `cargo check templates/vesl` Jinja issue — verified.
- **2026-05-13 §6.2** graft-inject split — closed prior cycle.

## Previously flagged (2026-05-13), retained intentionally

Same project-context retention reasons as prior cycles; recorded so future audits don't re-litigate:

- **`intent-graft.hoon`** — STAGED placeholder, `++intent-poke` arms crash with `%intent-graft-placeholder`. Retain.
- **`build_vesl_*_poke` deprecated aliases** in `graft_pokes/settle.rs:283-315` and `lib.rs:84-87` — retained for one more release cycle.
- **`IntentVerifier` alias** at `lib.rs:42` — retained for hull-llm's `FieldVerifier` impl.
- **`%diag-cue` / `%diag-sieve` / `%diag-hash` arms** in `vesl-kernel.hoon` (now `handle-diag-*`) — H-08 audit trail diagnostics.
- **`templates/graft-intent`** — family-5 placeholder; template compiles, graft crashes on invocation by design.
- **`templates/graft-scaffold/Cargo.toml`** `../../nockchain/…` path-deps — intentionally non-compiling at shipped depth; ci.yml skip marker covers it.
- **`vesl-stark-verifier.hoon`** (980 lines) — large but not bloated; 3 public arms (`verify`, `verify-settlement`, `verify-door`) over polynomial-evaluation math that is inherently dense. No extractable helper arms identified by this cycle's Hoon deep-dive.
- **`vesl-nockup/test/vesl-test/src/watch.rs`** (801 lines) — handles four legitimately distinct concerns (command parsing, effect-drain scheduling, poke/peek dispatch, dual JSON/human rendering) for a single REPL-loop contract; splitting would fan out the integration-test imports without reducing surface area.
- **`vesl-nockup/tools/test-registry/`** — manual bash test fixture (`run-init.sh` + `local-registry.toml.tmpl`), intentionally not a workspace member. Documented usage in the script header; not dead code.

## Out of scope for this audit

- `hull-llm/` — prompt narrows scope to vesl-core + vesl-nockup. No re-verification.
- Security review beyond glaring red flags (prompt §15). None observed this cycle.
- Sister repos beyond the sync seam (zkvesl-docs, vesl-labs, vesl-agent, vesl-wallet source repo).
- Branches other than the parametize-3 branch (vesl-core, HEAD `10790ca`) and graft-inject-split branch (vesl-nockup, HEAD `244d1a1`). No probes against `main` or `dev` remote refs.
- Performance benchmarking — no `cargo bench` runs, no STARK proving-time measurements. The §5.2 peek allocation finding is a code-shape observation, not a measured regression.
