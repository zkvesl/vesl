//! Schnorr signing over the Cheetah curve — backwards-compat shim over
//! `vesl-signing`.
//!
//! Phase 0 W1-3 lifted the canonical Schnorr-over-Cheetah primitives to
//! `github.com/zkvesl/vesl-identity::vesl-signing`. This module retains
//! the `[Belt; 8]`-flavored API that vesl-core has historically exposed
//! to its callers (`settle.rs`, `config.rs`, `lib.rs` re-exports),
//! translating to/from vesl-signing's `UBig`-based representation at the
//! boundary.
//!
//! Type conversions:
//! - `nockchain_math::belt::Belt(u64)` ↔ `vesl_signing::prelude::Belt(u64)`
//!   is a memcpy through the public tuple field.
//! - `nockchain_math::crypto::cheetah::CheetahPoint` ↔
//!   `vesl_signing::schnorr::CheetahPoint`: structurally identical
//!   (verbatim port). Convert via the public `x: F6lt`, `y: F6lt`,
//!   `inf: bool` fields.
//!
//! Two functions stay local rather than delegating, because they hit
//! noun-aware machinery vesl-signing doesn't carry:
//!
//! - [`pubkey_hash`] uses `hash_noun_varlen_digest` from `nockchain-math`,
//!   which takes a `NounSlab` (Hoon-noun layer).
//! - [`key_from_seed_phrase`] uses an ad-hoc string-to-belts hash
//!   (NOT BIP39). The Phase 0 W6-8 `vesl-wallet` crate ships the
//!   pure-Rust BIP39 HD derivation that supersedes this helper.

use std::fmt;

use ibig::UBig;
use nockchain_math::belt::Belt;
use nockchain_math::crypto::cheetah::{
    trunc_g_order, CheetahPoint as NockCheetahPoint, F6lt as NockF6lt, G_ORDER,
};
use nockchain_math::tip5::hash::hash_varlen;
use nockchain_types::tx_engine::common::{Hash, SchnorrPubkey, SchnorrSignature};
use vesl_signing::prelude::Belt as VeslBelt;
use vesl_signing::schnorr::{
    schnorr_sign, CheetahPoint as VeslCheetahPoint, F6lt as VeslF6lt, SchnorrError,
    SchnorrPrivateKey,
};
use zeroize::Zeroize;

// ---------------------------------------------------------------------------
// Error type — preserves pre-shim API
// ---------------------------------------------------------------------------

#[derive(Debug)]
pub enum SigningError {
    InvalidSecretKey,
    ZeroNonce,
    ZeroChallenge,
    ZeroSignature,
    ZeroSeedScalar,
}

impl fmt::Display for SigningError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidSecretKey => write!(f, "secret key must be in (0, g_order)"),
            Self::ZeroNonce => write!(f, "deterministic nonce was zero"),
            Self::ZeroChallenge => write!(f, "challenge was zero"),
            Self::ZeroSignature => write!(f, "signature was zero"),
            Self::ZeroSeedScalar => {
                write!(f, "seed phrase produced zero scalar — use a different phrase")
            }
        }
    }
}

impl std::error::Error for SigningError {}

impl From<SchnorrError> for SigningError {
    fn from(e: SchnorrError) -> Self {
        // vesl-signing has more error variants than the pre-shim API;
        // fold them into the most-specific existing variant. Tests in
        // settle.rs / config.rs only branch on InvalidSecretKey today,
        // so the lossy fold is safe.
        match e {
            SchnorrError::BadPrivateKey | SchnorrError::OutOfRange => Self::InvalidSecretKey,
            SchnorrError::BadSignature => Self::ZeroSignature,
            SchnorrError::Curve(_)
            | SchnorrError::ChunkOverflow(_)
            | SchnorrError::BadChunk(_)
            | SchnorrError::BadPubkey(_) => Self::InvalidSecretKey,
        }
    }
}

// ---------------------------------------------------------------------------
// Public API — delegates to vesl-signing
// ---------------------------------------------------------------------------

/// Derive the Schnorr public key from a secret key.
///
/// `sk` is 8 × 32-bit Belt chunks (little-endian, matching Hoon's t8).
pub fn derive_pubkey(sk: &[Belt; 8]) -> SchnorrPubkey {
    let belts = nock_belts8_to_vesl(sk);
    let key = SchnorrPrivateKey::from_belts(&belts)
        .expect("vesl-core key derivation invariant: caller verified scalar in (0, G_ORDER)");
    SchnorrPubkey(vesl_point_to_nock(&key.public_key()))
}

