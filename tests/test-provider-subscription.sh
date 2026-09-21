#!/usr/bin/env bash
# Tests for scripts/_provider_subscription.sh — the `subscription` LLM provider arm of run.sh.
# Runs against a throwaway .env; never touches the real one. Usage: ./tests/test-provider-subscription.sh
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

. ./scripts/_provider_subscription.sh || { echo "scripts/_provider_subscription.sh not found"; exit 1; }

reset_env() { : > "$ENV"; F_SUBSCRIPTION_TOKEN=""; F_SUBSCRIPTION_MODEL=""; }

echo "subscription provider:"

t "writes the token and a default model from flags"
reset_env; F_SUBSCRIPTION_TOKEN="sk-ant-oat01-abc"
provider_subscription_configure >/dev/null 2>&1
if [ "$(getenv CLAUDE_CODE_OAUTH_TOKEN)" = "sk-ant-oat01-abc" ] \
   && [ "$(getenv CLAUDE_MODEL)" = "claude-sonnet-4-6" ]; then ok; else bad "$(cat "$ENV")"; fi

t "an explicit model flag wins over the default"
reset_env; F_SUBSCRIPTION_TOKEN="sk-ant-oat01-abc"; F_SUBSCRIPTION_MODEL="claude-sonnet-5"
provider_subscription_configure >/dev/null 2>&1
if [ "$(getenv CLAUDE_MODEL)" = "claude-sonnet-5" ]; then ok; else bad "$(getenv CLAUDE_MODEL)"; fi

# The agent puts subscription auth next-to-last in its precedence chain, so either of these
# left over from a previous provider would win and the token would never be read. Blanking
# them is load-bearing, not hygiene — same as bedrock-instance-role's AWS keys.
t "blanks ANTHROPIC_API_KEY so the token is actually reached"
reset_env; setenv ANTHROPIC_API_KEY "sk-ant-api-leftover"; F_SUBSCRIPTION_TOKEN="sk-ant-oat01-abc"
provider_subscription_configure >/dev/null 2>&1
if [ -z "$(getenv ANTHROPIC_API_KEY)" ]; then ok; else bad "key still $(getenv ANTHROPIC_API_KEY)"; fi

t "blanks ANTHROPIC_BASE_URL so a stale gateway doesn't win"
reset_env; setenv ANTHROPIC_BASE_URL "https://openrouter.ai/api"; F_SUBSCRIPTION_TOKEN="sk-ant-oat01-abc"
provider_subscription_configure >/dev/null 2>&1
if [ -z "$(getenv ANTHROPIC_BASE_URL)" ]; then ok; else bad "url still $(getenv ANTHROPIC_BASE_URL)"; fi

t "reuses a token already in .env when no flag is passed"
reset_env; setenv CLAUDE_CODE_OAUTH_TOKEN "sk-ant-oat01-saved"
provider_subscription_configure >/dev/null 2>&1
if [ "$(getenv CLAUDE_CODE_OAUTH_TOKEN)" = "sk-ant-oat01-saved" ]; then ok; else bad "$(getenv CLAUDE_CODE_OAUTH_TOKEN)"; fi

t "fails when non-interactive with no token anywhere"
reset_env
if provider_subscription_configure >/dev/null 2>&1; then bad "returned 0 with no token"; else ok; fi

# A Bedrock inference-profile id is rejected outright by the first-party API, so a model left
# over from a Bedrock run must not be carried onto this path.
t "replaces a leftover us.anthropic.* model id with the bare default"
reset_env; setenv CLAUDE_MODEL "us.anthropic.claude-sonnet-4-6"; F_SUBSCRIPTION_TOKEN="sk-ant-oat01-abc"
provider_subscription_configure >/dev/null 2>&1
if [ "$(getenv CLAUDE_MODEL)" = "claude-sonnet-4-6" ]; then ok; else bad "$(getenv CLAUDE_MODEL)"; fi

t "keeps a bare model id already in .env"
reset_env; setenv CLAUDE_MODEL "claude-opus-4-8"; F_SUBSCRIPTION_TOKEN="sk-ant-oat01-abc"
provider_subscription_configure >/dev/null 2>&1
if [ "$(getenv CLAUDE_MODEL)" = "claude-opus-4-8" ]; then ok; else bad "$(getenv CLAUDE_MODEL)"; fi

t "notes an API key pasted where a subscription token belongs"
reset_env; F_SUBSCRIPTION_TOKEN="sk-ant-api03-nope"
# Captured rather than piped: `grep -q` exits on first match, and the SIGPIPE that
# follows would become the pipeline's status under `set -o pipefail`.
note_out="$(provider_subscription_configure 2>&1)"
case "$note_out" in *"looks like an Anthropic API key"*) ok ;; *) bad "no note emitted" ;; esac

t "sets a default AWS_REGION (agent's title LLM needs a valid region even off-Bedrock)"
reset_env; F_SUBSCRIPTION_TOKEN="sk-ant-oat01-abc"
provider_subscription_configure >/dev/null 2>&1
if [ -n "$(getenv AWS_REGION)" ]; then ok; else bad "AWS_REGION empty"; fi

t "SUBSCRIPTION_KEYS lists every key the arm writes (for --reset)"
if printf '%s\n' "${SUBSCRIPTION_KEYS[@]}" | grep -qx CLAUDE_CODE_OAUTH_TOKEN; then ok; else bad "${SUBSCRIPTION_KEYS[*]:-unset}"; fi

echo; echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
