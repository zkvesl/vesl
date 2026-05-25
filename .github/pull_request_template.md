<!--
Thanks for opening a PR! Quick checklist before you submit:

- [ ] PR targets the `dev` branch (not `main`).
- [ ] `cargo test -p vesl-core` passes locally.
- [ ] `cargo clippy -p vesl-core -- -D warnings` is clean.
- [ ] `scripts/check-pins.sh` passes (NOCK_PIN agreement).

If your change touches `protocol/lib/*-kernel.hoon` or any library
it imports:

- [ ] Regenerated `assets/<name>.jam` and updated
      `scripts/CHECKSUMS.sha256`.
- [ ] `scripts/check-jam.sh` returns all-green locally (the pre-push
      preflight gates this — CI's `jam-determinism` workflow is
      currently disabled pending a reproducible hoonc build).
- [ ] Committed the JAM regen as a separate commit from the Hoon
      edit (reviewer needs the byte change in isolation).

If your change touches `crates/*`, expect a follow-up PR in
vesl-nockup (downstream sync). The `vesl-core-sync.yml` workflow
in vesl-nockup will flag the drift after merge.

First-time contributor? See CONTRIBUTING.md's "Good first PRs"
table — adding a graft manifest, rustdoc, or test vector is a
template-shaped change.
-->

## Summary

<!-- One or two sentences on what changed and why. -->

## Test plan

<!-- How did you verify the change? cargo test? scripts/check-jam.sh
     after a kernel regen? a specific graft composition? Reference
     the relevant command + expected output. -->
