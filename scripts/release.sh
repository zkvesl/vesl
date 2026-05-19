#!/usr/bin/env bash
# release.sh — preflight + version bump + release-notes draft for a vesl-core tag.
#
# Usage: scripts/release.sh <version>
#   <version> — semver string, optionally with -beta.N / -rc.N prerelease. Leading 'v' stripped.
#
# Behavior:
#   1. Preflight: clean tree, on dev/local-dev, tests + clippy + check-jam.
#   2. Uniform-bump every non-placeholder Cargo.toml under crates/* and kernels/*.
#   3. Render release notes to /tmp/vesl-core-release-notes-<version>.md.
#   4. Commit the bump.
#
# Does NOT push. Does NOT tag. Tagging happens on origin/main after squash-push.

set -euo pipefail

VERSION=${1:?usage: scripts/release.sh <version>}
VERSION=${VERSION#v}

REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

# --- Preflight ---
git diff --quiet || { echo "release.sh: uncommitted changes in working tree"; exit 1; }
git diff --cached --quiet || { echo "release.sh: staged but uncommitted changes"; exit 1; }

branch=$(git rev-parse --abbrev-ref HEAD)
[[ $branch == "dev" || $branch == "local-dev" ]] \
  || { echo "release.sh: must be on dev (or local-dev); current: $branch"; exit 1; }

echo "release.sh: running check-jam.sh"
scripts/check-jam.sh

echo "release.sh: running cargo test -p vesl-core"
cargo test -p vesl-core

echo "release.sh: running cargo clippy --workspace -- -D warnings"
cargo clippy --workspace -- -D warnings

# --- Bump ---
echo "release.sh: bumping crate versions to $VERSION"
for f in crates/*/Cargo.toml kernels/*/Cargo.toml; do
  [[ -f "$f" ]] || continue
  if grep -q '^version = "0.0.0-placeholder"' "$f"; then
    echo "  skip (placeholder): $f"
    continue
  fi
  sed -i "0,/^version = \".*\"/{s//version = \"$VERSION\"/}" "$f"
  echo "  bumped: $f"
done

# --- Compute substitutions ---
NOCK_PIN=$(cd ../nockchain && git rev-parse HEAD)
JAM_SUMS=$(cat assets/CHECKSUMS.sha256)
CRATE_TABLE=$(
  for f in crates/*/Cargo.toml kernels/*/Cargo.toml; do
    [[ -f "$f" ]] || continue
    name=$(awk -F'"' '/^name *=/{print $2; exit}' "$f")
    ver=$(awk -F'"' '/^version *=/{print $2; exit}' "$f")
    printf "| %-22s | %s |\n" "$name" "$ver"
  done
)

# --- Render notes ---
NOTES=/tmp/vesl-core-release-notes-${VERSION}.md
awk -v tag="$VERSION" \
    -v nock_pin="$NOCK_PIN" \
    -v jam_sums="$JAM_SUMS" \
    -v crate_table="$CRATE_TABLE" \
    '{
       gsub(/<TAG>/, tag);
       gsub(/<NOCK_PIN>/, nock_pin);
       if ($0 ~ /<JAM_SUMS>/) { print jam_sums; next }
       if ($0 ~ /<CRATE_TABLE>/) { print crate_table; next }
       print
     }' scripts/release-notes.template.md > "$NOTES"

# --- Commit ---
git add crates/*/Cargo.toml kernels/*/Cargo.toml
git commit -m "release: vesl-core $VERSION"

echo
echo "release.sh: done."
echo "  notes:  $NOTES"
echo "  next:   review notes, squash-push $branch to main, tag origin/main with v$VERSION"
