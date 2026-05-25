# Security Policy

## Reporting a Vulnerability

If you find a security issue in vesl-core — anything that bypasses a
kernel-integrity check, breaks a STARK soundness boundary, breaks a
cross-VM digest equivalence, lets a poke reach an unintended state, or
otherwise breaks the threat model documented in
`docs/AUDIT_REPORT_FINAL_BETA_2026-05-25.md` — please report it
privately via GitHub Security Advisories:

**[github.com/zkvesl/vesl-core/security/advisories/new](https://github.com/zkvesl/vesl-core/security/advisories/new)**

Do **not** open a public issue, post to chat, or otherwise disclose
the finding before a fix is shipped. We will coordinate disclosure
with you once a fix is ready.

## In scope

- Kernel integrity (`kernels-*` crates, `assets/*.jam`, the
  `verify_kernel()` gate, the `OnceLock`-guarded `kernel()` accessor)
- Hoon protocol (`protocol/lib/*-kernel.hoon`, `*-graft.hoon`,
  `vesl-merkle`, `vesl-stark-verifier`, `vesl-prover`, `vesl-gates`)
- STARK soundness — anything that lets an invalid proof verify or a
  valid proof fail to verify
- Rust ↔ Hoon boundary crates (`nock-noun-rs`, `nockchain-tip5-rs`,
  `nockchain-client-rs`, `vesl-core`, `vesl-checkpoint`)
- Settlement / replay / commitment logic in shipped JAMs

## Out of scope

- Bugs in upstream nockchain (report to `nockchain/nockchain` directly)
- Issues in pre-release placeholder code — notably the
  intent-scripting surface (`intent-graft.hoon`,
  `vesl-wallet::sign_intent`); these are documented as passthrough
  placeholders pending upstream design
- Style, documentation, or non-security correctness bugs — use the
  regular issue tracker for those

## Supported versions

The `dev` branch HEAD is the only supported surface today. After the
public beta tag lands, see the Releases page for the supported
version line.

## Acknowledgements

Security researchers who follow responsible disclosure are credited
by name in `CHANGELOG.md` and the corresponding GitHub Release notes,
unless they prefer anonymity.
