#!/usr/bin/env bash
# End-to-end tests for switching to and from the `subscription` provider with scripts/switch-llm.sh.
# Runs the real script (under its own set -euo pipefail, with no F_* vars pre-set) against a copy of
# scripts/ in a throwaway root with a stub `docker`, so the real .env is never touched and the stack
# is never started. Usage: ./tests/test-switch-llm-subscription.sh
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1

PASS=0; FAIL=0
t()   { printf '  %s … ' "$1"; }
ok()  { echo "ok"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
cp -R scripts "$ROOT/scripts"
mkdir -p "$ROOT/bin"
# No agent container running → switch-llm.sh rewrites .env and exits 0 before any compose/registration.
printf '#!/bin/sh\nexit 0\n' > "$ROOT/bin/docker"; chmod +x "$ROOT/bin/docker"
ENV="$ROOT/.env"
getenv() { grep -E "^$1=" "$ENV" 2>/dev/null | head -1 | cut -d= -f2- || true; }
switch() { PATH="$ROOT/bin:$PATH" "$ROOT/scripts/switch-llm.sh" "$@" -y >"$ROOT/out" 2>&1; }

echo "switch-llm.sh subscription:"

t "switching with only --subscription-token doesn't die on an unset flag var"
printf 'DEVKIT_MODEL=anthropic\nANTHROPIC_API_KEY=sk-ant-api03-x\n' > "$ENV"
if switch subscription --subscription-token sk-ant-oat01-x \
   && [ "$(getenv CLAUDE_CODE_OAUTH_TOKEN)" = "sk-ant-oat01-x" ] \
   && [ "$(getenv DEVKIT_MODEL)" = subscription ]; then ok; else bad "$(cat "$ROOT/out")"; fi

t "gateway → subscription does not inherit the gateway's model id"
cat > "$ENV" <<'ENVF'
DEVKIT_MODEL=gateway
ANTHROPIC_BASE_URL=https://openrouter.ai/api
ANTHROPIC_AUTH_TOKEN=gw-token
CLAUDE_MODEL=anthropic/claude-sonnet-4.6
ENVF
if switch subscription --subscription-token sk-ant-oat01-x \
   && [ "$(getenv CLAUDE_MODEL)" = "claude-sonnet-4-6" ] \
   && [ -z "$(getenv ANTHROPIC_BASE_URL)" ]; then ok; else bad "CLAUDE_MODEL=$(getenv CLAUDE_MODEL); $(cat "$ROOT/out")"; fi

t "the gateway's model is stashed under its own provider"
if [ "$(getenv _STASH_GATEWAY_CLAUDE_MODEL)" = "anthropic/claude-sonnet-4.6" ] \
   && [ -z "$(getenv _STASH_CLAUDE_MODEL)" ]; then ok; else bad "$(grep _STASH "$ENV")"; fi

t "subscription → gateway restores the gateway's own model, not the subscription's"
if switch gateway && [ "$(getenv CLAUDE_MODEL)" = "anthropic/claude-sonnet-4.6" ] \
   && [ "$(getenv _STASH_SUBSCRIPTION_CLAUDE_MODEL)" = "claude-sonnet-4-6" ]; then ok; else bad "CLAUDE_MODEL=$(getenv CLAUDE_MODEL); $(cat "$ROOT/out")"; fi

t "gateway → subscription again restores the stashed token without re-entry"
if switch subscription && [ "$(getenv CLAUDE_CODE_OAUTH_TOKEN)" = "sk-ant-oat01-x" ] \
   && [ "$(getenv CLAUDE_MODEL)" = "claude-sonnet-4-6" ]; then ok; else bad "$(cat "$ROOT/out")"; fi

t "a pre-namespacing flat stash is still honoured for an unshared key"
printf 'DEVKIT_MODEL=anthropic\nANTHROPIC_API_KEY=sk-ant-api03-x\n_STASH_CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-legacy\n_STASH_CLAUDE_MODEL=us.anthropic.claude-sonnet-4-6\n' > "$ENV"
if switch subscription && [ "$(getenv CLAUDE_CODE_OAUTH_TOKEN)" = "sk-ant-oat01-legacy" ]; then ok; else bad "$(cat "$ROOT/out")"; fi

t "…but a flat stash of a shared key (CLAUDE_MODEL) is ignored"
if [ "$(getenv CLAUDE_MODEL)" = "claude-sonnet-4-6" ]; then ok; else bad "CLAUDE_MODEL=$(getenv CLAUDE_MODEL)"; fi

echo; echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
