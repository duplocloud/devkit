#!/usr/bin/env bash
# Checks run.sh's admin login before minting the permanent API token never exits silently (DUPLOAI-5693).
#
# Why this exists: run.sh runs under `set -euo pipefail`, and the login is
#   JWT="$(curl -fsS … PasswordLogin … | python3 -c '…["access_token"]' 2>/dev/null || true)"
# Without the `|| true`, a response without access_token — e.g. 200 {"mustChangePassword":true} for an
# admin password shorter than the portal policy — made python3 raise KeyError, pipefail failed the
# assignment, and set -e killed the script *before* the "Login failed" line could print: setup just
# stopped after "==> Minting permanent admin API token…".
#
# This extracts the login block straight from run.sh (not a copy), runs it in a fresh bash under
# `set -euo pipefail` with curl stubbed, and checks a token continues and a missing token prints
# "Login failed" and exits 1. Nothing here starts the stack or touches .env.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
PASS=0; FAIL=0
t()   { printf '  %s … ' "$1"; }
ok()  { echo "ok"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# run.sh calls python3; on a Windows box python3 may be the Store stub while `python` works.
if ! python3 -c 'print(1)' >/dev/null 2>&1; then
  if python -c 'print(1)' >/dev/null 2>&1; then python3() { python "$@"; }; export -f python3
  else echo "SKIP: no working python3/python on PATH"; exit 0; fi
fi

echo "run.sh admin login:"

t "the token lookup ends in '|| true' (a KeyError under pipefail must not abort silently)"
if grep -q "print(json.load(sys.stdin)\[\"access_token\"\])' 2>/dev/null || true)\"" run.sh; then ok; else bad "'|| true' missing from the login"; fi

LOGIN_BLOCK="$(awk '/^  JWT="\$\(curl -fsS --max-time 10 -X POST "\$API\/api\/Account\/PasswordLogin"/,/Login failed for/' run.sh)"
if [ -z "$LOGIN_BLOCK" ]; then bad "login block not found in run.sh"; echo; echo "$PASS passed, $FAIL failed"; exit 1; fi

# Runs the real login block under set -euo pipefail with curl stubbed to print $1 and exit $2.
# Prints "JWT=<value>" (only if the block completed), then "rc=<exit status>"; stderr to $ERRF.
# A fresh `bash` process, not a ( subshell ): errexit is ignored inside a subshell whose caller sits in
# an && / || list or a function called that way, which would hide exactly the silent abort under test.
ERRF="$(mktemp)"; trap 'rm -f "$ERRF"' EXIT
login() { # body curl_rc
  LOGIN_BLOCK="$LOGIN_BLOCK" CURL_BODY="$1" CURL_RC="$2" bash -c '
    set -euo pipefail
    ADMIN_PW_MIN_LEN=12
    curl() { printf "%s" "$CURL_BODY"; return "$CURL_RC"; }
    EMAIL="admin@example.com"; PASSWORD="LongEnough123"; API="http://localhost:60021"
    eval "$LOGIN_BLOCK"
    echo "JWT=$JWT"' 2>"$ERRF"
  echo "rc=$?"
}

t "token response → continues with JWT set"
out="$(login '{"access_token":"abc.def"}' 0)"
if printf '%s' "$out" | grep -q '^JWT=abc.def' && printf '%s' "$out" | grep -qx 'rc=0'; then ok; else bad "out=$out stderr=$(cat "$ERRF")"; fi

t "mustChangePassword (short password) → exit 1 with \"Login failed\", not silently"
out="$(login '{"mustChangePassword":true,"challengeCode":"x"}' 0)"
if printf '%s' "$out" | grep -qx 'rc=1' && grep -q 'Login failed for admin@example.com' "$ERRF" && grep -q 'at least 12 characters' "$ERRF"; then ok
else bad "out=$out stderr=$(cat "$ERRF")"; fi

t "curl failure (401 / timeout) → exit 1 with \"Login failed\""
out="$(login '' 22)"
if printf '%s' "$out" | grep -qx 'rc=1' && grep -q 'Login failed' "$ERRF"; then ok; else bad "out=$out stderr=$(cat "$ERRF")"; fi

echo; echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
