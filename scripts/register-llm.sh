#!/usr/bin/env bash
# Register the LLM models the agent can run on with the studio, and make CLAUDE_MODEL the System default.
#
# WHY: the studio ships no LLM model records of its own, so on a fresh dev-kit DB the ticket LLM picker
# has nothing to offer. This registers each model, points it at the local agent, and makes that set the
# *only* models in the single System LlmModelMapping so the picker shows exactly what will work.
#
# Provider-agnostic: the ids come from .env, which run.sh sets per provider — CLAUDE_MODEL is what the
# agent runs on by default (the mapping default), CLAUDE_EXTRA_MODELS is a comma-separated list of extra
# ids to offer alongside it (e.g. Opus next to Sonnet). Bare ids (claude-sonnet-5) for direct Anthropic,
# inference-profile ids (us.anthropic.claude-sonnet-5) for either Bedrock mode, and whatever the gateway
# calls the model (e.g. anthropic/claude-sonnet-5 on OpenRouter) for the gateway provider. These are not
# interchangeable: the direct Anthropic API rejects the us.* prefix and Bedrock requires it, so
# registering the wrong variant yields a picker entry that fails on use.
#
# Usage: ./scripts/register-llm.sh [default-model-id [extra-model-id...]]
#   With no args, reads CLAUDE_MODEL + CLAUDE_EXTRA_MODELS from .env (what the agent container uses).
#   LLM_PROVIDER_LABEL (env, optional) suffixes the display names, e.g. "AWS Bedrock" →
#   "us.anthropic.claude-sonnet-5 (AWS Bedrock)". Defaults to a label inferred from the default id.
set -euo pipefail
cd "$(dirname "$0")/.."

source "$(dirname "$0")/_target.sh"   # → BASE_URL + TOKEN (+ _ENV_FILE, _envv) from .env per DUPLO_TARGET
[ -n "$TOKEN" ] || { echo "No token resolved — set DUPLO_ADMIN_TOKEN (local) or DUPLO_TOKEN (remote) in .env." >&2; exit 1; }

# Model ids: args > .env. $1 is the default; the rest (or CLAUDE_EXTRA_MODELS) are the extras.
if [ $# -gt 0 ]; then
  MODEL="$1"; shift; EXTRAS=("$@")
else
  MODEL="$(_envv CLAUDE_MODEL)"
  IFS=',' read -r -a EXTRAS <<<"$(_envv CLAUDE_EXTRA_MODELS)"
fi
[ -n "$MODEL" ] || { echo "No model id — pass one as \$1 or set CLAUDE_MODEL in .env." >&2; exit 1; }
# Ordered, de-duplicated, whitespace-trimmed list with the default first.
ALL_MODELS=()
for m in "$MODEL" "${EXTRAS[@]}"; do
  m="$(printf '%s' "$m" | tr -d '[:space:]')"; [ -n "$m" ] || continue
  for seen in "${ALL_MODELS[@]}"; do [ "$seen" = "$m" ] && continue 2; done
  ALL_MODELS+=("$m")
done

# Display-name suffix. run.sh passes the exact provider (it knows which Bedrock mode); standalone runs
# fall back to the shape of the id, which distinguishes Bedrock from direct Anthropic but not which
# Bedrock credential source is in play. A gateway is inferred from ANTHROPIC_BASE_URL being set in .env
# (that is also how the agent itself decides), since gateway model ids have no fixed shape.
if [ -z "${LLM_PROVIDER_LABEL:-}" ] && [ -n "$(_envv ANTHROPIC_BASE_URL)" ]; then
  LABEL="LLM Gateway"
else
  case "$MODEL" in
    us.*|global.*|*.anthropic.*) LABEL="${LLM_PROVIDER_LABEL:-AWS Bedrock}" ;;
    *)                           LABEL="${LLM_PROVIDER_LABEL:-Direct Anthropic}" ;;
  esac
fi

