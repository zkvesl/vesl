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
//! (atom payloads), `Option<bool>` (loobeans, where `0` = `%.y` and
//! `1` = `%.n`), or `Option<Vec<T>>` ([`peek_unit_list`] — for peek
//! results shaped `(unit (list T))`, e.g. `[%validate-rules ...]`).
//! Callers that need a multi-arg shape (e.g.
//! `[%rbac-has-perm pubkey=@ perm=@t ~]`) build the slab by hand and
//! feed the result to `unwrap_triple_unit_atom` or `peek_loobean`.
//!
//! Effect decoders for cross-graft cue-seam patterns
//! ([`decode_queue_popped`]) live alongside the peek decoders here;
//! they walk an `&[NounSlab]` effect list rather than a single peek
//! slab, but the noun-walking idioms are the same.
//!
//! [`effect_head_tag`] / [`effect_head_tags`] are the generic
//! head-atom rendering helpers — drivers that only need the cause-tag
//! of an effect should call these instead of re-implementing the
//! `slab.root() → as_cell → head().as_atom → from_utf8` dance.
//!
//! See zkvesl-docs `reference/sdk.md` "Peek calls from Rust" for
//! worked examples.

use nock_noun_rs::{atom_from_u64, make_tag_in, NounSlab};
use nockvm::noun::{Noun, D, T};

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

/// Decode a peek result whose payload is `(unit (... (unit @)))` as a u64,
/// walking through any depth of `[~ ...]` wrapping until it reaches the
/// innermost atom. Returns `None` for malformed shapes (any cell with a
/// non-`~` head, or a leaf that won't fit in `u64`); returns `Some(0)`
/// both when the value really is 0 *and* when the path didn't bind
/// (bare `~`, `[~ ~]`, deeper-`~` cases). Disambiguate with
/// [`peek_unit_list`] or a path-specific decoder when the null/zero
/// distinction matters for your domain.
///
/// Use for atomic peek paths regardless of catalog wrapping depth:
///   `[%clock-now ~]`, `[%counter-value name ~]`,
///   `[%batch-pending-len ~]`, `[%queue-len ~]`, `[%log-len ~]`,
///   `[%rbac-perm-count pubkey ~]`. log, rbac, and validate add an
///   extra `[~ ...]` layer beyond the standard 2-deep peek wrap; the
///   walk handles either depth without caller awareness.
pub fn peek_atom_u64(result: &NounSlab) -> Option<u64> {
    let mut noun = unsafe { *result.root() };
    loop {
        if let Ok(atom) = noun.as_atom() {
            return atom.as_u64().ok();
        }
        let cell = noun.as_cell().ok()?;
        let head = cell.head().as_atom().ok()?;
        if !head.as_ne_bytes().iter().all(|&b| b == 0) {
            return None;
        }
        noun = cell.tail();
    }
}

