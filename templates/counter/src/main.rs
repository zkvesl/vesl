use std::error::Error;
use std::fs;

use nockapp::kernel::boot;
use nockapp::noun::slab::NounSlab;
use nockapp::wire::{SystemWire, Wire};
use nockapp::NockApp;
use nockvm::noun::{NounAllocator, D, T};
use nockvm_macros::tas;

#[tokio::main]
async fn main() -> Result<(), Box<dyn Error>> {
    let cli = boot::default_boot_cli(false);
    boot::init_default_tracing(&cli);

    let kernel = load_kernel()?;

    let mut app: NockApp =
        boot::setup(&kernel, cli, &[], "counter", None).await?;

    // Increment 3 times
    for i in 0..3 {
        let mut slab = NounSlab::new();
        let poke = T(&mut slab, &[D(tas!(b"inc")), D(0)]);
        slab.set_root(poke);

        let effects = app.poke(SystemWire.to_wire(), slab).await?;
        print_effects(&effects, &format!("inc #{}", i + 1));
    }

    // Decrement once
    let mut slab = NounSlab::new();
    let poke = T(&mut slab, &[D(tas!(b"dec")), D(0)]);
    slab.set_root(poke);

    let effects = app.poke(SystemWire.to_wire(), slab).await?;
    print_effects(&effects, "dec");

    // Reset
    let mut slab = NounSlab::new();
    let poke = T(&mut slab, &[D(tas!(b"reset")), D(0)]);
    slab.set_root(poke);

    let effects = app.poke(SystemWire.to_wire(), slab).await?;
    print_effects(&effects, "reset");

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

fn print_effects(effects: &[NounSlab], label: &str) {
    for effect in effects.iter() {
        let noun = unsafe { effect.root() };
        let space = effect.noun_space();
        if let Ok(cell) = noun.in_space(&space).as_cell() {
            if cell.head().eq_bytes(b"count") {
                if let Ok(atom) = cell.tail().as_atom() {
                    println!("[{}] count = {}", label, atom.as_u64().unwrap_or(0));
                }
            }
        }
    }
}
