//! Queue-graft poke builders.
//!
//! Queue is the third state-graft and the first under Phase 02
//! with a C1 mule-wrap site: `%queue-push` carries a jammed
//! `body=@` atom that the kernel cue's inside the poke arm. Pair
//! with the `%queue-push` / `%queue-pop` / `%queue-clear` arms
//! installed by `graft-inject`.
//!
//! Bodies are typed `*` (any noun) on the Hoon side. Callers are
//! responsible for jamming whatever shape they want. Domain-
//! specific shape validation belongs in a Phase 03 validate-graft,
//! not here.

use nock_noun_rs::{make_atom_in, make_tag_in, NounSlab};
use nockvm::noun::T;

/// Build a `[%queue-push payload=@]` poke.
///
/// `body_jammed` is the caller-jammed bytes of whatever noun the
/// queue body should hold. The kernel re-cue's it inside a mule
/// so malformed input surfaces as `%queue-error`.
pub fn build_queue_push_poke(body_jammed: &[u8]) -> NounSlab {
    let mut slab = NounSlab::new();
    let tag = make_tag_in(&mut slab, "queue-push");
    let payload = make_atom_in(&mut slab, body_jammed);
    let poke = T(&mut slab, &[tag, payload]);
    slab.set_root(poke);
    slab
}

/// Build a `[%queue-pop ~]` poke.
pub fn build_queue_pop_poke() -> NounSlab {
    let mut slab = NounSlab::new();
    let tag = make_tag_in(&mut slab, "queue-pop");
    let poke = T(&mut slab, &[tag, nockvm::noun::D(0)]);
    slab.set_root(poke);
    slab
}

/// Build a `[%queue-clear ~]` poke.
pub fn build_queue_clear_poke() -> NounSlab {
    let mut slab = NounSlab::new();
    let tag = make_tag_in(&mut slab, "queue-clear");
    let poke = T(&mut slab, &[tag, nockvm::noun::D(0)]);
    slab.set_root(poke);
    slab
}

#[cfg(test)]
mod tests {
    use super::*;
    use nock_noun_rs::{jam_to_bytes, new_stack, slab_root};

    #[test]
    fn build_queue_push_poke_emits_nonempty_jam() {
        let slab = build_queue_push_poke(b"\x02"); // jam(0) = 0x02
        let mut stack = new_stack();
        let bytes = jam_to_bytes(&mut stack, slab_root(&slab));
        assert!(!bytes.is_empty());
    }

    #[test]
    fn build_queue_pop_poke_emits_nonempty_jam() {
        let slab = build_queue_pop_poke();
        let mut stack = new_stack();
        let bytes = jam_to_bytes(&mut stack, slab_root(&slab));
        assert!(!bytes.is_empty());
    }

    #[test]
    fn build_queue_clear_poke_emits_nonempty_jam() {
        let slab = build_queue_clear_poke();
        let mut stack = new_stack();
        let bytes = jam_to_bytes(&mut stack, slab_root(&slab));
        assert!(!bytes.is_empty());
    }

    #[test]
    fn empty_body_does_not_panic() {
        let _slab = build_queue_push_poke(b"");
    }

    #[test]
    fn large_body_does_not_panic() {
        let body: Vec<u8> = (0..32_768).map(|i| (i & 0xff) as u8).collect();
        let _slab = build_queue_push_poke(&body);
    }
}
