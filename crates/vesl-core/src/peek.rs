//! Peek-path builders and result decoders for v0.1 grafts.
//!
//! Every commitment graft (mint/guard/settle) and state graft
//! (kv/counter/queue/registry/log/etc.) ships a `++peek` arm whose
//! result is wrapped as `[~ [~ (unit @)]]` — three layers of unit
//! around an atom. Drivers calling `app.peek(slab)` need the same
//! ~50 lines of slab construction + tail-walking to read out a value.
//!
//! Path-builders here cover the three shapes that v0.1 grafts use:
//!
//! - `[%<tag> hull=@ ~]` — hull-keyed (mint/guard/settle commitments)
//! - `[%<tag> key=@t ~]` — cord-keyed (kv/counter `@t` map keys)
//! - `[%<tag> ~]`        — keyless (log-len, queue-len, clock-now)
//!
//! Decoders strip the triple-unit and return either `Option<Vec<u8>>`
//! (atom payloads) or `Option<bool>` (loobeans, where `0` = `%.y`
//! and `1` = `%.n`). Callers that need a multi-arg shape (e.g.
//! `[%rbac-has-perm pubkey=@ perm=@t ~]`) build the slab by hand and
//! feed the result to `unwrap_triple_unit_atom` or `peek_loobean`.
//!
//! See zkvesl-docs `reference/sdk.md` "Peek calls from Rust" for
//! worked examples.

use nock_noun_rs::{atom_from_u64, make_tag_in, NounSlab};
use nockvm::noun::{D, T};

/// Build a `[%<tag> hull=@ ~]` peek path slab.
///
/// Used by every commitment graft (mint/guard/settle) — they all key
/// their trellis on `hull=@`.
pub fn build_hull_peek_path(tag: &str, hull: u64) -> NounSlab {
    let mut slab = NounSlab::new();
    let tag_atom = make_tag_in(&mut slab, tag);
    let hull_atom = atom_from_u64(&mut slab, hull);
    let path = T(&mut slab, &[tag_atom, hull_atom, D(0)]);
    slab.set_root(path);
    slab
}

/// Build a `[%<tag> key=@t ~]` peek path slab.
///
/// Cord-keyed analog of `build_hull_peek_path` — used by state grafts
/// that key on `@t` (kv-graft, counter-graft).
pub fn build_keyed_peek_path(tag: &str, key: &str) -> NounSlab {
    let mut slab = NounSlab::new();
    let tag_atom = make_tag_in(&mut slab, tag);
    let key_atom = make_tag_in(&mut slab, key);
    let path = T(&mut slab, &[tag_atom, key_atom, D(0)]);
    slab.set_root(path);
    slab
}

/// Build a `[%<tag> ~]` peek path slab.
///
/// For tag-only peeks: `log-len`, `queue-len`, `clock-now`,
/// `batch-pending-len`, `batch-threshold`.
pub fn build_keyless_peek_path(tag: &str) -> NounSlab {
    let mut slab = NounSlab::new();
    let tag_atom = make_tag_in(&mut slab, tag);
    let path = T(&mut slab, &[tag_atom, D(0)]);
    slab.set_root(path);
    slab
}

