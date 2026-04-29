//! Integration tests for the `vesl_core::signing` shim — exercises the
//! contract that the [Belt; 8] ↔ vesl-signing UBig conversion preserves
//! pre-shim semantics on every edge case the original implementation
//! handled.
//!
//! The shim was introduced in Phase 0 W1-3 (per
//! `vesl-labs/docs/plans/shared-infrastructure/10-PHASE-0-NOW.md`)
//! when canonical Schnorr-over-Cheetah signing moved out of vesl-core
//! and into `github.com/zkvesl/vesl-identity::vesl-signing`. Anything
//! that broke from the lift would surface here.

use ibig::UBig;
use nockchain_math::belt::Belt;
use nockchain_math::crypto::cheetah::G_ORDER;
use vesl_core::signing::{derive_pubkey, key_from_seed_phrase, pubkey_hash, sign, SigningError};

fn nonzero_key() -> [Belt; 8] {
    let mut sk = [Belt(0); 8];
    sk[0] = Belt(0xDEAD_BEEF);
    sk[1] = Belt(0xCAFE_BABE);
    sk
}

#[test]
fn round_trip_sign_then_derive_consistent() {
    let sk = nonzero_key();
    let pk1 = derive_pubkey(&sk);
    let pk2 = derive_pubkey(&sk);
    // Determinism: same key → same pubkey. (Belt-array fields aren't Eq;
    // compare via the inner CheetahPoint coordinates.)
    assert_eq!(pk1.0.x.0, pk2.0.x.0);
    assert_eq!(pk1.0.y.0, pk2.0.y.0);
    assert_eq!(pk1.0.inf, pk2.0.inf);
}

#[test]
fn sign_rejects_zero_scalar() {
    let sk = [Belt(0); 8];
    let m = [Belt(1), Belt(2), Belt(3), Belt(4), Belt(5)];
    let err = sign(&sk, &m).expect_err("zero scalar must fail");
    assert!(matches!(err, SigningError::InvalidSecretKey));
}

#[test]
fn sign_rejects_scalar_at_g_order() {
    // Build a [Belt; 8] whose UBig form equals G_ORDER exactly.
    let g_order_belts = ubig_to_belts8(&G_ORDER);
    let m = [Belt(1), Belt(2), Belt(3), Belt(4), Belt(5)];
    let err = sign(&g_order_belts, &m).expect_err("scalar == G_ORDER must fail");
    assert!(matches!(err, SigningError::InvalidSecretKey));
}

#[test]
fn sign_accepts_scalar_one_below_g_order() {
    // G_ORDER - 1 is the maximum valid scalar. Sign should succeed.
    let scalar = &*G_ORDER - UBig::from(1u64);
    let belts = ubig_to_belts8(&scalar);
    let m = [Belt(1), Belt(2), Belt(3), Belt(4), Belt(5)];
    sign(&belts, &m).expect("scalar == G_ORDER - 1 must succeed");
}

#[test]
fn sign_is_deterministic_across_calls() {
    let sk = nonzero_key();
    let m = [Belt(7), Belt(8), Belt(9), Belt(10), Belt(11)];
    let s1 = sign(&sk, &m).unwrap();
    let s2 = sign(&sk, &m).unwrap();
    assert_eq!(s1.chal, s2.chal);
    assert_eq!(s1.sig, s2.sig);
}

#[test]
fn pubkey_hash_distinguishes_keys() {
    let sk1 = nonzero_key();
    let mut sk2 = nonzero_key();
    sk2[2] = Belt(99);
    let pkh1 = pubkey_hash(&derive_pubkey(&sk1));
    let pkh2 = pubkey_hash(&derive_pubkey(&sk2));
    assert_ne!(pkh1.0, pkh2.0);
}

#[test]
fn key_from_seed_phrase_rejects_pathological() {
    // Empty phrase → hashes to *something*; the shim accepts it (the
    // "all-zero" rejection is at scalar level, not phrase level).
    // Document the contract: only an exact zero scalar is rejected.
    let result = key_from_seed_phrase("");
    // Empty phrase produces a non-zero scalar in the current
    // implementation, so this should succeed. If a hash collision ever
    // makes it zero, this asserts the error is reported (not silent
    // generation of a zero key).
    match result {
        Ok(sk) => {
            assert!(sk.iter().any(|b| b.0 != 0), "empty phrase must not produce zero key");
        }
        Err(SigningError::ZeroSeedScalar) => {
            // Acceptable — pathological scalar surfaces correctly.
        }
        Err(other) => panic!("unexpected error: {other:?}"),
    }
}

#[test]
fn key_from_seed_phrase_distinct_phrases_distinct_keys() {
    let a = key_from_seed_phrase("alice").unwrap();
    let b = key_from_seed_phrase("bob").unwrap();
    assert_ne!(a, b);
}

// ---------------------------------------------------------------------------
// Helper — replicate vesl_core::signing::ubig_to_belts8 (private to the
// crate, so we re-implement here for the at-G_ORDER edge cases).
// ---------------------------------------------------------------------------

fn ubig_to_belts8(val: &UBig) -> [Belt; 8] {
    let mut belts = [Belt(0); 8];
    let mut v = val.clone();
    let mask = UBig::from(0xFFFF_FFFFu64);
    for belt in &mut belts {
        let chunk = &v & &mask;
        *belt = Belt(u64::try_from(&chunk).expect("chunk fits in u32"));
        v >>= 32;
    }
    belts
}