/// Decode a triple-unit peek result whose payload is `(unit (list T))`.
///
/// Returns:
/// - `None` if the outer wrapper is malformed (path didn't bind, or
///   the slab isn't shaped like a peek result).
/// - `Some(vec![])` if the inner unit is `~` (path bound, but no
///   value is stored — e.g. `[%validate-rules cause-tag ~]` peek
///   when no rules are installed for the tag).
/// - `Some(items)` if the inner unit holds a non-empty `(list T)`,
///   with each element decoded via the caller-supplied closure.
///
/// `decode` extracts a `T` from each list element. Returning `None`
/// from the closure aborts the walk and propagates `None` from the
/// outer call. For atom-only lists (e.g. `(list @t)`), pull bytes
/// via `noun.as_atom().ok()?.as_ne_bytes()`. For cell-shaped
/// elements, decompose with `noun.as_cell()`.
///
/// Use cases that benefit:
/// - `[%validate-rules cause-tag ~]` → `Vec<RuleNounRepr>`
/// - `[%log-tail count ~]` → `Vec<LogEntry>`
///
/// Footgun: do **not** use [`unwrap_triple_unit_atom`] on a
/// `(unit (list T))` peek — the inner value is a cell, not an atom,
/// so the unwrap returns `None` even when items are present. Profiles
/// C and I (R3) hit this.
pub fn peek_unit_list<T>(
    result: &NounSlab,
    decode: impl Fn(Noun) -> Option<T>,
) -> Option<Vec<T>> {
    // SAFETY: copy the Noun out immediately; the slab outlives this scope.
    let noun = unsafe { *result.root() };

    let outer = noun.as_cell().ok()?;
    let inner_cell = outer.tail().as_cell().ok()?;
    let maybe_value = inner_cell.tail();

    // Inner unit is bare `~` → no value at the path; return empty vec.
    if let Ok(atom) = maybe_value.as_atom() {
        if atom.as_ne_bytes().iter().all(|&b| b == 0) {
            return Some(Vec::new());
        }
        return None;
    }

    // `[~ list]` cell — strip the `~` head, walk the list tail.
    let value_cell = maybe_value.as_cell().ok()?;
    let mut cur = value_cell.tail();
    let mut items = Vec::new();

    loop {
        if let Ok(atom) = cur.as_atom() {
            if atom.as_ne_bytes().iter().all(|&b| b == 0) {
                break; // `~` list terminator
            }
            return None; // malformed (non-zero atom mid-list)
        }
        let cell = cur.as_cell().ok()?;
        items.push(decode(cell.head())?);
        cur = cell.tail();
    }
    Some(items)
}

/// Extract the head-atom tag of an effect cell as a string.
///
/// Drivers that just want to inspect *which* effect was emitted typically
/// only need the cause-name. This helper unifies the
/// `slab.root() → as_cell → head().as_atom → trim → from_utf8` dance
/// that otherwise gets re-implemented in every effect-consuming driver.
///
/// Returns `None` for atom-shaped effects (no head) and for cell effects
/// whose head is itself a cell. NUL-padding from the `tas!` cord
/// representation is stripped before UTF-8 decode; non-UTF-8 head bytes
/// are rendered via [`String::from_utf8_lossy`] (so the function never
/// returns `None` purely because of byte-encoding noise — only when the
/// effect's *shape* prevents a head-tag from being read at all).
pub fn effect_head_tag(effect: &NounSlab) -> Option<String> {
    // SAFETY: the slab outlives this function call.
    let root = unsafe { *effect.root() };
    let cell = root.as_cell().ok()?;
    let tag_atom = cell.head().as_atom().ok()?;
    let trimmed = trim_trailing_zeros(tag_atom.as_ne_bytes());
    Some(String::from_utf8_lossy(&trimmed).into_owned())
}

/// Slice form of [`effect_head_tag`]. Filters out effects that don't
/// expose a head-atom tag, so the returned `Vec` may be shorter than
/// `effects`.
pub fn effect_head_tags(effects: &[NounSlab]) -> Vec<String> {
    effects.iter().filter_map(effect_head_tag).collect()
}

