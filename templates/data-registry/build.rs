use std::path::Path;
use std::process::Command;
use std::{env, fs};

fn main() {
    println!("cargo:rerun-if-changed=hoon/app/app.hoon");
    println!("cargo:rerun-if-changed=hoon/lib/lib.hoon");
    // Manifest changes affect the generated kernel_cause_tags.rs; re-run
    // when any .toml under hoon/lib/ moves.
    println!("cargo:rerun-if-changed=hoon/lib");

    let out_dir = env::var("OUT_DIR").unwrap();
    let hoon_app_file = "hoon/app/app.hoon";

    if Path::new(hoon_app_file).exists() {
        let output = Command::new("hoonc")
            .args(&[hoon_app_file, "--output", &format!("{}/app.nock", out_dir)])
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
                    "cargo:warning=Could not run hoonc: {}. Skipping Hoon compilation.",
                    e
                );
            }
        }
    } else {
        println!(
            "cargo:warning=No Hoon file found at {}. Skipping Hoon compilation.",
            hoon_app_file
        );
    }
}

/// Drift-detection codegen: emit `kernel_cause_tags.rs` so drivers can
/// `include!` the slice + `assert_kernel_cause_tag!` macro, letting cargo
/// build catch driver/kernel cause-tag drift. Failures are warnings —
/// drivers can opt out by gating the macro on `cfg(any())` or skipping the
/// include — so the build still succeeds when graft-inject isn't installed.
fn emit_kernel_cause_tags(out_dir: &str, hoon_app_file: &str) {
    let cause_tags_out = format!("{}/kernel_cause_tags.rs", out_dir);
    let result = Command::new("graft-inject")
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
