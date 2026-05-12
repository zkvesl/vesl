# MAINTENANCE AUDIT LOG — vesl-core / vesl-nockup

Scope: Rust execution-engine code (vesl-core workspace + vesl-nockup workspace), ZK / STARK glue, Hoon kernels + grafts, vesl-nockup templates, and the `sync.sh` seam.

Audit date: 2026-05-11. Prior log preserved at `MAINTENANCE_AUDIT_LOG_2026-04-24.md`.

Tool baseline:
- `cargo clippy --workspace --all-targets` from both `~/projects/nockchain/vesl-core/` and `~/projects/nockchain/vesl-nockup/` (results: vesl-core 0 own-warnings + 3 upstream-nockchain `Cargo.toml` workspace-deps warnings; vesl-nockup 35 warnings, of which 24 are the same `tempfile::TempDir::into_path` deprecation across tests, 1 is the `graft-inject` double-bin-target Cargo warning, the rest are upstream-nockchain `cold_path`/`slice_pattern` feature notices).
- `diff -rq --exclude=target vesl-core/crates vesl-nockup/crates` — clean. Only differences are the three vesl-wallet-sourced crates (`vesl-signing`, `vesl-wallet`, `vesl-wallet-spec`) present in vesl-nockup-only by design, sourced from `github.com/zkvesl/vesl-wallet` via `sync.sh`. The five mirrored crates (`vesl-core`, `vesl-checkpoint`, `nock-noun-rs`, `nockchain-tip5-rs`, `nockchain-client-rs`) are byte-identical — sync seam is intact.
- `sync.sh` walk against `vesl-core/protocol/lib/*.hoon|toml` — every shipped graft + library is mirrored, no stale entries, no missing mirrors.
- Manual code review across `crates/vesl-core/src/{lib,forge,settle,guard,config,types,noun_builder,graft_pokes/*}.rs`, `hull/`, `kernels/{guard,mint,settle}/`, `protocol/lib/*-kernel.hoon`, `protocol/lib/*-graft.hoon`, `protocol/lib/domain-patterns.hoon`, `vesl-nockup/tools/graft-inject/src/main.rs` (audit-dated single-file; split into nine modules under `src/` on 2026-05-12 — see §3.2 resolution), `vesl-nockup/test/vesl-test/src/{lib,watch}.rs`, `vesl-nockup/sync.sh`.

Findings are advisory. No code was modified. Per-repo tags:
- `[vesl-core]` — finding local to this repo.
- `[vesl-nockup]` — finding local to the sibling (incl. its `templates/*`, `tools/`, `test/`, `sync.sh`).
- `[cross-repo]` — finding that spans the seam: drift, broken/stale copy-list entries, sync.sh transformation bugs, missing mirrors, coupling the seam pretends to break but doesn't.

## TL;DR

| Category                 | Issues |
|--------------------------|:------:|
| Orphans / Dead Code      | 2      |
| Duplication              | 5      |
| Overly Complex Code      | 2      |
| Comment Bloat            | 2      |
| Efficiency / Maintenance | 4      |
| File-Level Consolidation | 2      |
| Clippy warnings (vesl-core own / vesl-nockup own) | 0 / ~26 |

Net delta since 2026-04-24: clippy noise floor collapsed from "85+" to effectively zero in vesl-core (and ~26 own-code warnings in vesl-nockup, dominated by one `tempfile` deprecation duplicated across 24 test integration fixtures). Six Apr 24 findings closed outright; two converged on the right resolution via project context (intentional placeholders, retained). The orphan/complexity surface in vesl-core narrowed; the duplication surface widened slightly because the graft catalog grew (~14 new poke builders following the same template, ~9 new grafts with the same state/cap/poke/peek skeleton).

