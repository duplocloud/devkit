#!/usr/bin/env bash
# Turn the dev-kit's Qdrant container into a usable Knowledge Base.
#
# WHY: docker-compose brings Qdrant up, but the studio only ever talks to it through platform records —
# and a fresh dev-kit DB has none of them. This creates the chain the backend actually resolves:
#
#   provider  local-qdrant   type=qdrant, category=vectorDatabase, accountId=<url>, credential 'qdrant'
#   scope     qdrant         over that provider, so the provider shows up in the ticket scope picker
#   workspace extension-dev  ← the scope attached, which is what makes it selectable
#   collection devkit-docs   EMPTY — you upload your own documents from the UI
#
# The provider shape is not negotiable: QdrantConnectionResolver.FromProvider reads the URL from
# `accountId` and the key from a credential DataEx entry keyed `apiKey` (case-insensitive), and throws if
# either is missing. GetByTypeAsync("qdrant") is an exact, case-sensitive match on `type`, so the type
# string must be lowercase 'qdrant' or the KB worker will never find the provider.
#
# NOTE (this surprises people): the collection's OWN read access is not the 'qdrant' scope below. The KB
# reconcile worker mints a read-only, collection-scoped Qdrant token, stores it as a second credential on
# the same provider, wraps it in a scope named kb-devkit-docs-readonly, and attaches THAT to the
# collection's ownerWorkspaceId — all by itself, ~60s after create. That is why we pass ownerWorkspaceId
# and never create the read scope here. The 'qdrant' scope is the plain provider scope, a separate thing.
#
# Usage: ./scripts/register-qdrant.sh [workspace-id]
#   workspace-id defaults to EXTENSION_DEV_WORKSPACE_ID in .env; without one the scope is left unattached
#   and the collection is created admin-managed (no owner workspace).
#   QDRANT_INTERNAL_URL (env, optional) overrides the Qdrant URL. It must be the compose-network name
#   (http://qdrant:6333) — the studio container resolves it, and localhost there is the studio itself.
#   QDRANT_API_KEY (.env) is the master key, matching QDRANT__SERVICE__API_KEY in docker-compose.yml.
#
# Exit codes: 0 = provider, scope and collection all in place. 3 = partial — the provider and scope were
#   created, the collection was skipped because the studio has not seeded an embedding model yet; re-run.
#   1 = failed. run.sh distinguishes all three in its summary banner, so keep 3 meaning exactly this.
#
# Ingestion, separately, needs AWS Bedrock: the seeded embedding model is Bedrock/Cohere and the agent
# rejects every other provider, so on the direct-Anthropic path the collection still reaches Ready but
# document uploads fail. Creating it anyway is deliberate — one code path, and the Knowledge Base is there
# to inspect either way.
set -euo pipefail
cd "$(dirname "$0")/.."

source "$(dirname "$0")/_target.sh"   # → BASE_URL + TOKEN from .env per DUPLO_TARGET
require_local_target "$(basename "$0")"
[ -n "$TOKEN" ] || { echo "No token resolved — set DUPLO_ADMIN_TOKEN (local) or DUPLO_TOKEN (remote) in .env." >&2; exit 1; }

API="$BASE_URL/v1/aiservicedesk/admin/data"

