//! Cargo integration test. Compile the kernel first
//! (`hoonc hoon/app/app.hoon hoon/`), then `cargo test`.

use vesl_test::GraftTestHarness;

#[tokio::test]
async fn graft_lifecycle() -> anyhow::Result<()> {
    let mut harness = GraftTestHarness::boot("out.jam").await?;

    // 1. Run vesl's standard 8-op suite against settle-graft: register,
    //    duplicate-register, verify, register-b, note, replay-note,
    //    unregistered-hull, root-mismatch. Passes for any kernel composed
    //    with settle-graft and the default single-leaf hash gate.
    let report = harness.run_standard_suite().await;
    assert!(
        report.is_success(),
        "standard suite failed:\n  passed: {:?}\n  failed: {:?}",
        report.passed,
        report.failed,
    );

    // 2. Extend with your domain pokes. Example:
    //
    //     use vesl_core::build_counter_increment_poke;
    //     let tags = harness.poke_slab(build_counter_increment_poke("requests")).await?;
    //     assert!(tags.iter().any(|t| t == "counter-incremented"));

    Ok(())
}
