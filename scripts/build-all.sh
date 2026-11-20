#!/usr/bin/env bash
# Build every agent in this repo — one per extensions/<name>/manifest.json — into <dir>/dist/agent.zip.
# A repo can hold many independent agents; this is the canonical "build the whole repo" entrypoint that CI uses.
#
# Usage: ./scripts/build-all.sh [--native]
set -euo pipefail
cd "$(dirname "$0")/.."
shopt -s nullglob

# Strip --native, same rotating-"$@" idiom as build-extension.sh (it preserves arguments containing
# spaces). EXPORTED here, unlike in its sibling: the per-extension build-extension.sh calls below are
# child processes that each run their own builder_dispatch, and a plain shell variable is invisible to
# them — so on a native host each one would containerize and `--native` would mean N container builds
# instead of none. (Inside the container they take the native branch regardless, via /.dockerenv and
# the builder service's own DUPLO_BUILD_NATIVE=1.)
for a in "$@"; do shift; case "$a" in --native) export DUPLO_BUILD_NATIVE=1 ;; *) set -- "$@" "$a" ;; esac; done

# Discover BEFORE resolving a target or a toolchain. A repo with nothing to build must stay a no-op that
# exits 0: it needs no platform, no credentials and no builder image, and CI runs this on every push —
# including on repos that ship no extensions/ at all, with no DUPLO_HOST set. Sourcing _target.sh above
# this point turned that no-op into a hard failure ("DUPLO_TARGET=remote but DUPLO_HOST is unset"). It
# also spent a container start, and possibly a multi-minute image build, to print "nothing to build".
#
# Canonical layout is extensions/<name>/manifest.json. The legacy singular extension/<name>/ and
# extension/manifest.json layouts are still accepted so older repos keep building.
manifests=(extensions/*/manifest.json extension/*/manifest.json extension/manifest.json)
dirs=()
for m in "${manifests[@]}"; do
  # `extension/manifest.json` has no wildcard, so nullglob cannot drop it — it survives as a literal
  # even when absent. This -f is what filters it out.
  [ -f "$m" ] || continue
  dirs+=("$(dirname "$m")")
done
if [ "${#dirs[@]}" -eq 0 ]; then
  echo "No extensions/<name>/manifest.json found — briefs-only directories (PROMPT.md), nothing to build yet."
  exit 0
fi

# shellcheck source=scripts/_target.sh
source "$(dirname "$0")/_target.sh"
# shellcheck source=scripts/_builder.sh
source "$(dirname "$0")/_builder.sh"
# Containerize ONCE for the whole repo, not once per agent: inside the container each
# build-extension.sh call takes the in-container native branch. Safe to dispatch here despite the
# call-it-early rule — this script installs no EXIT trap and creates no temp file, so the `exec` on the
# container path has nothing to strand.
builder_dispatch scripts/build-all.sh

for dir in "${dirs[@]}"; do
  echo "==================== build: $dir ===================="
  ./scripts/build-extension.sh "$dir"
done
echo "==> Built ${#dirs[@]} agent bundle(s)."