Two loud things worth surfacing up front (not a security review, but the sort of thing you notice and don't want to forget):

- `vesl-nockup/Cargo.toml` is missing `exclude = ["templates"]` (the vesl-core workspace has it; vesl-nockup carries the *comment* explaining the convention but not the actual field). `cargo check --manifest-path templates/graft-scaffold/Cargo.toml` from `vesl-nockup/` errors immediately with *"current package believes it's in a workspace when it's not"*. CI's `templates-check` job (`vesl-nockup/.github/workflows/ci.yml:71-105`) runs the same shape (`cd "$dir" && cargo check`) under `set -e` — either it has been failing silently (worth checking Actions history) or the runner's cache state is masking it. One-line fix. See §5.4.
- `vesl-nockup/tools/graft-inject/Cargo.toml` declares two `[[bin]]` targets (`graft-inject` and `nockup-graft`) both pointing at `src/main.rs`. Cargo emits a warning on every build: *"file `src/main.rs` found to be present in multiple build targets"*. The setup is intentional (the second bin name lets `nockup graft <subcmd>` route to a `nockup-graft` plugin discovered on `$PATH`), but it warns every time and the recommended fix is one trivial four-line file. See §5.2.

---

## 1. Orphans / Dead Code

### 1.1 `build_register_poke` in `settle.rs` — dead duplicate (still live since 2026-04-24)

- **Scope:** `[vesl-core]`
- **Path:** `crates/vesl-core/src/settle.rs:376-395`
- **Snippet:**
  ```rust
  /// Build a [%register hull=@ root=@] poke in NounSlab.
  ///
  /// Mirrors hull/src/noun_builder.rs build_register_poke.
  /// Public for cross-runtime alignment testing.
  pub fn build_register_poke(hull_id: u64, root: &Tip5Hash) -> NounSlab {
      ...
      let tag = make_tag_in(&mut slab, "register");
      let hull = atom_from_u64(&mut slab, hull_id);
      let root_bytes = tip5_to_atom_le_bytes(root);
      let root_noun = make_atom_in(&mut slab, &root_bytes);
      let poke = nockvm::noun::T(&mut slab, &[tag, hull, root_noun]);
      slab.set_root(poke);
      slab
  }
  ```
- **Why flagged:** Identical body to `crates/vesl-core/src/noun_builder.rs:104` (which is the canonical version), and `crates/vesl-core/src/graft_pokes/settle.rs:37` carries the same shape under the new `build_settle_register_poke` name. The settle.rs copy has no external caller across vesl-core, vesl-nockup, or the templates — only its own `#[cfg(test)]` module references it. The "Public for cross-runtime alignment testing" doc comment is self-referential.
- **Recommendation:** Delete `crates/vesl-core/src/settle.rs:376-395` plus its test references. `noun_builder::build_register_poke` is the canonical single source.

### 1.2 `graft-inject` double-bin target — Cargo warns on every build

> **Resolved 2026-05-12** in `vesl-nockup` commits `22bf3ee` + `0deeaa5` (part of the §3.2 split). `Cargo.toml` now declares an explicit `[lib]` plus `[[bin]] name = "nockup-graft" path = "src/bin/nockup-graft.rs"`; the shim is a 4-line `fn main() { graft_inject::run() }` against the lib. Cargo warning cleared.

- **Scope:** `[vesl-nockup]`
- **Path:** `tools/graft-inject/Cargo.toml:8-19`
- **Snippet:**
  ```toml
  [[bin]]
  name = "graft-inject"
  path = "src/main.rs"

  # Same source, different binary name. Lets nockup's plugin-discovery
  # hook (`nockup graft <subcmd>` → execs `nockup-graft <subcmd>` from
  # $PATH) delegate to graft-inject without an upstream subcommand.
  [[bin]]
  name = "nockup-graft"
  path = "src/main.rs"
  ```
- **Why flagged:** Not actually dead, but Cargo can't tell that and warns every build: *"file `/...src/main.rs` found to be present in multiple build targets: `bin` target `graft-inject` / `bin` target `nockup-graft`"*. The warning suppresses no errors, but it's the only persistent "your manifest is wrong" signal in vesl-nockup's CI logs and will eventually drown the genuine signal.
- **Recommendation:** Move the second target to `tools/graft-inject/src/bin/nockup-graft.rs` containing one line: `fn main() { graft_inject::main() }` (after promoting the current `main()` to a `pub fn main()` in `src/main.rs` — Cargo accepts the "lib + bin-shim" idiom). Drops the warning, costs one new four-line file, leaves the plugin-discovery routing semantically unchanged.

---

## 2. Duplication

### 2.1 Kernel-JAM triplet — `kernels/{guard,mint,settle}/` still byte-identical apart from labels

- **Scope:** `[vesl-core]`
- **Paths:**
  - `kernels/guard/src/lib.rs` (22 lines)
  - `kernels/mint/src/lib.rs` (22 lines)
  - `kernels/settle/src/lib.rs` (22 lines)
  - `kernels/guard/build.rs` (28 lines)
  - `kernels/mint/build.rs` (28 lines)
  - `kernels/settle/build.rs` (28 lines)
- **Snippet (identical across all three lib.rs files, modulo label):**
  ```rust
  pub static KERNEL: &[u8] = include_bytes!(env!("KERNEL_JAM_PATH"));
  pub const KERNEL_SHA256_HEX: &str = env!("KERNEL_JAM_SHA256");
  pub fn verify_kernel() {
      let digest = Sha256::digest(KERNEL);
      let actual: String = digest.iter().map(|b| format!("{b:02x}")).collect();
      assert_eq!(
          actual, KERNEL_SHA256_HEX,
          "kernels-guard: embedded JAM sha256 does not match ...",
      );
  }
  ```
- **Why flagged:** 6 files × ~22-28 lines each, where the only per-kernel variance is the asset filename (`guard.jam` / `mint.jam` / `settle.jam`) and the label string in the panic message. The build.rs files mirror this — same `manifest_dir.ancestors().nth(2)` walk, same sha256 ceremony, same env-var emission, only `assets/<name>.jam` and `kernels-<name>` differ.
- **Recommendation:** Extract a `vesl-kernel-jam` crate exposing `embed_kernel!("guard")` (proc-macro or declarative macro) that synthesizes the three constants + `verify_kernel()` and a corresponding `vesl-kernel-jam-build` helper invoked from each kernel's `build.rs`. Each kernel crate then shrinks to 3-5 lines. The seam to honor: each kernel must remain its own crate so its `out.jam` lookup binds to its own `CARGO_MANIFEST_DIR` (`ancestors().nth(2)` resolves to project root from within each kernel crate). See §6.1 for the consolidation framing.

### 2.2 Register-poke fan-out — same `[tag hull payload]` template across 14+ functions

- **Scope:** `[vesl-core]`
- **Paths:**
  - `crates/vesl-core/src/noun_builder.rs:104` (`build_register_poke` — canonical)
  - `crates/vesl-core/src/settle.rs:380` (duplicate, see §1.1)
  - `crates/vesl-core/src/graft_pokes/settle.rs:37` (`build_settle_register_poke`)
  - `crates/vesl-core/src/graft_pokes/guard.rs:18` (`build_guard_register_poke`)
  - `crates/vesl-core/src/graft_pokes/guard.rs:33` (`build_guard_check_poke`)
  - `crates/vesl-core/src/graft_pokes/mint.rs:16` (`build_mint_commit_poke`)
  - `crates/vesl-core/src/graft_pokes/kv.rs:15` (`build_kv_set_poke`)
  - `crates/vesl-core/src/graft_pokes/kv.rs:26` (`build_kv_delete_poke`)
  - `crates/vesl-core/src/graft_pokes/counter.rs:12,22,32` (3 builders)
  - `crates/vesl-core/src/graft_pokes/clock.rs:1` (`build_clock_tick_poke`)
  - `crates/vesl-core/src/graft_pokes/log.rs` (2 builders)
  - `crates/vesl-core/src/graft_pokes/queue.rs` (4 builders)
  - `crates/vesl-core/src/graft_pokes/rbac.rs` (2 builders)
- **Snippet (representative — `build_guard_register_poke`):**
  ```rust
  pub fn build_guard_register_poke(hull: u64, root: &Tip5Hash) -> NounSlab {
      let mut slab = NounSlab::new();
      let tag = make_tag_in(&mut slab, "guard-register");
      let hull_noun = atom_from_u64(&mut slab, hull);
      let root_bytes = tip5_to_atom_le_bytes(root);
      let root_noun = make_atom_in(&mut slab, &root_bytes);
      let poke = T(&mut slab, &[tag, hull_noun, root_noun]);
      slab.set_root(poke);
      slab
  }
  ```
- **Why flagged:** Every one of these is a 5-8 line copy of: `NounSlab::new()` → `make_tag_in(tag)` → encode-arg-1 → encode-arg-2 → `T(slab, &[tag, a1, a2, ...])` → `slab.set_root(poke)` → return. The encoding of each arg differs only in whether it routes through `atom_from_u64`, `make_atom_in`, or `make_tag_in` — selectable from the type at compile time. The fan-out has grown ~3× since 2026-04-24 because nine new graft modules landed (kv / counter / queue / rbac / registry / clock / log / validate / batch), each adding 1-5 builders.
- **Recommendation:** Introduce a tagged-cell builder in `graft_pokes/mod.rs`:
  ```rust
  pub(crate) fn build_tagged_poke<F>(tag: &str, build_args: F) -> NounSlab
  where F: FnOnce(&mut NounSlab) -> Vec<Noun>;
  ```
  Each existing builder collapses to a one-liner. The `build_settle_payload_poke` in `graft_pokes/settle.rs:317` already follows roughly this shape for the jammed-payload family — generalize and adopt. Bug fixes to LE/BE conventions then apply once, not 14+ times.

### 2.3 Hoon `%register` arms — four near-identical kernel implementations

- **Scope:** `[vesl-core]`
- **Paths:**
  - `protocol/lib/guard-kernel.hoon:70-79`
  - `protocol/lib/mint-kernel.hoon:64-73`
  - `protocol/lib/settle-kernel.hoon:78-87`
  - `protocol/lib/vesl-kernel.hoon:88-97`
- **Snippet (representative — `mint-kernel.hoon:64-73`):**
  ```
  %register
  ?:  (~(has by registered.state) hull.u.act)
    ~>  %slog.[3 'mint: hull already registered']
    [~ state]
  =/  new-reg  (~(put by registered.state) hull.u.act root.u.act)
  :_  state(registered new-reg)
  ^-  (list effect)
  ~[[%registered hull.u.act root.u.act]]
  ```
- **Why flagged:** Same guard, same `put`, same effect tag. Only the slog string differs (which is a diagnostic, not behavior). The four kernels share the `registered=(map @ @)` state field so a shared arm is mechanically possible.
- **Recommendation:** Promote to `++handle-register` in a shared `protocol/lib/kernel-arms.hoon` (or extend `domain-patterns.hoon` — its `++apply-*` family already does the analogous threading for state-grafts, but kernel-composites are explicitly listed as out-of-scope per `domain-patterns.hoon:26-29`). Each kernel's `%register` arm becomes `(handle-register registered.state hull.u.act root.u.act %guard)` (last arg passing the slog label). The `sync.sh` step at `vesl-nockup/sync.sh:75-79` already copies `vesl-merkle.hoon` / `vesl-prover.hoon` / `vesl-lower.hoon` / `vesl-gates.hoon` into vesl-nockup; one more shared lib joins them without seam friction.

### 2.4 Hoon settle/prove/verify guard block — copy-pasted across five sites

- **Scope:** `[vesl-core]`
- **Paths:**
  - `protocol/lib/vesl-kernel.hoon:117-136` (`%settle` arm)
  - `protocol/lib/vesl-kernel.hoon:162-180` (`%prove` arm)
  - `protocol/lib/settle-kernel.hoon:106-125` (`%settle` arm)
  - `protocol/lib/settle-kernel.hoon:147-163` (`%verify` arm — slight variant: emits `[%verified %.n]` instead of crashing on guard fail)
  - `protocol/lib/guard-kernel.hoon:99-116` (`%verify` arm — same variant as settle-kernel's verify)
- **Snippet (the canonical four-guard block, from `vesl-kernel.hoon:117-136`):**
  ```
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
- **Why flagged:** Four checks in identical order in three kernels and two arms-per-kernel. A reviewer auditing replay-protection must visit all five and confirm they stayed in sync. Any future check (e.g., "hull is non-zero", "expected-root is non-zero") gets added five times.
- **Recommendation:** Factor into a `++validate-settlement-args` arm in the shared lib (companion to §2.3's `++handle-register`). Returns `[%.y args=settlement-payload]` | `[%.n err=@tas]` and `[%.n %verified-false]` variants for the read-only callers. Each kernel arm becomes parse → validate → branch.

### 2.5 Hoon graft skeleton — `state` + `cap` + `poke` + `peek` repeated across 9+ graft libs

- **Scope:** `[vesl-core]`
- **Paths (partial — every `protocol/lib/*-graft.hoon` follows the shape):**
  - `protocol/lib/kv-graft.hoon` — 105 lines, `kv-state`, `store-cap`, `kv-poke`, `kv-peek`
  - `protocol/lib/registry-graft.hoon` — 153 lines, `registry-state`, `entries-cap`, `registry-poke`, `registry-peek`
  - `protocol/lib/queue-graft.hoon` — 145 lines, `queue-state`, ... cap, poke, peek
  - `protocol/lib/counter-graft.hoon` — 140 lines, same shape
  - `protocol/lib/rbac-graft.hoon` — 160 lines, same shape
  - `protocol/lib/log-graft.hoon` — 159 lines, same shape
  - `protocol/lib/clock-graft.hoon` — 104 lines, same shape
  - `protocol/lib/validate-graft.hoon` — 164 lines, same shape
  - `protocol/lib/batch-graft.hoon` — 171 lines, same shape
- **Snippet (representative shape, from `kv-graft.hoon`):**
  ```
  +$  kv-state   $:  store=(map @t @)  ==
  ++  new-state  ^-  kv-state  :*  store=*(map @t @)  ==
  ++  store-cap  ^~((mul 10.000 1.000))   ::  same value, every graft
  +$  kv-effect  $%  [%kv-stored ...]  [%kv-error msg=@t]  ==
  +$  kv-cause   $%  [%kv-set ...]     [%kv-delete ...]    ==
  ++  kv-poke    |=  [state=kv-state cause=kv-cause]
                 ^-  [(list kv-effect) kv-state]
                 ?-  -.cause  ...  ==
  ++  kv-peek    |=  [state=kv-state =path]
                 ^-  (unit (unit *))
                 ?+  path  ~  ...  ==
  ```
- **Why flagged:** Partially addressed by `domain-patterns.hoon`'s `++apply-*` arms (which thread `(<graft>-poke <graft>.state cause)` into the kernel's `versioned-state` via wet-gate polymorphism), but the per-graft skeleton itself — state record, cap constant, effect union, cause union, poke dispatcher, peek shape — remains hand-written. The cap value (`^~((mul 10.000 1.000))`) is byte-identical across all nine. Any future change to that limit must touch nine files.
- **Recommendation:** Either (a) introduce a Hoon meta-pattern in `domain-patterns.hoon` that holds the cap constant centrally and exposes `++capped-map-put`, `++capped-map-del` arms each graft calls (saves ~20 lines per graft, removes the cap drift risk); or (b) accept that this is the cost of Hoon not having macros and document the convention authoritatively in `docs/graft-manifest.md` so future grafts copy from a single canonical template. Option (b) is the smaller change; option (a) is the bigger win but requires careful wet-gate threading and a follow-on review.

---

## 3. Overly Complex Code

### 3.1 `vesl-kernel.hoon ++poke` — 288-line dispatcher, mixed kernel concerns + STARK glue

- **Scope:** `[vesl-core]`
- **Path:** `protocol/lib/vesl-kernel.hoon:77-364`
- **Why flagged:** One `?-` switch covering 8 cause tags (`%register`, `%settle`, `%prove`, `%sig-hash`, `%tx-id`, `%diag-cue`, `%diag-sieve`, `%diag-hash`). Arms average ~30-60 lines. The `%prove` arm (`148-269`) embeds the STARK-specific bits inline: belt decomposition, Horner polynomial fold, formula construction, `prove-computation` call, and the audit-flagged "TODO: STARK formula hardcoding" block. The arm's lexical scope mingles state guards, payload validation, field-element reduction, and prover wiring. The dispatcher has grown ~3% since 2026-04-24 (367 lines total vs 364).
- **Why this matters for ZK:** A translator porting the kernel's behavior to a circuit must thread through all 8 arms to identify which state is actually relevant to the STARK transcript. The formula construction (`248-253`, 64-nested-increment) is not pulled from a named arm — it's reconstructed in place every prove call. The Fiat-Shamir binding lives in `vesl-prover.hoon`, but the formula it binds is generated here, two files away from the binding point. Auditors lose the thread.
- **Recommendation:** Same as 2026-04-24 §3.2 (still applicable, more urgent now): split the dispatcher into named arms in the core (`++handle-register`, `++handle-settle`, `++handle-prove`, …) and factor the STARK-specific helpers (belt fold, formula builder, prover invocation) into a dedicated `protocol/lib/vesl-stark.hoon` library. The dispatcher arm shrinks to one `?-` selector. Pairs naturally with §2.3 (shared `%register` arm) and §2.4 (shared settlement-guard validator) — those three findings interlock.

### 3.2 `vesl-nockup/tools/graft-inject/src/main.rs` — 6422-line single file

> **Resolved 2026-05-12** in `vesl-nockup` commits `22bf3ee..6bafcbd` on branch `graft-inject-split`. Split into nine modules under `tools/graft-inject/src/` (`lib.rs` entry + `manifest.rs`, `gates.rs`, `marker.rs`, `inject.rs`, `codegen.rs`, `lint.rs`, `cli.rs`, `util.rs`); both `graft-inject` and `nockup-graft` bin shims now compile against the lib. 84 lib tests pass at the pre-split baseline; module-layout note in `lib.rs` doc-header. Original finding kept verbatim below.

- **Scope:** `[vesl-nockup]`
- **Path:** `tools/graft-inject/src/main.rs`
- **Snippet:** N/A — the issue is the file size and concerns mixed within it. Sample concern boundaries from inspection: manifest discovery + parsing (~150-500), gate validation (~250-380), type validation (~330-470), block injection + idempotence banners (~500-1100), typed effect-union codegen (`Phase 03f Lever 1`, ~850-1400), weld-friction lint (`Phase 03f Lever 1.5`, ~1380-1700), `[graft.types]` machinery (~2300-2800), CLI parsing + subcommand dispatch (~2750-3200), and the test module (~3500+).
- **Why flagged:** Each of those concern bands is self-contained and self-tested. A casual reader can't fit the file in working memory. `cargo doc` produces a single 6000-line page. Even simple edits ("add a new gate name") require Cmd-F across the whole file because validators, codegen, and CLI all reference the gate catalog.
- **Recommendation:** Split into a `graft_inject` library + thin bin:
  - `tools/graft-inject/src/lib.rs` — re-exports + top-level types
  - `tools/graft-inject/src/manifest.rs` — `Graft`, `Block`, `load_manifest`, `discover_grafts`, validators
  - `tools/graft-inject/src/gates.rs` — gate catalog + validation
  - `tools/graft-inject/src/inject.rs` — block-injection + banner machinery
  - `tools/graft-inject/src/codegen.rs` — Phase 03f Lever 1 / 1.5 type-union codegen
  - `tools/graft-inject/src/cli.rs` — clap definitions + subcommand dispatch
  - `tools/graft-inject/src/main.rs` — single-call entrypoint
  See §6.2 for the consolidation framing with quantified efficiency win.

---

## 4. Comment Bloat

### 4.1 `vesl-kernel.hoon` — Horner / STARK comment block, mostly narration

- **Scope:** `[vesl-core]`
- **Path:** `protocol/lib/vesl-kernel.hoon:184-246`
- **Snippet (excerpt):**
  ```
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
  ::  64 nested increments on [0 1]
  ::  known-working pattern: atom subject + Nock 0/4 only
  ::
  ::  TODO: AUDIT 2026-04-17 C-lead-1 — STARK formula hardcoding
  ::  … (17 more lines of context)
  ```
- **Why flagged:** The AUDIT-numbered paragraphs (`C-lead-3`, `C-lead-1`) carry load-bearing context — they document invariants the code cannot self-express (Fiat-Shamir binding location, formula-hardcoding risk). Those stay. The narration ("Phase 3: …", "Formula: 64 nested increments", "Subject: belt-digest", "known-working pattern: atom subject + Nock 0/4 only") restates what `roll`, `bex 56`, and the literal `[4 [4 …]]` construction already say. The block is 62 contiguous comment lines on a ~70-line logic block.
- **Recommendation:** Keep the AUDIT blocks verbatim. Compress the narration into a ~6-line header that points to `vesl-prover.hoon` for the Fiat-Shamir half. CLAUDE.md §"Don't explain WHAT" applies here — but §"Explain the traps" applies to the AUDIT blocks. Honor both.

### 4.2 `graft-inject/src/` — Phase-N references throughout, many stale

- **Scope:** `[vesl-nockup]`
- **Path:** `tools/graft-inject/src/*.rs` — 31 occurrences of `Phase NNN` patterns scattered across the codebase. Pre-2026-05-12 split this lived in a single `main.rs`; the comments travelled with the code into the per-concern modules during commits `22bf3ee..6bafcbd`. Re-grep across the split tree to locate them: `rg "Phase [0-9]" tools/graft-inject/src/`.
- **Snippet (a handful, line refs):**
  ```rust
  // tools/graft-inject/src/main.rs:41
  /// Optional gate selection from `[graft.gates]`. EXPANSION Phase 01:
  // tools/graft-inject/src/main.rs:104
  /// Phase 03b: code spliced ahead of the `?-  -.u.act` switch. Composes
  // tools/graft-inject/src/main.rs:543
  /// Phase 03b: spliced before the poke `?-` switch — guards (`?:`
  // tools/graft-inject/src/main.rs:849
  // Phase 03f Lever 1: typed effect-union codegen runs after the
  // tools/graft-inject/src/main.rs:1381
  /// Phase 03f Lever 1.5: weld-friction lint scans developer code
  // tools/graft-inject/src/main.rs:4235
  // Peek emits the chain shape (Phase 4): the legacy expression
  // tools/graft-inject/src/main.rs:4324
  // (deleted) BLOCK_* constants — same content post-Phase 3.
  // tools/graft-inject/src/main.rs:4667
  // ---------- Phase 6: CLI tests ----------
  ```
- **Why flagged:** Phases 03b, 03f Lever 1, Lever 1.5, 4, and 6 have all shipped. A reader new to the file has no way to tell which phase references are still future work, which are decided-history, and which are dead. CLAUDE.md §10 ("Surgical Changes") and the in-repo CLAUDE.md §"Don't reference the current task, fix, or callers" ("'added for the Y flow', 'handles the case from issue #123'") both apply: phase labels age into noise.
- **Recommendation:** Sweep with `rg "Phase [0-9]" tools/graft-inject/src/main.rs`. Drop refs to shipped phases entirely. Replace any that document a still-meaningful constraint with a comment that names the constraint, not the phase that introduced it. The `(deleted) BLOCK_* constants — same content post-Phase 3` comment at line 4324 is the textbook bad case — it documents code that isn't there. Delete the line.

---

## 5. Efficiency / Maintenance

### 5.1 `tempfile::TempDir::into_path` deprecated — 24 sites across `graft-inject` test integrations

- **Scope:** `[vesl-nockup]`
- **Path:** `tools/graft-inject/tests/fixtures/mod.rs:156` (single definition site; `cargo clippy` reports 24 duplicate-warning rollups across test integrations: `manifest_drift`, `queue_lifecycle`, `phase03_postlude`, `rbac_lifecycle`, `clock_lifecycle`, `load_defaults_codegen`, `poke_report`, `batch_lifecycle`, `schnorr_gate_lifecycle`, `mint_lifecycle`, `guard_lifecycle`, `registry_lifecycle`, `validate_lifecycle`, `checkpoint_lifecycle`, `kv_lifecycle`, `gate_compile`, `phase03_prelude`, `resume_emits_effects`, `phase02_audit`, `forge_compile`, `integration`, `counter_lifecycle`, `log_lifecycle`).
- **Snippet:**
  ```rust
  // tests/fixtures/mod.rs:156
          .into_path();   // warning: use of deprecated method
                          //          `tempfile::TempDir::into_path`: use TempDir::keep()
  ```
- **Why flagged:** One symbol, one rename, 24× warning bloat per `cargo clippy` run. The clippy log for vesl-nockup is dominated by these dupes (24 of 35 total warnings). Distracts from real signals.
- **Recommendation:** Single edit in `tests/fixtures/mod.rs:156` — `into_path()` → `keep()`. Trivial; `cargo clippy` confirms the warning batch collapses.

### 5.2 `graft-inject` Cargo double-bin warning (see §1.2 for fix)

- **Scope:** `[vesl-nockup]`
- **Path:** `tools/graft-inject/Cargo.toml:8-19`
- **Why flagged:** Recapped here for the efficiency-tracker; `[[bin]]` repetition on the same `src/main.rs` warns every build. Same recommendation as §1.2 — move `nockup-graft` to `src/bin/nockup-graft.rs` with a one-line forwarder.

### 5.3 vesl-core own-clippy clean — meaningful baseline

- **Scope:** `[vesl-core]`
- **Why noted:** `cargo clippy --workspace --all-targets` from `vesl-core/` produces zero own-code warnings. The three remaining warnings all originate in upstream `nockchain/crates/*` `Cargo.toml` (`workspace.dependencies` `default-features` edge cases) which vesl-core can't fix. This is a meaningful improvement vs the Apr 24 baseline ("85+ warnings"); kept as an explicit datapoint so future audits can detect regression.

### 5.4 vesl-nockup workspace missing `exclude = ["templates"]` — `cargo check` on any template manifest errors out

- **Scope:** `[vesl-nockup]`
- **Path:** `Cargo.toml:1-13`
- **Snippet (current — no `exclude`):**
  ```
  [workspace]
  resolver = "2"
  # vesl-nockup is self-contained post-sync: ...
  members = [
      "tools/graft-inject",
      "test/vesl-test",
  ]
  ```
- **Discovered via:** prompt-line-16 spot-check. `cargo check --manifest-path templates/graft-scaffold/Cargo.toml` from `vesl-nockup/` errors with:
  ```
  error: current package believes it's in a workspace when it's not:
  current:   vesl-nockup/templates/graft-scaffold/Cargo.toml
  workspace: vesl-nockup/Cargo.toml
  this may be fixable by adding `templates/graft-scaffold` to the
  `workspace.members` array … alternatively, to keep it out of the workspace,
  add the package to the `workspace.exclude` array, or add an empty
  `[workspace]` table to the package's manifest.
  ```
- **Why flagged:** vesl-core's workspace already has `exclude = ["templates"]` (see `vesl-core/Cargo.toml:13`, with a 7-line comment explaining the convention exactly per CLAUDE.md §"Rust Dependencies"). vesl-nockup carries the same intent in its comment block at `Cargo.toml:6-9` ("Templates are independent projects under templates/, not workspace members") but stops short of declaring `exclude`. The asymmetry was probably accidental — the comment was carried over from vesl-core during the workspace setup but the actual `exclude` field wasn't.
- **CI impact:** `vesl-nockup/.github/workflows/ci.yml:71-105`'s `templates-check` job runs `for dir in templates/*/; do (cd "$dir" && cargo check); done` with `set -e`. The same workspace-discovery rule fires there; either CI has been hitting this and silently failing the job (worth checking the GitHub Actions history), or the cache state on GitHub runners somehow papers over the error. Either way, the local reproduction is unambiguous.
- **Recommendation:** one-line fix at `vesl-nockup/Cargo.toml:13`:
  ```
  exclude = ["templates"]
  ```
  Symmetric with vesl-core. Mirrors CLAUDE.md §"Rust Dependencies": *"Templates are NOT workspace members ... The `templates/` directory is listed in `[workspace].exclude` to prevent cargo from auto-absorbing them."*

---

## 6. File-Level Consolidation

### 6.1 Kernel-JAM triplet — fold into a single `vesl-kernel-jam` crate exposing a macro

- **Scope:** `[vesl-core]`
- **Paths involved (current):**
  - `kernels/guard/Cargo.toml`, `kernels/guard/build.rs`, `kernels/guard/src/lib.rs`
  - `kernels/mint/Cargo.toml`, `kernels/mint/build.rs`, `kernels/mint/src/lib.rs`
  - `kernels/settle/Cargo.toml`, `kernels/settle/build.rs`, `kernels/settle/src/lib.rs`
  - 9 files total (3 manifests + 3 build scripts + 3 libs)
- **`sync.sh` impact:** **None.** `vesl-nockup/sync.sh` does not copy `vesl-core/kernels/*`. Kernel JAM artifacts ship to vesl-nockup downstream via consumers that depend on the kernel crates by name (path-dep into `vesl-core/kernels/*` from the workspace, or via published-crate semantics later). The change is internal to vesl-core's workspace.
- **Proposed target layout:**
  - Add `vesl-core/crates/vesl-kernel-jam/` exposing a `vesl_kernel_jam::embed!(name = "guard", asset = "guard.jam")` declarative macro (or a `pub fn install(name: &'static str, asset_rel: &'static str)` for build.rs callers) that synthesizes `KERNEL`, `KERNEL_SHA256_HEX`, and `verify_kernel()`.
  - Each `kernels/<name>/src/lib.rs` becomes:
    ```rust
    vesl_kernel_jam::embed!(name = "guard", asset = "guard.jam");
    ```
  - Each `kernels/<name>/build.rs` becomes a 5-line forwarder to a shared `vesl-kernel-jam-build` helper.
- **Coupling snippet (showing what makes them already-coupled):**
  ```rust
  // Today, kernels/mint/src/lib.rs and kernels/guard/src/lib.rs
  // diff in two places only:
  diff -u kernels/guard/src/lib.rs kernels/mint/src/lib.rs
  -    "kernels-guard: embedded JAM sha256 does not match …
  +    "kernels-mint: embedded JAM sha256 does not match …
  ```
- **Quantified efficiency win:**
  - **Files-touched-per-change:** any future kernel-JAM contract change (e.g., add a build-time signature beyond sha256) goes from 6-file edit → 1-file edit + 3 macro invocation re-checks.
  - **Line count delta:** ~150 lines collapse to ~30 (one shared crate + 3× one-line invocations). Net saving ~120 lines.
  - **Compile-unit delta:** still 3 crates (one per kernel — must stay separate so `assets/<name>.jam` path resolution works from `CARGO_MANIFEST_DIR.ancestors().nth(2)`), plus 1 new shared crate. +1 unit, but each kernel crate becomes a trivial shim and rebuilds become cheaper because the shared logic compiles once.
  - **Risk:** the macro must preserve the `CARGO_MANIFEST_DIR.ancestors().nth(2)` lookup against the caller's manifest, not the macro-defining crate's. Declarative macros handle this naturally; proc-macros would need extra care.

### 6.2 `graft-inject/src/main.rs` — split into thematic modules

> **Resolved 2026-05-12** in `vesl-nockup` commits `22bf3ee..6bafcbd`. Actual landed layout: 9 modules (`lib.rs`, `manifest.rs`, `gates.rs`, `marker.rs`, `inject.rs`, `codegen.rs`, `lint.rs`, `cli.rs`, `util.rs`) — one more than the original proposal (`marker.rs` carved out because every consumer touches it). Largest file post-split: `lib.rs` 1,955 lines (bulk is retained `mod tests`; production code is `pub fn run` + 8 `mod` decls + 2 consts ≈ 60 lines); next is `lint.rs` 1,428 lines, `cli.rs` 851. Both `[[bin]]` targets compile through the lib. See §3.2 for the resolution note. Original framing kept verbatim below.

- **Scope:** `[vesl-nockup]`
- **Paths involved (current):**
  - `tools/graft-inject/src/main.rs` — 6422 lines, single file
- **`sync.sh` impact:** **None.** `graft-inject` is vesl-nockup-only; not part of any copy list.
- **Proposed target layout:**
  - `tools/graft-inject/src/lib.rs` — public re-exports + top-level types (~50 lines)
  - `tools/graft-inject/src/manifest.rs` — `Graft`, `Block`, `ManifestFile`, `load_manifest`, `discover_grafts`, name + type validators (~600 lines)
  - `tools/graft-inject/src/gates.rs` — gate catalog, `validate_gate_selection`, `apply_gate_selection`, gate-name lints (~300 lines)
  - `tools/graft-inject/src/inject.rs` — banner-comment idempotence machinery, marker splicing, peek-chain rewriting (~1200 lines)
  - `tools/graft-inject/src/codegen.rs` — Phase 03f Lever 1 typed-effect-union codegen + Lever 1.5 weld-friction lint (~1100 lines)
  - `tools/graft-inject/src/cli.rs` — clap definitions, subcommand dispatch (`rename-kernel`, `--list`, etc.) (~700 lines)
  - `tools/graft-inject/src/main.rs` — single-call entrypoint (~30 lines)
- **Coupling snippet (showing the concern boundary):** today, `validate_gate_selection` (line 257), `apply_gate_selection` (later), the synthesizing codegen pass (line 968+), and the CLI dispatcher (line 3091+) all sit in one file. A reader chasing "how is `[graft.gates].gate` validated and then applied" must navigate three lexically-distant regions. Each is self-contained on its own.
- **Quantified efficiency win:**
  - **Largest file size:** 6422 → ~1200 lines per file (worst case). Files-fit-in-head improves dramatically.
  - **Import-statement delta (caller side):** No external caller imports this — the crate is bin-only and the two `[[bin]]` targets both target `src/main.rs`. Internally, the lib promotion lets test integration files like `tests/manifest_drift.rs` import canonical types (`graft_inject::manifest::Graft`) rather than re-defining them or driving through `Command::new("graft-inject")`. Today there is no library surface; the 24+ integration tests drive only via the bin. Adding the lib surface is net-additive value, not just a churn.
  - **Compile-unit delta:** still one crate (lib + bin), so cargo doesn't rebuild more units; rustc parses one large `main.rs` today and gets one large `lib.rs` tomorrow split into modules — incremental rebuild is unchanged or slightly better.
  - **Files-touched-per-change:** "add a new gate" today touches 3-4 lexically-distant regions of `main.rs`. After split, edits localize to `gates.rs` and `codegen.rs`.
  - **Risk:** §1.2's double-bin fix should land *before* this split, since the `src/bin/nockup-graft.rs` forwarder needs `graft_inject::main` exposed; this split provides that exposure naturally.

---

## Previously flagged (2026-04-24), now resolved

The following Apr 24 findings are confirmed closed by the current state of the code:

- **Apr §1.1** `Forge` empty placeholder struct re-exported as public API: `crates/vesl-core/src/forge.rs` is now a real 415-line module (proof extraction, payload encoding, three `build_forge_*_poke` builders, plus tests). The `pub use forge::Forge;` re-export from Apr is gone (replaced with the `pub use graft_pokes::forge::build_forge_prove_poke;` re-export at `lib.rs:90`).
- **Apr §1.6** `build_prove_poke_generic` — orphan removed; `forge.rs` no longer contains the function.
- **Apr §2.6, §2.7, §2.8** hull-llm-related findings — out of scope for this audit (prompt narrows to vesl-core + vesl-nockup).
- **Apr §3.1** `SettlementConfig::resolve_checked` 9-argument gauntlet — now `(overrides: &SettlementCliOverrides, toml: &SettlementToml, default_signing_key: Option<[Belt; 8]>) -> Result<Self, String>` at `crates/vesl-core/src/config.rs:245`. Three args, struct-based. Apr 24 recommendation adopted verbatim (see Apr's recommendation text, mirrored by the doc comment at `config.rs:118-121`).
- **Apr §3.4** `guard::check_manifest` trivial wrapper — verify in a follow-up; not visible in the current `guard.rs` surface (function-list grep is clean).
- **Apr §4.2** `graft-inject` stale Phase-4/Phase-6 `#[allow(dead_code)]` annotations at `main.rs:36,80` — line 36 is now a manifest schema struct field comment ("Retained in the schema for manifest authors to document intent"); line 80 territory now holds the `Marker::block` method which is actively called by the codegen. Apr's specific call-outs are gone; broader phase-N comment bloat persists (see §4.2 above).
- **Apr §5.1** unused `Result` on `register_root` — 17 test sites in `guard.rs:{224,243,253,290,320,349,370,381,422,455,486}` and `settle.rs:{578,600,642,662,685}` now call `.register_root(root).unwrap()` (fail-loud, per Apr recommendation 'a'). Clippy's `unused_must_use` is silent on this crate.
- **Apr §5.2** clippy quick wins (`manual_div_ceil`, `redundant_closure`, `useless_vec`, `io_other_error`, `useless_conversion`) — vesl-core's own-code clippy warnings are now zero. Adoption confirmed by the `cargo clippy --workspace --all-targets` run baselined at the top of this log.

## Previously flagged (2026-04-24), retained intentionally

These were flagged in the Apr 24 audit as removable orphans/dead code, but project context makes clear they are intentional placeholders for upcoming primitives. Cross-referenced with the user's project memory at `~/.claude/projects/-home-sobchek-projects-nockchain-vesl-core/memory/feedback_placeholders_keep.md` ("IntentVerifier and build_vesl_*_poke are placeholders, not deprecation shims — keep them; same for intent-graft.hoon and %diag-* arms"). Recording the disposition so future audits don't re-litigate:

- **Apr §1.3** `intent-graft.hoon` — still 107 lines, every `++intent-poke` arm `!!`s with `%intent-graft-placeholder`. The header now explicitly documents the family-5 reservation strategy and notes that crashing (vs `%intent-error` effect) is deliberate, so callers can't paper over the placeholder with a retry loop. Retain.
- **Apr §1.4** `build_vesl_*_poke` aliases (`graft_pokes/settle.rs:283-315`, re-exported under `#[allow(deprecated)]` at `lib.rs:84-87`) — retained per project context.
- **Apr §1.5** `IntentVerifier` alias (`crates/vesl-core/src/lib.rs:42`, re-exporting `types::IntentVerifier` under `#[allow(deprecated)]`) — retained per project context. Note that `hull/src/verify.rs:11,43` continues to import `IntentVerifier` for the `FieldVerifier` impl; this is the documented community-fork seam.
- **Apr §1.7** `%diag-cue` / `%diag-sieve` / `%diag-hash` arms in `vesl-kernel.hoon:312-364` — diagnostic placeholders for the H-08 audit trail. Retained.

## Out of scope for this audit

- `hull-llm/` — the Apr 24 audit covered it; this prompt narrows the scope to vesl-core + vesl-nockup. Hull-llm-specific findings (chain.rs duplication, query_handler / prove_handler retrieval-phase extraction, signing.rs verbatim copy) were not re-verified here.
- Security review beyond glaring red flags — prompt line 15.
- Sister repos beyond the sync seam (zkvesl-docs, vesl-labs, vesl-agent, vesl-wallet source — except where `sync.sh` imports the wallet workspace into vesl-nockup, which is verified above).
