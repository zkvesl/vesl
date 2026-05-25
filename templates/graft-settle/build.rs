use std::path::Path;
use std::process::Command;
use std::{env, fs};

fn main() {
    println!("cargo:rerun-if-changed=hoon/app/app.hoon");
    println!("cargo:rerun-if-changed=hoon/lib/settle-graft.hoon");
    println!("cargo:rerun-if-changed=hoon/lib/rag-logic.hoon");
    println!("cargo:rerun-if-changed=hoon/lib/vesl-merkle.hoon");
    println!("cargo:rerun-if-changed=hoon/sur/vesl.hoon");
    println!("cargo:rerun-if-changed=hoon/lib");

    let out_dir = env::var("OUT_DIR").unwrap();
    let hoon_app_file = "hoon/app/app.hoon";

    if Path::new(hoon_app_file).exists() {
        let nock_home = env::var("NOCK_HOME").ok();
        let mut args = vec![
            hoon_app_file.to_string(),
            "--output".to_string(),
            format!("{}/app.nock", out_dir),
        ];
        if let Some(ref home) = nock_home {
            args.push(format!("{}/hoon/", home));
        }

        // AUDIT 2026-05-25 H-25: resolve hoonc the same way nockup-graft
        // is resolved in `vesl/build.rs` (audit H-19) — explicit
        // `HOONC_BIN`, then ~/.cargo/bin/hoonc, never a bare PATH search.
        // A malicious `hoonc` earlier on PATH would otherwise hijack
        // `cargo build` AND produce an attacker-controlled `out.jam`
        // baked into the released binary.
        let Some(hoonc) = resolve_hoonc() else {
            println!(
                "cargo:warning=hoonc not found at $HOONC_BIN or ~/.cargo/bin/hoonc; \
                 skipping kernel JAM compile. Install via the nockchain quick-start \
                 or set HOONC_BIN to a binary path."
            );
            return;
        };
        let output = Command::new(&hoonc)
            .args(&args)
            .output();

        match output {
            Ok(result) => {
                if !result.status.success() {
                    panic!(
                        "Failed to compile Hoon: {}",
                        String::from_utf8_lossy(&result.stderr)
                    );
                }
                println!("cargo:rustc-env=COMPILED_HOON_PATH={}/app.nock", out_dir);
                emit_kernel_cause_tags(&out_dir, hoon_app_file);
            }
            Err(e) => {
                println!(
                    "cargo:warning=Could not run hoonc: {}. Using pre-compiled out.jam.",
                    e
                );
            }
        }
    }
}

/// Drift-detection codegen: emit `kernel_cause_tags.rs` so drivers can
/// `include!` the slice + `assert_kernel_cause_tag!` macro, letting cargo
/// build catch driver/kernel cause-tag drift. Failures are warnings —
/// drivers can opt out by gating the macro on `cfg(any())` or skipping the
/// include — so the build still succeeds when graft-inject isn't installed.
fn emit_kernel_cause_tags(out_dir: &str, hoon_app_file: &str) {
    let cause_tags_out = format!("{}/kernel_cause_tags.rs", out_dir);
    // AUDIT 2026-05-19 H-19: resolve the codegen binary from an explicit
    // path (NOCKUP_GRAFT_BIN), never a bare PATH search — a malicious
    // graft-inject earlier on PATH would otherwise hijack `cargo build`.
    // Unset → skip codegen (non-fatal; set it to enable the cause-tag
    // drift check).
    let graft_bin = match env::var("NOCKUP_GRAFT_BIN") {
        Ok(p) => p,
        Err(_) => {
            println!(
                "cargo:warning=NOCKUP_GRAFT_BIN unset — skipping cause-tag \
                 codegen; set it to the graft-inject binary path to enable."
            );
            return;
        }
    };
    let result = Command::new(&graft_bin)
        .args([
            "codegen",
            "kernel-cause-tags",
            hoon_app_file,
            "--out",
            &cause_tags_out,
        ])
        .output();
    match result {
        Ok(r) if r.status.success() => {
            println!(
                "cargo:rustc-env=KERNEL_CAUSE_TAGS_PATH={}",
                cause_tags_out
            );
        }
        Ok(r) => println!(
            "cargo:warning=graft-inject codegen failed: {}",
            String::from_utf8_lossy(&r.stderr)
        ),
        Err(e) => println!(
            "cargo:warning=Could not run graft-inject: {}. Skipping cause-tag codegen — \
             driver `assert_kernel_cause_tag!` invocations will fail to expand.",
            e
        ),
    }
    let _ = fs::metadata(out_dir);
}

/// Resolve the hoonc binary path with no PATH lookup. Tries an explicit
/// `HOONC_BIN` env var first, then ~/.cargo/bin/hoonc, then gives up.
/// Per audit 2026-05-25 H-25 — never bare PATH for the binary that
/// produces our kernel JAM.
fn resolve_hoonc() -> Option<String> {
    if let Ok(p) = env::var("HOONC_BIN") {
        if Path::new(&p).exists() {
            return Some(p);
        }
    }
    if let Some(home) = env::var_os("HOME") {
        let candidate = Path::new(&home).join(".cargo/bin/hoonc");
        if candidate.exists() {
            return Some(candidate.to_string_lossy().into_owned());
        }
    }
    None
}
