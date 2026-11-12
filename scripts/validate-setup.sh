#!/usr/bin/env bash
# Validates a manifest's frontend.setup the way the portal does at runtime (a bad entry is silently ignored there).
# Usage: validate-setup.sh <manifest.json>   → exit 0 if absent or valid; else one "  ✗" line per problem on stderr, exit 1.
set -euo pipefail

M="${1:?usage: validate-setup.sh <manifest.json>}"
viol=0
bad() { echo "  ✗ $1" >&2; viol=1; }

[ "$(jq -r '.frontend.setup | type' "$M")" != "null" ] || exit 0
if [ "$(jq -r '.frontend.setup | type' "$M")" != "object" ]; then
  bad "frontend.setup must be an object"; exit 1
fi

url=$(jq -r '.frontend.setup.relativeUrl | if type == "string" then . else "" end' "$M")
if [ -z "$url" ]; then
  bad "frontend.setup.relativeUrl is required"
else
  case "$url" in extensions/*) ;; *) bad "frontend.setup.relativeUrl '$url' must start with extensions/" ;; esac
  # Routes without a scope are workspace-scoped, so only an explicit "admin" matches.
  if ! jq -e --arg u "$url" '[.frontend.routes[]? | select(.path == $u and .scope == "admin")] | length > 0' "$M" >/dev/null; then
    bad "frontend.setup.relativeUrl '$url' must match an admin-scoped route in frontend.routes (add { \"path\": \"$url\", \"scope\": \"admin\" })"
  fi
fi

if jq -e '.frontend.setup | has("title") and (.title | type) != "string"' "$M" >/dev/null; then
  bad "frontend.setup.title must be a string"
fi

exit "$viol"
