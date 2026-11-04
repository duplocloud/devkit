#!/usr/bin/env bash
set -euo pipefail

# Provisions a Secret Field Service Account: read non-secret spec from
# shared/secret-field-service-account.json, "create" the account (simulated — no real external system),
# and write the result back via the resource's OWN REST route. Status and results are two separate APIs.
#
# The password NEVER appears on this script's stdout/stderr and is never assigned to a variable that
# outlives the one block that uses it — see reference/21-secrets.md and this skill's SKILL.md.

SPEC_FILE="shared/secret-field-service-account.json"
SECRETS_FILE="shared/secret-field-service-account.secrets.json"

WORKSPACE_ID=$(jq -r '.ownerWorkspaceId' "$SPEC_FILE")
ID=$(jq -r '.id' "$SPEC_FILE")
USERNAME=$(jq -r '.spec.username // ""' "$SPEC_FILE")

BASE="${DUPLO_BASE:-$DUPLO_HOST}"
RES="$BASE/v1/aiservicedesk/user/data/workspaces/$WORKSPACE_ID/environment/extensions/secret-field-service-accounts/$ID"

auth=(-H "Authorization: Bearer $DUPLO_TOKEN" -H "Content-Type: application/json")

# 1. Report progress
curl -fsS -X POST "$RES/status" "${auth[@]}" \
  -d '{"status":"Processing","subStatus":"Creating service account"}'

# 2. "Do the work." A real skill would authenticate to the target system here with the password,
#    extracted immediately before this one use and never echoed or stored in a variable beyond this
#    block. This sample has no real external system to call, so it only validates the password was
#    actually set (never logs it) and derives a deterministic fake account id from the username.
if [ -f "$SECRETS_FILE" ]; then
  PASSWORD_SET=$(jq -r 'if (.password // "") != "" then "yes" else "no" end' "$SECRETS_FILE")
else
  PASSWORD_SET=$(jq -r 'if (.spec.password // "") != "" then "yes" else "no" end' "$SPEC_FILE")
fi
if [ "$PASSWORD_SET" != "yes" ]; then
  curl -fsS -X POST "$RES/status" "${auth[@]}" \
    -d '{"status":"Failed","faults":["No password was provided for this service account."]}'
  echo "Failed: no password set" >&2
  exit 1
fi
ACCOUNT_ID="acct-$(printf '%s' "$USERNAME" | sha256sum | cut -c1-12)"

# 3. Write the result — the body IS the typed SecretFieldServiceAccountResult object. accountId is an
#    identifier, not a credential — it is fine to log/post/display.
curl -fsS -X POST "$RES/results" "${auth[@]}" \
  -d "$(jq -nc --arg aid "$ACCOUNT_ID" '{accountId:$aid}')"

# 4. Complete
curl -fsS -X POST "$RES/status" "${auth[@]}" \
  -d '{"status":"Complete","subStatus":"Service account created"}'

echo "Done: $ACCOUNT_ID"
