#!/usr/bin/env bash
# Checks run.sh's admin login before minting the permanent API token (DUPLOAI-5693):
#   - it never exits silently. run.sh runs under `set -euo pipefail`; a response without access_token
#     (e.g. 200 {"mustChangePassword":true} for a password below the portal policy) used to make python3
#     raise KeyError and set -e kill the script before any message printed. The token lookup now ends
#     in `|| true`.
#   - an unreachable studio (curl fails) or a studio error (5xx) is reported as such and does NOT point
#     at --reset, which wipes the DB. Only a rejected login (4xx, or a 2xx without a token) does.
#
# This extracts the login block straight from run.sh (not a copy), runs it in a fresh bash under
# `set -euo pipefail` with curl stubbed, and checks the outcome. Nothing here starts the stack or touches .env.
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

LOGIN_BLOCK="$(awk '/^  LOGIN_RC=0$/,/^  # \(END LOGIN\)$/' run.sh)"
if [ -z "$LOGIN_BLOCK" ] || ! printf '%s' "$LOGIN_BLOCK" | grep -q 'END LOGIN'; then
  bad "login block not found in run.sh"; echo; echo "$PASS passed, $FAIL failed"; exit 1
fi

# Runs the real login block under set -euo pipefail with curl stubbed. Like the real curl with
# -w '\n%{http_code}', the stub prints the body, a newline and the HTTP code, then exits curl_rc.
# Prints "JWT=<value>" (only if the block completed), then "rc=<exit status>"; stderr to $ERRF.
# A fresh `bash` process, not a ( subshell ): errexit is ignored inside a subshell whose caller sits in
# an && / || list or a function called that way, which would hide exactly the silent abort under test.
ERRF="$(mktemp)"; trap 'rm -f "$ERRF"' EXIT
login() { # body http_code curl_rc
  LOGIN_BLOCK="$LOGIN_BLOCK" CURL_BODY="$1" CURL_CODE="$2" CURL_RC="$3" bash -c '
    set -euo pipefail
    ADMIN_PW_MIN_LEN=12
    curl() { printf "%s\n%s" "$CURL_BODY" "$CURL_CODE"; return "$CURL_RC"; }
    EMAIL="admin@example.com"; PASSWORD="LongEnough123"; API="http://localhost:60021"
    eval "$LOGIN_BLOCK"
    echo "JWT=$JWT"' 2>"$ERRF"
  echo "rc=$?"
}
exited1() { printf '%s' "$1" | grep -qx 'rc=1'; }

t "token response → continues with JWT set"
out="$(login '{"access_token":"abc.def"}' 200 0)"
if printf '%s' "$out" | grep -q '^JWT=abc.def' && printf '%s' "$out" | grep -qx 'rc=0'; then ok; else bad "out=$out stderr=$(cat "$ERRF")"; fi

t "mustChangePassword (short password) → \"Login failed\" with the password-policy hint, not silently"
out="$(login '{"mustChangePassword":true,"challengeCode":"x"}' 200 0)"
if exited1 "$out" && grep -q 'Login failed for admin@example.com' "$ERRF" && grep -q 'does not meet the portal password policy' "$ERRF"; then ok
else bad "out=$out stderr=$(cat "$ERRF")"; fi

t "401 (wrong password) → \"Login failed\" pointing at --reset, without the password-policy hint"
out="$(login '{"error":"invalid credentials"}' 401 0)"
if exited1 "$out" && grep -q 'Login failed for admin@example.com (HTTP 401)' "$ERRF" && grep -q -- '--reset to re-enter' "$ERRF" \
   && ! grep -q 'portal password policy' "$ERRF"; then ok; else bad "out=$out stderr=$(cat "$ERRF")"; fi

t "connection refused (curl exit 7) → \"not reachable\", no --reset advice"
out="$(login '' 000 7)"
if exited1 "$out" && grep -q 'not reachable (curl exit 7)' "$ERRF" && ! grep -q 'Login failed' "$ERRF" \
   && ! grep -q -- '--reset to' "$ERRF"; then ok; else bad "out=$out stderr=$(cat "$ERRF")"; fi

t "timeout (curl exit 28) → \"not reachable\", no --reset advice"
out="$(login '' 000 28)"
if exited1 "$out" && grep -q 'not reachable (curl exit 28)' "$ERRF" && ! grep -q -- '--reset to' "$ERRF"; then ok
else bad "out=$out stderr=$(cat "$ERRF")"; fi

t "500 from the studio → studio error, no --reset advice"
out="$(login 'Internal Server Error' 500 0)"
if exited1 "$out" && grep -q 'returned HTTP 500' "$ERRF" && ! grep -q 'Login failed' "$ERRF" \
   && ! grep -q -- '--reset to' "$ERRF"; then ok; else bad "out=$out stderr=$(cat "$ERRF")"; fi

echo; echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
