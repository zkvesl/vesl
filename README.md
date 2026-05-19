# Vesl

A verification SDK for Nockchain. Four primitives — **mint** (commit), **guard** (verify), **settle** (on-chain), **forge** (STARK-prove) — each shipping as a Hoon kernel with a Rust facade in `vesl-core`, plus graft templates for adding them to an existing NockApp.

Grafts in Vesl fall into five families: **commitment** (shipped), **verification gates** (scaffolded library), **state** (planned), **behavior** (planned), and **intent** (placeholder, pending canonical upstream). The priority lattice in [`docs/graft-manifest.md`](docs/graft-manifest.md) is the authoritative map; the summary below groups the current primitive list the same way.

For the LLM/RAG reference implementation (ingest, retrieve, Ollama, on-chain settlement), see [zkvesl/hull-llm](https://github.com/zkvesl/hull-llm).

The repo name reflects its flagship Rust crate. Alongside `vesl-core` this tree ships `nock-noun-rs`, `nockchain-tip5-rs`, `nockchain-client-rs`, the `hull` harness, the Hoon kernels, and the graft templates.


## Structure

```
protocol/                       Hoon source
  lib/                            grafts + kernels, grouped by family
    mint-kernel.hoon                family 1 — commit data → root
    guard-kernel.hoon               family 1 — verify inclusion proofs
    settle-kernel.hoon              family 1 — on-chain settlement
    forge-kernel.hoon               family 1 — STARK-prove arbitrary computation
    mint-graft.hoon                 family 1 — mint composition (priority 20)
    guard-graft.hoon                family 1 — guard composition (priority 30)
    settle-graft.hoon               family 1 — settle composition (priority 10)
    forge-graft.hoon                family 1 — forge composition (priority 40)
    intent-graft.hoon               family 5 — placeholder (priority 200, crashes on invocation)
    vesl-merkle.hoon                tip5 Merkle math
    vesl-prover.hoon                STARK proof generation
    vesl-verifier.hoon              STARK proof verification
    vesl-test.hoon                  compile-time assertions
  sur/vesl.hoon                   types

kernels/                        compiled kernel crates (one per JAM)
  mint/  guard/  settle/

crates/                         Rust crates
  vesl-core/                      SDK — Mint/Guard/Settle/Forge facades
  nock-noun-rs/                   Nock noun construction from Rust
  nockchain-tip5-rs/              standalone tip5 Merkle tree + hashing
  nockchain-client-rs/            chain RPC client

hull/                           agnostic reference harness
  src/                            kernel boot, HTTP shell, verify + commit endpoints

templates/                      starter NockApps + graft templates
  counter/  data-registry/  settle-report/       teach the core patterns
  graft-scaffold/  graft-mint/  graft-settle/    commitment-family grafts
  graft-hash-gate/                                custom-gate demo
  graft-intent/                                   family-5 placeholder stub (see MOVED.md)
  GRAFTING.md                                     long-form integration guide

assets/                         compiled kernel JAMs (mint, guard, settle)
scripts/                        setup + template checks
hoon/                           symlink tree (setup-hoon-tree.sh links $NOCK_HOME)
```

## Primitive families

Five graft families, one row each. Priority bands come straight from [`docs/graft-manifest.md`](docs/graft-manifest.md); see that file for the rationale behind the lattice.

| # | Family | Role | Priority band | Status | What ships today |
|---|---|---|---|---|---|
| 1 | Commitment | STARK-bearing primitives that commit data to hull-keyed roots | 10–40 | Shipped | `settle-graft` (10), `mint-graft` (20), `guard-graft` (30), `forge-graft` (40) |
| 2 | Verification gates | Parameterized decision functions consumed by commitment grafts; a library, not a priority-claimed graft | n/a (library) | Scaffolded | `vesl-gates.hoon` (planned; see `.dev/01_GATE_CATALOG.md`) |
| 3 | State | Domain-keyed app-state primitives (kv, counter, queue, rbac, registry) | 50–99 | Shipped | `kv-graft` (50), `counter-graft` (60), `queue-graft` (70), `rbac-graft` (80), `registry-graft` (90) |
| 4 | Behavior | Runtime wrappers that enforce or observe rules around other grafts | 100–149 | Planned | see `.dev/03_BEHAVIOR_GRAFTS.md` |
| 5 | Intent | Multi-party coordination primitives (declare / match / cancel / expire) | 200–299 | Placeholder | `intent-graft` stub; crashes on invocation pending canonical upstream |

Commitments do not require intents. A NockApp can produce a ZK proof and settle it without ever declaring an intent. Intents are optional coordination on top of commitments — the STARK pipeline itself is intent-free.


## Nockchain for Rust Developers

If you're coming from EVM or Solidity, this table will save you a few hours of head-scratching.

| Nockchain | EVM equivalent |
|-----------|---------------|
| kernel | smart contract |
| hull | dApp backend / off-chain server |
| poke | transaction / state-changing call |
| peek | view / staticcall (read-only) |
| hoonc | solc (compiler) |
| NockApp | dApp |
| the subject | contract storage |
| crash | revert |
| nockvm | EVM (deterministic interpreter, but in-process — not a separate VM) |

A **kernel** is a Hoon program compiled to Nock that runs inside a NockApp. It holds state in *the subject* (think: a single persistent storage slot that's the entire state tree) and responds to pokes and peeks. Pokes mutate state and return effects; peeks read without changing anything. If something goes wrong, the kernel crashes — equivalent to a Solidity `revert`, the state change gets discarded.

The **hull** is the off-chain Rust process that hosts the kernel, handles HTTP, talks to the chain, and does the heavy lifting. Kernels don't do I/O — the hull does.

**hoonc** compiles Hoon source to a `.jam` binary. No ABI, no deploy step — the compiled noun *is* the program.


## Quick Start

Two ways in, depending on what you're building.

### NockUp — add verification to your NockApp

If you're building a NockApp with `nockup` and want to graft Vesl's verification primitives onto it, head to [vesl-nockup](https://github.com/zkVesl/vesl-nockup). That repo has pre-resolved git deps, a `graft-inject` CLI that auto-wires your kernel, a `vesl-test` harness, and a full walkthrough — none of which you need to clone this monorepo for.

For developers integrating by hand, [GRAFTING.md](templates/GRAFTING.md) is the long-form guide.

### Manual Setup

For contributors who want a local nockchain checkout and bare-metal builds.

**Layout.** vesl-core is a Cargo **workspace** with 8 members under `crates/`, `hull/`, and `kernels/`. The workspace root (`Cargo.toml`) declares nockchain deps as paths into a sibling `../nockchain/` clone. Templates under `templates/` are *not* workspace members — each is a standalone Cargo package meant to be copied out as a starter scaffold. Expected layout:

```
<wherever>/
├── nockchain/                     # https://github.com/nockchain/nockchain
└── vesl-core/                     # this repo (workspace root)
```

If your layout differs, rewrite the `path = "..."` entries in `Cargo.toml` (workspace root, plus each standalone template) to fit your tree — or swap them for git-deps against `nockchain/nockchain` at a rev you want to pin. We don't ship a canonical rev for forks; plug the Nockchain dep however works for you.

**Prerequisites:** `hoonc` and `nockchain` on your `$PATH` (built from the Nockchain monorepo). Rust nightly `2025-11-26` (pinned in repo-root `rust-toolchain.toml`; templates pin it too in their own `rust-toolchain.toml` files).

```bash
git clone https://github.com/zkvesl/vesl-core.git
cd vesl-core
cp vesl.toml.example vesl.toml     # edit nock_home if your layout differs
make setup                          # create hoon symlinks
make build                          # cargo build --workspace --release
```

Run `make help` for all available targets. `cargo check --workspace` verifies the whole core; for a specific template, `cd templates/<name> && cargo check` (templates are standalone).


## Test

```bash
make test-unit                      # unit tests
make test                           # all tests (unit + e2e)
```

Hoon tests are compile-time assertions — build success means pass:

```bash
hoonc --new protocol/tests/red-team.hoon hoon/
hoonc --new protocol/tests/prove-verify.hoon hoon/
```


## Settlement Modes

Vesl supports three settlement modes. Set via `--settlement-mode`, `VESL_SETTLEMENT_MODE`, or `settlement_mode` in `vesl.toml`.

| Mode | What happens | Chain required |
|------|-------------|----------------|
| `local` | Kernel verifies, no chain interaction. Default. | No |
| `fakenet` | Full pipeline — sign, build tx, submit to a local nockchain fakenet. | Yes (local) |
| `dumbnet` | Same as fakenet but uses a real seed phrase for key derivation. | Yes (live) |

Precedence: CLI flag > environment variable > `vesl.toml` > mode defaults. Passing `--chain-endpoint` or `--submit` without an explicit mode infers `fakenet`.


## Verify a transaction

Once a tx has been submitted to Nockchain, you can fetch a chain-attested receipt for it:

```
GET /tx/:tx_id
```

Returns JSON shaped like:

```json
{
  "tx_hash": "...",
  "accepted": true,
  "block_id": "...",
  "block_height": 42,
  "timestamp": 1714000000,
  "fee": 256,
  "amount_total": 1000,
  "inputs":  [ { "note_name": "...", "amount": 1256, "source_tx_id": "...", "coinbase": false } ],
  "outputs": [ { "note_name": "...", "amount": 1000, "lock_summary": "P2PKH:9yPe..." } ],
  "primary_lock_summary": "P2PKH:9yPe..."
}
```

**No `sender` and no `receiver`.** Nockchain is a UTXO chain — there is no single sender or receiver field on a transaction. There are notes being spent (`inputs`) and notes being created (`outputs`); each output carries a `lock_summary` string that names the spend condition. `primary_lock_summary` is a convenience field, populated only when a tx has exactly one output. Multi-output txs must read `outputs` directly.

The "proof" here is chain attestation: the node confirms the tx is in a block (or in mempool, with `accepted: false`). For an offline-verifiable Merkle commitment over a `(tx_hash, ...)` tuple, use the Mint/Guard primitives instead.

Available in `fakenet` and `dumbnet` modes. In `local` mode the endpoint returns `400 Bad Request` — there is no chain to query.

The same data is available from Rust via `vesl_core::fetch_receipt(client, tx_hash)` for NockApps that embed the SDK without running the hull.

## Standalone Crates

These work independently of Vesl. Any NockApp can use them. Built on primitives from the [nockchain](https://github.com/nockchain/nockchain) monorepo — packaged as standalone libraries with documentation.

**[nock-noun-rs](crates/nock-noun-rs/)** — Build Nock nouns from Rust without reading 57K lines of wallet code. NockStack helpers, cord/tag/loobean builders, jam/cue round-trips. Handles the footguns (loobeans are inverted, cords aren't strings, lists are null-terminated) so you don't have to.

**[nockchain-tip5-rs](crates/nockchain-tip5-rs/)** — Standalone tip5 Merkle tree. ~100 arithmetic constraints per hash vs ~30,000 for SHA-256 — 100x cheaper in ZK circuits. Cross-runtime aligned: Rust output is byte-identical to Hoon.

**[vesl-test](protocol/lib/vesl-test.hoon)** — Compile-time Hoon testing. Eight assertion arms, zero configuration, no test runner. If it builds, it passes.


## License

Dual-licensed under either of:

- Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
- MIT License ([LICENSE-MIT](LICENSE-MIT))

at your option. Unless you explicitly state otherwise, any contribution intentionally submitted for inclusion in this work by you, as defined in the Apache-2.0 license, shall be dual-licensed as above, without any additional terms or conditions.
