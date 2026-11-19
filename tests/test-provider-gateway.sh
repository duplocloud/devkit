#!/usr/bin/env bash
# Tests for scripts/_provider_gateway.sh — the `gateway` LLM provider arm of run.sh.
# Runs against a throwaway .env; never touches the real one. Usage: ./tests/test-provider-gateway.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

PASS=0; FAIL=0
t()   { printf '  %s … ' "$1"; }
ok()  { echo "ok"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# Minimal stand-ins for run.sh's .env helpers, pointed at a temp file.
ENV="$(mktemp)"; trap 'rm -f "$ENV"' EXIT
getenv() { grep -E "^$1=" "$ENV" 2>/dev/null | head -1 | cut -d= -f2- || true; }
setenv() {
  python3 - "$ENV" "$1" "${2-}" <<'PY'
import sys
p,k,v=sys.argv[1],sys.argv[2],sys.argv[3]
lines=open(p).read().splitlines(); out=[]; found=False
for ln in lines:
    if ln.startswith(k+"="): out.append(f"{k}={v}"); found=True
    else: out.append(ln)
if not found: out.append(f"{k}={v}")
open(p,"w").write("\n".join(out)+"\n")
PY
}
NONINTERACTIVE=1
resolve() { local cur="$1" envkey="$2"; [ -z "$cur" ] && cur="$(getenv "$envkey")"
  [ -n "$cur" ] || { echo "Missing $envkey" >&2; exit 1; }; printf '%s' "$cur"; }

. ./scripts/_provider_gateway.sh || { echo "scripts/_provider_gateway.sh not found"; exit 1; }

reset_env() { : > "$ENV"; F_GATEWAY_URL=""; F_GATEWAY_TOKEN=""; F_GATEWAY_MODEL=""
  F_GATEWAY_DISABLE_BETAS=""; F_GATEWAY_MAX_CONTEXT=""; F_GATEWAY_COMPACT_WINDOW=""; }

echo "gateway provider:"

t "writes URL, token and model from flags"
reset_env; F_GATEWAY_URL="https://openrouter.ai/api"; F_GATEWAY_TOKEN="sk-or-abc"; F_GATEWAY_MODEL="anthropic/claude-sonnet-5-5"
provider_gateway_configure >/dev/null 2>&1
if [ "$(getenv ANTHROPIC_BASE_URL)" = "https://openrouter.ai/api" ] \
   && [ "$(getenv ANTHROPIC_AUTH_TOKEN)" = "sk-or-abc" ] \
   && [ "$(getenv CLAUDE_MODEL)" = "anthropic/claude-sonnet-5-5" ]; then ok; else bad "$(cat "$ENV")"; fi

t "blanks ANTHROPIC_API_KEY so the agent takes the gateway path, not the proxy path"
reset_env; setenv ANTHROPIC_API_KEY "sk-ant-leftover"
F_GATEWAY_URL="https://bifrost.local:8080"; F_GATEWAY_TOKEN="t"; F_GATEWAY_MODEL="m"
provider_gateway_configure >/dev/null 2>&1
if grep -qx 'ANTHROPIC_API_KEY=' "$ENV"; then ok; else bad "ANTHROPIC_API_KEY still set: $(getenv ANTHROPIC_API_KEY)"; fi

t "strips a trailing slash from the URL"
reset_env; F_GATEWAY_URL="https://openrouter.ai/api/"; F_GATEWAY_TOKEN="t"; F_GATEWAY_MODEL="m"
provider_gateway_configure >/dev/null 2>&1
if [ "$(getenv ANTHROPIC_BASE_URL)" = "https://openrouter.ai/api" ]; then ok; else bad "$(getenv ANTHROPIC_BASE_URL)"; fi

t "non-interactive with no URL fails naming the --gateway-url flag"
reset_env; F_GATEWAY_TOKEN="t"
OUT="$(provider_gateway_configure 2>&1)"; RC=$?
if [ "$RC" != 0 ] && grep -q -- '--gateway-url' <<<"$OUT" && ! grep -q "must start with" <<<"$OUT"; then ok; else bad "rc=$RC: $OUT"; fi

t "rejects a URL without http(s) scheme"
reset_env; F_GATEWAY_URL="openrouter.ai/api"; F_GATEWAY_TOKEN="t"; F_GATEWAY_MODEL="m"
if (provider_gateway_configure >/dev/null 2>&1); then bad "accepted"; else ok; fi

t "warns (but accepts) a localhost URL — inside the container that is not the host"
reset_env; F_GATEWAY_URL="http://localhost:8080"; F_GATEWAY_TOKEN="t"; F_GATEWAY_MODEL="m"
OUT="$(provider_gateway_configure 2>&1)"
if [ "$(getenv ANTHROPIC_BASE_URL)" = "http://localhost:8080" ] && grep -q host.docker.internal <<<"$OUT"; then ok; else bad "$OUT"; fi

t "token is optional (unauthenticated gateway) — explicit 'none' leaves it blank"
reset_env; F_GATEWAY_URL="https://bifrost.local"; F_GATEWAY_TOKEN="none"; F_GATEWAY_MODEL="m"
provider_gateway_configure >/dev/null 2>&1
if grep -qx 'ANTHROPIC_AUTH_TOKEN=' "$ENV"; then ok; else bad "token=$(getenv ANTHROPIC_AUTH_TOKEN)"; fi

t "model defaults to claude-sonnet-5-5 when not given"
reset_env; F_GATEWAY_URL="https://bifrost.local"; F_GATEWAY_TOKEN="t"
provider_gateway_configure >/dev/null 2>&1
if [ "$(getenv CLAUDE_MODEL)" = "claude-sonnet-5-5" ]; then ok; else bad "$(getenv CLAUDE_MODEL)"; fi

t "reuses values already in .env on a re-run (no flags)"
reset_env; setenv ANTHROPIC_BASE_URL "https://saved.example"; setenv ANTHROPIC_AUTH_TOKEN "saved-tok"; setenv CLAUDE_MODEL "saved-model"
provider_gateway_configure >/dev/null 2>&1
if [ "$(getenv ANTHROPIC_BASE_URL)" = "https://saved.example" ] && [ "$(getenv ANTHROPIC_AUTH_TOKEN)" = "saved-tok" ] \
   && [ "$(getenv CLAUDE_MODEL)" = "saved-model" ]; then ok; else bad "$(cat "$ENV")"; fi

t "passes through the optional CLAUDE_CODE_* tuning knobs when given"
reset_env; F_GATEWAY_URL="https://x.example"; F_GATEWAY_TOKEN="t"; F_GATEWAY_MODEL="m"
F_GATEWAY_DISABLE_BETAS=1; F_GATEWAY_MAX_CONTEXT=200000; F_GATEWAY_COMPACT_WINDOW=160000
provider_gateway_configure >/dev/null 2>&1
if [ "$(getenv CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS)" = "1" ] && [ "$(getenv CLAUDE_CODE_MAX_CONTEXT_TOKENS)" = "200000" ] \
   && [ "$(getenv CLAUDE_CODE_AUTO_COMPACT_WINDOW)" = "160000" ]; then ok; else bad "$(cat "$ENV")"; fi

t "defaults the context/compact window to 262144/200000 on gateway"
reset_env; F_GATEWAY_URL="https://x.example"; F_GATEWAY_TOKEN="t"; F_GATEWAY_MODEL="m"
provider_gateway_configure >/dev/null 2>&1
if [ "$(getenv CLAUDE_CODE_MAX_CONTEXT_TOKENS)" = "262144" ] && [ "$(getenv CLAUDE_CODE_AUTO_COMPACT_WINDOW)" = "200000" ]; then ok; else bad "max=$(getenv CLAUDE_CODE_MAX_CONTEXT_TOKENS) compact=$(getenv CLAUDE_CODE_AUTO_COMPACT_WINDOW)"; fi

t "flags override the context/compact defaults"
reset_env; F_GATEWAY_URL="https://x.example"; F_GATEWAY_TOKEN="t"; F_GATEWAY_MODEL="m"
F_GATEWAY_MAX_CONTEXT=200000; F_GATEWAY_COMPACT_WINDOW=160000
provider_gateway_configure >/dev/null 2>&1
if [ "$(getenv CLAUDE_CODE_MAX_CONTEXT_TOKENS)" = "200000" ] && [ "$(getenv CLAUDE_CODE_AUTO_COMPACT_WINDOW)" = "160000" ]; then ok; else bad "$(cat "$ENV")"; fi

t "does not default the betas knob (most gateways don't need it)"
reset_env; F_GATEWAY_URL="https://x.example"; F_GATEWAY_TOKEN="t"; F_GATEWAY_MODEL="m"
provider_gateway_configure >/dev/null 2>&1
if [ -z "$(getenv CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS)" ]; then ok; else bad "$(getenv CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS)"; fi

t "leaves the tuning knobs untouched when not given"
reset_env; setenv CLAUDE_CODE_MAX_CONTEXT_TOKENS "123"; F_GATEWAY_URL="https://x.example"; F_GATEWAY_TOKEN="t"; F_GATEWAY_MODEL="m"
provider_gateway_configure >/dev/null 2>&1
if [ "$(getenv CLAUDE_CODE_MAX_CONTEXT_TOKENS)" = "123" ]; then ok; else bad "$(getenv CLAUDE_CODE_MAX_CONTEXT_TOKENS)"; fi

t "sets a default AWS_REGION (agent's title LLM needs a valid region even off-Bedrock)"
reset_env; F_GATEWAY_URL="https://x.example"; F_GATEWAY_TOKEN="t"; F_GATEWAY_MODEL="m"
provider_gateway_configure >/dev/null 2>&1
if [ -n "$(getenv AWS_REGION)" ]; then ok; else bad "AWS_REGION empty"; fi

t "GATEWAY_KEYS lists every key the arm writes (for --reset)"
if printf '%s\n' "${GATEWAY_KEYS[@]}" | grep -qx ANTHROPIC_BASE_URL \
   && printf '%s\n' "${GATEWAY_KEYS[@]}" | grep -qx ANTHROPIC_AUTH_TOKEN \
   && printf '%s\n' "${GATEWAY_KEYS[@]}" | grep -qx CLAUDE_CODE_AUTO_COMPACT_WINDOW; then ok; else bad "${GATEWAY_KEYS[*]:-unset}"; fi

# This arm keeps the .env model across runs, so a bumped default never reaches an existing install on
# its own. An exact previous default (bare id, i.e. the prompt default accepted) is upgraded; a gateway's
# own names, explicit flags and anything else are kept (PR #86 review).
echo "gateway provider — previous-default migration:"
t "upgrades the previous default (claude-sonnet-5) left in .env, with a note"
reset_env; setenv CLAUDE_MODEL "claude-sonnet-5"; F_GATEWAY_URL="https://x.example"; F_GATEWAY_TOKEN="t"
note="$(provider_gateway_configure 2>&1 >/dev/null)"
if [ "$(getenv CLAUDE_MODEL)" = "claude-sonnet-5-5" ] && grep -q "previous default 'claude-sonnet-5'" <<<"$note" \
   && grep -q -- '--gateway-model' <<<"$note"; then ok; else bad "CLAUDE_MODEL=$(getenv CLAUDE_MODEL); $note"; fi

t "keeps a gateway-namespaced id (anthropic/claude-sonnet-5)"
reset_env; setenv CLAUDE_MODEL "anthropic/claude-sonnet-5"; F_GATEWAY_URL="https://x.example"; F_GATEWAY_TOKEN="t"
provider_gateway_configure >/dev/null 2>&1
if [ "$(getenv CLAUDE_MODEL)" = "anthropic/claude-sonnet-5" ]; then ok; else bad "$(getenv CLAUDE_MODEL)"; fi

t "keeps an explicit --gateway-model for the run that passes it, even a previous default"
reset_env; F_GATEWAY_URL="https://x.example"; F_GATEWAY_TOKEN="t"; F_GATEWAY_MODEL="claude-sonnet-5"
provider_gateway_configure >/dev/null 2>&1
if [ "$(getenv CLAUDE_MODEL)" = "claude-sonnet-5" ]; then ok; else bad "$(getenv CLAUDE_MODEL)"; fi

for v in '*' 'claude-*' '[c]laude-sonnet-5'; do
  t "keeps a glob-looking .env value ($v) — no pattern matching"
  reset_env; setenv CLAUDE_MODEL "$v"; F_GATEWAY_URL="https://x.example"; F_GATEWAY_TOKEN="t"
  provider_gateway_configure >/dev/null 2>&1
  if [ "$(getenv CLAUDE_MODEL)" = "$v" ]; then ok; else bad "$(getenv CLAUDE_MODEL)"; fi
done

echo; echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
