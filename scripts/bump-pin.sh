#!/usr/bin/env bash
# Atomically bump an upstream PIN across every site in vesl-core.
#
# Usage:
#   scripts/bump-pin.sh nock <40-char-sha>
#
# Currently supported pin type: `nock` (nockchain upstream).
#
# vesl-core's NOCK_PIN lives in two places:
#   .github/workflows/jam-determinism.yml  — CI's NOCK_PIN env
#   Dockerfile                              — ARG NOCKCHAIN_COMMIT
#
# Both must move together; this script writes both in one shot.
#
# Pre-flight: SHA must be 40 lowercase hex chars AND reachable in the
# nockchain repo (sibling ../nockchain/ rev-parse preferred; ls-remote
# fallback). Refuses to write a ghost SHA — directly addresses the
# audit-class bug where sync.sh/CI carried non-existent SHAs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

usage() {
    echo "usage: $0 <type> <sha>" >&2
    echo "  type:  nock" >&2
    echo "  sha:   40-char lowercase hex" >&2
    echo "" >&2
    echo "example: $0 nock fe46f4e3a0ce9532288e9cf3a3fb7e94bf9cba1f" >&2
    exit 2
}

if [[ $# -ne 2 ]]; then
    usage
fi

TYPE="$1"
SHA="$2"

# Validate SHA shape FIRST (defends against sed-injection à la audit
# H-16; SHA flows into sed substitution patterns below).
if [[ ! "$SHA" =~ ^[0-9a-f]{40}$ ]]; then
    echo "error: '$SHA' is not a 40-char lowercase hex SHA" >&2
    exit 2
fi

case "$TYPE" in
    nock)
        REPO_PATH="../nockchain"
        REPO_URL="https://github.com/nockchain/nockchain"
        ;;
    *)
        echo "error: unknown pin type: $TYPE" >&2
        usage
        ;;
esac

# Validate SHA exists upstream.
existed=0
if [[ -d "$REPO_PATH/.git" ]]; then
    if git -C "$REPO_PATH" cat-file -t "$SHA" >/dev/null 2>&1; then
        existed=1
        echo "ok — SHA $SHA found in sibling $REPO_PATH"
    fi
fi
if [[ $existed -eq 0 ]]; then
    if git ls-remote --exit-code "$REPO_URL" "$SHA" >/dev/null 2>&1; then
        existed=1
        echo "ok — SHA $SHA reachable via ls-remote $REPO_URL"
    fi
fi
if [[ $existed -eq 0 ]]; then
    echo "error: SHA $SHA not found in $REPO_PATH and not reachable at $REPO_URL" >&2
    echo "       refusing to bump pin to a ghost SHA" >&2
    exit 1
fi

# --- Apply edits ---
JAM_WF=".github/workflows/jam-determinism.yml"
DOCKERFILE="Dockerfile"

case "$TYPE" in
    nock)
        # NOCK_PIN: <40hex>
        sed -i -E "s/(NOCK_PIN:[[:space:]]*)[0-9a-f]{40}/\1$SHA/" "$JAM_WF"
        # ARG NOCKCHAIN_COMMIT=<40hex>
        sed -i -E "s/(NOCKCHAIN_COMMIT=)[0-9a-f]{40}/\1$SHA/" "$DOCKERFILE"
        echo "updated $JAM_WF"
        echo "updated $DOCKERFILE"
        ;;
esac

echo ""
echo "Bumped $TYPE pin to $SHA in 2 site(s)."
echo "Run scripts/check-pins.sh to verify; commit the diff."
