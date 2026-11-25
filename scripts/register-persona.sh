#!/usr/bin/env bash
# Register a starter 'devops' skill + persona with the studio and attach the persona to a workspace.
#
# WHY: a fresh dev-kit DB has built-in skills but no persona, and a workspace with no persona gives the
# agent no role to play. This creates one end-to-end example of the chain — Skill → Persona → Workspace —
# that you then edit in the UI (AI Admin → Skills / Personas) rather than build from scratch.
#
# Idempotent by NAME, like register-agent.sh: an existing skill or persona is adopted, never rewritten,
# so your edits to the placeholder SKILL.md survive every subsequent ./run.sh.
#
# Usage: ./scripts/register-persona.sh [workspace-id]
set -euo pipefail
cd "$(dirname "$0")/.."

source "$(dirname "$0")/_target.sh"   # → BASE_URL + TOKEN from .env per DUPLO_TARGET
require_local_target "$(basename "$0")"
[ -n "$TOKEN" ] || { echo "No token resolved — set DUPLO_ADMIN_TOKEN (local) or DUPLO_TOKEN (remote) in .env." >&2; exit 1; }

SKILL_NAME=devops
PERSONA_NAME=devops

# Look up a record id by exact name in an admin/data collection. Empty when absent.
id_by_name() { # collection name
  curl -fsS --max-time 15 "$BASE_URL/v1/aiservicedesk/admin/data/$1" \
    -H "Authorization: Bearer $TOKEN" 2>/dev/null \
    | N="$2" python3 -c 'import sys,json,os
d=json.load(sys.stdin); items=d.get("data",{}); items=items.get("items",items) if isinstance(items,dict) else items
print(next((x["id"] for x in (items or []) if x.get("name")==os.environ["N"] and x.get("isActive",True)), ""))' 2>/dev/null || true
}

# ── the 'devops' skill (format SkillMd — content lives in the record, editable in the UI) ─────────
SKILL_ID="$(id_by_name skills "$SKILL_NAME")"
if [ -n "$SKILL_ID" ]; then
  # Never PUT over it: by now this is whatever you wrote in the UI, not the placeholder we shipped.
  echo "==> Skill '$SKILL_NAME' already registered (id: $SKILL_ID) — leaving its content alone"
else
  echo "==> Registering placeholder skill '$SKILL_NAME'"
  SKILL_ID=$(python3 -c '
import json
skill_md = """---
name: devops
description: "Placeholder DevOps skill. Replace this with your own. MUST invoke when:
  (1) the user asks about deploying, operating or troubleshooting infrastructure;
  (2) the task involves CI/CD, Kubernetes or cloud resources."
---

# DevOps

This is a starter skill created by the dev kit so the Skill -> Persona -> Workspace chain is wired up
end to end. It does nothing useful yet — edit it under AI Admin -> Skills.

## Core principle

Say, in a sentence or two, how the task this skill covers actually works.

## Steps

1. Replace these steps with the real procedure.
2. Be specific: name the commands, APIs and files the agent should use.

## Best practices

- Spell out the trigger conditions in the description above — that is how the agent decides when to
  apply this skill at all.
"""
print(json.dumps({"name":"devops","type":"Custom","description":"Starter DevOps skill — edit me.",
                  "skillMd":skill_md,"format":"SkillMd","metaData":{}}))' \
    | curl -fsS --max-time 15 -X POST "$BASE_URL/v1/aiservicedesk/admin/data/skills" \
        -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" --data-binary @- \
    | python3 -c "import sys,json;print(json.load(sys.stdin)['data']['id'])")
  echo "    skill id: $SKILL_ID"
fi
[ -n "$SKILL_ID" ] || { echo "Failed to register/resolve the '$SKILL_NAME' skill." >&2; exit 1; }

# ── the 'devops' persona (carries the skill) ──────────────────────────────────────────────────────
PERSONA_ID="$(id_by_name personas "$PERSONA_NAME")"
if [ -n "$PERSONA_ID" ]; then
  # Adopted as-is: its skill list may have been curated in the UI, and re-adding ours would undo that.
  echo "==> Persona '$PERSONA_NAME' already registered (id: $PERSONA_ID) — leaving its skills alone"
else
  echo "==> Registering persona '$PERSONA_NAME' with skill '$SKILL_NAME'"
  PERSONA_ID=$(S="$SKILL_ID" python3 -c 'import json,os
print(json.dumps({"name":"devops","description":"Starter DevOps persona — edit me.",
                  "avatarUrl":"card-account-details-outline","skillIds":[os.environ["S"]],"metaData":{}}))' \
    | curl -fsS --max-time 15 -X POST "$BASE_URL/v1/aiservicedesk/admin/data/personas" \
        -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" --data-binary @- \
    | python3 -c "import sys,json;print(json.load(sys.stdin)['data']['id'])")
  echo "    persona id: $PERSONA_ID"
fi
[ -n "$PERSONA_ID" ] || { echo "Failed to register/resolve the '$PERSONA_NAME' persona." >&2; exit 1; }

# ── attach to the workspace (idempotent: skipped when already present) ────────────────────────────
# There is no sub-resource route for personas (unlike agents), so this is a whole-record PUT. Read the
# current workspace and append — writing a bare {personaIds:[...]} would drop its scopes and agents.
WS="${1:-}"
if [ -z "$WS" ]; then
  echo "    (no workspace id given — attach later with: PUT …/workspaces/<id> including persona $PERSONA_ID)"
  exit 0
fi
PATCH=$(curl -fsS --max-time 15 "$BASE_URL/v1/aiservicedesk/admin/data/workspaces/$WS" \
  -H "Authorization: Bearer $TOKEN" 2>/dev/null \
  | P="$PERSONA_ID" python3 -c 'import sys,json,os
d=json.load(sys.stdin); w=d.get("data",d); pid=os.environ["P"]
ids=w.get("personaIds") or []
if pid not in ids:
    print(json.dumps({"personaIds":ids+[pid],"scopeIds":w.get("scopeIds") or [],
                      "agentIds":w.get("agentIds") or [],"name":w.get("name",""),
                      "description":w.get("description",""),"id":w["id"]}))' 2>/dev/null || true)
if [ -z "$PATCH" ]; then
  echo "==> Persona already attached to workspace $WS"
else
  echo "==> Attaching persona to workspace $WS"
  printf '%s' "$PATCH" | curl -fsS --max-time 15 -X PUT "$BASE_URL/v1/aiservicedesk/admin/data/workspaces/$WS" \
    -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" --data-binary @- >/dev/null
  echo "    attached."
fi
