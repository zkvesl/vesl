# MAINTENANCE AUDIT LOG — vesl-core / vesl-nockup

Scope: Rust execution-engine code (vesl-core workspace + vesl-nockup workspace), ZK / STARK glue, Hoon kernels + grafts, vesl-nockup templates, and the `sync.sh` seam.

Audit date: 2026-05-13. Prior logs preserved at `MAINTENANCE_AUDIT_LOG_2026-05-11.md` and `MAINTENANCE_AUDIT_LOG_2026-04-24.md`.

Tool baseline:
- `cargo clippy --workspace --all-targets` from both `~/projects/nockchain/vesl-core/` and `~/projects/nockchain/vesl-nockup/` — both report 0 own-code warnings. The only diagnostics are 3 (vesl-core) / 3 (vesl-nockup) upstream `nockchain/crates/*` warnings (stale `cold_path`/`slice_pattern` feature gates, `default-features` workspace-deps notices) which neither repo can fix.
- `diff -rq --exclude=target vesl-core/crates vesl-nockup/crates` — clean. The three vesl-wallet-sourced crates (`vesl-signing`, `vesl-wallet`, `vesl-wallet-spec`) are vesl-nockup-only by design (sourced from `github.com/zkvesl/vesl-wallet` via `sync.sh`). The five mirrored crates are byte-identical — sync seam is intact.
- `diff -rq --exclude=target vesl-core/templates vesl-nockup/templates` — every template `Cargo.toml` + `build.rs` differs as `sync.sh` intends (path-dep → git-dep rewrite for `../../../nockchain/...` patterns, `graft-inject` → `nockup-graft` in build.rs). Surplus-in-vesl-core: `templates/README.md`, `templates/GRAFTING.md` (not in sync.sh's copy list — flagged §5.2). Surplus-in-vesl-nockup: `templates/app.hoon`, `templates/WALLET_CONFIG.md` (kept-canonical there).
- `sync.sh` walk against `vesl-core/protocol/lib/*.{hoon,toml}` — every shipped graft + library is mirrored; `kernel-arms.hoon` and `vesl-stark.hoon` (new in commits `8cb5098`, `19d6ce1`) are correctly omitted because they're imported only by kernel libraries that aren't shipped, but the omission is undocumented (§3.3).
- `cargo check --manifest-path templates/graft-scaffold/Cargo.toml` from `vesl-nockup/` fails — `ibig` patch resolves to a non-existent `vesl-nockup/nockchain/...` tree (§5.3). CI's `templates-check` would hit the same failure once it first executes.
- Manual code review across `crates/vesl-core/src/{forge,settle,guard,noun_builder,graft_pokes/*}.rs`, `hull/`, `kernels/{guard,mint,settle}/`, `protocol/lib/*-kernel.hoon`, `protocol/lib/{kernel-arms,vesl-stark,vesl-entrypoint,domain-patterns}.hoon`, `vesl-nockup/sync.sh`, `vesl-nockup/.github/workflows/ci.yml`, `vesl-nockup/test/vesl-test/src/lib.rs`, `vesl-nockup/tools/graft-inject/src/*.rs`, and all `templates/*/{Cargo.toml,build.rs,src/main.rs}` in both repos.

Findings are advisory. No code was modified. Per-repo tags:
- `[vesl-core]` — finding local to this repo.
- `[vesl-nockup]` — finding local to the sibling (incl. its `templates/*`, `tools/`, `test/`, `sync.sh`).
- `[cross-repo]` — finding that spans the seam: drift, broken/stale copy-list entries, sync.sh transformation bugs, missing mirrors, coupling the seam pretends to break but doesn't.

## TL;DR

| Category                 | New issues | Carried | Resolved during this cycle | Open |
|--------------------------|:----------:|:-------:|:--------------------------:|:----:|
| Orphans / Dead Code      | 3 (+1 withdrawn §1.2) | 0 | §1.1, §1.3                 | §1.4 |
| Duplication              | 4          | 4       | —                          | 8    |
| Overly Complex Code      | 1          | 1       | —                          | 2    |
| Comment Bloat            | 1          | 0       | —                          | 1    |
| Efficiency / Maintenance | 4          | 1       | —                          | 5    |
| File-Level Consolidation | 1          | 2       | —                          | 3    |
| Clippy warnings (vesl-core / vesl-nockup) | 0 / 0 | | | |

Net delta since 2026-05-11: every own-code clippy warning closed in vesl-nockup (was ~26, now 0 — `tempfile::into_path` rename landed, `graft-inject` double-bin warning closed via the §3.2 split). vesl-nockup workspace `exclude = ["templates"]` added (§5.4 closed). graft-inject split landed cleanly. New surfaces opened: a sync-pin drift between CI env and committed `.sync-pins.toml` (§5.1 — would break sync-verify on first CI run), the graft-scaffold template won't pass CI's templates-check job (§5.3 — same first-run issue).

**Resolved during this audit cycle (2026-05-13):**
- §1.1 — ForgePayload-shaped forge helpers relocated to `hull-llm/src/forge.rs`; `vesl-core/src/forge.rs` deleted; `ForgePayload` + `LeafWithProof` moved from `vesl-core/src/types.rs` to `hull-llm/src/forge.rs`. Sync-seam parity preserved (matching deletions in `vesl-nockup/crates/vesl-core/`). hull-llm imports rewired; the previously-flagged hull-llm `e2e_core.rs:182` broken import fixed opportunistically. All 164 vesl-core unit tests + 12 forge tests pass.
- §1.3 — name collision dissolved as a side-effect of §1.1 (only one `build_forge_prove_poke` left in vesl-core, at `graft_pokes/forge.rs`).
- §1.2 — **withdrawn**, original analysis missed an actual call site (see §1.2 note).

Two loud things worth surfacing up front (not a security review, but the sort of thing you notice and don't want to forget):

- **`vesl-nockup/.github/workflows/ci.yml` env pins are stale** (`NOCK_PIN: c51f8040…`, `VESL_CORE_PIN: 19d6ce10…`), but `vesl-nockup/sync.sh` defaults to newer pins (`1a23ccd…`, `c4ca118…`) and the committed `vesl-nockup/.sync-pins.toml` records those newer pins. The first CI run will see workflow env overriding sync.sh's defaults, regenerate `.sync-pins.toml` with the *old* pins, and fail the `sync-verify` job. Zero workflow runs exist on GitHub yet (`gh api repos/zkvesl/vesl-nockup/actions/runs` → `total_count: 0`), so this hasn't been observed. One-line fix in `ci.yml`. See §5.1.
- **`vesl-nockup/templates/graft-scaffold/Cargo.toml`** declares path-deps at `../../nockchain/...` (two levels up, not three). From `vesl-nockup/templates/graft-scaffold/`, that resolves to `vesl-nockup/nockchain/...` — a directory that doesn't exist in vesl-nockup, in vesl-core, or in CI's checkout layout. The template ships with "adjust paths to your nockchain clone" comments, so it's intentionally non-compiling at its shipped depth, but CI's `templates-check` job (`vesl-nockup/.github/workflows/ci.yml:71-105`) has only a Jinja-placeholder skip — no skip for graft-scaffold. First CI run will fail the templates-check job. See §5.3.

---

## 1. Orphans / Dead Code

### 1.1 `forge::extract_proof_from_effects` and ForgePayload-shaped `build_forge_*_poke` — moved to hull-llm

> **Resolved 2026-05-13 during this audit cycle** (option (a) — relocation). After explicit user authorization to modify the hull-llm repo, `crates/vesl-core/src/forge.rs` and its two ForgePayload-shape types (`ForgePayload`, `LeafWithProof`) were moved verbatim to `hull-llm/src/forge.rs`. Verified pre-move that hull-llm was the sole external caller (`rg` for `extract_proof_from_effects`, `build_forge_settle_poke`, `build_forge_verify_poke`, `ForgePayload`, `LeafWithProof` across vesl-core, vesl-nockup, hull-llm — only own-definitions + own-tests + `hull-llm/tests/e2e_forge.rs:19-24` consumer). After the move:
> - `vesl-core/crates/vesl-core/src/forge.rs` deleted
> - `vesl-core/crates/vesl-core/src/types.rs` — `ForgePayload`, `LeafWithProof` removed (lines 86-101 of pre-move file)
> - `vesl-core/crates/vesl-core/src/lib.rs` — `pub mod forge;` removed + `ForgePayload, LeafWithProof` dropped from the `pub use types::{...}` block
> - Same three edits applied to `vesl-nockup/crates/vesl-core/src/{forge.rs,types.rs,lib.rs}` to keep the sync-seam byte-identical (`vesl-core-sync.yml` gate)
> - `hull-llm/src/forge.rs` created (415 lines: types + 4 builders + `extract_proof_from_effects` + 12 unit tests, imports `Note`/`NoteState` from `vesl_core::types`)
> - `hull-llm/src/lib.rs:11` — `pub mod forge;` added
> - `hull-llm/tests/e2e_forge.rs:19-25` — imports rewritten from `vesl_core::forge::{...}` + `vesl_core::types::{ForgePayload, LeafWithProof, ...}` to `hull_llm::forge::{..., ForgePayload, LeafWithProof}` + `vesl_core::types::{Note, NoteState}`
> - `hull-llm/tests/e2e_core.rs:182` — fixed the long-standing broken import `vesl_core::settle::build_register_poke` → `vesl_core::noun_builder::build_register_poke` (was the carry-over break flagged in the 2026-05-11 §1.1 "previously resolved" note; addressed opportunistically since the hull-llm repo was already open)
>
> Verification (post-move):
> - `cargo check --workspace --all-targets` clean in all three repos (0 own-code warnings in vesl-core / vesl-nockup; pre-existing 6 hull-llm warnings unchanged)
> - `cargo test -p vesl-core --lib` — 164/164 pass (vesl-core); 164/164 pass (vesl-nockup mirror)
> - `cargo test -p hull-llm --lib forge::` — 12/12 pass (all relocated unit tests survive)
> - `diff -rq --exclude=target vesl-core/crates/vesl-core vesl-nockup/crates/vesl-core` — empty (sync-seam intact)
>
> Note: hull-llm's current `vesl-core` git-pin (`ee88748`) is 86 commits behind the post-move HEAD, so hull-llm's e2e tests still resolve `vesl_core::forge::*` against the pinned old vesl-core for now. The import rewrite in `e2e_forge.rs` only takes effect once hull-llm bumps its pin past whichever commit lands the deletion in vesl-core. Until then both paths coexist via the pin lag.
>
> Original finding kept verbatim below.

- **Scope:** `[vesl-core]`
- **Path:** `crates/vesl-core/src/forge.rs:29-62, 136-148`
- **Snippet:**
  ```rust
  // crates/vesl-core/src/forge.rs:136-148
  pub fn build_forge_prove_poke(payload: &ForgePayload) -> NounSlab {
      build_forge_poke("prove", payload)
  }
  pub fn build_forge_settle_poke(payload: &ForgePayload) -> NounSlab {
      build_forge_poke("settle", payload)
  }
  pub fn build_forge_verify_poke(payload: &ForgePayload) -> NounSlab {
      build_forge_poke("verify", payload)
  }
  ```
- **Why flagged:** `rg -t rust 'extract_proof_from_effects|build_forge_settle_poke|build_forge_verify_poke'` across `vesl-core` + `vesl-nockup` returns only the function's own definitions and its own tests. The one external caller of all four functions is `hull-llm/tests/e2e_forge.rs:19-22` — a sister repo that this prompt explicitly narrows out of scope. From the perspective of the two repos under audit, this is 415 lines of dead Rust kept alive only because hull-llm imports it via `vesl_core::forge::*`.
- **Recommendation:** Two routes. Either (a) move the ForgePayload-shaped builders + `extract_proof_from_effects` into hull-llm itself (the only caller) and shrink vesl-core's `forge.rs` to the proof-bytes extraction primitive that other future hulls might reuse; or (b) accept that vesl-core ships hull-llm-only API surface and document `forge::*` as "consumed downstream by hull-llm; do not remove without coordinated hull-llm bump." The current state — kept alive with no in-repo justification — is the worst of both. Option (a) is the cleaner cut; (b) is the smaller change. Cross-references the §1.3 same-name collision below.

### 1.2 ~~`noun_builder::{hash_to_noun_generic, proof_node_to_noun, chunk_to_noun, retrieval_to_noun, retrieval_list_to_noun}` — public but unused~~ **(withdrawn — original analysis was wrong)**

> **Withdrawn 2026-05-13 during this audit cycle.** The original analysis missed that `hull-llm/src/noun_builder.rs:29` calls `retrieval_list_to_noun(stack, &m.results)` through the bare re-export name (no `noun_builder::` prefix), so the prior `rg 'noun_builder::retrieval_list_to_noun'` query reported zero call sites when there's actually a live one. That single call transitively pulls `retrieval_to_noun` → `chunk_to_noun` + `proof_list_to_noun` → `proof_node_to_noun` through the function-call graph inside vesl-core's `noun_builder.rs`. So four of the five helpers carry their weight via the hull-llm RAG-manifest serialization path.
>
> The one helper still without any live caller is **`hash_to_noun_generic`** (`crates/vesl-core/src/noun_builder.rs:29`) — its only internal use was inside `build_register_poke` (line 109), and `hash_to_noun_generic` re-exported through `hull-llm/src/noun_builder.rs:7` has no downstream call. Marginal — the function is 4 lines, `pub` for generic-allocator callers that haven't materialized yet. Carrying cost is ~4 lines + one re-export entry.
>
> Verified the corrected picture by re-running the search with broader patterns (`rg '\bretrieval_list_to_noun\b'`, etc.) against all three repos:
> - `retrieval_list_to_noun` → 1 live call (`hull-llm/src/noun_builder.rs:29`)
> - `retrieval_to_noun` → 1 internal call (`retrieval_list_to_noun` at noun_builder.rs:74)
> - `chunk_to_noun`, `proof_list_to_noun`, `proof_node_to_noun` → internal call chain via `retrieval_to_noun` / its own helpers
> - `hash_to_noun_generic` → no live caller outside its 4-line body
>
> No code changed for this withdrawn finding. The deeper architecture observation that these helpers are RAG-specific (Chunk/Retrieval/Manifest types) and might belong in hull-llm alongside `manifest_to_noun` rather than in vesl-core stands — but that's a larger relocation involving `Chunk` and `Retrieval` types themselves, and out of scope for this audit cycle.

### 1.3 Two `build_forge_prove_poke` functions, different signatures, both `pub` — name collision footgun

> **Resolved 2026-05-13 during this audit cycle.** The `forge::build_forge_prove_poke` flavor moved to hull-llm along with the rest of `forge.rs` (see §1.1). vesl-core now has a single `build_forge_prove_poke` at `crates/vesl-core/src/graft_pokes/forge.rs:21` — the `(hull, note_id, data)` shape used by graft-composed kernels. The hull-llm-side `ForgePayload`-shape lives at `hull_llm::forge::build_forge_prove_poke`, separately from the vesl-core name. No collision. Original finding kept verbatim below.

- **Scope:** `[vesl-core]`
- **Paths:**
  - `crates/vesl-core/src/forge.rs:136` — `pub fn build_forge_prove_poke(payload: &ForgePayload) -> NounSlab`
  - `crates/vesl-core/src/graft_pokes/forge.rs:21` — `pub fn build_forge_prove_poke(hull: u64, note_id: u64, data: &[u8]) -> NounSlab`
  - `crates/vesl-core/src/lib.rs:90` — `pub use graft_pokes::forge::build_forge_prove_poke;` (chooses graft_pokes flavor for the top-level re-export)
- **Snippet:**
  ```rust
  // crates/vesl-core/src/forge.rs:136
  pub fn build_forge_prove_poke(payload: &ForgePayload) -> NounSlab {
      build_forge_poke("prove", payload)
  }
  // crates/vesl-core/src/graft_pokes/forge.rs:21
  pub fn build_forge_prove_poke(hull: u64, note_id: u64, data: &[u8]) -> NounSlab {
      ...
  }
  ```
- **Why flagged:** Two functions with the exact same name live at `vesl_core::forge::build_forge_prove_poke` and `vesl_core::graft_pokes::forge::build_forge_prove_poke`. They take different argument shapes (`&ForgePayload` vs `(u64, u64, &[u8])`) and produce different noun layouts (multi-leaf payload vs single-leaf hull/note_id/data). lib.rs:90 re-exports the graft_pokes flavor as `vesl_core::build_forge_prove_poke`, so the public top-level name is unambiguous — but the module-path name is. A caller writing `use vesl_core::forge::*` lands on a function that *looks* like the same one they read about in the README but produces an incompatible noun shape. The two shipped tests (forge.rs `tests::build_forge_prove_poke_produces_cell` at line 213 and graft_pokes/forge.rs `tests::build_forge_prove_poke_emits_nonempty_jam` at line 38) sit in different files but share enough naming overlap that a `cargo test build_forge_prove_poke` runs both and obscures which one is failing.
- **Recommendation:** Rename one. The graft_pokes flavor is the one re-exported at the crate root, so the natural rename targets the `forge.rs` one — e.g., `build_forge_prove_poke_payload` (matches its `&ForgePayload` argument). If hull-llm is the only external caller of the `forge.rs` flavor (it is — see §1.1), the rename is a one-commit fix here plus a one-commit fix on hull-llm.

### 1.4 `protocol/lib/vesl-entrypoint.hoon` — referenced only by tests, never imported by a shipped kernel

- **Scope:** `[vesl-core]`
- **Path:** `protocol/lib/vesl-entrypoint.hoon` (33 lines)
- **Snippet:**
  ```
  ++  vesl-entrypoint
    |=  payload=@
    ^-  [id=@ hull=@ root=@ state=[%settled ~]]
    =/  raw=*  (cue payload)
    =/  args=settlement-payload  ;;(settlement-payload raw)
    (settle-note note.args mani.args expected-root.args)
  ```
- **Why flagged:** Added in commit `fe3d64b templates: add canonical vesl entry-point (option 3)` as the canonical ABI boundary, but `rg '/\+ +\*vesl-entrypoint'` across `protocol/lib/*.hoon`, `kernels/`, and `hoon/app/` returns only `protocol/tests/{cross-vm,test-entrypoint}.hoon`. No shipped kernel, graft, or app.hoon imports it. The library's README (`protocol/lib/README.md:18`) lists it among support libraries but nothing wires it up.
- **Recommendation:** Either (a) wire `vesl-entrypoint` into `vesl-kernel.hoon` (replacing the inline cue+sieve+settle chain in `handle-settle` / `handle-prove`) so the "canonical" claim has a real consumer; or (b) tag it `:: STAGED:` in the file header and the README so future audits know it's intentional placeholder. Cross-references `[[feedback_placeholders_keep]]` — if the user wants this preserved as a future-canonical placeholder, option (b) suffices; if not, wire it through. The current "added but not adopted" state will silently rot.

---

## 2. Duplication

### 2.1 `vesl-test` crate re-implements vesl-core's poke builders — hull-id panic risk

- **Scope:** `[vesl-nockup]`
- **Paths:**
  - `test/vesl-test/src/lib.rs:222-230` — `build_register_poke(hull: u64, root: &Tip5Hash) -> NounSlab`
  - `test/vesl-test/src/lib.rs:233-240` — `build_payload_poke(verb: &str, payload: &[u8]) -> NounSlab`
  - `test/vesl-test/src/lib.rs:245-260` — `jam_graft_payload(note_id, hull, root, data) -> Vec<u8>`
- **Snippet (vesl-test):**
  ```rust
  // test/vesl-test/src/lib.rs:222-230
  pub fn build_register_poke(hull: u64, root: &Tip5Hash) -> NounSlab {
      let mut slab = NounSlab::new();
      let tag = make_tag_in(&mut slab, "settle-register");
      let root_bytes = tip5_to_atom_le_bytes(root);
      let root_atom = make_atom_in(&mut slab, &root_bytes);
      let poke = T(&mut slab, &[tag, D(hull), root_atom]);
      slab.set_root(poke);
      slab
  }
  ```
  Compare with `crates/vesl-core/src/graft_pokes/settle.rs:37-46`:
  ```rust
  pub fn build_settle_register_poke(hull: u64, root: &Tip5Hash) -> NounSlab {
      let mut slab = NounSlab::new();
      let tag = make_tag_in(&mut slab, "settle-register");
      let hull_noun = atom_from_u64(&mut slab, hull);  // <-- DIRECT_MAX-safe
      let root_bytes = tip5_to_atom_le_bytes(root);
      let root_noun = make_atom_in(&mut slab, &root_bytes);
      let poke = T(&mut slab, &[tag, hull_noun, root_noun]);
      slab.set_root(poke);
      slab
  }
  ```
- **Why flagged:** vesl-test's `build_register_poke` uses `D(hull)` directly (line 227), which **panics** when `hull > DIRECT_MAX = 2^63-1` — exactly the failure mode vesl-core's `atom_from_u64` exists to prevent (see `crates/vesl-core/src/graft_pokes/settle.rs:43` and the regression test `large_hull_id_does_not_panic` at line 429). The vesl-test version was written when only small hull-ids were used in test harnesses, but `vesl-test::jam_graft_payload` line 252 has the same issue (`T(&mut slab, &[D(note_id), D(hull), ...])`). Hash-derived hulls routinely exceed DIRECT_MAX (per the comment at vesl-core graft_pokes/settle.rs:60 "settled note IDs are usually `hash-leaf(jam(payload))` which exceeds `DIRECT_MAX`"). Any vesl-test caller passing a hash-derived hull/note_id crashes the test harness instead of failing the actual assertion.
- **Recommendation:** Replace `vesl-test::build_register_poke` with a direct call to `vesl_core::build_settle_register_poke`, and `vesl-test::build_payload_poke` with the `vesl_core::build_settle_*_poke` family (the verb-tag dispatch is already there as a closure-builder pair `build_settle_note_poke_with_data` / `build_settle_verify_poke_with_data`). `vesl-test::jam_graft_payload` should be replaced with the private `build_graft_single_leaf_payload_in` at `graft_pokes/settle.rs:350` — promote it to `pub(crate)` then `pub` and re-export under `vesl_core::graft_pokes::settle::build_graft_single_leaf_payload`. Net effect: removes ~40 lines from vesl-test, fixes the latent panic, and keeps the noun-layout convention single-sourced.

### 2.2 Mule-wrap cue+sieve preamble — same 5-line block at 5 kernel sites

- **Scope:** `[vesl-core]`
- **Paths:**
  - `protocol/lib/vesl-kernel.hoon:80-83` (`handle-settle`)
  - `protocol/lib/vesl-kernel.hoon:103-106` (`handle-prove`)
  - `protocol/lib/settle-kernel.hoon:93-96` (`%settle`)
  - `protocol/lib/settle-kernel.hoon:118-121` (`%verify`)
  - `protocol/lib/guard-kernel.hoon:87-90` (`%verify`)
- **Snippet (representative — `vesl-kernel.hoon:80-83`):**
  ```
  =/  parsed
    %-  mule  |.
    =/  raw=*  (cue payload.act)
    ;;(settlement-payload raw)
  ?:  ?=(%| -.parsed)
    ~>  %slog.[3 'vesl: malformed settle payload']
    ...
  ```
- **Why flagged:** The five sites differ only in the slog label (`vesl:` / `settle:` / `guard:`), the failure-effect tag (`[%settle-error 'vesl: malformed payload']` vs `[%verified %.n]`), and whether `?=(%| -.parsed)` returns `[~ state]` or emits an effect first. The structural pattern — `mule .|. cue/sieve` followed by `?:  ?=(%| -.parsed)` branch — is identical. The §2.4 fix in the prior audit (`validate-settlement-args`) factored the *post-parse* settlement-guard chain into `kernel-arms.hoon`; this finding sits one step earlier in the pipeline.
- **Recommendation:** Add `++parse-payload` to `kernel-arms.hoon`:
  ```
  ++  parse-payload
    |=  [payload=@ label=@t]
    ^-  $%  [%.y args=settlement-payload]
            [%.n msg=@t]
        ==
    =/  parsed
      %-  mule  |.
      =/  raw=*  (cue payload)
      ;;(settlement-payload raw)
    ?:  ?=(%| -.parsed)
      ~>  %slog.[3 (rap 3 ~[label ' malformed payload'])]
      [%.n (rap 3 ~[label ' malformed payload'])]
    [%.y p.parsed]
  ```
  Each kernel arm collapses its preamble to one line + the existing branch on `[%.y _]` / `[%.n _]`. The slog/error split between mutate and read-only modes already lives in `validate-settlement-args` next door — this is the natural companion arm. Caveat: the mode-dependent failure shape ([%verified %.n] vs [%settle-error msg]) stays at the kernel site; the helper only owns the parse step.

### 2.3 Templates' `build.rs` files — three identical, four near-identical-with-drift

- **Scope:** `[vesl-core]`, `[vesl-nockup]` (mirrored via sync.sh — same drift in both)
- **Paths:**
  - `templates/{counter,data-registry,settle-report}/build.rs` (84 lines each — byte-identical via `diff counter/build.rs data-registry/build.rs`)
  - `templates/{graft-mint,graft-settle,graft-hash-gate,graft-intent}/build.rs` (75-90 lines — `diff graft-mint/build.rs graft-hash-gate/build.rs` shows 3 comment-only diffs: a `manifest-changes` rerun-if-changed comment, a `$NOCK_HOME for tip5 resolution` comment, and the full `Drift-detection codegen` docblock)
- **Snippet (the divergent comment from `graft-mint/build.rs:11-12` that the other three siblings lack):**
  ```rust
      // Manifest changes affect the generated kernel_cause_tags.rs;
      // re-run when any .toml under hoon/lib/ moves.
      println!("cargo:rerun-if-changed=hoon/lib");
  ```
- **Why flagged:** The graft templates' build.rs files do effectively the same job (compile `hoon/app/app.hoon` via `hoonc`, then emit `kernel_cause_tags.rs` via `graft-inject codegen kernel-cause-tags`), with only minor differences in `rerun-if-changed` watch paths and explanatory comments. A reviewer who fixes a real issue in one (say, the `cargo:warning=` wording or the codegen failure handling) must remember to apply the same edit to the other three. The committed state already shows partial drift: `graft-mint/build.rs` was updated with more context comments than `graft-settle/build.rs`, `graft-hash-gate/build.rs`, and `graft-intent/build.rs`. Same drift survives the sync into vesl-nockup (sync.sh copies, doesn't rewrite — except for the `graft-inject` → `nockup-graft` strings).
- **Recommendation:** Since templates are intentionally standalone (CLAUDE.md §"Rust Dependencies": "[templates] each declares its own deps directly so end-users can copy a template out and build it standalone"), a shared crate import won't work. Two options: (a) make this drift loud — add a CI lint that asserts the `emit_kernel_cause_tags` function body is byte-identical across all `templates/graft-*/build.rs`; or (b) pick one template (graft-mint, the most-commented) as the canonical and have a `scripts/check-template-buildrs-drift.sh` that diffs the others against it, flagging the explanatory-comment delta as drift. Option (b) is the smaller change and the natural companion to `scripts/check-jam.sh`. Whichever route, the count is 7 files where the cargo+codegen logic should stay synced — manually impractical past four.

### 2.4 `graft-settle/src/main.rs` hand-assembles NounSlab plumbing that the SDK now collapses

- **Scope:** `[vesl-core]`, `[vesl-nockup]` (same logic in both — synced)
- **Paths:**
  - `templates/graft-settle/src/main.rs:113-166` (~50 lines of hand-rolled note + payload + jam assembly, duplicated again at 142-166 for the replay test)
  - `templates/vesl/src/main.rs:23-31` (the same lifecycle in 8 lines using `vesl_core::{build_settle_register_poke, build_settle_note_poke}`)
- **Snippet (graft-settle/src/main.rs:113-138 — the hand-rolled `%settle-note` poke):**
  ```rust
  {
      let mut slab = NounSlab::new();
      let rb = tip5_to_atom_le_bytes(&single_root);
      let note_id = D(1);
      let note_hull = D(settle_hull);
      let note_root = make_atom_in(&mut slab, &rb);
      let pending_tag = make_tag_in(&mut slab, "pending");
      let state = T(&mut slab, &[pending_tag, D(0)]);
      let note = T(&mut slab, &[note_id, note_hull, note_root, state]);
      let data = make_atom_in(&mut slab, reports[0].1.as_bytes());
      let exp_root = make_atom_in(&mut slab, &rb);
      let payload_noun = T(&mut slab, &[note, data, exp_root]);
      let payload_bytes = {
          let mut stack = new_stack();
          jam_to_bytes(&mut stack, payload_noun)
      };
      let jammed = make_atom_in(&mut slab, &payload_bytes);
      let tag = make_tag_in(&mut slab, "settle-note");
      let poke = T(&mut slab, &[tag, jammed]);
      slab.set_root(poke);
      let effects = app.poke(SystemWire.to_wire(), slab).await?;
      print_effects(&effects, "settle-note");
  }
  ```
  Equivalent in vesl/src/main.rs:31:
  ```rust
  poke(&mut app, build_settle_note_poke(1, 1, &root, items[0])).await?;
  ```
- **Why flagged:** The graft-settle template predates `build_settle_note_poke` and hand-assembles every byte of the graft-payload noun. The `vesl` template (added in commit `fe3d64b`) demonstrates the modern SDK pattern at 1/6 the line count. The graft-settle template is now actively misleading — a new user reading it learns that "settling a note" requires 50 lines of NounSlab plumbing when the SDK collapses it to one. Worse, `D(note_id)` / `D(note_hull)` at line 117-118 reproduces the §2.1 DIRECT_MAX panic risk. The same hand-assembly recurs at lines 142-166 for the replay test.
- **Recommendation:** Update `templates/graft-settle/src/main.rs` to use `build_settle_register_poke` + `build_settle_note_poke` from `vesl_core`. Drop the `make_atom_in`/`make_cord_in`/`make_tag_in`/`new_stack`/`jam_to_bytes` imports along with the bytes they assemble. Net delta: ~60 lines removed, footgun closed, template stays educational on the *lifecycle* (commit → register → settle → replay-reject → tampered-verify) without making the reader memorize the noun shape. The Mint+Guard parts of the file (the local Merkle commitment and proof-check loop) are still worth keeping verbatim — those are the genuinely instructive parts.

### 2.5 Carried — kernel-JAM triplet, register-poke fan-out, %register kernel arms, graft skeleton

- **Scope:** `[vesl-core]`
- **Recap (full text in `MAINTENANCE_AUDIT_LOG_2026-05-11.md` §§2.1, 2.2, 2.3, 2.5):**
  - **§2.1** `kernels/{guard,mint,settle}/src/lib.rs` + `build.rs` still byte-identical apart from labels. Six files, ~150 lines.
  - **§2.2** `build_*_poke` fan-out across 14+ functions in `graft_pokes/*.rs` — same `NounSlab::new → make_tag_in → encode args → T → set_root` template. No `build_tagged_poke<F>` helper introduced yet.
  - **§2.3** %register arms still copy-pasted across four kernels — though the *body* now routes through `kernel-arms::handle-register` (closed). The arm's dispatch shell (`?-  -.u.act ... %register ...`) and the per-kernel surrounding `[~ state]` plumbing remain duplicated; not worth a separate finding now that the body is shared.
  - **§2.5** Hoon graft skeleton — 9 grafts still share the `state + cap + effect-union + cause-union + poke + peek` shape; `apply-<graft>` wet-gates in `domain-patterns.hoon` add a thin polymorphism layer but the per-graft *skeleton* is still hand-rolled.
- **Why retained:** None of these were addressed in the 2026-05-11 → 2026-05-13 window. The §6.1 macro-crate proposal in the prior audit is still the right framing for §2.1; §2.2 still needs the closure-helper; §2.5 still benefits from the shared `cap` constant. No new evidence changes the prior recommendations.

---

## 3. Overly Complex Code

### 3.1 `vesl-kernel.hoon ++poke` — addressed; per-cause `handle-*` arms now live, dispatcher is a 9-line selector

- **Scope:** `[vesl-core]`
- **Recap (full text in `MAINTENANCE_AUDIT_LOG_2026-05-11.md` §3.1):** The 288-line `?-` switch was split into per-cause `handle-*` arms in commit `19d6ce1`, and STARK input prep moved to `vesl-stark.hoon` in the same commit. `++poke` is now the 9-line dispatcher at `vesl-kernel.hoon:241-258`. The complexity finding from 2026-05-11 is closed.
- **What remains:** `handle-prove` at `vesl-kernel.hoon:98-129` still mixes the STARK call (`prove-computation`) and the result-bytes packing in one arm. If the prover ever grows a second mode (multi-leaf, parametric formula, gate-specific subject prep), this arm will become the next over-stuffed one. Not a current issue; flag for revisit if `handle-prove` accumulates further conditional logic.

### 3.2 Carried — `graft-inject/src/main.rs` 6422-line single file

- **Scope:** `[vesl-nockup]`
- **Status:** Resolved on 2026-05-12 — see `MAINTENANCE_AUDIT_LOG_2026-05-11.md` §3.2 and §6.2. Split into 9 modules (`lib.rs`, `manifest.rs`, `gates.rs`, `marker.rs`, `inject.rs`, `codegen.rs`, `lint.rs`, `cli.rs`, `util.rs`, plus `test_support.rs` extracted in POST_GRAPH §1.1 and per-module test relocations in POST_GRAPH §§1.2a-c, 1.3). Largest current file: `inject.rs` at 1,598 lines (production code; tests already moved out per POST_GRAPH §1.2a), `lint.rs` at 1,428, `codegen.rs` at 1,106, `cli.rs` at 1,059. All under the working-memory threshold the prior finding flagged. No new complexity issue introduced by the split.

### 3.3 `sync.sh` — undocumented "intentionally skipped" libraries

- **Scope:** `[vesl-nockup]`
- **Path:** `sync.sh:127-166`
- **Snippet:** The Hoon lib copy block enumerates 33 files but does not copy `kernel-arms.hoon` or `vesl-stark.hoon` (both new in vesl-core commits `8cb5098` / `19d6ce1`). The script has no comment explaining the omission.
- **Why flagged:** Both `kernel-arms.hoon` (65 lines) and `vesl-stark.hoon` (86 lines) are imported only by the four kernel libraries (`{guard,mint,settle,vesl}-kernel.hoon`) — which `sync.sh` also doesn't copy, because vesl-nockup users compose grafts into their own `app.hoon` and never recompile a kernel from source. The omission is correct, but a future maintainer running `diff <(ls vesl-core/protocol/lib/) <(ls vesl-nockup/hoon/lib/)` will see the gap and reach for the "obviously missing — add to sync.sh" fix that breaks nothing today but inflates the bundle and ships kernel-private internals to template authors. The same logic explains why `forge-kernel.hoon`, `guard-kernel.hoon`, `mint-kernel.hoon`, `settle-kernel.hoon`, `vesl-kernel.hoon`, `vesl-entrypoint.hoon`, `vesl-mint.hoon`, `vesl-stark-verifier.hoon`, `vesl-test.hoon`, `vesl-verifier.hoon`, and `rag-logic.hoon` are skipped — none have an explanatory comment either.
- **Recommendation:** Add a comment block above `sync.sh:127` listing the kernel-private libraries (kernel-arms, vesl-stark, rag-logic, vesl-mint, all `*-kernel.hoon`, vesl-stark-verifier, vesl-verifier, vesl-test) and explaining that they're consumed only by the kernel families vesl-nockup doesn't ship. One paragraph, eight bulleted file names. Saves the next maintainer (or audit) a 30-minute "is this a sync bug?" detour.

---

## 4. Comment Bloat

### 4.1 `vesl-nockup/sync.sh` — AUDIT-2026-04-19 inline references are durable but verbose

- **Scope:** `[vesl-nockup]`
- **Path:** `sync.sh:84-109`, `sync.sh:174-182`
- **Snippet:**
  ```bash
  # sync.sh:84-94
  # AUDIT 2026-04-19 M-21: refuse to run when source and destination
  # resolve to the same real path. `rm -rf $here/hoon/common` followed
  # by `cp -rL` would otherwise self-nuke the repo. Cheap check; the
  # resolved paths are stable across the script's lifetime. Apply the
  # same check to the vesl-wallet-repo arg.
  if [[ "$(realpath "$here" 2>/dev/null)" == "$(realpath "$vesl" 2>/dev/null)" ]]; then
      ...
  ```
- **Why flagged:** The AUDIT-2026-04-19 reference comments at `sync.sh:84-94`, `sync.sh:102-109`, and the M-21 callouts collectively carry ~30 lines of incident context for a defensive check that is, in itself, 5 lines of bash. The pattern follows CLAUDE.md §"Explain the traps" (the `rm -rf` self-nuke risk is genuinely non-obvious), but the audit-ID format ("AUDIT 2026-04-19 M-21") is the same kind of phase-N reference that CLAUDE.md §"Don't reference the current task" warns against in code comments — fine for commit messages and PRs, but as inline file comments they age into "what's M-21 again?" lookups. The two M-21 callouts duplicate each other 18 lines apart (sync.sh:84-89 and 102-109 both narrate the symlink-flatten safety story).
- **Recommendation:** Compress to one short block: keep the "refuse to run when source and dest resolve to the same path" guard at the top with a single-line comment ("guard against `rm -rf $here/...` self-nuking when src/dest collide"), and consolidate the symlink-flattening narrative at lines 102-109 with the matching `cp -rL` note at line 218 into one explanation, not two. Strip the "AUDIT 2026-04-19 M-21" labels — the rationale is in the git history; the inline comment can name the *invariant*, not the audit lineage. ~15 lines compressed to ~5.

---

## 5. Efficiency / Maintenance

### 5.1 `vesl-nockup/.github/workflows/ci.yml` env pins are stale relative to `sync.sh` defaults and committed `.sync-pins.toml`

- **Scope:** `[cross-repo]` (CI workflow lives in vesl-nockup; the pin lineage spans vesl-core's commit history)
- **Paths:**
  - `vesl-nockup/.github/workflows/ci.yml:13-15` — workflow-level env
  - `vesl-nockup/sync.sh:37,43` — script defaults
  - `vesl-nockup/.sync-pins.toml:5,9` — committed bundle pin record
- **Snippet (the disagreement):**
  ```yaml
  # vesl-nockup/.github/workflows/ci.yml:13-15
  env:
    NOCK_PIN: c51f8040457de1c7d799de6024c4b22275371cf4
    VESL_CORE_PIN: 19d6ce10ad837665f56bd6dd1d76cd3e6b2a7d0e
  ```
  ```bash
  # vesl-nockup/sync.sh:37,43
  NOCK_PIN="${NOCK_PIN:-1a23ccdabf3f8909bf7c7966c48edc36cbf91a66}"
  VESL_CORE_PIN="${VESL_CORE_PIN:-c4ca118b5e8478e1d3c3f121f0b876f0891aef31}"
  ```
  ```toml
  # vesl-nockup/.sync-pins.toml
  [vesl-core]
  pin  = "c4ca118b5e8478e1d3c3f121f0b876f0891aef31"
  [nockchain]
  pin  = "1a23ccdabf3f8909bf7c7966c48edc36cbf91a66"
  ```
- **Why flagged:** GitHub Actions exposes workflow-level `env:` to all step shells. When the `sync-verify` job (`ci.yml:21-44`) invokes `./sync.sh --verify "$GITHUB_WORKSPACE/vesl-core" ...`, sync.sh's `${NOCK_PIN:-default}` resolves to the workflow env value (`c51f8040…`) — overriding the script default (`1a23ccd…`). sync.sh then runs the bundle into a temp dir, regenerates `.sync-pins.toml` with the workflow-pinned NOCK_PIN, and diffs against the committed `.sync-pins.toml` (which records `1a23ccd…`). **Diff mismatches → exit 1 → sync-verify fails.** The vesl-core checkout step (`ci.yml:29-33`) uses the workflow's `VESL_CORE_PIN: 19d6ce10…` as `ref:` — so the checked-out tree is `19d6ce10`, not the `c4ca118` that the script defaults to and that the committed pins record. sync.sh's pin-check (`sync.sh:65-75`) will pass (`vesl_head == VESL_CORE_PIN` from env), then the verify step (`sync.sh:336-356`) will fail on the regenerated `.sync-pins.toml` mismatch. CI has run zero times so far (`gh api repos/zkvesl/vesl-nockup/actions/runs` → `total_count: 0`) — this is a latent first-run failure.
- **Recommendation:** Bump `ci.yml:13-15` to match the current committed pins:
  ```yaml
  env:
    NOCK_PIN: 1a23ccdabf3f8909bf7c7966c48edc36cbf91a66
    VESL_CORE_PIN: c4ca118b5e8478e1d3c3f121f0b876f0891aef31
  ```
  Two-line edit. Better still: add a CI step that asserts `ci.yml env.NOCK_PIN == grep '^NOCK_PIN=' sync.sh | head -1` so future pin bumps in sync.sh fail loudly when the workflow env wasn't bumped in lockstep — pure mechanical check, no policy. The structural fix is to make the workflow read pins from `.sync-pins.toml` directly (single source of truth) and drop the workflow env-vars entirely; that's a 5-line refactor but a real seam improvement.

### 5.2 `templates/README.md` and `templates/GRAFTING.md` not synced; sync.sh copies `docs/graft-manifest.md` but not these

- **Scope:** `[cross-repo]`
- **Paths:**
  - `vesl-core/templates/README.md` (12K, walks through counter / data-registry / settle-report)
  - `vesl-core/templates/GRAFTING.md` (15K, the "how to graft mint onto your nockapp" walkthrough — explicitly addresses both `nockup` users and Docker integrators)
  - `vesl-nockup/sync.sh:201-207` (`docs/graft-manifest.md` is mirrored; the two template-level docs aren't)
- **Snippet (what's actually copied today — `sync.sh:201-207`):**
  ```bash
  # --- Docs ---
  # Manifest schema lives in vesl/docs/graft-manifest.md (canonical).
  # Mirror it into vesl-nockup so the README's Reference link resolves
  # without the consumer needing access to the private vesl repo.
  echo "  docs (manifest schema)"
  mkdir -p "$here/docs"
  cp "$vesl/docs/graft-manifest.md" "$here/docs/"
  ```
- **Why flagged:** `templates/README.md` is the entry-point document for anyone wandering into the `templates/` directory — it explains which template solves which pain point. `templates/GRAFTING.md` explicitly addresses both nockup workflows ("nockup users: install via `nockup package add zkvesl/vesl-graft` ...") and Docker workflows. Both target vesl-nockup's user base more directly than vesl-core's, yet sync.sh leaves them behind. End users who pull a single template via `nockup` and then visit the vesl-nockup repo see the templates without the orientation docs and have to scroll up to the repo-root README for context.
- **Recommendation:** Either extend sync.sh's docs block to copy both files (`cp "$vesl/templates/README.md" "$here/templates/README.md"` + `cp "$vesl/templates/GRAFTING.md" "$here/templates/GRAFTING.md"`), or leave them in vesl-core and add a `templates/README.md` to vesl-nockup that's a `Other docs at github.com/zkvesl/vesl-core/templates/` redirect. The first option is two lines and keeps the docs single-source-of-truth in vesl-core; preferred.

### 5.3 `templates/graft-scaffold/Cargo.toml` won't pass CI's `templates-check` job

- **Scope:** `[vesl-nockup]` (the failure surfaces in vesl-nockup's CI; the underlying path-dep convention is shared with vesl-core)
- **Paths:**
  - `vesl-nockup/templates/graft-scaffold/Cargo.toml:12-15,35-36`
  - `vesl-nockup/.github/workflows/ci.yml:71-105` (the `templates-check` job)
- **Snippet (`vesl-nockup/templates/graft-scaffold/Cargo.toml:11-16`):**
  ```toml
  [dependencies]
  # NockVM — adjust paths to your nockchain clone
  nockapp = { path = "../../nockchain/crates/nockapp", default-features = false }
  nockvm = { path = "../../nockchain/crates/nockvm/rust/nockvm" }
  nockvm_macros = { path = "../../nockchain/crates/nockvm/rust/nockvm_macros" }
  zkvm-jetpack = { path = "../../nockchain/crates/zkvm-jetpack" }
  ```
  `cargo check --manifest-path templates/graft-scaffold/Cargo.toml` from `vesl-nockup/`:
  ```
  error: failed to load source for dependency `ibig`
  Caused by:
    unable to update /home/sobchek/projects/nockchain/vesl-nockup/nockchain/crates/nockvm/rust/ibig
  Caused by:
    failed to read `/home/sobchek/projects/nockchain/vesl-nockup/nockchain/crates/nockvm/rust/ibig/Cargo.toml`
  ```
- **Why flagged:** The template's path-deps resolve relative to the manifest's own directory: from `templates/graft-scaffold/`, `../../nockchain/...` → `vesl-nockup/nockchain/...`. No such directory exists in vesl-nockup, in vesl-core (where `../../nockchain/` would equal `vesl-core/nockchain/`), or in CI's layout (where nockchain is at `$GITHUB_WORKSPACE/nockchain/`, not under vesl-nockup). The "adjust paths" comment at line 11 acknowledges this — graft-scaffold is the template where end users do the path-fixup manually after copying it out. CI's `templates-check` (`ci.yml:71-105`) has a Jinja-placeholder skip (handles `templates/vesl/Cargo.toml`'s `{{project_name}}`), but no skip for graft-scaffold's non-resolving path-deps:
  ```bash
  for dir in templates/*/; do
    if [ -f "$dir/Cargo.toml" ]; then
      if grep -q '{{' "$dir/Cargo.toml"; then
        ... skip ...
      fi
      (cd "$dir" && cargo check)
    fi
  done
  ```
  First CI run executes `cd templates/graft-scaffold && cargo check` and fails as above. Zero workflow runs exist on GitHub yet, so this hasn't been observed.
- **Recommendation:** Pick the same path the Jinja skip uses — a Cargo.toml marker the CI loop greps for. Two reasonable shapes:
  1. Add a leading comment in `graft-scaffold/Cargo.toml`: `# ci: skip-template-check (path-deps require user fixup)`, then have ci.yml's loop `grep -q '^# ci: skip-template-check' "$dir/Cargo.toml"` and `continue` before the cargo invocation. Two-line ci.yml change, one comment in graft-scaffold.
  2. Rewrite graft-scaffold's path-deps to the same `git = "https://github.com/nockchain/nockchain.git", rev = "$NOCK_PIN"` shape sync.sh uses for the deeper templates. The "adjust paths to your nockchain clone" comments stay as a *secondary* instruction ("or use a local clone, like this:"). End users who want offline builds edit; default builds work standalone.
  Option (1) is the smaller change and preserves the "graft-scaffold ships ready to be copy-and-edited" semantics. Option (2) is the more honest fix — the template that ships with non-resolving path-deps in its default state is itself a footgun, especially since the comments at `Cargo.toml:11,17,32-34` walk through one specific path-fixup scenario only.

### 5.4 `cargo check` against `templates/vesl/Cargo.toml` errors locally — Jinja substitution isn't visible until scaffold time

- **Scope:** `[vesl-nockup]`
- **Path:** `templates/vesl/Cargo.toml:2,7` (the `{{project_name}}` placeholders)
- **Snippet:**
  ```
  $ cargo check --manifest-path templates/vesl/Cargo.toml
  error: invalid character `{` in package name: `{{project_name}}`
   --> templates/vesl/Cargo.toml:2:8
  ```
- **Why flagged:** Not a bug — CI's templates-check correctly skips this template via the `{{` grep. But the failure mode is real for any local hand-test or audit that runs `cargo check --manifest-path templates/*/Cargo.toml` without replicating the CI skip. The §5.3 fix proposed above (a Cargo.toml-marker convention) generalizes cleanly: a `# ci: skip-template-check` marker in `templates/vesl/Cargo.toml` (alongside or replacing the Jinja-placeholder detection) keeps the skip declarative rather than pattern-matched. The current Jinja detection is brittle to any future template that happens to use `{{` in a real string (e.g., a Rust closure with `{{` in a doc comment) — unlikely but not impossible. Move to an explicit marker.
- **Recommendation:** Combine with §5.3. Single marker comment convention covers both the graft-scaffold "needs user path fixup" case and the vesl "needs scaffolding-time substitution" case.

### 5.5 Carried — `kernel-JAM triplet` not consolidated

- **Scope:** `[vesl-core]`
- **Status:** Unchanged from 2026-05-11 §6.1. The proposal (extract a `vesl-kernel-jam` crate exposing a declarative macro, collapse 9 files / ~150 lines to ~30 lines) still stands. The macro must preserve the `CARGO_MANIFEST_DIR.ancestors().nth(2)` lookup against the caller's manifest, not the macro-defining crate's.

---

## 6. File-Level Consolidation

### 6.1 Carried — `vesl-kernel-jam` macro crate (was §6.1 on 2026-05-11)

- **Scope:** `[vesl-core]`
- **Status:** Unimplemented. See `MAINTENANCE_AUDIT_LOG_2026-05-11.md` §6.1 for the full proposal (target layout, coupling snippet, quantified efficiency win). The work delta is unchanged: 9 files (3 manifests + 3 build scripts + 3 libs) collapse to ~30 lines via macro embedding; one new shared crate; each kernel crate stays its own compile unit so `CARGO_MANIFEST_DIR.ancestors().nth(2)` keeps resolving correctly.

### 6.2 Carried (resolved) — `graft-inject/src/main.rs` split

- **Scope:** `[vesl-nockup]`
- **Status:** Resolved 2026-05-12 in commits `22bf3ee..6bafcbd` plus the POST_GRAPH test-relocation series (`feb72d4..537c4f8`). See `MAINTENANCE_AUDIT_LOG_2026-05-11.md` §6.2 for the original framing. No regressions detected; the largest current file is `inject.rs` at 1,598 lines (production code only — tests already relocated per POST_GRAPH §1.2a).

### 6.3 New — `templates/graft-{mint,settle,hash-gate,intent}/build.rs` near-identical → consider a shared "check + dispatch" reference

- **Scope:** `[vesl-core]`, `[vesl-nockup]` (synced)
- **Paths involved:**
  - `templates/graft-mint/build.rs` (90 lines)
  - `templates/graft-settle/build.rs` (80 lines)
  - `templates/graft-hash-gate/build.rs` (78 lines)
  - `templates/graft-intent/build.rs` (78 lines)
- **`sync.sh` impact:** sync.sh's only template build.rs transform is `s/graft-inject/nockup-graft/g`. A consolidation that touched the build.rs *shape* would need sync.sh to apply the matching shape transform on each copy — manageable, but the simpler answer is "don't consolidate the files, audit their identity."
- **Proposed target layout:** Don't physically merge — templates need to ship standalone. Instead add `scripts/check-template-buildrs-drift.sh` (vesl-core) that diffs the four graft templates' `build.rs` files and reports the comment-only diffs as "intentional but please reconcile" warnings. A single canonical (graft-mint) gets the "explanatory" version; the others should match modulo the per-template `rerun-if-changed` paths. CI can run this as a soft check.
- **Coupling snippet (the comment delta — `graft-mint/build.rs:11-12` vs the other three):**
  ```rust
  // graft-mint/build.rs:11-12
      // Manifest changes affect the generated kernel_cause_tags.rs;
      // re-run when any .toml under hoon/lib/ moves.
  ```
  graft-settle/graft-hash-gate/graft-intent omit this comment but have an identical `rerun-if-changed=hoon/lib` line that the comment describes — informational drift, not behavior drift.
- **Quantified efficiency win:**
  - **Files-touched-per-change:** today, a real fix (e.g., the `cargo:warning=` wording or how `emit_kernel_cause_tags` handles graft-inject-missing) requires 4 edits. With the check-script in place, the second-touch-onward becomes mechanical: edit graft-mint, run the script, mirror the diff.
  - **Line-count delta:** ~0 — the consolidation is *audit-only*, not file-level.
  - **Compile-unit delta:** 0 — no change.
  - **Risk:** the four templates have *intentional* per-template `rerun-if-changed` entries (graft-mint watches `rag-logic.hoon` + `vesl-merkle.hoon` + `sur/vesl.hoon`; graft-hash-gate doesn't). The check script must whitelist that delta. Spec the diff narrowly.
  - **Cross-reference §2.3** — same problem, different framing. §2.3 frames it as a duplication finding asking for *some* enforcement mechanism; this §6.3 entry proposes the specific lint-script form.

---

## Previously flagged (2026-05-11), now resolved

The following 2026-05-11 findings are confirmed closed by the current state of the code (verified by re-running the relevant cargo / grep / diff probes against `parametize-3` branch HEAD `c4ca118`):

- **2026-05-11 §1.1** `settle::build_register_poke` orphan — removed in commit `50d95cf`. **Side-effect flagged below**: hull-llm's e2e tests still import `vesl_core::settle::build_register_poke` (10 sites across `tests/e2e_core.rs`, `tests/e2e_forge.rs`) and will fail to compile against the new vesl-core. Hull-llm is out of scope for this audit, but the cross-repo break is real and worth noting for the next hull-llm bump. The non-test references in hull-llm (`src/{api,main,noun_builder}.rs`) all use `noun_builder::build_register_poke` (the surviving canonical name) and are fine.
- **2026-05-11 §1.2** `graft-inject` double-bin warning — closed in `22bf3ee`/`0deeaa5` (explicit `[lib]` + `[[bin]] path = src/bin/nockup-graft.rs` shim). Cargo no longer warns.
- **2026-05-11 §2.3** Hoon `%register` arms — bodies now route through `kernel-arms::handle-register` (commits `8cb5098`, `0bbb72f`, `4a31d5e`, `a03437b`). Per-arm dispatch shells still duplicated but minimally (~3 lines each).
- **2026-05-11 §2.4** Hoon settle/prove/verify guard block — factored into `kernel-arms::validate-settlement-args` (commit `8cb5098`); all five call sites adopted.
- **2026-05-11 §3.1** vesl-kernel ++poke 288-line dispatcher — split in commit `19d6ce1` (see §3.1 above for current state).
- **2026-05-11 §3.2** graft-inject 6422-line file — split in commits `22bf3ee..6bafcbd`. See §3.2 above.
- **2026-05-11 §4.1** vesl-kernel Horner/STARK narration — compressed in commit `5889c6e`; AUDIT blocks retained, narration trimmed.
- **2026-05-11 §4.2** graft-inject Phase-N comments — stripped in commit `9bb3a96` (verified `rg "Phase [0-9]" tools/graft-inject/src/*.rs` returns zero).
- **2026-05-11 §5.1** `tempfile::TempDir::into_path` deprecation — single-edit fix landed (verified by `cargo clippy --workspace --all-targets` from vesl-nockup → 0 own warnings).
- **2026-05-11 §5.2** `graft-inject` Cargo double-bin — same as §1.2 above.
- **2026-05-11 §5.4** vesl-nockup workspace missing `exclude = ["templates"]` — fixed (verified `Cargo.toml:14` now reads `exclude = ["templates"]`).
- **2026-05-11 §6.2** graft-inject thematic split — see §3.2 / §6.2 above.

## Previously flagged (2026-05-11), retained intentionally

Same project-context retention reasons as the 2026-04-24 audit; recorded so future audits don't re-litigate. Cross-referenced with `~/.claude/projects/.../memory/feedback_placeholders_keep.md`:

- **`intent-graft.hoon`** — still placeholder, all `++intent-poke` arms crash with `%intent-graft-placeholder`. Retain.
- **`build_vesl_*_poke` deprecated aliases** in `graft_pokes/settle.rs:283-315` and `lib.rs:84-87` — retained for one release cycle, per project context.
- **`IntentVerifier` alias** at `lib.rs:42` — retained for hull-llm's `FieldVerifier` impl which still imports it via `vesl_core::IntentVerifier`. Documented community-fork seam.
- **`%diag-cue` / `%diag-sieve` / `%diag-hash` arms** in `vesl-kernel.hoon` (now `handle-diag-cue`, `handle-diag-sieve`, `handle-diag-hash` after the §3.1 split) — H-08 audit trail diagnostics. Retained.
- **`templates/graft-intent`** — family-5 placeholder Cargo + scaffold. The template itself is functional (compiles, crashes on intent pokes by design); the graft library it composes is the placeholder, not the template.

## Out of scope for this audit

- `hull-llm/` — prompt narrows scope to vesl-core + vesl-nockup. Hull-llm-specific findings (chain.rs duplication, query_handler / prove_handler retrieval-phase extraction, signing.rs verbatim copy) were not re-verified here. **The cross-repo break previously flagged here was fixed during this cycle**: `hull-llm/tests/e2e_core.rs:182` switched from `vesl_core::settle::build_register_poke` (deleted in vesl-core commit `50d95cf`) to `vesl_core::noun_builder::build_register_poke` (the surviving canonical). `hull-llm/tests/e2e_forge.rs:19-25` import block similarly updated to read `hull_llm::forge::{...}` + `vesl_core::types::{Note, NoteState}` as part of the §1.1 relocation. Both fixes are no-op against hull-llm's current pinned vesl-core (`ee88748`, which still has the old surface) but unblock the next pin bump.
- Security review beyond glaring red flags — prompt line 15. The latent panic in `vesl-test::build_register_poke` / `jam_graft_payload` (§2.1) is the only safety-adjacent finding; it's a test-only panic, not a production exposure, and crashes loud rather than producing incorrect results.
- Sister repos beyond the sync seam (zkvesl-docs, vesl-labs, vesl-agent, vesl-wallet source — except where sync.sh imports the wallet workspace into vesl-nockup, which is verified clean above).
- Branches other than the parametize-3 branch (vesl-core) and graft-inject-split branch (vesl-nockup) — both are the active heads at audit time. No probes ran against `main` or `dev` remote refs.
