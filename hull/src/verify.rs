//! FieldVerifier — generic IntentVerifier for key-value field data.
//!
//! Community developers: this is the file you replace. Define what
//! "correct" means for your domain by implementing IntentVerifier.
//! The hull handles everything else (Merkle trees, kernel pokes,
//! HTTP endpoints, settlement config).

use nock_noun_rs::NounSlab;
use nockchain_tip5_rs::verify_proof;

use vesl_core::types::{GraftPayload, IntentVerifier, ProofNode, Tip5Hash};

use crate::api::Field;

use serde::{Deserialize, Serialize};

/// A field paired with its Merkle proof, used in settlement payloads.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FieldWithProof {
    pub field: Field,
    pub proof: Vec<ProofNode>,
}

/// Encode a field as leaf bytes for Merkle hashing.
///
/// Encoding is `"key:value"` as UTF-8 bytes — deterministic and easy
/// to reproduce in any language. Community developers change this for
/// their domain's leaf encoding.
pub fn field_to_leaf_bytes(field: &Field) -> Vec<u8> {
    format!("{}:{}", field.key, field.value).into_bytes()
}

/// Field-based verifier. The generic IntentVerifier for non-RAG domains.
///
/// Verification logic:
/// 1. Deserialize payload as JSON array of FieldWithProof
/// 2. For each field, verify Merkle proof against expected_root
/// 3. All fields must verify. Any failure = reject.
///
/// Replace this with your domain verifier when forking hull.
pub struct FieldVerifier;

impl IntentVerifier for FieldVerifier {
    fn verify(&self, _note_id: u64, data: &[u8], expected_root: &Tip5Hash) -> bool {
        let fields: Vec<FieldWithProof> = match serde_json::from_slice(data) {
            Ok(f) => f,
            Err(_) => return false,
        };

        if fields.is_empty() {
            return false;
        }

        for fwp in &fields {
            let leaf_bytes = field_to_leaf_bytes(&fwp.field);
            if !verify_proof(&leaf_bytes, &fwp.proof, expected_root) {
                return false;
            }
        }

        true
    }

    fn build_settle_poke(&self, payload: &GraftPayload) -> anyhow::Result<NounSlab> {
        // Generic hull: settle = register root with note metadata.
        // The settle kernel's %register poke is the settlement primitive
        // for domains that don't need a custom settle handler.
        Ok(vesl_core::noun_builder::build_register_poke(
            payload.note.hull,
            &payload.expected_root,
        ))
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use vesl_core::{Mint, format_tip5};

    #[test]
    fn field_verifier_valid() {
        let fields = vec![
            Field { key: "commit".into(), value: "abc123".into() },
            Field { key: "config".into(), value: "release".into() },
        ];

        let leaf_data: Vec<Vec<u8>> = fields.iter().map(field_to_leaf_bytes).collect();
        let leaf_refs: Vec<&[u8]> = leaf_data.iter().map(|v| v.as_slice()).collect();

        let mut mint = Mint::new();
        let root = mint.commit(&leaf_refs);

        let fields_with_proof: Vec<FieldWithProof> = fields
            .into_iter()
            .enumerate()
            .map(|(i, field)| FieldWithProof {
                field,
                proof: mint.proof(i).expect("proof within committed range"),
            })
            .collect();

        let data = serde_json::to_vec(&fields_with_proof).unwrap();
        let verifier = FieldVerifier;
        assert!(verifier.verify(1, &data, &root), "valid fields should verify");
        println!("root: {}", format_tip5(&root));
    }

    #[test]
    fn field_verifier_tampered_value() {
        let fields = [Field { key: "commit".into(), value: "abc123".into() }];

        let leaf_data: Vec<Vec<u8>> = fields.iter().map(field_to_leaf_bytes).collect();
        let leaf_refs: Vec<&[u8]> = leaf_data.iter().map(|v| v.as_slice()).collect();

        let mut mint = Mint::new();
        let root = mint.commit(&leaf_refs);

        // Tamper with the value
        let tampered = vec![FieldWithProof {
            field: Field { key: "commit".into(), value: "TAMPERED".into() },
            proof: mint.proof(0).expect("proof within committed range"),
        }];

        let data = serde_json::to_vec(&tampered).unwrap();
        let verifier = FieldVerifier;
        assert!(!verifier.verify(1, &data, &root), "tampered field should fail");
    }

    #[test]
    fn field_verifier_empty_rejects() {
        let verifier = FieldVerifier;
        let data = serde_json::to_vec::<Vec<FieldWithProof>>(&vec![]).unwrap();
        assert!(!verifier.verify(1, &data, &[0; 5]));
    }

    #[test]
    fn field_verifier_bad_json_rejects() {
        let verifier = FieldVerifier;
        assert!(!verifier.verify(1, b"not json", &[0; 5]));
    }
}
