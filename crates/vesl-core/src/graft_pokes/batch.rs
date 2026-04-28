//! Batch-graft poke builders.
//!
//! batch-graft v0.1 is the settlement-flush buffer — accumulates
//! caller-supplied intents and emits a single `%batch-flushed` effect
//! when the configured count threshold trips. The downstream
//! orchestrator (this Rust side or whoever owns the kernel) listens
//! for the bundled flush and routes each intent into settle-graft on
//! its own time.
//!
//! v0.1 ships ONE trigger: `count`. The other two triggers from the
//! 03 spec (`pages`, `time`) are deferred per
//! `vesl-nockup/.dev/03_DEFERRALS.md`.
//!
//! C1: `%batch-add` carries a jammed intent atom that the kernel
//! re-cues inside its poke arm. Wrap is the canonical mule pattern
//! from queue-graft / log-graft.

use nock_noun_rs::{atom_from_u64, make_atom_in, make_tag_in, NounSlab};
use nockvm::noun::{D, T};

/// Build a `[%batch-init threshold=@ud]` poke.
///
/// `threshold = 0` disables auto-flush (manual `%batch-flush` only).
/// `threshold = 1` flushes on every add (functionally equivalent to
/// no batching — included so the count knob has a well-defined low
/// end without special-casing).
pub fn build_batch_init_poke(threshold: u64) -> NounSlab {
    let mut slab = NounSlab::new();
    let tag = make_tag_in(&mut slab, "batch-init");
    let value = atom_from_u64(&mut slab, threshold);
    let poke = T(&mut slab, &[tag, value]);
    slab.set_root(poke);
    slab
}

/// Build a `[%batch-add payload=@]` poke.
///
/// `intent_jammed` is the caller-jammed bytes of whatever noun the
/// intent should carry. The kernel re-cues it inside a mule, so
/// malformed input surfaces as `%batch-error`.
pub fn build_batch_add_poke(intent_jammed: &[u8]) -> NounSlab {
    let mut slab = NounSlab::new();
    let tag = make_tag_in(&mut slab, "batch-add");
    let payload = make_atom_in(&mut slab, intent_jammed);
    let poke = T(&mut slab, &[tag, payload]);
    slab.set_root(poke);
    slab
}

/// Build a `[%batch-flush ~]` poke.
pub fn build_batch_flush_poke() -> NounSlab {
    let mut slab = NounSlab::new();
    let tag = make_tag_in(&mut slab, "batch-flush");
    let poke = T(&mut slab, &[tag, D(0)]);
    slab.set_root(poke);
    slab
}

#[cfg(test)]
mod tests {
    use super::*;
    use nock_noun_rs::{jam_to_bytes, new_stack, slab_root};

    #[test]
    fn build_batch_init_poke_emits_nonempty_jam() {
        let slab = build_batch_init_poke(5);
        let mut stack = new_stack();
        let bytes = jam_to_bytes(&mut stack, slab_root(&slab));
        assert!(!bytes.is_empty());
    }

    #[test]
    fn build_batch_init_poke_handles_disable() {
        // threshold=0 must encode without panic.
        let _slab = build_batch_init_poke(0);
    }

    #[test]
    fn build_batch_init_poke_handles_max() {
        // u64::MAX must encode without panic — manifest's pending-cap
        // gate happens kernel-side, helpers stay ignorant.
        let _slab = build_batch_init_poke(u64::MAX);
    }

    #[test]
    fn build_batch_add_poke_emits_nonempty_jam() {
        let slab = build_batch_add_poke(b"\x02"); // jam(0)
        let mut stack = new_stack();
        let bytes = jam_to_bytes(&mut stack, slab_root(&slab));
        assert!(!bytes.is_empty());
    }

    #[test]
    fn build_batch_add_poke_handles_empty_payload() {
        let _slab = build_batch_add_poke(b"");
    }

    #[test]
    fn build_batch_add_poke_handles_large_payload() {
        let body: Vec<u8> = (0..32_768).map(|i| (i & 0xff) as u8).collect();
        let _slab = build_batch_add_poke(&body);
    }

    #[test]
    fn build_batch_flush_poke_emits_nonempty_jam() {
        let slab = build_batch_flush_poke();
        let mut stack = new_stack();
        let bytes = jam_to_bytes(&mut stack, slab_root(&slab));
        assert!(!bytes.is_empty());
    }
}
