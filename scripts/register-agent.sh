#!/usr/bin/env bash
# Register the bundled claude-code-agent with the studio and (optionally) attach it to a workspace.
# Provisioning tickets are assigned from the workspace's agent list, so a resource only provisions
# once its workspace has an agent attached.
#
# Usage: ./scripts/register-agent.sh [workspace-id]
set -euo pipefail
cd "$(dirname "$0")/.."

# Registers the LOCAL dockerized agent (endpoint http://claude-code-agent:8000, on the compose network).
# Remote platforms manage their own agents — this is a local-stack tool.
source "$(dirname "$0")/_target.sh"   # → BASE_URL + TOKEN from .env per DUPLO_TARGET
[ -n "$TOKEN" ] || { echo "No token resolved — set DUPLO_ADMIN_TOKEN (local) or DUPLO_TOKEN (remote) in .env." >&2; exit 1; }

# Idempotent: reuse an existing 'local-agent' instead of creating a duplicate (run.sh calls this every run).
AGENT_ID=$(curl -fsS --max-time 15 "$BASE_URL/v1/aiservicedesk/admin/data/AIAgents" \
  -H "Authorization: Bearer $TOKEN" 2>/dev/null \
  | python3 -c 'import sys,json
d=json.load(sys.stdin); items=d.get("data",{}); items=items.get("items",items) if isinstance(items,dict) else items
print(next((a["id"] for a in (items or []) if a.get("name")=="local-agent"), ""))' 2>/dev/null || true)
if [ -n "$AGENT_ID" ]; then
  echo "==> Agent 'local-agent' already registered (id: $AGENT_ID)"
  # Heal registrations made before streaming was enabled: the portal's agent live-feed (SignalR) only stays
  # connected when the agent has metaData.STREAMING_ENABLED="true". Best-effort — never fail the script.
  PATCH=$(curl -fsS --max-time 15 "$BASE_URL/v1/aiservicedesk/admin/data/AIAgents/$AGENT_ID" \
    -H "Authorization: Bearer $TOKEN" 2>/dev/null \
    | python3 -c 'import sys,json
d=json.load(sys.stdin); a=d.get("data",d)
md=a.get("metaData") or {}
if md.get("STREAMING_ENABLED","").lower()!="true" or not a.get("doesSupportStreaming"):
    a["doesSupportStreaming"]=True; md["STREAMING_ENABLED"]="true"; a["metaData"]=md
    print(json.dumps(a))' 2>/dev/null || true)
  if [ -n "$PATCH" ]; then
    printf '%s' "$PATCH" | curl -fsS --max-time 15 -X PUT "$BASE_URL/v1/aiservicedesk/admin/data/AIAgents/$AGENT_ID" \
      -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" --data-binary @- >/dev/null 2>&1 \
      && echo "    ensured metaData.STREAMING_ENABLED=true (agent live-feed)" \
      || echo "    (could not update streaming metadata — set it manually if the live feed stays silent)"
  fi
else
  echo "==> Registering agent 'local-agent' → http://claude-code-agent:8000"
  # NOTE: path has NO leading slash — the studio joins endpoint + '/' + path, so a leading slash
  # would produce a double slash (…:8000//api/sendMessage → 404).
  AGENT_ID=$(curl -fsS --max-time 15 -X POST "$BASE_URL/v1/aiservicedesk/admin/data/AIAgents" \
    -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    -d '{"name":"local-agent","endpoint":"http://claude-code-agent:8000","endpointDetails":{"path":"api/sendMessage","method":"POST","httpHeaders":{}},"doesSupportStreaming":true,"vendor":"claude-code","metaData":{"STREAMING_ENABLED":"true"}}' \
    | python3 -c "import sys,json;print(json.load(sys.stdin)['data']['id'])")
  echo "    agent id: $AGENT_ID"
fi
[ -n "$AGENT_ID" ] || { echo "Failed to register/resolve the agent." >&2; exit 1; }

WS="${1:-}"
if [ -n "$WS" ]; then
  echo "==> Attaching agent to workspace $WS"
  curl -fsS --max-time 10 -X POST "$BASE_URL/v1/aiservicedesk/admin/data/Workspaces/$WS/agents/$AGENT_ID" \
    -H "Authorization: Bearer $TOKEN" >/dev/null
  echo "    attached."
else
  echo "    (no workspace id given — attach later with: POST …/Workspaces/<id>/agents/$AGENT_ID)"
fi
echo "==> Done. Ensure the agent has an LLM credential in .env or the environment (ANTHROPIC_API_KEY or AWS Bedrock) for provisioning to run."
