# shellcheck shell=bash
# Sourced by scripts/build-extension.sh — validates the manifest `id`. The id is the namespace of every
# analytics event the extension emits, so it must be lowercase reverse-DNS with at least 3 segments.
# Reserved portal namespaces are NOT checked here; that belongs to extension signing/publish.

EXTENSION_ID_REGEX='^[a-z0-9]+(\.[a-z0-9-]+){2,}$'

# extension_id_valid <id> -> 0 if the id matches EXTENSION_ID_REGEX.
extension_id_valid() { [[ "${1-}" =~ $EXTENSION_ID_REGEX ]]; }

# extension_id_error <id> -> the ✗ message for a bad id.
extension_id_error() {
  printf "  ✗ manifest.json id '%s' must be lowercase reverse-DNS with at least 3 segments, matching %s (e.g. com.acme.my-extension) — it is the analytics event namespace" "${1-}" "$EXTENSION_ID_REGEX"
}

# extension_id_fe_mismatches <frontend-src-dir> <manifest-id> -> prints each `EXTENSION_ID = '<v>'` value found
# under the dir that differs from the manifest id (one per line); prints nothing when none declared or all match.
# A stale value makes the host silently drop every analytics event.
extension_id_fe_mismatches() {
  local dir="${1-}" mid="${2-}" v
  [ -d "$dir" ] || return 0
  while IFS= read -r v; do
    [ -n "$v" ] && [ "$v" != "$mid" ] && printf '%s\n' "$v"
  done < <(grep -rhoE "EXTENSION_ID[[:space:]]*=[[:space:]]*'[^']*'" "$dir" 2>/dev/null | sed -E "s/.*'([^']*)'.*/\1/" | sort -u)
  return 0
}
