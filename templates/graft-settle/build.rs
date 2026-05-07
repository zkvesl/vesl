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
    }
}

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
            "cargo:warning=Could not run graft-inject: {}. Skipping cause-tag codegen.",
            e
        ),
    }
    let _ = fs::metadata(out_dir);
}
