use std::error::Error;
use std::fs;

use nock_noun_rs::{make_atom_in, make_tag_in};
use nockapp::kernel::boot;
use nockapp::noun::slab::NounSlab;
use nockapp::wire::{SystemWire, Wire};
use nockapp::NockApp;
use nockvm::noun::{D, T};

/// graft-intent — family-5 placeholder driver.
///
/// Pokes `%intent-declare` to prove the placeholder crashes loudly with
/// `%intent-graft-placeholder`. A working intent coordination app drops into
/// this same shape once Nockchain upstream publishes the canonical intent
/// structure; until then this binary just demonstrates the reservation.
#[tokio::main]
async fn main() -> Result<(), Box<dyn Error>> {
    let cli = boot::default_boot_cli(false);
    boot::init_default_tracing(&cli);

    let kernel = load_kernel()?;

    let mut app: NockApp =
        boot::setup(&kernel, cli, &[], "graft-intent", None).await?;

    println!("=== graft-intent placeholder demo ===");
    println!();
    println!("Poking %intent-declare on the placeholder kernel.");
    println!("Expected: kernel crashes with %intent-graft-placeholder.");
    println!();

    let mut slab = NounSlab::new();
    let tag = make_tag_in(&mut slab, "intent-declare");
    let hull = D(1);
    let body = make_atom_in(&mut slab, b"placeholder-body");
    let expires_at = D(0);
    let poke = T(&mut slab, &[tag, hull, body, expires_at]);
    slab.set_root(poke);

    let result = app.poke(SystemWire.to_wire(), slab).await;
    match result {
        Ok(effects) => {
            println!("unexpected: poke returned without crashing ({} effects)", effects.len());
            println!("the placeholder is supposed to bang on every cause arm.");
            println!("check that hoon/lib/intent-graft.hoon still has the bang arms.");
            Err("placeholder did not crash".into())
        }
        Err(e) => {
            println!("kernel crashed as expected:");
            println!("  {}", e);
            println!();
            println!("the %intent-graft-placeholder trace confirms the family-5 slot");
            println!("is reserved, not implemented. swap intent-graft.hoon when the");
            println!("canonical upstream intent structure lands.");
            Ok(())
        }
    }
}

/// Read `out.jam` and verify its integrity before boot.
///
/// When `VESL_KERNEL_SHA256` is set, the kernel's sha256 must match it or
/// boot is refused; when unset, boot proceeds with a warning. This keeps
/// the edit-Hoon / recompile / rerun loop fast while letting a production
/// deploy pin the kernel hash (audit C-01).
fn load_kernel() -> Result<Vec<u8>, Box<dyn Error>> {
    use sha2::{Digest, Sha256};

    let kernel =
        fs::read("out.jam").map_err(|e| format!("Failed to read out.jam: {e}"))?;
    match std::env::var("VESL_KERNEL_SHA256") {
        Ok(expected) => {
            let expected = expected.trim();
            let actual: String = Sha256::digest(&kernel)
                .iter()
                .map(|b| format!("{b:02x}"))
                .collect();
            if actual != expected {
                return Err(format!(
                    "out.jam sha256 mismatch: expected {expected}, got {actual} \
                     — refusing to boot"
                )
                .into());
            }
        }
        Err(_) => eprintln!(
            "warning: out.jam integrity unverified — \
             set VESL_KERNEL_SHA256 to pin the kernel hash"
        ),
    }
    Ok(kernel)
}
