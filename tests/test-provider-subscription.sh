#!/usr/bin/env bash
# Tests for scripts/_provider_subscription.sh — the `subscription` LLM provider arm of run.sh.
# Runs against a throwaway .env; never touches the real one. Usage: ./tests/test-provider-subscription.sh
set -euo pipefail
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
   && [ "$(getenv CLAUDE_MODEL)" = "claude-sonnet-5-5" ]; then ok; else bad "$(cat "$ENV")"; fi

t "an explicit model flag wins over the default"
reset_env; F_SUBSCRIPTION_TOKEN="sk-ant-oat01-abc"; F_SUBSCRIPTION_MODEL="claude-sonnet-5-5"
provider_subscription_configure >/dev/null 2>&1
if [ "$(getenv CLAUDE_MODEL)" = "claude-sonnet-5-5" ]; then ok; else bad "$(getenv CLAUDE_MODEL)"; fi

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
reset_env; setenv CLAUDE_MODEL "us.anthropic.claude-sonnet-5-5"; F_SUBSCRIPTION_TOKEN="sk-ant-oat01-abc"
provider_subscription_configure >/dev/null 2>&1
if [ "$(getenv CLAUDE_MODEL)" = "claude-sonnet-5-5" ]; then ok; else bad "$(getenv CLAUDE_MODEL)"; fi

t "replaces a leftover gateway-namespaced model id with the bare default"
reset_env; setenv CLAUDE_MODEL "anthropic/claude-sonnet-5-5"; F_SUBSCRIPTION_TOKEN="sk-ant-oat01-abc"
provider_subscription_configure >/dev/null 2>&1
if [ "$(getenv CLAUDE_MODEL)" = "claude-sonnet-5-5" ]; then ok; else bad "$(getenv CLAUDE_MODEL)"; fi

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

# compose resolves ${VAR:-} from the shell before .env, so the .env blanks can't defeat an exported
# key. The unset is silent by choice — it fixes the scripts' own compose calls, and the warning that
# used to accompany it was noise on a path the user had just deliberately chosen.
t "stays silent about exported ANTHROPIC_API_KEY / ANTHROPIC_BASE_URL"
reset_env; F_SUBSCRIPTION_TOKEN="sk-ant-oat01-abc"
warn_out="$(ANTHROPIC_API_KEY=sk-ant-api03-shell ANTHROPIC_BASE_URL=https://x.example provider_subscription_configure 2>&1)"
case "$warn_out" in *WARNING*|*"exported in your shell"*) bad "$warn_out" ;; *) ok ;; esac

# The unset itself is load-bearing and must survive the warning's removal: run.sh / switch-llm.sh
# start the agent right after, so the exported key has to be dropped from the calling script's env
# for their own compose calls to be right.
t "unsets the exported vars in-process so the script's compose calls don't see them"
reset_env; F_SUBSCRIPTION_TOKEN="sk-ant-oat01-abc"
left="$(export ANTHROPIC_API_KEY=sk-ant-api03-shell ANTHROPIC_BASE_URL=https://x.example
        provider_subscription_configure >/dev/null 2>&1; env | grep -cE '^ANTHROPIC_(API_KEY|BASE_URL)=' || true)"
if [ "$left" = 0 ]; then ok; else bad "$left still in env"; fi

t "no shell-export warning when neither is set"
reset_env; F_SUBSCRIPTION_TOKEN="sk-ant-oat01-abc"
warn_out="$(unset ANTHROPIC_API_KEY ANTHROPIC_BASE_URL; provider_subscription_configure 2>&1)"
case "$warn_out" in *WARNING*) bad "$warn_out" ;; *) ok ;; esac

t "SUBSCRIPTION_KEYS lists every key the arm writes (for --reset)"
if printf '%s\n' "${SUBSCRIPTION_KEYS[@]}" | grep -qx CLAUDE_CODE_OAUTH_TOKEN; then ok; else bad "${SUBSCRIPTION_KEYS[*]:-unset}"; fi

# This arm keeps the .env model across runs, so an install created on the previous default would
# never pick up a new one. A value equal to a previous default is upgraded; a deliberate pick isn't.
t "upgrades the previous default (claude-sonnet-5) left in .env to the current default"
reset_env; setenv CLAUDE_MODEL "claude-sonnet-5"; F_SUBSCRIPTION_TOKEN="sk-ant-oat01-abc"
provider_subscription_configure >/dev/null 2>&1
if [ "$(getenv CLAUDE_MODEL)" = "claude-sonnet-5-5" ]; then ok; else bad "$(getenv CLAUDE_MODEL)"; fi

t "keeps an explicit --subscription-model even when it is a previous default"
reset_env; F_SUBSCRIPTION_TOKEN="sk-ant-oat01-abc"; F_SUBSCRIPTION_MODEL="claude-sonnet-5"
provider_subscription_configure >/dev/null 2>&1
if [ "$(getenv CLAUDE_MODEL)" = "claude-sonnet-5" ]; then ok; else bad "$(getenv CLAUDE_MODEL)"; fi
F_SUBSCRIPTION_MODEL=""