/// Strip the triple-unit `[~ [~ (unit @)]]` wrapper that every v0.1
/// graft places around `(~(get by …) k)` peeks.
///
/// Returns `Some(atom_bytes)` when a value is present, `None` for a
/// hit on an absent key. Trailing zeros are trimmed so callers can
/// compare against canonical input bytes (e.g. the original cord).
///
/// Footgun: for loobean peeks (e.g. `%rbac-has-perm`), the decoder
/// collapses atom-0-as-`%.y` onto the same `None` boundary as
/// "absent value." Use [`peek_loobean`] for those — never
/// `unwrap_triple_unit_atom`.
///
/// Structural mismatches (peek result wasn't a valid triple-unit
/// shape) silently return `None` rather than surfacing an error.
/// If your driver needs strict decode failure, walk the noun yourself.
pub fn unwrap_triple_unit_atom(result: &NounSlab) -> Option<Vec<u8>> {
    // SAFETY: copy the Noun out immediately; the slab outlives this scope.
    let noun = unsafe { *result.root() };

    let outer = noun.as_cell().ok()?;
    let inner_cell = outer.tail().as_cell().ok()?;
    let maybe_value = inner_cell.tail();

    if let Ok(atom) = maybe_value.as_atom() {
        let bytes = atom.as_ne_bytes();
        if bytes.iter().all(|&b| b == 0) {
            return None;
        }
        return Some(trim_trailing_zeros(bytes));
    }

    let value_cell = maybe_value.as_cell().ok()?;
    let root_atom = value_cell.tail().as_atom().ok()?;
    Some(trim_trailing_zeros(root_atom.as_ne_bytes()))
}

/// Decode a triple-unit peek result as a Hoon loobean.
///
/// Hoon's `?` is `0` = `%.y` (true), `1` = `%.n` (false). After
/// trimming trailing zeros, true round-trips as an empty byte vec
/// (atom 0) and false as `[1]`. Returns `None` if the inner unit is
/// bare `~` (graft never produced a loobean for this key) or if the
/// bytes don't match a recognized loobean shape.
///
/// Use this in preference to [`unwrap_triple_unit_atom`] whenever
/// the graft contract returns `(unit ?)` — the latter conflates
/// atom-0 (true) with the absent case, which is wrong for loobeans.
pub fn peek_loobean(result: &NounSlab) -> Option<bool> {
    let noun = unsafe { *result.root() };

    let outer = noun.as_cell().ok()?;
    let inner_cell = outer.tail().as_cell().ok()?;
    let maybe_value = inner_cell.tail();

    // Inner ~ → no loobean produced for this key.
    let value_cell = maybe_value.as_cell().ok()?;
    let atom = value_cell.tail().as_atom().ok()?;
    let trimmed = trim_trailing_zeros(atom.as_ne_bytes());
    match trimmed.as_slice() {
        [] => Some(true),    // atom 0 = %.y
        [1] => Some(false),  // atom 1 = %.n
        _ => None,
    }
}

/// Atoms are word-aligned little-endian; trim trailing zero padding so
/// the returned bytes match the cord/atom the caller fed in.
fn trim_trailing_zeros(bytes: &[u8]) -> Vec<u8> {
    let len = bytes.iter().rposition(|&b| b != 0).map_or(0, |i| i + 1);
    bytes[..len].to_vec()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn build_hull_peek_path_emits_three_element_path() {
        let slab = build_hull_peek_path("settle-registered", 42);
        let noun = unsafe { *slab.root() };
        let outer = noun.as_cell().expect("outer cell");
        let _tag = outer.head();
        let tail = outer.tail().as_cell().expect("tail cell");
        let _hull = tail.head();
        assert_eq!(
            tail.tail().as_atom().unwrap().as_u64().unwrap(),
            0,
            "third element must be ~ (D(0))",
        );
    }

    #[test]
    fn build_keyed_peek_path_round_trips_cord() {
        let slab = build_keyed_peek_path("kv-value", "greeting");
        let noun = unsafe { *slab.root() };
        let outer = noun.as_cell().unwrap();
        let tail = outer.tail().as_cell().unwrap();
        let key_bytes = tail.head().as_atom().unwrap().as_ne_bytes().to_vec();
        assert_eq!(trim_trailing_zeros(&key_bytes), b"greeting");
    }

    #[test]
    fn build_keyless_peek_path_is_two_element() {
        let slab = build_keyless_peek_path("log-len");
        let noun = unsafe { *slab.root() };
        let outer = noun.as_cell().unwrap();
        assert_eq!(
            outer.tail().as_atom().unwrap().as_u64().unwrap(),
            0,
            "tail of keyless path must be ~",
        );
    }
}