# ── .env helpers (same line-based idiom as run.sh; safe for values with special chars) ──
ENV_FILE="${DUPLO_ENV_FILE:-.env}"
[ -f "$ENV_FILE" ] || touch "$ENV_FILE"
getenv() { grep -E "^$1=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true; }
setenv() {
  python3 - "$ENV_FILE" "$1" "${2-}" <<'PY'
import sys
p,k,v=sys.argv[1],sys.argv[2],sys.argv[3]
lines=open(p).read().splitlines()
out=[];found=False
for ln in lines:
    if ln.startswith(k+"="): out.append(f"{k}={v}");found=True
    else: out.append(ln)
if not found: out.append(f"{k}={v}")
open(p,"w").write("\n".join(out)+"\n")
PY
}

# ── record helpers (mirrors run.sh) ───────────────────────────────────────────
# Idempotency is lookup-then-create, never .env alone: `./run.sh --reset` wipes the DB but leaves the ids
# in .env, so a stale id must fall through to a by-name lookup and then to a create.
# The timeout is generous on purpose: a timeout here is indistinguishable from a 404, and reading a slow
# studio as "no such record" falls through to a create that then 400s on name uniqueness.
data_exists() { # id collection
  [ -n "$1" ] && curl -fsS -o /dev/null --max-time 15 "$API/$2/$1" -H "Authorization: Bearer $TOKEN" 2>/dev/null
}
data_id_by_name() { # collection name
  curl -fsS --max-time 8 "$API/$1" -H "Authorization: Bearer $TOKEN" 2>/dev/null \
    | N="$2" python3 -c 'import sys,json,os
d=json.load(sys.stdin); items=d.get("data",{}); items=items.get("items",items) if isinstance(items,dict) else items
print(next((x["id"] for x in (items or []) if x.get("name")==os.environ["N"]), ""))' 2>/dev/null || true
}
created_id() { python3 -c "import sys,json;print(json.load(sys.stdin)['data']['id'])"; }

WS="${1:-$(getenv EXTENSION_DEV_WORKSPACE_ID)}"
QURL="${QDRANT_INTERNAL_URL:-http://qdrant:6333}"
QKEY="$(getenv QDRANT_API_KEY)"; QKEY="${QKEY:-devkit-local-qdrant}"

# Resolve the workspace ONCE, up front. `./run.sh --reset` wipes the DB but leaves
# EXTENSION_DEV_WORKSPACE_ID in .env, so the id can point at nothing. Both consumers below depend on it
# (the scope attach in step 3, and ownerWorkspaceId in step 5 — which the API rejects with a 400 for an
# unknown workspace), so a stale id is dropped here rather than failing twice in different ways. The
# knowledge base is still worth creating without one: it is simply admin-managed until someone shares it.
WS_STALE=""
if [ -n "$WS" ] && ! data_exists "$WS" Workspaces; then
  echo "    WARNING: workspace '$WS' does not exist — continuing without it." >&2
  echo "             Fix EXTENSION_DEV_WORKSPACE_ID in .env (or re-run ./run.sh) and run this again to" >&2
  echo "             attach the scope; the knowledge base itself is created either way." >&2
  WS_STALE="$WS"; WS=""
fi

# ── 1. provider: the connection (url + master key) ────────────────────────────
# accountId carries the URL (QdrantConnectionResolver reads it there, trailing slash trimmed) and the
# 'qdrant' credential carries the key under DataEx key 'apiKey', flagged sensitive so the platform
# encrypts it at rest and redacts it from admin reads.
PROVIDER_ID="$(getenv QDRANT_PROVIDER_ID)"
if ! data_exists "$PROVIDER_ID" Providers; then
  PROVIDER_ID="$(data_id_by_name Providers local-qdrant)"
  if [ -z "$PROVIDER_ID" ]; then
    echo "==> Registering vector-database provider 'local-qdrant' → $QURL"
    PROVIDER_ID="$(curl -fsS --max-time 15 -X POST "$API/Providers" \
      -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
      --data "$(U="$QURL" K="$QKEY" python3 -c 'import json,os
print(json.dumps({
  "name":"local-qdrant",
  "description":"Dev-kit Qdrant (docker compose service \"qdrant\")",
  "type":"qdrant",
  "category":"vectorDatabase",
  "accountId":os.environ["U"],
  "credentials":[{"name":"qdrant","dataEx":[
      {"key":"apiKey","value":os.environ["K"],"type":"secret","isSensitive":True}]}],
}))')" | created_id)"
  fi
  setenv QDRANT_PROVIDER_ID "$PROVIDER_ID"
fi
[ -n "$PROVIDER_ID" ] || { echo "Failed to register/resolve the qdrant provider." >&2; exit 1; }
echo "    provider   local-qdrant ($PROVIDER_ID)"

# ── 2. scope: the provider + which of its credentials to use ──────────────────
SCOPE_ID="$(getenv QDRANT_SCOPE_ID)"
if ! data_exists "$SCOPE_ID" Scopes; then
  SCOPE_ID="$(data_id_by_name Scopes qdrant)"
  if [ -z "$SCOPE_ID" ]; then
    echo "==> Creating scope 'qdrant' over provider $PROVIDER_ID"
    SCOPE_ID="$(curl -fsS --max-time 15 -X POST "$API/Scopes" \
      -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
      --data "$(P="$PROVIDER_ID" python3 -c 'import json,os
print(json.dumps({
  "name":"qdrant",
  "description":"Dev-kit Qdrant vector database",
  "providerId":os.environ["P"],
  "credentialName":"qdrant",
}))')" | created_id)"
  fi
  setenv QDRANT_SCOPE_ID "$SCOPE_ID"
fi
[ -n "$SCOPE_ID" ] || { echo "Failed to create/resolve the qdrant scope." >&2; exit 1; }
echo "    scope      qdrant ($SCOPE_ID)"

# ── 3. attach the scope to the workspace ──────────────────────────────────────
# Dedicated sub-route, not a whole-workspace PUT — same shape as the agent attach in register-agent.sh,
# and idempotent server-side, so re-running attaches nothing twice.
#
# Best-effort ON PURPOSE, never fatal: this attach only makes the provider selectable in the ticket scope
# picker. The knowledge base's actual read access comes from ownerWorkspaceId in step 5 (the worker
# attaches the kb-…-readonly scope itself). Aborting here would skip steps 4-5 and leave a provider and
# scope but no knowledge base — exactly the half-built state the lookup-then-create design exists to
# prevent — and it would sacrifice the load-bearing step for the cosmetic one. So: warn loudly, carry on.
if [ -n "$WS" ]; then
  if curl -fsS --max-time 10 -X POST "$API/Workspaces/$WS/scopes/$SCOPE_ID" \
       -H "Authorization: Bearer $TOKEN" >/dev/null 2>&1; then
    echo "    workspace  $WS ← scope attached"
  else
    echo "    workspace  $WS ← ATTACH FAILED (the scope will not show in the ticket scope picker)" >&2
    echo "               the knowledge base below is unaffected; retry the attach with:" >&2
    echo "               curl -X POST $API/Workspaces/$WS/scopes/$SCOPE_ID -H \"Authorization: Bearer \$DUPLO_ADMIN_TOKEN\"" >&2
  fi
elif [ -n "$WS_STALE" ]; then
  echo "    workspace  (skipped — '$WS_STALE' does not exist; see the warning above)"
else
  echo "    workspace  (none given — attach later with: POST …/Workspaces/<id>/scopes/$SCOPE_ID)"
fi

# ── 4. embedding model: required by the collection, and it fixes the vector size ──
# The studio seeds a default at boot (EmbeddingModelSeeder, a hosted service). Prefer the flagged default,
# else any enabled one. Its `dimension` becomes qdrantSpec.vectorSize server-side — we must NOT send one.
EMBED="$(curl -fsS --max-time 15 "$API/EmbeddingModels" -H "Authorization: Bearer $TOKEN" 2>/dev/null \
  | python3 -c 'import sys,json
d=json.load(sys.stdin); items=d.get("data",{}); items=items.get("items",items) if isinstance(items,dict) else items
items=[m for m in (items or []) if m.get("enabled",True) and m.get("isActive",True)]
m=next((x for x in items if x.get("isDefault")), None) or (items[0] if items else None)
print(m["id"]+" "+(m.get("displayName") or m.get("modelId") or "")) if m else print("")' 2>/dev/null || true)"
EMBED_ID="${EMBED%% *}"; EMBED_LABEL="${EMBED#* }"
if [ -z "$EMBED_ID" ]; then
  echo "    embedding  (none registered yet — skipping the collection)"
  echo "==> The studio seeds the default embedding model on first boot; it may not have finished."
  echo "    Re-run ./scripts/register-qdrant.sh${WS:+ $WS} in a minute to create the 'devkit-docs' collection."
  # 3, not 0: the provider and scope exist but the collection does not, and a caller that reads this as
  # success reports a knowledge base that was never created.
  exit 3
fi
echo "    embedding  $EMBED_LABEL ($EMBED_ID)"

# ── 5. collection: created EMPTY — you upload the documents ───────────────────
# vectorSize is deliberately absent: create validation derives it from the model's dimension and a
# mismatch fails every upsert. distance is one of Cosine | Dot | Euclid | Manhattan.
# ownerWorkspaceId is what makes the KB writable from (and auto-shared with) the workspace.
COLLECTION_ID="$(getenv QDRANT_COLLECTION_ID)"
if ! data_exists "$COLLECTION_ID" KnowledgeBaseCollections; then
  COLLECTION_ID="$(data_id_by_name KnowledgeBaseCollections devkit-docs)"
  if [ -z "$COLLECTION_ID" ]; then
    echo "==> Creating knowledge base 'devkit-docs' (empty)"
    COLLECTION_ID="$(curl -fsS --max-time 15 -X POST "$API/KnowledgeBaseCollections" \
      -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
      --data "$(P="$PROVIDER_ID" E="$EMBED_ID" W="$WS" python3 -c 'import json,os
body={
  "name":"devkit-docs",
  "description":"Dev-kit knowledge base — upload your own documents",
  "providerId":os.environ["P"],
  "embeddingModelId":os.environ["E"],
  "qdrantSpec":{"distance":"Cosine"},
}
if os.environ.get("W"): body["ownerWorkspaceId"]=os.environ["W"]
print(json.dumps(body))')" | created_id)"
  fi
  setenv QDRANT_COLLECTION_ID "$COLLECTION_ID"
fi
[ -n "$COLLECTION_ID" ] || { echo "Failed to create/resolve the 'devkit-docs' knowledge base." >&2; exit 1; }
echo "    collection devkit-docs ($COLLECTION_ID)"

echo "==> Done. 'devkit-docs' is created empty and provisions asynchronously (worker tick ~60s) —"
echo "    it shows Pending, then Ready. Uploading documents needs AWS Bedrock credentials with access to"
echo "    cohere.embed-v4, the seeded embedding model — on the direct-Anthropic path the knowledge base"
echo "    provisions and is inspectable, but every upload fails. See docs/configuration.md#knowledge-base."
