//! vesl-core — High-level Vesl SDK
//!
//! Four primitives, each a different weight class:
//!
//! - **Mint** — Data commitment. Pure math, zero async. Commit chunks, get a root.
//! - **Guard** — Verification. Prove chunks and manifests against trusted roots.
//! - **Settle** — Settlement. Kernel boot + chain access for note state transitions.
//! - **Forge** — STARK proof. Everything Settle does, plus proof generation.
//!
//! Callers pick the primitive they need. Mint users never touch the kernel.
//! Forge users get the full pipeline.

pub mod settle;
pub mod config;
pub mod noun_builder;
pub mod tx_builder;
pub mod guard;
pub mod mint;
pub mod forge;
pub mod graft_pokes;
pub mod signing;
pub mod types;
pub mod verify_tx;

// Top-level re-exports so callers can write:
//   use vesl_core::{Mint, Guard, Tip5Hash, ProofNode};
pub use mint::Mint;
pub use guard::Guard;
pub use settle::Settle;

pub use types::{
    Chunk, Manifest, Note, NockZkp, NoteState, Retrieval,
    Tip5Hash, ProofNode, TIP5_ZERO, MerkleTree,
    ChainClient, ChainConfig, WalletClient, WalletConfig,
    format_tip5, hash_leaf, hash_pair, tip5_to_atom_le_bytes, verify_proof,
    CommitmentVerifier, GraftPayload, NounSlab,
    ForgePayload, LeafWithProof,
};
// Deprecated alias — remove in next minor release. Callers should migrate to CommitmentVerifier.
#[allow(deprecated)]
pub use types::IntentVerifier;
pub use guard::GuardError;
pub use mint::MintError;
pub use settle::RagVerifier;
pub use signing::{SigningError, derive_pubkey, pubkey_hash, sign, key_from_seed_phrase};
pub use config::{SettlementMode, SettlementConfig, SettlementToml};

// Vesl wallet derivation spec — BIP44 5-level layout. Re-exported from the
// `vesl-wallet` workspace so Hull authors get role constants and the typed
// `DerivationPath` via `use vesl_core::*` without depending on the spec
// crate directly.
pub use vesl_wallet_spec::{
    BIP44_PURPOSE, DerivationPath,
    ROLE_INTENT, ROLE_RECEIVING, ROLE_ENCRYPTION, ROLE_SESSION, ROLE_X402,
};

// High-level Hull-author wallet API. Bundles BIP-39 seed handling +
// Cheetah-BIP32-over-Tip5 HD derivation + the BIP-44 layout. Hull
// authors call `VeslWallet::from_seed_phrase(...)`, then drive an
// intent-app or payment-app role from the same code via
// `intent_signer()` / `payment_signer()` (the TOML config-toggle
// pattern; see `SettlementToml::wallet`).
pub use vesl_wallet::{
    DerivedKey, VeslWallet, WalletError, VESL_COIN_TYPE_PLACEHOLDER,
};
pub use verify_tx::{fetch_receipt, TxInputView, TxOutputView, TxReceipt, VerifyTxError};

// Graft poke builders — used by callers that compose grafted kernels via
// `graft-inject` (in vesl-nockup). One submodule per primitive.
//
// Phase 12A renamed the settle helpers from `build_vesl_*_poke` to
// `build_settle_*_poke` to match the `%settle-*` cause-tag rename.
// Deprecated aliases are re-exported below for one release cycle.
pub use graft_pokes::settle::{
    build_settle_note_poke, build_settle_register_poke, build_settle_verify_poke,
};
#[allow(deprecated)]
pub use graft_pokes::settle::{
    build_vesl_register_poke, build_vesl_settle_poke, build_vesl_verify_poke,
};
pub use graft_pokes::mint::build_mint_commit_poke;
pub use graft_pokes::guard::{build_guard_register_poke, build_guard_check_poke};
pub use graft_pokes::forge::build_forge_prove_poke;
pub use graft_pokes::kv::{build_kv_set_poke, build_kv_delete_poke};
pub use graft_pokes::counter::{
    build_counter_increment_poke, build_counter_reset_poke, build_counter_set_poke,
};
pub use graft_pokes::queue::{
    build_queue_clear_poke, build_queue_pop_poke, build_queue_push_poke,
};
pub use graft_pokes::rbac::{build_rbac_grant_poke, build_rbac_revoke_poke};
pub use graft_pokes::registry::{
    build_registry_del_poke, build_registry_put_poke, build_registry_update_poke,
};
pub use graft_pokes::clock::build_clock_tick_poke;
pub use graft_pokes::log::build_log_append_poke;
pub use graft_pokes::validate::{build_validate_clear_poke, build_validate_init_poke, Rule as ValidateRule};
pub use graft_pokes::batch::{build_batch_add_poke, build_batch_flush_poke, build_batch_init_poke};