/// Compute the PKH (public-key hash) from a public key.
///
/// Matches Hoon's `hash:schnorr-pubkey` = `(hash-hashable:tip5 leaf+pk)`.
/// This hashes the **entire pubkey noun** (including inf flag and cell
/// structure) through `hash_noun_varlen_digest`, NOT just the coordinate
/// belts. Stays in vesl-core because vesl-signing does not carry the
/// noun layer.
pub fn pubkey_hash(pk: &SchnorrPubkey) -> Hash {
    use nockapp::noun::slab::NounSlab;
    use nockchain_math::tip5::hash::hash_noun_varlen_digest;
    use noun_serde::NounEncode;

    let mut slab: NounSlab = NounSlab::new();
    let noun = pk.to_noun(&mut slab);
    let digest = hash_noun_varlen_digest(&mut slab, noun)
        .expect("hash_noun_varlen_digest should not fail on a valid SchnorrPubkey noun");
    Hash::from_limbs(&digest)
}

/// Sign a message digest with a secret key.
///
/// `sk`: secret key as 8 × 32-bit Belt chunks.
/// `message`: tip5 noun-digest (5 × 64-bit limbs).
///
/// Returns a `SchnorrSignature` with challenge and signature components,
/// each stored as 8 × 32-bit Belt chunks. Compatible with Hoon's
/// `sign:affine:belt-schnorr:cheetah`.
///
/// # Deterministic nonce — contract (AUDIT 2026-04-17 M-06)
///
/// The nonce is derived as
/// `trunc_g_order(hash_varlen([pk.x, pk.y, message, sk]))`. This is
/// deterministic: the same `(sk, message)` pair always produces the
/// same signature. Matches the Hoon spec
/// (`sign:affine:belt-schnorr:cheetah`, three.hoon lines 1628-1661).
///
/// Security is only preserved if every call for a given key uses a
/// **distinct** `message` value. Re-signing the same logical document
/// is safe (same signature = no new entropy leaked). Signing two
/// different logical documents that happen to hash to the same `message`
/// is not — and any caller that lets the message be chosen (or reused)
/// adversarially breaks the signature scheme.
///
/// Callers who don't fully control message entropy must include a fresh
/// nonce / counter in the message body before digesting. The signing
/// layer does not add randomness on behalf of the caller.
pub fn sign(sk: &[Belt; 8], message: &[Belt; 5]) -> Result<SchnorrSignature, SigningError> {
    let belts = nock_belts8_to_vesl(sk);
    let key = SchnorrPrivateKey::from_belts(&belts)?;
    let m = nock_belts5_to_vesl(message);
    let (chal, sig) = schnorr_sign(&key, &m)?;
    Ok(SchnorrSignature {
        chal: ubig_to_belts8(&chal),
        sig: ubig_to_belts8(&sig),
    })
}

// ---------------------------------------------------------------------------
// Key derivation (local — non-BIP39, superseded by vesl-wallet at W6-8)
// ---------------------------------------------------------------------------

/// Derive a signing key from a seed phrase.
///
/// Hashes the phrase bytes through tip5's `hash_varlen`, then truncates
/// to a valid scalar in `(0, g_order)` and packs into 8 × 32-bit Belts.
/// **Not BIP39.** The Phase 0 W6-8 `vesl-wallet` crate provides
/// pure-Rust BIP39 HD derivation; once it ships, callers should migrate.
pub fn key_from_seed_phrase(phrase: &str) -> Result<[Belt; 8], SigningError> {
    let bytes = phrase.as_bytes();
    // Pack bytes into Belt values (8 bytes per Belt, little-endian)
    let mut belts: Vec<Belt> = Vec::with_capacity(bytes.len().div_ceil(8));
    for chunk in bytes.chunks(8) {
        let mut val: u64 = 0;
        for (i, &b) in chunk.iter().enumerate() {
            val |= (b as u64) << (i * 8);
        }
        belts.push(Belt(val));
    }
    let hash = hash_varlen(&mut belts);
    // Zeroize: belts contains seed-derived key material (C-002)
    for b in belts.iter_mut() {
        b.0.zeroize();
    }
    let scalar = SecretScalar(trunc_g_order(&hash));
    if *scalar == UBig::from(0u64) {
        return Err(SigningError::ZeroSeedScalar);
    }
    let result = ubig_to_belts8(&scalar);
    // scalar zeroized on drop (C-002)
    Ok(result)
}

