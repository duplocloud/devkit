#!/usr/bin/env bash
# Wiring tests for the `subscription` LLM provider: the grep-level checks that run.sh,
# switch-llm.sh, docker-compose.yml and .env.example all actually know about it. Static only —
# nothing is executed and no .env is touched. Usage: ./tests/test-run-subscription-wiring.sh
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1

PASS=0; FAIL=0
t()   { printf '  %s … ' "$1"; }
ok()  { echo "ok"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

echo "subscription wiring:"

t "--help documents --model subscription and the --subscription-* flags"
if grep -q -- "--model subscription" run.sh && grep -q -- "--subscription-token" run.sh; then ok; else bad "run.sh usage header"; fi

t "every --subscription-* flag is parsed (not 'Unknown flag')"
miss=""
for f in --subscription-token --subscription-model; do
  grep -qE "^[[:space:]]*$f\)" run.sh || miss="$miss $f"
done
if [ -z "$miss" ]; then ok; else bad "unparsed:$miss"; fi

t "menu maps 5 → subscription"
if grep -q "5) MODEL=subscription" run.sh; then ok; else bad "numeric mapping"; fi

t "both provider menus offer option 5"
if [ "$(grep -c '5) Claude Code subscription' run.sh)" = 2 ]; then ok; else bad "expected in both the IMDS and non-IMDS menu"; fi

t "run.sh sources the helper and calls provider_subscription_configure"
if grep -q "scripts/_provider_subscription.sh" run.sh && grep -q "provider_subscription_configure" run.sh; then ok; else bad "not wired into run.sh"; fi

t "switch-llm.sh supports subscription"
if grep -q "provider_subscription_configure" scripts/switch-llm.sh \
   && grep -q "subscription" <(grep known_providers scripts/switch-llm.sh); then ok; else bad "not wired into switch-llm.sh"; fi

t "--reset clears the subscription keys"
if grep -q 'SUBSCRIPTION_KEYS\[@\]' run.sh; then ok; else bad "SUBSCRIPTION_KEYS not in the --reset list"; fi

t "docker-compose passes CLAUDE_CODE_OAUTH_TOKEN to the agent"
if grep -q 'CLAUDE_CODE_OAUTH_TOKEN=${CLAUDE_CODE_OAUTH_TOKEN:-}' docker-compose.yml; then ok; else bad "compose passthrough missing"; fi

t ".env.example documents subscription and has a blank key"
if grep -q "^CLAUDE_CODE_OAUTH_TOKEN=$" .env.example && grep -q "subscription  " .env.example; then ok; else bad ".env.example"; fi

t "docs mention the provider"
if grep -q "CLAUDE_CODE_OAUTH_TOKEN" docs/configuration.md && grep -q -- "--subscription-token" docs/cli-reference.md; then ok; else bad "docs not updated"; fi

t "bash -n on run.sh, switch-llm.sh and the helper"
if bash -n run.sh && bash -n scripts/switch-llm.sh && bash -n scripts/_provider_subscription.sh; then ok; else bad "syntax error"; fi

echo; echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
