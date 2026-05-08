//! Snapshot / resume wrapper for live NockApps.
//!
//! Closes the RM1 HARD-BUG-1 gap: without a checkpoint API, "does state
//! from earlier profiles survive through composition changes?" — the
//! defining test of the meta-mode dogfood round — is unreachable.
//!
//! Two-call API:
//!
//! ```ignore
//! let snap = vesl_checkpoint::snapshot(&app, snapshot_dir, &app_hoon).await?;
//! drop(app);
//! let resumed = vesl_checkpoint::resume(&jam_path, &snap, "name").await?;
//! ```
//!
//! `snapshot()` writes a `state.jam` (in
//! [`nockapp::nockapp::export::ExportedState`] format) plus a
//! `meta.toml` with the source app.hoon SHA-256, timestamp, and
//! nockapp crate version. `resume()` parses the meta, sets
//! [`nockapp::kernel::boot::Cli::state_jam`] to the snapshot's
//! `state.jam`, and calls [`nockapp::kernel::boot::setup`] — i.e., it
//! reuses the existing import path inside nockapp; no companion
//! upstream patch on the resume side.
//!
//! The schema-migration helper (declarative state-shape diff or
//! per-transition migrators) is intentionally out of scope here. Wait
//! for actual cumulative-domain pressure to surface what shape it
//! should take.
//!
//! The reference consumer is the meta-mode dogfood driver documented in
//! `vesl-core/.dev/DOGFOOD_META.md` "Per-transition procedure" Step 5
//! ("State-shape compatibility check"); see that doc for the
//! `snapshot-state` / `restore-state-and-exercise` driver wiring.

use std::path::{Path, PathBuf};
use std::time::SystemTime;

use anyhow::{anyhow, Context, Result};
use nockapp::kernel::boot;
use nockapp::NockApp;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

/// Bundle returned by [`snapshot`] and consumed by [`resume`].
///
/// `dir` is the directory holding the snapshot artifacts
/// (`state.jam` plus `meta.toml`). Callers can persist `Snapshot`
/// directly via `serde` if they want a typed handle, or just hold
/// the `dir: PathBuf` and reconstruct via [`Snapshot::load`] later.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Snapshot {
    /// Directory holding the snapshot files.
    pub dir: PathBuf,
    /// Hex-encoded SHA-256 of the app.hoon source at snapshot time.
    /// Lets resumes verify the consumer is loading state into a
    /// kernel built from the same Hoon (mismatches are warnings, not
    /// errors, since composition changes are the whole point of
    /// snapshot/resume).
    pub source_sha256: String,
    /// Wall-clock when `snapshot` returned.
    pub timestamp: SystemTime,
    /// `CARGO_PKG_VERSION` of the `vesl-checkpoint` crate that wrote
    /// the snapshot. Lets future versions detect format-incompatible
    /// older bundles (no migration logic ships with this version —
    /// the field is forward-looking).
    pub vesl_checkpoint_version: String,
}

impl Snapshot {
    /// Read a previously written snapshot from `dir`. Equivalent to
    /// holding the [`Snapshot`] returned by [`snapshot`] across a
    /// restart.
    pub async fn load(dir: &Path) -> Result<Self> {
        let meta_path = dir.join(META_TOML);
        let bytes = tokio::fs::read(&meta_path)
            .await
            .with_context(|| format!("read {}", meta_path.display()))?;
        let meta: MetaToml = toml::from_str(
            std::str::from_utf8(&bytes)
                .with_context(|| format!("decode {} as utf-8", meta_path.display()))?,
        )
        .with_context(|| format!("parse {}", meta_path.display()))?;
        Ok(Self {
            dir: dir.to_path_buf(),
            source_sha256: meta.snapshot.source_sha256,
            timestamp: parse_timestamp(&meta.snapshot.timestamp)?,
            vesl_checkpoint_version: meta.snapshot.vesl_checkpoint_version,
        })
    }

    /// Path to the bundled `state.jam`. Set this on
    /// [`nockapp::kernel::boot::Cli::state_jam`] (or pass through
    /// [`resume`]) to load the captured kernel state into a fresh
    /// boot.
    pub fn state_jam(&self) -> PathBuf {
        self.dir.join(STATE_JAM)
    }
}

/// Capture the live `app`'s kernel state into `dir`.
///
/// Creates `dir` if missing. Writes:
/// - `dir/state.jam` — bincode-encoded
///   [`nockapp::nockapp::export::ExportedState`], ready for
///   `Cli::state_jam` import on resume.
/// - `dir/meta.toml` — source SHA-256, timestamp, nockapp version.
///
/// The app is not consumed; callers can keep poking it after the
/// snapshot returns. (Contrast with `boot::setup`'s
/// `cli.export_state_jam` path, which exits after writing.)
///
/// `source_app_hoon` is the file used to compile this kernel — the
/// snapshot records its sha256 so a future `resume` can detect "you
/// loaded into a different kernel build" if needed.
pub async fn snapshot(
    app: &NockApp,
    dir: &Path,
    source_app_hoon: &Path,
) -> Result<Snapshot> {
    tokio::fs::create_dir_all(dir)
        .await
        .with_context(|| format!("create snapshot dir {}", dir.display()))?;

    let source_sha256 = sha256_of_file(source_app_hoon)
        .await
        .with_context(|| format!("hash {}", source_app_hoon.display()))?;
    let timestamp = SystemTime::now();
    let vesl_checkpoint_version = env!("CARGO_PKG_VERSION").to_string();

    let state_jam_path = dir.join(STATE_JAM);
    app.export_state(&state_jam_path)
        .await
        .map_err(|e| anyhow!("export_state failed: {e}"))?;

    let meta = MetaToml {
        snapshot: MetaSection {
            source_sha256: source_sha256.clone(),
            timestamp: format_timestamp(timestamp),
            vesl_checkpoint_version: vesl_checkpoint_version.clone(),
        },
    };
    let meta_str = toml::to_string_pretty(&meta).context("serialize meta.toml")?;
    let meta_path = dir.join(META_TOML);
    tokio::fs::write(&meta_path, meta_str)
        .await
        .with_context(|| format!("write {}", meta_path.display()))?;

    Ok(Snapshot {
        dir: dir.to_path_buf(),
        source_sha256,
        timestamp,
        vesl_checkpoint_version,
    })
}