t "keeps a non-default bare model id (claude-opus-5) in .env"
reset_env; setenv CLAUDE_MODEL "claude-opus-5"; F_SUBSCRIPTION_TOKEN="sk-ant-oat01-abc"
provider_subscription_configure >/dev/null 2>&1
if [ "$(getenv CLAUDE_MODEL)" = "claude-opus-5" ]; then ok; else bad "$(getenv CLAUDE_MODEL)"; fi

# The previous-default check is plain string equality: a hand-edited value with glob characters can
# only equal itself, never match a previous default (PR #86 review).
for v in '*' 'claude-*' '?laude-sonnet-5' '[c]laude-sonnet-5'; do
  t "keeps a glob-looking .env value ($v) — no pattern matching"
  reset_env; setenv CLAUDE_MODEL "$v"; F_SUBSCRIPTION_TOKEN="sk-ant-oat01-abc"
  provider_subscription_configure >/dev/null 2>&1
  if [ "$(getenv CLAUDE_MODEL)" = "$v" ]; then ok; else bad "$(getenv CLAUDE_MODEL)"; fi
done

t "every entry of a multi-entry previous-defaults list is upgraded"
saved="$SUBSCRIPTION_PREVIOUS_DEFAULTS"; SUBSCRIPTION_PREVIOUS_DEFAULTS="claude-sonnet-5 claude-sonnet-4-6"; r=""
for v in claude-sonnet-5 claude-sonnet-4-6; do
  reset_env; setenv CLAUDE_MODEL "$v"; F_SUBSCRIPTION_TOKEN="sk-ant-oat01-abc"
  provider_subscription_configure >/dev/null 2>&1; r="$r $(getenv CLAUDE_MODEL)"
done
SUBSCRIPTION_PREVIOUS_DEFAULTS="$saved"
if [ "$r" = " claude-sonnet-5-5 claude-sonnet-5-5" ]; then ok; else bad "got:$r"; fi

# This path talks to the first-party API with bare model ids, exactly like the `anthropic` arm —
# so the picker should offer the same extras. (The gateway arm blanks them for a different reason:
# a gateway names models its own way, and we only know the one id the user gave us.)
t "registers claude-opus-5-5 as an extra so the picker offers it"
reset_env; F_SUBSCRIPTION_TOKEN="sk-ant-oat01-abc"
provider_subscription_configure >/dev/null 2>&1
if [ "$(getenv CLAUDE_EXTRA_MODELS)" = "claude-opus-5-5" ]; then ok; else bad "$(getenv CLAUDE_EXTRA_MODELS)"; fi

# A Bedrock/gateway id left in the extras is rejected by the first-party API just as CLAUDE_MODEL
# would be, so the list is always rewritten rather than carried over.
t "overwrites leftover provider-specific extras from a previous provider"
reset_env; setenv CLAUDE_EXTRA_MODELS "us.anthropic.claude-opus-5-5"; F_SUBSCRIPTION_TOKEN="sk-ant-oat01-abc"
provider_subscription_configure >/dev/null 2>&1
if [ "$(getenv CLAUDE_EXTRA_MODELS)" = "claude-opus-5-5" ]; then ok; else bad "$(getenv CLAUDE_EXTRA_MODELS)"; fi

# The title LLM being Bedrock-only is a detail of an unrelated subsystem; it told the user nothing
# actionable on a path they'd just chosen deliberately.
t "does not print the Bedrock-only ticket-titles note"
reset_env; F_SUBSCRIPTION_TOKEN="sk-ant-oat01-abc"
title_out="$(provider_subscription_configure 2>&1)"
case "$title_out" in *"ticket titles are not generated"*) bad "note still printed" ;; *) ok ;; esac

# Normalization, not validation: no valid opaque bearer token contains whitespace, so trimming can
# never turn a good token away regardless of future token shape. Deliberately NOT a length or
# stricter format check — the prefix is not a documented contract (see the file header).
t "trims surrounding whitespace from a pasted token"
reset_env; F_SUBSCRIPTION_TOKEN="  sk-ant-oat01-abc
"
provider_subscription_configure >/dev/null 2>&1
if [ "$(getenv CLAUDE_CODE_OAUTH_TOKEN)" = "sk-ant-oat01-abc" ]; then ok; else bad "[$(getenv CLAUDE_CODE_OAUTH_TOKEN)]"; fi

t "trims a token that came from .env with trailing whitespace"
reset_env; setenv CLAUDE_CODE_OAUTH_TOKEN "sk-ant-oat01-saved   "
provider_subscription_configure >/dev/null 2>&1
if [ "$(getenv CLAUDE_CODE_OAUTH_TOKEN)" = "sk-ant-oat01-saved" ]; then ok; else bad "[$(getenv CLAUDE_CODE_OAUTH_TOKEN)]"; fi

t "a whitespace-only token is treated as no token at all"
reset_env; F_SUBSCRIPTION_TOKEN="   "
if provider_subscription_configure >/dev/null 2>&1; then bad "returned 0 for a blank token"; else ok; fi

echo; echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
