//! Graft poke builders.
//!
//! One module per primitive (settle / mint / guard / forge). Each exposes
//! `build_<primitive>_<verb>_poke(...)` free functions returning a
//! `NounSlab` ready to hand to a kernel `poke`.
//!
//! Every commitment-bearing graft keys its trellis on `hull=@`, so
//! signatures are uniform: `(hull, ...verb-specific...) -> NounSlab`.
//! See vesl/docs/graft-manifest.md and the parameterization plan
//! (vesl-nockup/.dev/00_PARAMETIZATION.md, §"Rust helper surface")
//! for the full convention.

pub mod settle;
pub mod mint;
pub mod guard;
pub mod forge;
pub mod kv;
pub mod counter;
pub mod queue;
pub mod rbac;
pub mod registry;
pub mod clock;
pub mod log;
pub mod validate;
pub mod batch;
