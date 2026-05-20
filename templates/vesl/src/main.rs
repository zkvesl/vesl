use std::error::Error;
use std::fs;

use nockapp::kernel::boot;
use nockapp::noun::slab::NounSlab;
use nockapp::wire::{SystemWire, Wire};
use nockapp::NockApp;
use vesl_core::{
    build_settle_note_poke, build_settle_register_poke, Mint, Tip5Hash,
};

#[tokio::main]
async fn main() -> Result<(), Box<dyn Error>> {
    let cli = boot::default_boot_cli(false);
    boot::init_default_tracing(&cli);
    let kernel = load_kernel()?;
    let mut app: NockApp = boot::setup(&kernel, cli, &[], "{{project_name}}", None).await?;

    // 1. Commit data to a Merkle tree.
    //    Default hash-gate verifies single-leaf commits only; see the
    //    vesl-nockup README "Customizing" section for multi-leaf /
    //    signed / STARK gates.
    let items: [&[u8]; 1] = [b"first"];
    let mut mint = Mint::new();
    let root: Tip5Hash = mint.commit(&items);

    // 2. Register the root under hull_id = 1
    poke(&mut app, build_settle_register_poke(1, &root)).await?;

    // 3. Settle a note committing to `first` (note_id = 1, hull = 1)
    poke(&mut app, build_settle_note_poke(1, 1, &root, items[0])).await?;

    Ok(())
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

async fn poke(app: &mut NockApp, slab: NounSlab) -> Result<(), Box<dyn Error>> {
    let effects = app.poke(SystemWire.to_wire(), slab).await?;
    if effects.is_empty() {
        return Err("kernel returned no effects (likely duplicate hull \
                    registration or replay; see settle kernel slog)"
            .into());
    }
    for tag in vesl_core::effect_head_tags(&effects) {
        println!("  effect: %{tag}");
    }
    Ok(())
}
