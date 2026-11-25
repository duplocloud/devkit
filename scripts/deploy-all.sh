#!/usr/bin/env bash
# Hot-load every built extension in this repo onto the platform. Run after build-all.sh. Each extension is loaded
# independently; a failed load fails the run.
#
# A build leaves either dist/extension.zip, built from the host's own SDK, or one dist/sdk-<v>/extension.zip per
# version in DUPLO_SDK_VERSIONS. The host loads only a bundle whose sdkVersion equals its own, so for the per-version
# layout this reads the host's SDK version and loads the bundle stamped with it. An extension with no matching
# bundle fails the run, since the host would refuse every other one.
#
# Usage: ./scripts/deploy-all.sh
set -euo pipefail
cd "$(dirname "$0")/.."
shopt -s nullglob

host_sdk=""
# host_sdk_version: the host's SDK version, read through the same endpoint build-extension.sh uses.
host_sdk_version() {
  [ -n "$host_sdk" ] && { printf '%s\n' "$host_sdk"; return; }
  # shellcheck source=scripts/_target.sh
  source "$(dirname "$0")/_target.sh"
  BASE_URL="${BASE_URL%/}"
  [ -n "${TOKEN:-}" ] || { echo "No token resolved — set DUPLO_ADMIN_TOKEN (local) or DUPLO_TOKEN (remote)." >&2; exit 1; }
  host_sdk="$(curl -sSL -m 30 -H "Authorization: Bearer $TOKEN" "$BASE_URL/v1/aiservicedesk/extensions/sdk-version" \
    | jq -r '.version // empty' 2>/dev/null || true)"
  [ -n "$host_sdk" ] \
    || { echo "ERROR: could not read the host SDK version from $BASE_URL/v1/aiservicedesk/extensions/sdk-version" >&2; exit 1; }
  printf '%s\n' "$host_sdk"
}

# bundle_for <dir>: the bundle the host takes, or nothing with a message when the per-version build has none for it.
bundle_for() {
  local dir="$1" z sdk
  [ -f "$dir/dist/extension.zip" ] && { printf '%s\n' "$dir/dist/extension.zip"; return; }
  local versioned=("$dir"/dist/sdk-*/extension.zip)
  [ "${#versioned[@]}" -gt 0 ] || return 0
  sdk="$(host_sdk_version)" || return 1
  for z in "${versioned[@]}"; do
    [ "$(unzip -p "$z" manifest.json | jq -r '.sdkVersion // empty')" = "$sdk" ] && { printf '%s\n' "$z"; return; }
  done
  echo "ERROR: $dir has no bundle for the host's SDK $sdk (built: ${versioned[*]}). Add $sdk to DUPLO_SDK_VERSIONS." >&2
  return 1
}

count=0
for m in extensions/*/manifest.json extension/*/manifest.json extension/manifest.json; do
  [ -f "$m" ] || continue
  dir="$(dirname "$m")"
  z="$(bundle_for "$dir")"
  [ -n "$z" ] || continue
  count=$((count + 1))
  echo "==================== deploy: $z ===================="
  ./scripts/deploy-extension.sh "$z"
done
[ "$count" -gt 0 ] || { echo "No built bundles found — run ./scripts/build-all.sh first." >&2; exit 1; }
echo "==> Hot-loaded $count extension bundle(s)."
