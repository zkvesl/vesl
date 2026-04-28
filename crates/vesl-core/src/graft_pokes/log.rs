//! Log-graft poke builder.
//!
//! log-graft v0.1 is the append-only audit-trail primitive —
//! `%log-append` prepends an entry with a monotonic seq + caller-
//! supplied `tag=@ta` + caller-jammed `data=*` payload. Newest first;
//! oldest evicted past the retention cap (hardcoded at 100k for v0.1
//! — see the graft header for why).
//!
//! C1: payload is jammed by the caller and re-cued inside the kernel
//! arm, wrapped in mule. Malformed input surfaces as `%log-error`
//! rather than a panic.
//!
//! Pair with the `%log-append` arm installed by `graft-inject`.

use nock_noun_rs::{make_atom_in, make_tag_in, NounSlab};
use nockvm::noun::T;

/// Build a `[%log-append tag=@ta payload=@]` poke.
///
/// `tag` is a short ASCII identifier (typically a graft / cause name —
/// e.g. `"settle"`, `"registry-put"`). `data_jammed` is the caller-
/// jammed bytes of whatever noun the entry should carry. The kernel
/// re-cue's it inside a mule so malformed input surfaces as
/// `%log-error`.
pub fn build_log_append_poke(tag: &str, data_jammed: &[u8]) -> NounSlab {
    let mut slab = NounSlab::new();
    let cause_tag = make_tag_in(&mut slab, "log-append");
    let entry_tag = make_tag_in(&mut slab, tag);
    let payload = make_atom_in(&mut slab, data_jammed);
    let poke = T(&mut slab, &[cause_tag, entry_tag, payload]);
    slab.set_root(poke);
    slab
}

#[cfg(test)]
mod tests {
    use super::*;
    use nock_noun_rs::{jam_to_bytes, new_stack, slab_root};

    #[test]
    fn build_log_append_poke_emits_nonempty_jam() {
        let slab = build_log_append_poke("settle", b"\x02"); // jam(0) = 0x02
        let mut stack = new_stack();
        let bytes = jam_to_bytes(&mut stack, slab_root(&slab));
        assert!(!bytes.is_empty());
    }

    #[test]
    fn empty_data_does_not_panic() {
        let _slab = build_log_append_poke("settle", b"");
    }

    #[test]
    fn large_data_does_not_panic() {
        let body: Vec<u8> = (0..32_768).map(|i| (i & 0xff) as u8).collect();
        let _slab = build_log_append_poke("registry-put", &body);
    }
}
