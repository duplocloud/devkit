#!/usr/bin/env bash
# Checks that the register-* scripts only ever configure the local stack: they refuse a remote target without any
# network call, and run.sh pins the local target before it calls them.
#
# A stub `curl` first on PATH records every call, so nothing here reaches a real studio.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
PASS=0; FAIL=0
t()   { printf '  %s … ' "$1"; }
ok()  { echo "ok"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
printf '#!/usr/bin/env bash\necho "$*" >> "%s/curl.log"\nexit 22\n' "$TMP" > "$TMP/bin/curl"
chmod +x "$TMP/bin/curl"

echo "register-* local-only guard:"

for s in agent persona llm qdrant; do
  t "register-$s.sh refuses DUPLO_TARGET=remote and makes no request"
  rm -f "$TMP/curl.log"
  OUT="$(env -u DUPLO_BASE -u DUPLO_ADMIN_TOKEN PATH="$TMP/bin:$PATH" DUPLO_ENV_FILE=/dev/null \
    DUPLO_TARGET=remote DUPLO_HOST=https://remote.example DUPLO_TOKEN=fixture \
    CLAUDE_MODEL=m "./scripts/register-$s.sh" 2>&1)"; RC=$?
  if [ "$RC" -ne 0 ] && grep -q 'local dev-kit stack only' <<<"$OUT" && [ ! -e "$TMP/curl.log" ]; then ok
  else bad "rc=$RC log=$([ -e "$TMP/curl.log" ] && echo present || echo none)"; fi
done

t "a host+token pair with no explicit target (in-platform ticket) is also refused"
OUT="$(env -u DUPLO_TARGET -u DUPLO_BASE PATH="$TMP/bin:$PATH" DUPLO_ENV_FILE=/dev/null \
  DUPLO_HOST=https://remote.example DUPLO_TOKEN=fixture ./scripts/register-agent.sh 2>&1)"; RC=$?
if [ "$RC" -ne 0 ] && grep -q "resolves to 'remote'" <<<"$OUT"; then ok; else bad "rc=$RC"; fi

t "a remote target set only in the env file is refused"
ENVF="$TMP/remote.env"; printf 'DUPLO_TARGET=remote\nDUPLO_HOST=https://remote.example\nDUPLO_TOKEN=fixture\n' > "$ENVF"
OUT="$(env -u DUPLO_TARGET -u DUPLO_HOST -u DUPLO_TOKEN -u DUPLO_BASE PATH="$TMP/bin:$PATH" DUPLO_ENV_FILE="$ENVF" \
  ./scripts/register-agent.sh 2>&1)"; RC=$?
if [ "$RC" -ne 0 ] && grep -q "resolves to 'remote'" <<<"$OUT" && [ ! -e "$TMP/curl.log" ]; then ok; else bad "rc=$RC"; fi

t "run.sh failure hints tell the user to set DUPLO_TARGET=local"
if ! grep -E '(run|re-run) \./scripts/register-|: +\./scripts/register-' run.sh | grep -q .; then ok; else bad "hint without DUPLO_TARGET=local"; fi

t "run.sh pins DUPLO_TARGET=local and DUPLO_BASE before any register-* call"
PIN="$(grep -n '^export DUPLO_TARGET=local DUPLO_BASE=' run.sh | head -1 | cut -d: -f1)"
FIRST="$(grep -nE '^[^#]*\./scripts/register-' run.sh | grep -vE 'echo|manually|re-run' | head -1 | cut -d: -f1)"
if [ -n "$PIN" ] && [ -n "$FIRST" ] && [ "$PIN" -lt "$FIRST" ]; then ok; else bad "pin=$PIN first-register=$FIRST"; fi

t "switch-llm.sh pins the local target on its register-llm.sh call"
if grep -qE 'DUPLO_TARGET=local DUPLO_BASE=.* \\$' scripts/switch-llm.sh && grep -A1 'DUPLO_TARGET=local DUPLO_BASE=' scripts/switch-llm.sh | grep -q 'register-llm.sh'; then ok; else bad "not pinned"; fi

t "_target.sh: an explicit local target wins over a remote one in the env file"
ENVF="$TMP/env"; printf 'DUPLO_TARGET=remote\nDUPLO_HOST=https://remote.example\nDUPLO_TOKEN=fixture\nDUPLO_ADMIN_TOKEN=local\n' > "$ENVF"
BASE="$(DUPLO_ENV_FILE="$ENVF" DUPLO_TARGET=local DUPLO_BASE=http://localhost:60021 \
  bash -c 'source scripts/_target.sh; require_local_target t && echo "$BASE_URL"' 2>&1)"
if [ "$BASE" = "http://localhost:60021" ]; then ok; else bad "got: $BASE"; fi

t "bash -n on run.sh and the register scripts"
if bash -n run.sh scripts/_target.sh scripts/switch-llm.sh scripts/register-*.sh; then ok; else bad "syntax"; fi

echo; echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
