#!/usr/bin/env bash
set -euo pipefail

# Provisions an Admin Setting Consumer: a WORKSPACE resource that uses an admin-scoped AdminSetting. The admin
# row's details are not in this resource's own spec — AdminSettingConsumerService.GetExpandedSpecForAgentAsync
# embeds them in shared/admin-setting-consumer.json as `adminSetting`. Write-back goes to the resource's OWN
# WORKSPACE route (it lives in a tenant workspace, unlike the admin setting it reads).
# Status and results are two separate APIs.

SPEC_FILE="shared/admin-setting-consumer.json"

ID=$(jq -r '.id' "$SPEC_FILE")
WS=$(jq -r '.ownerWorkspaceId' "$SPEC_FILE")
SETTING_NAME=$(jq -r '.adminSetting.name // ""' "$SPEC_FILE")
KEY=$(jq -r '.adminSetting.settingKey // ""' "$SPEC_FILE")

BASE="${DUPLO_BASE:-$DUPLO_HOST}"
RES="$BASE/v1/aiservicedesk/user/data/workspaces/$WS/environment/extensions/admin-setting-consumers/$ID"

auth=(-H "Authorization: Bearer $DUPLO_TOKEN" -H "Content-Type: application/json")

# Report Failed + a fault and stop. Best effort: no -f, and its own failure is ignored.
fail() {
  trap - ERR
  curl -sS -X POST "$RES/status" "${auth[@]}" \
    -d "$(jq -nc --arg f "$1" '{status:"Failed",faults:[$f]}')" >/dev/null || true
  echo "$1" >&2
}
# Any failing step from here on reports Failed before the script exits, so the resource does not sit in
# Processing until reconciliation flags it as stuck.
on_error() {
  fail "provision.sh line $1: '$2' failed (exit $3)"
}
trap 'on_error "$LINENO" "$BASH_COMMAND" "$?"' ERR

# The reference was validated on create, but the admin row may have changed or gone since.
if [ -z "$KEY" ]; then
  fail "The admin setting this resource references is missing or has no key — pick another one."
  exit 1
fi

# 1. Report progress
curl -fsS -X POST "$RES/status" "${auth[@]}" \
  -d '{"status":"Processing","subStatus":"Applying admin setting"}'

# 2. Apply (here: just describe it). A real skill applies adminSetting.settingValue to this workspace's
#    systems. It stays out of the summary: the Result is visible to every workspace member, and the read-only
#    admin view deliberately hides the value from them.
SUMMARY="Using $KEY (admin setting '$SETTING_NAME')"

# 3. Write the result — the body IS the typed AdminSettingConsumerResult object
curl -fsS -X POST "$RES/results" "${auth[@]}" \
  -d "$(jq -nc --arg s "$SUMMARY" '{summary:$s}')"

# 4. Complete
curl -fsS -X POST "$RES/status" "${auth[@]}" \
  -d '{"status":"Complete","subStatus":"Admin setting applied"}'

echo "Done: $SUMMARY"