/// Decode a `%queue-popped` effect into `(id, body_bytes)`.
///
/// Walks `effects` looking for the first cell whose head is the cord
/// `%queue-popped` (the queue-graft's pop-emit tag, defined at
/// `protocol/lib/queue-graft.hoon`'s `[%queue-popped job=(unit
/// [id=@ud body=*])]` shape). Returns:
/// - `None` if no `%queue-popped` effect is present, or if `job` was
///   `~` (queue empty at pop time).
/// - `Some((id, body_bytes))` if a head was popped. `body_bytes` is
///   the raw atom representation (`as_ne_bytes()`); pair with
///   [`crate::rejam_atom`] before forwarding to a cue-consuming graft
///   (`%batch-add`, `%log-append`, `%registry-put`) to canonicalize
///   the bytes through cue→jam at the cross-graft seam.
///
/// The body must be atom-shaped — this is the v0.1 cross-graft cue
/// seam pattern. Cell-shaped bodies (legal under `body=*` but not
/// produced by the v0.1 builders) return `None`.
pub fn decode_queue_popped(effects: &[NounSlab]) -> Option<(u64, Vec<u8>)> {
    for slab in effects {
        // SAFETY: copy the Noun out immediately; the slab outlives this scope.
        let root = unsafe { *slab.root() };

        let cell = match root.as_cell() {
            Ok(c) => c,
            Err(_) => continue,
        };
        let tag_atom = match cell.head().as_atom() {
            Ok(a) => a,
            Err(_) => continue,
        };
        let tag_trimmed = trim_trailing_zeros(tag_atom.as_ne_bytes());
        if tag_trimmed.as_slice() != b"queue-popped" {
            continue;
        }

        // Tail is the unit `(unit [id=@ud body=*])`.
        let job = cell.tail();

        // `~` (atom 0) → queue was empty at pop time.
        if let Ok(atom) = job.as_atom()
            && atom.as_ne_bytes().iter().all(|&b| b == 0)
        {
            return None;
        }

        // `[~ [id body]]` — strip the unit `~`, then split the pair.
        let unit_cell = job.as_cell().ok()?;
        let pair = unit_cell.tail().as_cell().ok()?;
        let id = pair.head().as_atom().ok()?.as_u64().ok()?;
        let body_atom = pair.tail().as_atom().ok()?;
        // Raw atom bytes; do NOT trim — caller forwards to rejam_atom
        // which expects the native atom representation.
        return Some((id, body_atom.as_ne_bytes().to_vec()));
    }
    None
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

    // ---- peek_unit_list ----

    /// Helper: wrap a payload noun in the triple-unit peek envelope
    /// `[~ [~ payload]]` and return the slab.
    fn wrap_triple_unit(payload_builder: impl FnOnce(&mut NounSlab) -> Noun) -> NounSlab {
        let mut slab: NounSlab = NounSlab::new();
        let payload = payload_builder(&mut slab);
        let inner = T(&mut slab, &[D(0), payload]);
        let outer = T(&mut slab, &[D(0), inner]);
        slab.set_root(outer);
        slab
    }

    #[test]
    fn peek_unit_list_returns_empty_for_inner_unit_zero() {
        // [~ [~ ~]] — path bound, no value installed.
        let slab = wrap_triple_unit(|_| D(0));
        let result: Option<Vec<u64>> =
            peek_unit_list(&slab, |n| n.as_atom().ok().and_then(|a| a.as_u64().ok()));
        assert_eq!(result, Some(Vec::new()));
    }

    #[test]
    fn peek_unit_list_decodes_atom_list() {
        // Inner value: [~ [1 [2 [3 0]]]] → list of three atoms.
        let slab = wrap_triple_unit(|s| {
            let one = atom_from_u64(s, 1);
            let two = atom_from_u64(s, 2);
            let three = atom_from_u64(s, 3);
            let list = T(s, &[one, two, three, D(0)]);
            T(s, &[D(0), list])
        });
        let result: Option<Vec<u64>> =
            peek_unit_list(&slab, |n| n.as_atom().ok().and_then(|a| a.as_u64().ok()));
        assert_eq!(result, Some(vec![1u64, 2, 3]));
    }

    #[test]
    fn peek_unit_list_decoder_failure_propagates_none() {
        // Same shape as above but the decoder rejects the second item.
        let slab = wrap_triple_unit(|s| {
            let one = atom_from_u64(s, 1);
            let two = atom_from_u64(s, 99);
            let list = T(s, &[one, two, D(0)]);
            T(s, &[D(0), list])
        });
        let result: Option<Vec<u64>> = peek_unit_list(&slab, |n| {
            let v = n.as_atom().ok()?.as_u64().ok()?;
            if v == 99 { None } else { Some(v) }
        });
        assert_eq!(result, None);
    }

    // ---- peek_atom_u64 ----

    /// Helper: wrap a payload noun in N nested `[~ ...]` units.
    /// `wrap_n_unit(2, ...)` builds `[~ [~ payload]]`;
    /// `wrap_n_unit(3, ...)` builds `[~ [~ [~ payload]]]`.
    fn wrap_n_unit(depth: usize, payload_builder: impl FnOnce(&mut NounSlab) -> Noun) -> NounSlab {
        let mut slab: NounSlab = NounSlab::new();
        let mut current = payload_builder(&mut slab);
        for _ in 0..depth {
            current = T(&mut slab, &[D(0), current]);
        }
        slab.set_root(current);
        slab
    }

    #[test]
    fn peek_atom_u64_decodes_two_deep_wrap() {
        let slab = wrap_n_unit(2, |s| atom_from_u64(s, 42));
        assert_eq!(peek_atom_u64(&slab), Some(42));
    }

    #[test]
    fn peek_atom_u64_decodes_three_deep_wrap() {
        // rbac/log/validate wrap one layer deeper than the standard peek.
        let slab = wrap_n_unit(3, |s| atom_from_u64(s, 999));
        assert_eq!(peek_atom_u64(&slab), Some(999));
    }

    #[test]
    fn peek_atom_u64_collapses_bare_null_to_zero() {
        // Root is bare `~` (atom 0). Walker returns Some(0) — null/zero collapse.
        let mut slab: NounSlab = NounSlab::new();
        slab.set_root(D(0));
        assert_eq!(peek_atom_u64(&slab), Some(0));
    }

    #[test]
    fn peek_atom_u64_collapses_inner_null_to_zero() {
        // [~ ~] — outer matched, inner is bare `~`. Same null/zero collapse.
        let mut slab: NounSlab = NounSlab::new();
        let cell = T(&mut slab, &[D(0), D(0)]);
        slab.set_root(cell);
        assert_eq!(peek_atom_u64(&slab), Some(0));
    }

    #[test]
    fn peek_atom_u64_returns_some_zero_for_real_zero() {
        // [~ [~ 0]] — value really is 0. Must not error.
        let slab = wrap_n_unit(2, |s| atom_from_u64(s, 0));
        assert_eq!(peek_atom_u64(&slab), Some(0));
    }

    #[test]
    fn peek_atom_u64_rejects_non_zero_head() {
        // [1 42] — head isn't `~`, so this isn't a (unit ...) chain.
        let mut slab: NounSlab = NounSlab::new();
        let bad = T(&mut slab, &[D(1), D(42)]);
        slab.set_root(bad);
        assert_eq!(peek_atom_u64(&slab), None);
    }

    #[test]
    fn peek_atom_u64_rejects_deeper_malformed() {
        // [~ [1 42]] — outer cell OK, inner cell head is non-zero.
        let mut slab: NounSlab = NounSlab::new();
        let inner = T(&mut slab, &[D(1), D(42)]);
        let outer = T(&mut slab, &[D(0), inner]);
        slab.set_root(outer);
        assert_eq!(peek_atom_u64(&slab), None);
    }

    // ---- decode_queue_popped ----

    /// Helper: build a single-effect slab for `[%queue-popped <job>]`.
    fn build_queue_popped_effect(job_builder: impl FnOnce(&mut NounSlab) -> Noun) -> NounSlab {
        let mut slab: NounSlab = NounSlab::new();
        let tag = make_tag_in(&mut slab, "queue-popped");
        let job = job_builder(&mut slab);
        let effect = T(&mut slab, &[tag, job]);
        slab.set_root(effect);
        slab
    }

    #[test]
    fn decode_queue_popped_returns_none_for_empty_effects() {
        let effects: Vec<NounSlab> = Vec::new();
        assert_eq!(decode_queue_popped(&effects), None);
    }

    #[test]
    fn decode_queue_popped_returns_none_for_empty_queue() {
        // [%queue-popped ~] — kernel emits this on pop-against-empty.
        let slab = build_queue_popped_effect(|_| D(0));
        assert_eq!(decode_queue_popped(&[slab]), None);
    }

    #[test]
    fn decode_queue_popped_extracts_id_and_body() {
        // [%queue-popped [~ [42 <body>]]]
        let slab = build_queue_popped_effect(|s| {
            let id = atom_from_u64(s, 42);
            let body = nock_noun_rs::make_atom_in(s, b"hello");
            let pair = T(s, &[id, body]);
            T(s, &[D(0), pair])
        });
        let (id, body) = decode_queue_popped(&[slab]).expect("popped");
        assert_eq!(id, 42);
        assert_eq!(trim_trailing_zeros(&body), b"hello");
    }

    #[test]
    fn decode_queue_popped_skips_non_matching_tag() {
        // [%rbac-granted ~] — different tag, decoder must skip.
        let mut slab: NounSlab = NounSlab::new();
        let tag = make_tag_in(&mut slab, "rbac-granted");
        let effect = T(&mut slab, &[tag, D(0)]);
        slab.set_root(effect);
        assert_eq!(decode_queue_popped(&[slab]), None);
    }

    // ---- effect_head_tag / effect_head_tags ----

    #[test]
    fn effect_head_tag_returns_tag_for_well_formed_cell() {
        // [%settle-noted *] — the typical effect shape.
        let mut slab: NounSlab = NounSlab::new();
        let tag = make_tag_in(&mut slab, "settle-noted");
        let effect = T(&mut slab, &[tag, D(99)]);
        slab.set_root(effect);
        assert_eq!(effect_head_tag(&slab).as_deref(), Some("settle-noted"));
    }

    #[test]
    fn effect_head_tag_returns_none_for_atom_only_effect() {
        // Bare atom — no head/tail to inspect.
        let mut slab: NounSlab = NounSlab::new();
        slab.set_root(D(42));
        assert_eq!(effect_head_tag(&slab), None);
    }

    #[test]
    fn effect_head_tag_returns_none_for_cell_with_cell_head() {
        // [[a b] *] — head is a cell, not an atom.
        let mut slab: NounSlab = NounSlab::new();
        let head = T(&mut slab, &[D(1), D(2)]);
        let effect = T(&mut slab, &[head, D(0)]);
        slab.set_root(effect);
        assert_eq!(effect_head_tag(&slab), None);
    }

    #[test]
    fn effect_head_tag_lossy_decodes_non_utf8_head() {
        // Build [<bad-bytes> ~] where the head atom contains non-UTF-8 bytes.
        // 0xff 0xfe is not a valid UTF-8 sequence; from_utf8_lossy renders
        // it as two U+FFFD replacement characters.
        let mut slab: NounSlab = NounSlab::new();
        let head = nock_noun_rs::make_atom_in(&mut slab, &[0xff, 0xfe]);
        let effect = T(&mut slab, &[head, D(0)]);
        slab.set_root(effect);
        let got = effect_head_tag(&slab).expect("non-UTF-8 still produces Some");
        assert!(
            got.contains('\u{fffd}'),
            "expected lossy replacement, got {got:?}",
        );
    }

    #[test]
    fn effect_head_tags_collects_only_valid_heads() {
        // Three slabs: one atom-only, one well-formed cell, one cell with
        // cell head. effect_head_tags must keep only the middle one.
        let mut atom_slab: NounSlab = NounSlab::new();
        atom_slab.set_root(D(7));

        let mut good_slab: NounSlab = NounSlab::new();
        let tag = make_tag_in(&mut good_slab, "registry-stored");
        let good = T(&mut good_slab, &[tag, D(0)]);
        good_slab.set_root(good);

        let mut nested_slab: NounSlab = NounSlab::new();
        let head = T(&mut nested_slab, &[D(1), D(2)]);
        let nested = T(&mut nested_slab, &[head, D(0)]);
        nested_slab.set_root(nested);

        let tags = effect_head_tags(&[atom_slab, good_slab, nested_slab]);
        assert_eq!(tags, vec!["registry-stored".to_string()]);
    }

    #[test]
    fn effect_head_tags_preserves_order_for_multiple_cell_effects() {
        let mut a: NounSlab = NounSlab::new();
        let ta = make_tag_in(&mut a, "settle-registered");
        let na = T(&mut a, &[ta, D(0)]);
        a.set_root(na);

        let mut b: NounSlab = NounSlab::new();
        let tb = make_tag_in(&mut b, "settle-noted");
        let nb = T(&mut b, &[tb, D(0)]);
        b.set_root(nb);

        let tags = effect_head_tags(&[a, b]);
        assert_eq!(
            tags,
            vec!["settle-registered".to_string(), "settle-noted".to_string()],
        );
    }
}