/// Boot a fresh `NockApp` from `jam_path` with the snapshot's state
/// imported.
///
/// Reads the kernel jam at `jam_path` (typically the freshly compiled
/// out.jam from the new kernel build), constructs a boot `Cli` whose
/// `state_jam` field points at the snapshot's `state.jam`, and runs
/// `boot::setup`. The import path inside nockapp picks up the
/// `state_jam` and rehydrates the kernel state on top of the new
/// kernel definition.
///
/// Mismatch handling: if the new kernel's `++load` arm rejects the
/// snapshotted state shape, `boot::setup` propagates the error.
/// Schema migration is the consumer's responsibility (see crate-level
/// docs — out of scope here).
///
/// **Schema-extension caveat (RM4 §1).** Same-composition resume
/// (the new kernel has the same set of grafts as the snapshot)
/// roundtrips cleanly — pre- and post-resume pokes both emit effects.
/// **Schema-extension resume** (the new kernel adds grafts that
/// weren't in the snapshot) is currently a silent-failure case: the
/// marker template's `++load` arm is identity, so new graft state
/// fields end up at undefined nockvm axes. Subsequent pokes against
/// those grafts run inside the wrapper's mule guard, panic on the
/// undefined access, and return empty effect lists — the operator
/// sees `Ok(vec![])` instead of a clear error. The fix lives in
/// graft-inject's codegen (a `nockup:load-defaults` marker
/// populated with each graft's `++new-state` default); deferred
/// until v0.2 surfaces the requirement. Until then, treat resume as
/// same-composition only and re-run the full poke sequence after
/// any composition change rather than relying on snapshot+resume.
pub async fn resume(
    jam_path: &Path,
    snapshot: &Snapshot,
    name: &str,
) -> Result<NockApp> {
    let kernel_bytes = tokio::fs::read(jam_path)
        .await
        .with_context(|| format!("read kernel jam at {}", jam_path.display()))?;

    let mut cli = boot::default_boot_cli(false);
    cli.state_jam = Some(
        snapshot
            .state_jam()
            .to_str()
            .context("snapshot state.jam path is not utf-8")?
            .to_string(),
    );

    boot::setup(&kernel_bytes, cli, &[], name, None)
        .await
        .map_err(|e| anyhow!("boot::setup failed during resume: {e}"))
}

const STATE_JAM: &str = "state.jam";
const META_TOML: &str = "meta.toml";

#[derive(Debug, Serialize, Deserialize)]
struct MetaToml {
    snapshot: MetaSection,
}

#[derive(Debug, Serialize, Deserialize)]
struct MetaSection {
    source_sha256: String,
    timestamp: String,
    vesl_checkpoint_version: String,
}

async fn sha256_of_file(path: &Path) -> Result<String> {
    let bytes = tokio::fs::read(path)
        .await
        .with_context(|| format!("read {}", path.display()))?;
    let mut hasher = Sha256::new();
    hasher.update(&bytes);
    let hash = hasher.finalize();
    Ok(format!("{:x}", hash))
}

fn format_timestamp(t: SystemTime) -> String {
    let secs = t
        .duration_since(SystemTime::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    format!("@unix:{secs}")
}

fn parse_timestamp(s: &str) -> Result<SystemTime> {
    let secs: u64 = s
        .strip_prefix("@unix:")
        .context("meta.toml timestamp missing @unix: prefix")?
        .parse()
        .context("meta.toml timestamp seconds did not parse")?;
    Ok(SystemTime::UNIX_EPOCH + std::time::Duration::from_secs(secs))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn timestamp_round_trips() {
        let now = SystemTime::now();
        let s = format_timestamp(now);
        assert!(s.starts_with("@unix:"));
        let back = parse_timestamp(&s).unwrap();
        // Whole-second precision only — drop sub-second fragment.
        let now_secs = now
            .duration_since(SystemTime::UNIX_EPOCH)
            .unwrap()
            .as_secs();
        let back_secs = back
            .duration_since(SystemTime::UNIX_EPOCH)
            .unwrap()
            .as_secs();
        assert_eq!(now_secs, back_secs);
    }

    #[test]
    fn meta_toml_round_trips() {
        let meta = MetaToml {
            snapshot: MetaSection {
                source_sha256: "abc123".into(),
                timestamp: "@unix:1700000000".into(),
                vesl_checkpoint_version: "0.1.0".into(),
            },
        };
        let s = toml::to_string_pretty(&meta).unwrap();
        let back: MetaToml = toml::from_str(&s).unwrap();
        assert_eq!(back.snapshot.source_sha256, meta.snapshot.source_sha256);
        assert_eq!(back.snapshot.timestamp, meta.snapshot.timestamp);
        assert_eq!(
            back.snapshot.vesl_checkpoint_version,
            meta.snapshot.vesl_checkpoint_version
        );
    }

    #[tokio::test]
    async fn sha256_matches_known_value() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("hello.txt");
        tokio::fs::write(&path, b"hello").await.unwrap();
        let hash = sha256_of_file(&path).await.unwrap();
        // sha256("hello") = 2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824
        assert_eq!(
            hash,
            "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        );
    }
}
