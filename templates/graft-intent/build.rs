use std::path::Path;
use std::process::Command;
use std::{env, fs};

fn main() {
    println!("cargo:rerun-if-changed=hoon/app/app.hoon");
    println!("cargo:rerun-if-changed=hoon/lib/intent-graft.hoon");
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

        let output = Command::new("hoonc")
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

        let _ = fs::copy(format!("{}/app.nock", out_dir), "out.jam");
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
