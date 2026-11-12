#!/usr/bin/env bash
# Validates a manifest's frontend.setup the way the portal does at runtime (a bad entry is silently ignored there).
# With a sibling frontend/src, also checks its SETUP_PATH constant equals relativeUrl.
# Usage: validate-setup.sh <manifest.json>   → exit 0 if absent or valid; else one "  ✗" line per problem on stderr, exit 1.
set -euo pipefail

M="${1:?usage: validate-setup.sh <manifest.json>}"
viol=0
bad() { echo "  ✗ $1" >&2; viol=1; }

# A non-object manifest or frontend is "no setup" to the portal, so it is not an error here.
kind=$(jq -r '(if type == "object" then .frontend else null end) | (if type == "object" then .setup else null end) | type' "$M")
[ "$kind" != "null" ] || exit 0
[ "$kind" = "object" ] || { bad "frontend.setup must be an object"; exit 1; }

url=$(jq -r '.frontend.setup.relativeUrl | if type == "string" then . else "" end' "$M")
if [ -z "$url" ]; then
  bad "frontend.setup.relativeUrl is required"
else
  case "$url" in extensions/*) ;; *) bad "frontend.setup.relativeUrl '$url' must start with extensions/" ;; esac
  # Routes without a scope are workspace-scoped, so only an explicit "admin" matches.
  if ! jq -e --arg u "$url" '[(.frontend.routes // []) | arrays | .[] | objects | select(.path == $u and .scope == "admin")] | length > 0' "$M" >/dev/null; then
    bad "frontend.setup.relativeUrl '$url' must match an admin-scoped route in frontend.routes (add { \"path\": \"$url\", \"scope\": \"admin\" })"
  fi
fi

if jq -e '.frontend.setup | has("title") and (.title | type) != "string"' "$M" >/dev/null; then
  bad "frontend.setup.title must be a string"
fi

# Build-only: the frontend's setup-page guard matches this path, so its SETUP_PATH must equal relativeUrl.
src="$(dirname "$M")/frontend/src"
if [ -n "$url" ] && [ -d "$src" ]; then
  vals=$( { grep -rhoE "SETUP_PATH[[:space:]]*=[[:space:]]*['\"][^'\"]*['\"]" "$src" 2>/dev/null || true; } \
          | sed -E "s/^[^'\"]*['\"]([^'\"]*)['\"]$/\1/")
  if ! printf '%s\n' "$vals" | grep -qxF -- "$url"; then
    found=$(printf '%s' "$vals" | head -3 | tr '\n' ' ')
    bad "frontend/src has no SETUP_PATH = '$url' (frontend.setup.relativeUrl; the setup page's canMatch reads it)${found:+ — found: $found}"
  fi
fi

exit "$viol"
