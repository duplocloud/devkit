#!/usr/bin/env bash
# Checks the end of run.sh tells the user which portal URL to open (DUPLOAI-5372): the URL comes from
# Authentication__FrontendBaseUrl (falling back to localhost:UI_PORT), the run checks the portal answers
# before saying so, and the "open the portal" message is the very last thing printed.
# Static checks plus portal_open_message() run in isolation — nothing here starts the stack or touches .env.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
PASS=0; FAIL=0
t()   { printf '  %s … ' "$1"; }
ok()  { echo "ok"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

echo "run.sh portal message wiring:"

t "run.sh is syntactically valid and defines portal_open_message"
if bash -n run.sh 2>/dev/null && grep -q '^portal_open_message() {' run.sh; then ok
else bad "missing/syntax error"; exit 1; fi

t "PORTAL_URL comes from portal_url(Authentication__FrontendBaseUrl, UI_PORT)"
if grep -q '^portal_url() {' run.sh \
   && grep -q 'PORTAL_URL="$(portal_url "$(getenv Authentication__FrontendBaseUrl)" "$UI_PORT")"' run.sh; then ok; else bad "PORTAL_URL source"; fi

# getenv always succeeds, so `$(getenv UI_PORT || echo 4200)` never falls back and could store
# "http://localhost:" (PR #87 review). The write must check for a blank UI_PORT explicitly.
t "the FrontendBaseUrl default write can't store a port-less http://localhost:"
if ! grep -q 'getenv UI_PORT 2>/dev/null || echo' run.sh \
   && grep -q 'FB_PORT="$(getenv UI_PORT)"; \[ -n "$FB_PORT" \] || FB_PORT=4200' run.sh \
   && grep -q 'setenv Authentication__FrontendBaseUrl "http://localhost:$FB_PORT"' run.sh; then ok; else bad "FrontendBaseUrl default write"; fi

eval "$(awk '/^portal_url\(\) \{/,/^}/' run.sh)"
echo "portal_url() — localhost follows UI_PORT, any other host is kept (PR #87 review):"
pu() { # stored port expected label
  t "$4"
  local got; got="$(portal_url "$1" "$2")"
  if [ "$got" = "$3" ]; then ok; else bad "portal_url '$1' '$2' → '$got' (expected '$3')"; fi
}
pu ""                            4310 "http://localhost:4310"    "empty stored value → localhost:UI_PORT"
pu "http://localhost:4210"       4310 "http://localhost:4310"    "stale localhost port after UI_PORT moved → current UI_PORT"
pu "http://localhost:"           4310 "http://localhost:4310"    "port-less http://localhost: → current UI_PORT"
pu "http://127.0.0.1:4210"       4310 "http://localhost:4310"    "127.0.0.1 is treated as localhost"
pu "http://localhost:4210/"      4210 "http://localhost:4210"    "unchanged port, trailing slash → no slash"
pu "https://devkit.example.com/" 4310 "https://devkit.example.com" "custom host kept as-is, trailing slash trimmed"
pu "http://10.0.0.5:4210"        4310 "http://10.0.0.5:4210"     "non-localhost IP kept as-is"

t "the banner's UI line shows PORTAL_URL, not a hard-coded localhost"
if grep -qE '^  UI +\$PORTAL_URL ' run.sh && ! grep -qE '^  UI +http://localhost' run.sh; then ok; else bad "UI line"; fi

t "the portal is probed on localhost:UI_PORT before the banner"
probe="$(grep -n 'curl .*"http://localhost:$UI_PORT/"' run.sh | head -1 | cut -d: -f1)"
banner="$(grep -n '^✔ Platform ready' run.sh | head -1 | cut -d: -f1)"
if [ -n "$probe" ] && [ -n "$banner" ] && [ "$probe" -lt "$banner" ]; then ok; else bad "probe=$probe banner=$banner"; fi

t "portal_open_message is the last command in run.sh"
last="$(grep -vE '^\s*(#|$)' run.sh | tail -1)"
if [ "$last" = 'portal_open_message "$PORTAL_URL" "$EMAIL" "$PORTAL_UP"' ]; then ok; else bad "last line: $last"; fi

eval "$(awk '/^portal_open_message\(\) \{/,/^}/' run.sh)"
echo "portal_open_message():"

t "prints the URL and the sign-in email"
out="$(SSH_CONNECTION='' portal_open_message "http://localhost:4210" "a@b.com" 1)"
if grep -q '^==> Open the portal in your browser:  http://localhost:4210$' <<<"$out" && grep -q 'Sign in as a@b.com' <<<"$out"; then ok
else bad "$out"; fi

t "no warning and no SSH hint when the portal is up and not on SSH"
if ! grep -qE "isn't answering|ssh -L" <<<"$out"; then ok; else bad "$out"; fi

t "warns when the portal did not answer"
out="$(SSH_CONNECTION='' portal_open_message "http://localhost:4210" "a@b.com" 0)"
if grep -q "isn't answering yet" <<<"$out"; then ok; else bad "$out"; fi

t "over SSH with a localhost URL, prints the tunnel command for that port"
out="$(SSH_CONNECTION='10.0.0.1 5000 10.0.0.2 22' portal_open_message "http://localhost:4210" "a@b.com" 1)"
if grep -q 'ssh -L 4210:localhost:4210 ' <<<"$out"; then ok; else bad "$out"; fi

t "over SSH, the port is taken from the URL even with a trailing path"
out="$(SSH_CONNECTION='x' portal_open_message "http://127.0.0.1:4300/app" "a@b.com" 1)"
if grep -q 'ssh -L 4300:localhost:4300 ' <<<"$out"; then ok; else bad "$out"; fi

t "over SSH with a non-localhost URL, no tunnel hint"
out="$(SSH_CONNECTION='x' portal_open_message "https://devkit.example.com" "a@b.com" 1)"
if ! grep -q 'ssh -L' <<<"$out" && grep -q 'https://devkit.example.com' <<<"$out"; then ok; else bad "$out"; fi

t "returns 0 in every branch (run.sh is set -e)"
rc=0
for s in '' x; do for u in 0 1; do for url in http://localhost:4210 https://h.example.com; do
  SSH_CONNECTION="$s" portal_open_message "$url" e 1 >/dev/null 2>&1 || rc=1
  SSH_CONNECTION="$s" portal_open_message "$url" e "$u" >/dev/null 2>&1 || rc=1
done; done; done
if [ "$rc" = 0 ]; then ok; else bad "non-zero return"; fi

echo; echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
