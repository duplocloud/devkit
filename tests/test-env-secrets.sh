#!/usr/bin/env bash
# Tests for scripts/_env_secrets.sh and its wiring: provider secrets exported in the environment are used
# when .env has none, are never written to .env, and only the chosen provider's keys reach the agent.
# Runs against throwaway files; never touches the real .env. The compose checks render config only
# (no containers) and are skipped when neither docker nor podman has compose.
# Usage: ./tests/test-env-secrets.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

PASS=0; FAIL=0; SKIP=0
t()    { printf '  %s … ' "$1"; }
ok()   { echo "ok"; PASS=$((PASS+1)); }
bad()  { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
skip() { echo "skip ($1)"; SKIP=$((SKIP+1)); }

ENV="$(mktemp)"; TMPD="$(mktemp -d)"; trap 'rm -rf "$ENV" "$TMPD"' EXIT
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

. ./scripts/_env_secrets.sh || { echo "scripts/_env_secrets.sh not found"; exit 1; }

# Each case runs in a subshell so exports, unsets and ENV_TAKEN never leak between cases.
echo "env_supplied:"

t "uses the environment when flag and .env are empty"
echo "ANTHROPIC_API_KEY=" > "$ENV"
if (export ANTHROPIC_API_KEY=from-env; env_supplied "" ANTHROPIC_API_KEY); then ok; else bad "expected 0"; fi

t "a value in .env wins over the environment (existing setups unchanged)"
echo "ANTHROPIC_API_KEY=in-dotenv" > "$ENV"
if (export ANTHROPIC_API_KEY=from-env; env_supplied "" ANTHROPIC_API_KEY); then bad "expected 1"; else ok; fi

t "a flag wins over the environment"
: > "$ENV"
if (export ANTHROPIC_API_KEY=from-env; env_supplied "from-flag" ANTHROPIC_API_KEY); then bad "expected 1"; else ok; fi

t "unset or empty environment falls through to resolve/prompt"
: > "$ENV"
if (unset ANTHROPIC_API_KEY; env_supplied "" ANTHROPIC_API_KEY) || (export ANTHROPIC_API_KEY=; env_supplied "" ANTHROPIC_API_KEY)
then bad "expected 1"; else ok; fi

t "safe under set -u when the variable is unset"
: > "$ENV"
if (set -u; unset AWS_SECRET_ACCESS_KEY; env_supplied "" AWS_SECRET_ACCESS_KEY; [ $? -eq 1 ]) 2>/dev/null; then ok
else bad "errored or returned 0 under set -u"; fi

t "bedrock with only one AWS key exported does not qualify"
: > "$ENV"
if (export AWS_ACCESS_KEY_ID=ak; unset AWS_SECRET_ACCESS_KEY
    env_supplied "" AWS_ACCESS_KEY_ID && env_supplied "" AWS_SECRET_ACCESS_KEY); then bad "expected 1"; else ok; fi

echo "env_take_session_token:"

t "flag is exported and taken, never written to .env"
echo "AWS_SESSION_TOKEN=stale" > "$ENV"
r="$(unset AWS_SESSION_TOKEN; env_take_session_token "tok-flag"; env_taken AWS_SESSION_TOKEN && echo "taken:$AWS_SESSION_TOKEN")"
if [ "$r" = "taken:tok-flag" ] && [ "$(getenv AWS_SESSION_TOKEN)" = "" ]; then ok; else bad "got '$r', .env='$(getenv AWS_SESSION_TOKEN)'"; fi

t "exported token is taken; stale .env token blanked"
echo "AWS_SESSION_TOKEN=stale" > "$ENV"
r="$(export AWS_SESSION_TOKEN=tok-env; env_take_session_token ""; env_taken AWS_SESSION_TOKEN && echo taken)"
if [ "$r" = "taken" ] && [ "$(getenv AWS_SESSION_TOKEN)" = "" ]; then ok; else bad "got '$r'"; fi

t "no token anywhere: blanked, not taken"
echo "AWS_SESSION_TOKEN=stale" > "$ENV"
r="$(unset AWS_SESSION_TOKEN; env_take_session_token ""; env_taken AWS_SESSION_TOKEN && echo taken || echo none)"
if [ "$r" = "none" ] && [ "$(getenv AWS_SESSION_TOKEN)" = "" ]; then ok; else bad "got '$r'"; fi

echo "env_isolate:"

t "keeps taken keys, unsets every other provider key"
r="$(export ANTHROPIC_API_KEY=a AWS_ACCESS_KEY_ID=b AWS_SECRET_ACCESS_KEY=c ANTHROPIC_BASE_URL=d
     env_take AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; env_isolate >/dev/null
     echo "${ANTHROPIC_API_KEY-unset}|${ANTHROPIC_BASE_URL-unset}|${AWS_ACCESS_KEY_ID-unset}|${AWS_SECRET_ACCESS_KEY-unset}")"
if [ "$r" = "unset|unset|b|c" ]; then ok; else bad "got '$r'"; fi

