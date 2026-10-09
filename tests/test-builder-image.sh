#!/usr/bin/env bash
# Tests for builder_resolve_image in scripts/_builder.sh — which toolchain image a build runs in.
# Uses a stub `docker` on PATH and a throwaway .env; never pulls. Usage: ./tests/test-builder-image.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

PASS=0; FAIL=0
t()   { printf '  %s … ' "$1"; }
ok()  { echo "ok"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"; printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/bin/docker"; chmod +x "$TMP/bin/docker"
export PATH="$TMP/bin:$PATH"

# Stand-in for _target.sh's .env reader, pointed at a temp file.
ENV="$TMP/.env"; : > "$ENV"
_envv() { grep -E "^$1=" "$ENV" 2>/dev/null | head -1 | cut -d= -f2- || true; }

. ./scripts/_builder.sh || { echo "scripts/_builder.sh not found"; exit 1; }

resolve() { ( unset BUILDER_IMAGE BUILDER_TAG BUILDER_PULL; eval "$1"; builder_resolve_image >/dev/null 2>&1; echo "$BUILDER_IMAGE" ); }

echo "builder image:"

t "defaults to the digest-pinned toolchain image"
: > "$ENV"; got="$(resolve :)"
if [[ "$got" =~ ^quay\.io/duplocloud/duplo-extension-builder@sha256:[0-9a-f]{64}$ ]]; then ok; else bad "$got"; fi

t "docker-compose.yml falls back to the same pinned image"
: > "$ENV"; got="$(resolve :)"
if grep -qF -- "\${BUILDER_IMAGE:-$got}" docker-compose.yml; then ok; else bad "compose does not default to $got"; fi

t "BUILDER_TAG in .env still selects a tag"
printf 'BUILDER_TAG=latest\n' > "$ENV"; got="$(resolve :)"
if [ "$got" = "quay.io/duplocloud/duplo-extension-builder:latest" ]; then ok; else bad "$got"; fi

t "BUILDER_IMAGE in the environment still replaces the image outright"
: > "$ENV"; got="$(resolve 'export BUILDER_IMAGE=example.com/mine:1')"
if [ "$got" = "example.com/mine:1" ]; then ok; else bad "$got"; fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
