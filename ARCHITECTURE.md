# Architecture

## Overview

Vesl is a verification SDK for Nockchain. Four commitment primitives — mint, guard, settle, forge — compile to Hoon kernels with a matching Rust facade (`vesl-core`). A NockApp integrator composes these via graft templates to add verified state, on-chain settlement, and STARK proofs to their own kernel.

The `hull/` crate in this repo is an agnostic reference harness that boots a kernel and exposes it over HTTP. For a concrete LLM/RAG implementation on top of `vesl-core`, see [zkvesl/hull-llm](https://github.com/zkVesl/hull-llm).

### nockvm: The Embedded Nock Interpreter

Throughout this document (and the codebase), "nockvm" refers to the Nock bytecode interpreter embedded inside the Rust binary. It is not a separate virtual machine or a second process — it's a deterministic interpreter that runs compiled Hoon (as Nock bytecode, serialized via JAM) within the same Rust process that runs the rest of the pipeline.

The actual runtime topology is one binary with two runtimes:

```
Rust process
├── native Rust code (tip5, Merkle, noun building, HTTP shell, chain client)
└── nockvm interpreter
    └── kernel JAM (compiled Hoon → Nock bytecode)
```

Rust interacts with the kernel only through pokes (JAM'd nouns in) and peeks (nouns out). The kernel's execution is hermetic — Rust cannot reach into the interpreter's state or override its crash semantics. This narrow interface is what makes the kernel a trust anchor: it either accepts a payload and settles, or it crashes, and there's no way to fudge the result from the Rust side.

When the docs say "cross-runtime alignment," they mean the invariant that native Rust computation and interpreted Nock computation must produce byte-identical results for the same inputs.

## Component Map

```
protocol/                        Hoon protocol layer (trust anchor)
  sur/vesl.hoon                  Type definitions
  lib/mint-kernel.hoon           Commit-data kernel
  lib/guard-kernel.hoon          Verify-inclusion kernel
  lib/settle-kernel.hoon         On-chain settlement kernel
  lib/forge-kernel.hoon          STARK prover (arbitrary Nock)
  lib/{mint,guard,settle,forge}-graft.{hoon,toml}  graft composition definitions
  lib/vesl-merkle.hoon           tip5 Merkle math
  lib/vesl-prover.hoon           STARK proof generation
  lib/vesl-verifier.hoon         STARK proof verification wrapper
  lib/vesl-stark-verifier.hoon   STARK verifier fork (non-puzzle proofs)
  tests/                         compile-time assertions

hull/                            Agnostic reference harness
  src/                           kernel boot, HTTP shell, commit + verify endpoints

kernels/                         Kernel compilation crates (one per JAM)
  mint/  guard/  settle/

assets/                          Compiled kernel JAMs (mint.jam, guard.jam, settle.jam)

crates/                          Rust SDK
  vesl-core/                     Mint/Guard/Settle/Forge facades
  nock-noun-rs/                  Nock noun construction from Rust
  nockchain-tip5-rs/             Standalone tip5 Merkle tree
  nockchain-client-rs/           gRPC client for on-chain settlement
```

## The graft catalog

Vesl's composition layer — the `graft-inject` pattern — groups grafts into five families, arranged on a priority lattice. Family 1 (commitment) owns the 10–40 band and is what ships today: `settle-graft`, `mint-graft`, `guard-graft`, `forge-graft` — the STARK-bearing primitives that commit data to hull-keyed roots. Family 2 (verification gates) is a library, not a graft; its arms are parameters consumed by family-1 grafts. Families 3 (state, 50–99) and 4 (behavior, 100–149) are planned buildouts covering app-state primitives and runtime wrappers. Family 5 (intent, 200–299) is a placeholder — `intent-graft.hoon` reserves the shape but crashes on invocation until the Nockchain monorepo publishes a canonical intent structure to swap in. Commitments don't require intents: a NockApp can produce a STARK proof and settle it without ever declaring one. See [`docs/graft-manifest.md`](docs/graft-manifest.md) for the authoritative lattice, band rationale, and manifest schema.

## Hash Function: tip5

Vesl uses tip5, the same algebraic hash used in Nockchain's block validation. tip5 operates over the Goldilocks field (p = 2^64 - 2^32 + 1) and costs ~300 R1CS constraints per hash — 100x cheaper than SHA-256 in STARK circuits.

Leaf data is encoded via 7-byte little-endian chunking (each chunk guaranteed < 2^56 < p), fed to tip5's variable-length sponge. Pair hashing uses the fixed-rate 10-element sponge. Both Hoon and Rust implement identical encoding, verified by cross-runtime alignment tests.

## STARK Proofs

The STARK prover (`vesl-prover.hoon`) is a fork of Nockchain's `nock-prover.hoon` that accepts arbitrary `[subject formula]` pairs instead of PoW puzzles. The constraint system (compute-table, memory-table) enforces correct Nock VM execution regardless of which computation is proved.

The verifier (`vesl-stark-verifier.hoon`) is a minimal fork of `stark/verifier.hoon` — 8 lines changed to accept `[s f]` as parameters instead of deriving them from puzzle data. All FRI, linking-checks, and constraint polynomial evaluation are unchanged.

## Crash Semantics

The kernel crashes on invalid input. This is correct — crash is revert. There is no partial failure, no error code, no exception object. The kernel either accepts the payload and transitions state, or it crashes and nothing changes. A valid STARK proof of the settlement computation is proof that all checks passed.

The SDK (`vesl-core`) validates payloads before they reach the kernel. `Guard::validate_manifest()` and `Settle::settle()` catch the most common failures — unregistered roots, duplicate chunk IDs, prompt reconstruction mismatches, duplicate note IDs — and return specific error messages. Any consuming hull wraps kernel poke errors with context (which poke, which note, likely cause).

If a poke still crashes after pre-flight checks pass, the input violated a kernel guard that the SDK doesn't cover. This is a real bug to investigate, not a normal error path.