// ---------------------------------------------------------------------------
// Sensitive scalar wrapper (C-002) — see AUDIT 2026-04-17 L-06 for the
// non-zeroizing UBig caveat.
// ---------------------------------------------------------------------------

/// Wrapper for UBig values derived from secret key material. Overwrites
/// the value with zero on drop. See AUDIT 2026-04-17 L-06.
struct SecretScalar(UBig);

impl Drop for SecretScalar {
    fn drop(&mut self) {
        self.0 = UBig::from(0u64);
    }
}

impl std::ops::Deref for SecretScalar {
    type Target = UBig;
    fn deref(&self) -> &UBig {
        &self.0
    }
}

impl std::ops::DerefMut for SecretScalar {
    fn deref_mut(&mut self) -> &mut UBig {
        &mut self.0
    }
}

// ---------------------------------------------------------------------------
// Conversion helpers
// ---------------------------------------------------------------------------

/// Convert nockchain-math `[Belt; 8]` into vesl-signing's `[Belt; 8]`.
/// Both Belt structs wrap `u64` in a public tuple field; the conversion
/// is a memcpy through `.0`.
fn nock_belts8_to_vesl(belts: &[Belt; 8]) -> [VeslBelt; 8] {
    std::array::from_fn(|i| VeslBelt(belts[i].0))
}

/// Same as [`nock_belts8_to_vesl`] for the 5-Belt message digest shape.
fn nock_belts5_to_vesl(belts: &[Belt; 5]) -> [VeslBelt; 5] {
    std::array::from_fn(|i| VeslBelt(belts[i].0))
}

/// Convert a vesl-signing `CheetahPoint` to the nockchain-math form.
/// The structs are byte-isomorphic by construction (vesl-signing's math
/// is a verbatim port). Both `F6lt` types wrap `[Belt; 6]` in a public
/// tuple field.
fn vesl_point_to_nock(p: &VeslCheetahPoint) -> NockCheetahPoint {
    NockCheetahPoint {
        x: NockF6lt(std::array::from_fn(|i| Belt(p.x.0[i].0))),
        y: NockF6lt(std::array::from_fn(|i| Belt(p.y.0[i].0))),
        inf: p.inf,
    }
}

// Inverse direction (kept for symmetry; not currently used by the shim
// but available if the signing_shim_compat test grows).
#[allow(dead_code)]
fn nock_point_to_vesl(p: &NockCheetahPoint) -> VeslCheetahPoint {
    VeslCheetahPoint {
        x: VeslF6lt(std::array::from_fn(|i| VeslBelt(p.x.0[i].0))),
        y: VeslF6lt(std::array::from_fn(|i| VeslBelt(p.y.0[i].0))),
        inf: p.inf,
    }
}

/// Reconstruct a UBig from 8 × 32-bit Belt chunks (little-endian).
/// Matches Hoon's `rep 5 sk-as-32-bit-belts`.
#[allow(dead_code)]
pub(crate) fn belts8_to_ubig(belts: &[Belt; 8]) -> UBig {
    let mut bytes = [0u8; 32];
    for (i, belt) in belts.iter().enumerate() {
        let chunk = (belt.0 as u32).to_le_bytes();
        bytes[i * 4..i * 4 + 4].copy_from_slice(&chunk);
    }
    let result = UBig::from_le_bytes(&bytes);
    bytes.zeroize();
    result
}

/// Split a UBig into 8 × 32-bit Belt chunks (little-endian). Matches
/// Hoon's `rip 5` with zero-padding to 8 elements.
pub(crate) fn ubig_to_belts8(val: &UBig) -> [Belt; 8] {
    let mut belts = [Belt(0); 8];
    let mut v = val.clone();
    let mask = UBig::from(0xFFFF_FFFFu64);
    for belt in &mut belts {
        let chunk = &v & &mask;
        // AUDIT 2026-04-19 L-18: chunk is `v & 0xFFFF_FFFF`, so it fits
        // in 32 bits (and therefore in u64) by construction. A silent
        // `unwrap_or(0)` would mask any invariant break and zero the
        // limb, producing invalid key material. Prefer a named expect.
        *belt = Belt(u64::try_from(&chunk).expect("chunk is 32-bit by construction"));
        v >>= 32;
    }
    belts
}