# ── resolve the agent id (prefer 'local-agent', else first active agent) ──────────
AGENT_ID=$(curl -fsS --max-time 15 "$BASE_URL/v1/aiservicedesk/admin/data/AIAgents" \
  -H "Authorization: Bearer $TOKEN" 2>/dev/null \
  | python3 -c 'import sys,json
d=json.load(sys.stdin); items=d.get("data",{}); items=items.get("items",items) if isinstance(items,dict) else items
items=items or []
a=next((x for x in items if x.get("name")=="local-agent"), None) or next((x for x in items if x.get("isActive",True)), None)
print(a["id"] if a else "")' 2>/dev/null || true)
[ -n "$AGENT_ID" ] || { echo "No agent found — run ./scripts/register-agent.sh first." >&2; exit 1; }
echo "==> Using agent id: $AGENT_ID"

# ── register each LLM model (idempotent by modelId) ───────────────────────────────
# Prints the studio uuid for a model id, registering it first if needed.
register_model() { # model-id → uuid on stdout
  local m="$1" uuid
  uuid=$(curl -fsS --max-time 15 "$BASE_URL/v1/aiservicedesk/admin/data/Models?filters%5BmodelId%5D=$m" \
    -H "Authorization: Bearer $TOKEN" 2>/dev/null \
    | M="$m" python3 -c 'import sys,json,os
d=json.load(sys.stdin); items=d.get("data",{}); items=items.get("items",items) if isinstance(items,dict) else items
print(next((x["id"] for x in (items or []) if x.get("modelId")==os.environ["M"] and x.get("isActive",True)), ""))' 2>/dev/null || true)
  if [ -n "$uuid" ]; then
    echo "==> LLM model '$m' already registered (id: $uuid)" >&2
  else
    echo "==> Registering LLM model '$m' → agent $AGENT_ID" >&2
    uuid=$(curl -fsS --max-time 15 -X POST "$BASE_URL/v1/aiservicedesk/admin/data/Models" \
      -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
      --data "$(M="$m" A="$AGENT_ID" L="$LABEL" python3 -c 'import json,os
m=os.environ["M"]; label=os.environ["L"]
print(json.dumps({"modelId":m,"displayName":m+" ("+label+")","agentIds":[os.environ["A"]],"enabled":True,"createdBy":"dev-kit"}))')" \
      | python3 -c "import sys,json;print(json.load(sys.stdin)['data']['id'])")
    echo "    model id: $uuid" >&2
  fi
  [ -n "$uuid" ] || { echo "Failed to register/resolve LLM model '$m'." >&2; exit 1; }
  printf '%s' "$uuid"
}

UUIDS=()
for m in "${ALL_MODELS[@]}"; do UUIDS+=("$(register_model "$m")"); done
MODEL_UUID="${UUIDS[0]}"
UUID_CSV="$(IFS=','; printf '%s' "${UUIDS[*]}")"

# ── make them the System models (idempotent) ──────────────────────────────────────
# Only one active System mapping may exist. If the seeder already created one (full of broken
# us.anthropic.* entries), PUT it back with ONLY our models. Otherwise create a fresh one.
MAPPING=$(curl -fsS --max-time 15 "$BASE_URL/v1/aiservicedesk/admin/data/ModelMappings?filters%5Bscope%5D=System" \
  -H "Authorization: Bearer $TOKEN" 2>/dev/null \
  | python3 -c 'import sys,json
d=json.load(sys.stdin); items=d.get("data",{}); items=items.get("items",items) if isinstance(items,dict) else items
m=next((x for x in (items or []) if x.get("scope")=="System" and x.get("isActive",True)), None)
print(json.dumps(m) if m else "")' 2>/dev/null || true)

if [ -z "$MAPPING" ]; then
  echo "==> Creating System model mapping (default: $MODEL; models: ${ALL_MODELS[*]})"
  MAPPING_ID=$(curl -fsS --max-time 15 -X POST "$BASE_URL/v1/aiservicedesk/admin/data/ModelMappings" \
    -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    --data "$(U="$UUID_CSV" A="$AGENT_ID" python3 -c 'import json,os
us=os.environ["U"].split(","); a=os.environ["A"]
print(json.dumps({"scope":"System","models":[{"modelId":u,"agentId":a} for u in us],"defaultModelId":us[0],"createdBy":"dev-kit"}))')" \
    | python3 -c "import sys,json;print(json.load(sys.stdin)['data']['id'])")
  echo "    mapping id: $MAPPING_ID"
else
  # Already configured? (model set == ours AND the default is CLAUDE_MODEL) → no-op.
  if printf '%s' "$MAPPING" | U="$UUID_CSV" python3 -c 'import sys,json,os
m=json.load(sys.stdin); us=os.environ["U"].split(",")
have=sorted(x.get("modelId") for x in (m.get("models") or []))
sys.exit(0 if (have==sorted(us) and m.get("defaultModelId")==us[0]) else 1)' 2>/dev/null; then
    MAPPING_ID=$(printf '%s' "$MAPPING" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("id",""))')
    echo "==> System model mapping already configured for '${ALL_MODELS[*]}' (id: $MAPPING_ID) — nothing to do."
  else
    echo "==> Replacing System model mapping with only '${ALL_MODELS[*]}' (removing existing entries)"
    PAYLOAD=$(printf '%s' "$MAPPING" | U="$UUID_CSV" A="$AGENT_ID" python3 -c 'import sys,json,os
m=json.load(sys.stdin); us=os.environ["U"].split(","); a=os.environ["A"]
m["models"]=[{"modelId":u,"agentId":a} for u in us]
m["defaultModelId"]=us[0]
m["updatedBy"]="dev-kit"
print(json.dumps(m))')
    MAPPING_ID=$(printf '%s' "$PAYLOAD" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
    printf '%s' "$PAYLOAD" | curl -fsS --max-time 15 -X PUT "$BASE_URL/v1/aiservicedesk/admin/data/ModelMappings/$MAPPING_ID" \
      -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" --data-binary @- >/dev/null
    echo "    updated mapping id: $MAPPING_ID"
  fi
fi

echo "==> Done. System default LLM: '$MODEL' (model $MODEL_UUID, mapping $MAPPING_ID); available: ${ALL_MODELS[*]}."
