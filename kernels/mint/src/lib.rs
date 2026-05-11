//! Vesl Mint kernel JAM embedding crate.
//!
//! Embeds the compiled Hoon kernel at build time; runtime sha256-
//! verifies the embedded bytes match what build.rs hashed. Kernel
//! source: protocol/lib/mint-kernel.hoon.
//! AUDIT 2026-04-17 M-07: runtime sha256 check.

use sha2::{Digest, Sha256};

pub static KERNEL: &[u8] = include_bytes!(env!("KERNEL_JAM_PATH"));

pub const KERNEL_SHA256_HEX: &str = env!("KERNEL_JAM_SHA256");

pub fn verify_kernel() {
    let digest = Sha256::digest(KERNEL);
    let actual: String = digest.iter().map(|b| format!("{b:02x}")).collect();
    assert_eq!(
        actual, KERNEL_SHA256_HEX,
        "kernels-mint: embedded JAM sha256 does not match build-time expected \
         (actual: {actual}, expected: {KERNEL_SHA256_HEX}) — JAM was tampered \
         between build-time hash and binary link, refusing to boot",
    );
}
