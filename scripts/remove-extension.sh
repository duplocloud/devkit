#!/usr/bin/env bash
# Unload + delete a loaded extension by its manifest id.
# Usage: ./scripts/remove-extension.sh com.duplocloud.helloworld
set -euo pipefail
cd "$(dirname "$0")/.."

ID="${1:?usage: remove-extension.sh <extension-id>}"
source "$(dirname "$0")/_target.sh"   # → BASE_URL + TOKEN from .env per DUPLO_TARGET
[ -n "$TOKEN" ] || { echo "No token resolved — set DUPLO_ADMIN_TOKEN (local) or DUPLO_TOKEN (remote) in .env." >&2; exit 1; }

echo "==> Removing extension '$ID' from $BASE_URL"
curl -fsS -X DELETE "$BASE_URL/v1/aiservicedesk/admin/extensions/$ID" \
  -H "Authorization: Bearer $TOKEN"
echo "==> Removed (route withdrawn live)."
