#!/usr/bin/env bash
# Recompile each kernel from source Hoon and assert the resulting JAM sha256
# matches assets/CHECKSUMS.sha256.
#
# Catches refactors that change kernel bytes without a reviewed checksum bump —
# the class of bug that a "harmless" Hoon cleanup can introduce when nobody
# notices the STARK subject shifted.
#
# Covers the kernels whose JAM assets live in vesl-core:
#   guard-kernel.hoon  → assets/guard.jam
#   mint-kernel.hoon   → assets/mint.jam
#   settle-kernel.hoon → assets/settle.jam
#   forge-kernel.hoon  → assets/forge.jam
#
# vesl-kernel.hoon and its JAM (vesl.jam) live in hull-llm, since
# vesl-kernel composes RAG-specific logic; that repo owns its own check.
#
# Usage:
#   ./scripts/check-jam.sh
#
# Env:
#   NOCK_HOME — path to the nockchain monorepo root (falls back to vesl.toml).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# -- Resolve NOCK_HOME (mirrors Makefile pattern) ----------------------------
if [[ -z "${NOCK_HOME:-}" ]] && [[ -f vesl.toml ]]; then
    NOCK_HOME="$(grep -s '^nock_home' vesl.toml | sed 's/.*= *"\(.*\)"/\1/' | head -1)"
fi
if [[ -z "${NOCK_HOME:-}" ]]; then
    echo "error: NOCK_HOME is not set and vesl.toml has no nock_home entry." >&2
    echo "       set NOCK_HOME to the nockchain monorepo root, or populate vesl.toml." >&2
    exit 2
fi
if [[ ! -d "$NOCK_HOME/hoon/common" ]]; then
    echo "error: $NOCK_HOME/hoon/common not found — is NOCK_HOME correct?" >&2
    exit 2
fi

# -- Check hoonc --------------------------------------------------------------
if ! command -v hoonc >/dev/null 2>&1; then
    echo "error: hoonc not on PATH." >&2
    echo "       build it from the nockchain monorepo: cd \$NOCK_HOME && make install-hoonc" >&2
    exit 2
fi

# -- Check library symlinks (setup-hoon-tree.sh pre-req) ----------------------
for dir in common apps dat jams test-jams; do
    if [[ ! -L "hoon/$dir" ]]; then
        echo "error: hoon/$dir is missing — run scripts/setup-hoon-tree.sh first." >&2
        exit 2
    fi
done

CHECKSUMS="assets/CHECKSUMS.sha256"
if [[ ! -f "$CHECKSUMS" ]]; then
    echo "error: $CHECKSUMS not found — nothing to verify against." >&2
    exit 2
fi

# -- Verify each kernel -------------------------------------------------------
status=0
for kernel in guard mint settle forge; do
    src="protocol/lib/${kernel}-kernel.hoon"
    if [[ ! -f "$src" ]]; then
        echo "error: $src missing." >&2
        status=1
        continue
    fi

    expected="$(awk -v k="${kernel}.jam" '$2 == k { print $1 }' "$CHECKSUMS")"
    if [[ -z "$expected" ]]; then
        echo "error: no checksum for ${kernel}.jam in $CHECKSUMS." >&2
        status=1
        continue
    fi

    # Compile into a per-kernel out file so a partial run doesn't corrupt later
    # iterations. hoonc always writes out.jam in cwd; rename once we have it.
    rm -f out.jam
    if ! hoonc --new "$src" hoon/ >/dev/null 2>&1; then
        echo "FAIL ${kernel}: hoonc exited non-zero." >&2
        status=1
        continue
    fi
    if [[ ! -f out.jam ]]; then
        echo "FAIL ${kernel}: hoonc produced no out.jam (library symlink missing?)." >&2
        status=1
        continue
    fi

    actual="$(sha256sum out.jam | awk '{print $1}')"
    if [[ "$actual" != "$expected" ]]; then
        echo "FAIL ${kernel}: sha256 mismatch." >&2
        echo "  source:   $src" >&2
        echo "  expected: $expected  ($CHECKSUMS)" >&2
        echo "  actual:   $actual  (freshly compiled)" >&2
        status=1
    else
        echo "ok   ${kernel}  $actual"
    fi
done

rm -f out.jam

if [[ "$status" -ne 0 ]]; then
    echo "" >&2
    echo "JAM determinism check failed." >&2
    echo "A refactor changed kernel bytes. Either: (a) back out the change, or" >&2
    echo "(b) if the change is intentional, update assets/CHECKSUMS.sha256 in a" >&2
    echo "dedicated commit with a reviewer explanation." >&2
    echo "" >&2
    echo "If kernel sources are UNMODIFIED, your local hoonc may be stale" >&2
    echo "relative to NOCK_PIN (rebuild: cd \$NOCK_HOME && make install-hoonc)," >&2
    echo "or the committed JAMs predate the current NOCK_PIN and need regen." >&2
    exit 1
fi

echo "all kernels verified against $CHECKSUMS"