// `_unused_g_order` reference keeps the import alive for downstream
// changes that may need direct G_ORDER access through this module.
#[allow(dead_code)]
fn _g_order_marker() {
    let _ = &*G_ORDER;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use nockchain_math::crypto::cheetah::{ch_add, ch_neg, ch_scal_big, A_GEN, F6_ZERO};

    #[test]
    fn derive_pubkey_from_nonzero_key() {
        let mut sk = [Belt(0); 8];
        sk[0] = Belt(42);
        let pk = derive_pubkey(&sk);
        assert!(!pk.0.inf);
        assert_ne!(pk.0.x, F6_ZERO);
    }

    #[test]
    fn sign_and_verify_roundtrip() {
        let mut sk = [Belt(0); 8];
        sk[0] = Belt(12345);
        sk[1] = Belt(67890);

        let message = [Belt(1), Belt(2), Belt(3), Belt(4), Belt(5)];

        let sig = sign(&sk, &message).expect("signing should succeed");

        let pubkey = derive_pubkey(&sk);
        let chal_big = belts8_to_ubig(&sig.chal);
        let sig_big = belts8_to_ubig(&sig.sig);

        let left = ch_scal_big(&sig_big, &A_GEN).expect("valid sig scalar");
        let right = ch_neg(&ch_scal_big(&chal_big, &pubkey.0).expect("valid chal scalar"));
        let r_reconstructed = ch_add(&left, &right).expect("valid point add");
        assert_ne!(r_reconstructed.x, F6_ZERO, "R must not be at infinity");

        let mut hashable: Vec<Belt> = Vec::with_capacity(6 * 4 + 5);
        hashable.extend_from_slice(&r_reconstructed.x.0);
        hashable.extend_from_slice(&r_reconstructed.y.0);
        hashable.extend_from_slice(&pubkey.0.x.0);
        hashable.extend_from_slice(&pubkey.0.y.0);
        hashable.extend_from_slice(&message);
        let recomputed_hash = hash_varlen(&mut hashable);
        let recomputed_chal = trunc_g_order(&recomputed_hash);

        assert_eq!(
            recomputed_chal, chal_big,
            "recomputed challenge must match signed challenge"
        );
    }

    #[test]
    fn belts_roundtrip() {
        let original = UBig::from(0xDEADBEEF_CAFEBABE_u64);
        let belts = ubig_to_belts8(&original);
        let recovered = belts8_to_ubig(&belts);
        assert_eq!(original, recovered);
    }

    #[test]
    fn belts_roundtrip_large() {
        let mut val = UBig::from(1u64);
        for _ in 0..7 {
            val <<= 32;
            val += UBig::from(0xAAAA_BBBBu64);
        }
        let belts = ubig_to_belts8(&val);
        let recovered = belts8_to_ubig(&belts);
        assert_eq!(val, recovered);
    }

    #[test]
    fn pubkey_hash_produces_valid_hash() {
        let mut sk = [Belt(0); 8];
        sk[0] = Belt(999);
        let pk = derive_pubkey(&sk);
        let pkh = pubkey_hash(&pk);
        assert!(pkh.0.iter().any(|b| b.0 != 0));
    }

    #[test]
    fn different_messages_produce_different_signatures() {
        let mut sk = [Belt(0); 8];
        sk[0] = Belt(7777);

        let msg1 = [Belt(1), Belt(0), Belt(0), Belt(0), Belt(0)];
        let msg2 = [Belt(2), Belt(0), Belt(0), Belt(0), Belt(0)];

        let sig1 = sign(&sk, &msg1).expect("signing should succeed");
        let sig2 = sign(&sk, &msg2).expect("signing should succeed");

        assert_ne!(sig1.chal, sig2.chal);
        assert_ne!(sig1.sig, sig2.sig);
    }

    #[test]
    fn key_from_seed_phrase_produces_valid_key() {
        let sk = key_from_seed_phrase("test seed phrase for key derivation")
            .expect("key derivation should succeed");
        // Key should be non-zero
        assert!(sk.iter().any(|b| b.0 != 0));
        // Different phrases should produce different keys
        let sk2 = key_from_seed_phrase("a completely different seed phrase")
            .expect("key derivation should succeed");
        assert_ne!(sk, sk2);
    }

    #[test]
    fn point_conversion_roundtrip() {
        // Verify the nock <-> vesl CheetahPoint translation is exact.
        let mut sk = [Belt(0); 8];
        sk[0] = Belt(54321);
        let nock_pk = derive_pubkey(&sk);
        let vesl_pk = nock_point_to_vesl(&nock_pk.0);
        let back = vesl_point_to_nock(&vesl_pk);
        assert_eq!(back.x.0, nock_pk.0.x.0);
        assert_eq!(back.y.0, nock_pk.0.y.0);
        assert_eq!(back.inf, nock_pk.0.inf);
    }
}
