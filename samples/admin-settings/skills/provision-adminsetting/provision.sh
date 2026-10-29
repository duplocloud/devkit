#!/usr/bin/env bash
set -euo pipefail

# Provisions an Admin Setting: read settingKey + settingValue from the spec the platform wrote to
# shared/admin-setting.json, record `key = "value"` as the summary, and write it back via the resource's OWN
# ADMIN route. Admin routes carry no {workspaceId}: the resource always belongs to the Admin Workspace.
# Status and results are two separate APIs.

SPEC_FILE="shared/admin-setting.json"

ID=$(jq -r '.id' "$SPEC_FILE")
KEY=$(jq -r '.spec.settingKey // ""' "$SPEC_FILE")
VALUE=$(jq -r '.spec.settingValue // ""' "$SPEC_FILE")

BASE="${DUPLO_BASE:-$DUPLO_HOST}"
RES="$BASE/v1/aiservicedesk/admin/data/environment/extensions/admin-settings/$ID"

auth=(-H "Authorization: Bearer $DUPLO_TOKEN" -H "Content-Type: application/json")

# 1. Report progress
curl -fsS -X POST "$RES/status" "${auth[@]}" \
  -d '{"status":"Processing","subStatus":"Applying setting"}'

# 2. Apply (here: just describe it)
SUMMARY="$KEY = \"$VALUE\""

# 3. Write the result — the body IS the typed AdminSettingResult object
curl -fsS -X POST "$RES/results" "${auth[@]}" \
  -d "$(jq -nc --arg s "$SUMMARY" '{summary:$s}')"

# 4. Complete
curl -fsS -X POST "$RES/status" "${auth[@]}" \
  -d '{"status":"Complete","subStatus":"Setting applied"}'

echo "Done: $SUMMARY"
