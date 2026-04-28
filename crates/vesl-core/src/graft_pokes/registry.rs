//! Registry-graft poke builders.
//!
//! Registry is the strict structured store: create-only put,
//! modify-only update, error-on-missing delete, opaque `record=*`
//! values. Both put and update cue caller-supplied bytes inside
//! the poke arm under a mule guard — pre-jam your record on the
//! Rust side.

use nock_noun_rs::{atom_from_u64, make_atom_in, make_tag_in, NounSlab};
use nockvm::noun::T;

/// Build a `[%registry-put key=@ payload=@]` poke.
///
/// `record_jammed` is the caller-jammed bytes of the record noun.
/// The kernel re-cue's it inside a mule and emits `%registry-error`
/// on malformed jam.
pub fn build_registry_put_poke(key: u64, record_jammed: &[u8]) -> NounSlab {
    let mut slab = NounSlab::new();
    let tag = make_tag_in(&mut slab, "registry-put");
    let key_noun = atom_from_u64(&mut slab, key);
    let payload = make_atom_in(&mut slab, record_jammed);
    let poke = T(&mut slab, &[tag, key_noun, payload]);
    slab.set_root(poke);
    slab
}

/// Build a `[%registry-update key=@ payload=@]` poke.
pub fn build_registry_update_poke(key: u64, record_jammed: &[u8]) -> NounSlab {
    let mut slab = NounSlab::new();
    let tag = make_tag_in(&mut slab, "registry-update");
    let key_noun = atom_from_u64(&mut slab, key);
    let payload = make_atom_in(&mut slab, record_jammed);
    let poke = T(&mut slab, &[tag, key_noun, payload]);
    slab.set_root(poke);
    slab
}

/// Build a `[%registry-del key=@]` poke.
pub fn build_registry_del_poke(key: u64) -> NounSlab {
    let mut slab = NounSlab::new();
    let tag = make_tag_in(&mut slab, "registry-del");
    let key_noun = atom_from_u64(&mut slab, key);
    let poke = T(&mut slab, &[tag, key_noun]);
    slab.set_root(poke);
    slab
}

#[cfg(test)]
mod tests {
    use super::*;
    use nock_noun_rs::{jam_to_bytes, new_stack, slab_root};

    #[test]
    fn build_registry_put_poke_emits_nonempty_jam() {
        let slab = build_registry_put_poke(1, &[0x02]); // jam(0)
        let mut stack = new_stack();
        let bytes = jam_to_bytes(&mut stack, slab_root(&slab));
        assert!(!bytes.is_empty());
    }

    #[test]
    fn build_registry_update_poke_emits_nonempty_jam() {
        let slab = build_registry_update_poke(1, &[0x02]);
        let mut stack = new_stack();
        let bytes = jam_to_bytes(&mut stack, slab_root(&slab));
        assert!(!bytes.is_empty());
    }

    #[test]
    fn build_registry_del_poke_emits_nonempty_jam() {
        let slab = build_registry_del_poke(1);
        let mut stack = new_stack();
        let bytes = jam_to_bytes(&mut stack, slab_root(&slab));
        assert!(!bytes.is_empty());
    }

    #[test]
    fn large_key_does_not_panic() {
        // Hash-derived keys routinely exceed DIRECT_MAX (2^63 - 1).
        let _slab = build_registry_put_poke(u64::MAX - 7, &[0x02]);
    }

    #[test]
    fn large_record_does_not_panic() {
        let record: Vec<u8> = (0..32_768).map(|i| (i & 0xff) as u8).collect();
        let _slab = build_registry_put_poke(1, &record);
    }
}