t "names shadowed exports without printing values"
out="$(export ANTHROPIC_API_KEY=secret-value-xyz; env_isolate)"
if printf '%s' "$out" | grep -q 'ignoring ANTHROPIC_API_KEY' && ! printf '%s' "$out" | grep -q 'secret-value-xyz'
then ok; else bad "output: $out"; fi

t "silent when nothing is exported; empty-but-set is unset quietly"
out="$(unset "${PROVIDER_ENV_KEYS[@]}"; export AWS_SESSION_TOKEN=; env_isolate; echo "${AWS_SESSION_TOKEN-unset}")"
if [ "$out" = "unset" ]; then ok; else bad "output: $out"; fi

t "PROVIDER_ENV_KEYS covers every credential compose passes to the agent"
miss=""
for k in $(grep -oE '(ANTHROPIC_[A-Z_]+|AWS_(ACCESS|SECRET|SESSION)[A-Z_]*|CLAUDE_CODE_OAUTH_TOKEN|AZURE_[A-Z_]+)=\$\{' docker-compose.yml \
           | cut -d= -f1 | sort -u); do
  printf '%s\n' "${PROVIDER_ENV_KEYS[@]}" | grep -qx "$k" || miss="$miss $k"
done
if [ -z "$miss" ]; then ok; else bad "not isolated:$miss"; fi

echo "wiring:"

t "run.sh and switch-llm.sh source the helper and isolate right before compose up"
miss=""
for f in run.sh scripts/switch-llm.sh; do
  grep -q '_env_secrets.sh' "$f" || miss="$miss $f:source"
  grep -A1 '^env_isolate' "$f" | grep -q 'compose up' || miss="$miss $f:isolate"
done
if [ -z "$miss" ]; then ok; else bad "missing:$miss"; fi

t "anthropic and bedrock arms take environment keys instead of writing them"
miss=""
for f in run.sh scripts/switch-llm.sh; do
  grep -A1 'env_supplied "$F_ANTHROPIC" ANTHROPIC_API_KEY' "$f" | grep -q 'env_take ANTHROPIC_API_KEY' || miss="$miss $f:anthropic"
  grep -A1 'env_supplied "$F_AWS_SECRET" AWS_SECRET_ACCESS_KEY' "$f" | grep -q 'env_take AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY' \
    || miss="$miss $f:bedrock"
done
if [ -z "$miss" ]; then ok; else bad "missing:$miss"; fi

t "docs describe the behaviour"
if grep -q "Secrets from the environment" docs/configuration.md \
   && grep -q "configuration.md#secrets-from-the-environment" docs/cli-reference.md; then ok; else bad "docs"; fi

t "bash -n on run.sh, switch-llm.sh and the helper"
if bash -n run.sh && bash -n scripts/switch-llm.sh && bash -n scripts/_env_secrets.sh; then ok; else bad "syntax error"; fi

echo "compose (rendered config, dummy values only):"
RT=""
for c in docker podman; do command -v "$c" >/dev/null 2>&1 && "$c" compose version >/dev/null 2>&1 && { RT="$c"; break; }; done
render() { # key -> prints "<agent value>|<studio value>" for key, from $TMPD with the current environment
  (cd "$TMPD" && "$RT" compose config --format json 2>/dev/null) | python3 -c '
import json,sys
k=sys.argv[1]; s=json.load(sys.stdin)["services"]
v=lambda n:(s[n].get("environment") or {}).get(k)
print(str(v("claude-code-agent")) + "|" + str(v("duplo-ai-studio")))' "$1"
}
if [ -z "$RT" ]; then
  t "compose precedence"; skip "no docker/podman compose"
else
  cp docker-compose.yml "$TMPD/"
  grep -E '^[A-Z_]+_TAG=|^[A-Z_]*PORT=|^STUDIO_PLATFORM=' .env.example > "$TMPD/.env"
  echo "ANTHROPIC_API_KEY=from-dotenv" >> "$TMPD/.env"

  t "shell value beats .env for the agent (why env_isolate is needed)"
  r="$(export ANTHROPIC_API_KEY=from-shell; render ANTHROPIC_API_KEY)"
  if [ "${r%%|*}" = "from-shell" ]; then ok; else bad "agent got '${r%%|*}'"; fi

  t "after env_isolate the agent gets .env for an untaken key"
  r="$(export ANTHROPIC_API_KEY=from-shell; env_isolate >/dev/null; render ANTHROPIC_API_KEY)"
  if [ "${r%%|*}" = "from-dotenv" ]; then ok; else bad "agent got '${r%%|*}'"; fi

  t "a taken key survives env_isolate and reaches the agent"
  sed -i.bak 's/^ANTHROPIC_API_KEY=.*/ANTHROPIC_API_KEY=/' "$TMPD/.env"
  r="$(export ANTHROPIC_API_KEY=from-shell; env_take ANTHROPIC_API_KEY; env_isolate >/dev/null; render ANTHROPIC_API_KEY)"
  if [ "${r%%|*}" = "from-shell" ]; then ok; else bad "agent got '${r%%|*}'"; fi

  t "studio (env_file) never receives an environment-only value"
  if [ "${r##*|}" != "from-shell" ]; then ok; else bad "studio got the shell value"; fi
fi

echo; echo "$PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" = 0 ]
