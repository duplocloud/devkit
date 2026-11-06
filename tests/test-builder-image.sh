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
mkdir -p "$TMP/bin"
export BUILDER_TEST_LOG="$TMP/docker.calls"
cat > "$TMP/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$BUILDER_TEST_LOG"
[ "$1" = build ] && [ "${BUILDER_TEST_FAIL_BUILD:-0}" = 1 ] && exit 1
exit 0
DOCKER
chmod +x "$TMP/bin/docker"
export PATH="$TMP/bin:$PATH"

# Stand-in for _target.sh's .env reader, pointed at a temp file.
ENV="$TMP/.env"; : > "$ENV"
_envv() { grep -E "^$1=" "$ENV" 2>/dev/null | head -1 | cut -d= -f2- || true; }

. ./scripts/_builder.sh || { echo "scripts/_builder.sh not found"; exit 1; }
# builder_dispatch resolves RUNTIME before it ever calls builder_resolve_image. Calling the resolver directly
# skips that, so point it at the stub here.
RUNTIME=docker

resolve() { ( unset BUILDER_IMAGE BUILDER_TAG BUILDER_PULL; eval "$1"; builder_resolve_image >/dev/null 2>&1; echo "$BUILDER_IMAGE" ); }

echo "builder image:"

t "defaults to the local .NET 10 toolchain instead of the old SDK 8 image"
: > "$ENV"; got="$(resolve :)"
if [ "$got" = "duplo-extension-builder:dotnet10-local" ]; then ok; else bad "$got"; fi

t "docker-compose.yml falls back to the same local image"
: > "$ENV"; got="$(resolve :)"
if grep -qF -- "\${BUILDER_IMAGE:-$got}" docker-compose.yml; then ok; else bad "compose does not default to $got"; fi

t "BUILDER_TAG in .env still selects a tag"
printf 'BUILDER_TAG=1.2.3\n' > "$ENV"; got="$(resolve :)"
if [ "$got" = "quay.io/duplocloud/duplo-extension-builder:1.2.3" ]; then ok; else bad "$got"; fi

t "BUILDER_TAG=latest, left over in an older .env, also builds the .NET 10 image"
: > "$ENV"; pinned="$(resolve :)"
printf 'BUILDER_TAG=latest\n' > "$ENV"; got="$(resolve :)"
if [ "$got" = "$pinned" ]; then ok; else bad "$got"; fi

t "BUILDER_IMAGE in the environment still replaces the image outright"
: > "$ENV"; got="$(resolve 'export BUILDER_IMAGE=example.com/mine:1')"
if [ "$got" = "example.com/mine:1" ]; then ok; else bad "$got"; fi

t "the default builds the checked-out Dockerfile, even when a cached image exists"
: > "$ENV"; : > "$BUILDER_TEST_LOG"
resolve : >/dev/null
if grep -qF 'build -q -f build/Dockerfile.builder -t duplo-extension-builder:dotnet10-local build' "$BUILDER_TEST_LOG"; then ok
else bad "default reused a cached pre-migration image: $(cat "$BUILDER_TEST_LOG")"; fi

t "BUILDER_PULL=1 refreshes base images for the local builder"
: > "$BUILDER_TEST_LOG"
resolve 'export BUILDER_PULL=1' >/dev/null
if grep -qF 'build --pull -q' "$BUILDER_TEST_LOG"; then ok; else bad "$(cat "$BUILDER_TEST_LOG")"; fi

t "a failed local builder build fails resolution"
: > "$ENV"
if (unset BUILDER_IMAGE BUILDER_TAG; export BUILDER_TEST_FAIL_BUILD=1; builder_resolve_image) >/dev/null 2>&1; then bad "accepted a failed local build"
else ok; fi

t "explicit image overrides are never replaced by a local build"
: > "$BUILDER_TEST_LOG"
resolve 'export BUILDER_IMAGE=example.com/mine:1' >/dev/null
if grep -q '^build ' "$BUILDER_TEST_LOG"; then bad "rebuilt an explicitly selected image"; else ok; fi
echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
