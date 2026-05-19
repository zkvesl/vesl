#!/usr/bin/env bash
# Soft drift check across templates/*/build.rs.
#
# graft-mint is the canonical (most-commented) build.rs. This script
# auto-discovers every template whose build.rs defines
# emit_kernel_cause_tags() and diffs the helper + its doc-block
# against the canonical.
#
# Per-template cargo:rerun-if-changed lists legitimately differ (each
# template imports its own subset of hoon/lib/*.hoon), so main()'s
# body is NOT diffed — only the codegen helper, which does the same
# job everywhere.
#
# Exit code is always 0 — this is informational. Run it after editing
# any template's build.rs to confirm what kind of drift your change
# introduces. CI can wire this in as a non-gating check.
#
# Companion to scripts/check-jam.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

CANONICAL="templates/graft-mint/build.rs"
mapfile -t SIBLINGS < <(grep -l "^fn emit_kernel_cause_tags" templates/*/build.rs \
    | grep -v "^${CANONICAL}\$" \
    | sort)

# Print everything from the docblock for emit_kernel_cause_tags (or
# the fn signature if no doc block) through EOF. The helper sits at
# the bottom of build.rs in every template, so reading to EOF is safe.
extract_emit_section() {
    awk '
        /^\/\/\/ Drift-detection codegen/ { p=1 }
        /^fn emit_kernel_cause_tags\(/ { p=1 }
        p { print }
    ' "$1"
}

if [[ ! -f "$CANONICAL" ]]; then
    echo "error: canonical $CANONICAL not found" >&2
    exit 2
fi

canonical_section=$(extract_emit_section "$CANONICAL")
if [[ -z "$canonical_section" ]]; then
    echo "error: emit_kernel_cause_tags not found in $CANONICAL" >&2
    exit 2
fi

echo "canonical: $CANONICAL"

clean=1
for sib in "${SIBLINGS[@]}"; do
    if [[ ! -f "$sib" ]]; then
        echo "warn:  $sib missing — skipping"
        continue
    fi
    sib_section=$(extract_emit_section "$sib")
    if [[ "$sib_section" != "$canonical_section" ]]; then
        echo "drift: $sib"
        diff <(echo "$canonical_section") <(echo "$sib_section") | sed 's/^/       /' || true
        echo ""
        clean=0
    else
        echo "ok:    $sib"
    fi
done

if [[ "$clean" -eq 1 ]]; then
    echo "all template build.rs codegen helpers match canonical"
else
    echo "Drift detected. Real fixes (cargo:warning wording, codegen failure"
    echo "handling) should be reconciled across all templates with the helper."
    echo ""
    echo "To reconcile: copy the canonical emit_kernel_cause_tags + docblock"
    echo "from $CANONICAL into each sibling listed above. Then re-run."
fi

# Informational — never gates.
exit 0
