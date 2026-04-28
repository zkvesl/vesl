//! Clock-graft poke builder.
//!
//! clock-graft v0.1 is the deterministic event-counter primitive —
//! `%clock-tick` advances a monotonic counter in state by 1 and emits
//! `%clock-ticked now=@da`. Pair with the `%clock-tick` arm installed
//! by `graft-inject`.
//!
//! Determinism floor: there is no host wall-clock here. Callers pace
//! their own ticks; "now" is opaque kernel-time units. See the graft
//! header (`protocol/lib/clock-graft.hoon`) for why boot-offset and
//! block-time sources are deferred.

use nock_noun_rs::{make_tag_in, NounSlab};
use nockvm::noun::{D, T};

/// Build a `[%clock-tick ~]` poke.
pub fn build_clock_tick_poke() -> NounSlab {
    let mut slab = NounSlab::new();
    let tag = make_tag_in(&mut slab, "clock-tick");
    let poke = T(&mut slab, &[tag, D(0)]);
    slab.set_root(poke);
    slab
}

#[cfg(test)]
mod tests {
    use super::*;
    use nock_noun_rs::{jam_to_bytes, new_stack, slab_root};

    #[test]
    fn build_clock_tick_poke_emits_nonempty_jam() {
        let slab = build_clock_tick_poke();
        let mut stack = new_stack();
        let bytes = jam_to_bytes(&mut stack, slab_root(&slab));
        assert!(!bytes.is_empty());
    }
}
