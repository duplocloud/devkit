#!/usr/bin/env bash
# Checks run.sh installs its default extensions (DUPLOAI-4813): DEVKIT_EXTENSIONS holds Cloud Setup (the ticket's Cloud Deployment Agent),
# scripts/install-extensions.sh is called with it after the Knowledge Base step and before the portal step, a failure
# can't stop run.sh, and the "Platform ready" banner reports it. The same list becomes Extensions__DefaultIds before
# the stack starts (DUPLOAI-5854).
# Static checks only — nothing here starts the stack or touches .env.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
PASS=0; FAIL=0
t()   { printf '  %s … ' "$1"; }
ok()  { echo "ok"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

echo "run.sh default-extension wiring:"

t "syntax: run.sh is syntactically valid"
if bash -n run.sh 2>/dev/null; then ok; else bad "bash -n run.sh failed"; exit 1; fi

t "list_defined: DEVKIT_EXTENSIONS holds Cloud Setup's manifest id (com.duplocloud.cloud-setup); every entry a bare manifest id"
DEVKIT_EXTENSIONS=()
eval "$(awk '/^DEVKIT_EXTENSIONS=\(/,/^\)/' run.sh | tr -d '\r')"
okids=1
# No @version (the installer only takes the version it offers) and never the agent UUID, which installs nothing.
for e in "${DEVKIT_EXTENSIONS[@]}"; do
  [[ "$e" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || okids=0
  [[ "$e" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] && okids=0
done
if [ "${#DEVKIT_EXTENSIONS[@]}" -gt 0 ] && [ "$okids" = 1 ] \
   && printf '%s\n' "${DEVKIT_EXTENSIONS[@]}" | grep -qx 'com.duplocloud.cloud-setup'; then ok
else bad "DEVKIT_EXTENSIONS=(${DEVKIT_EXTENSIONS[*]})"; fi

t "call_is_non_fatal: the install runs as an if/elif-condition, so set -e can't stop run.sh"
call="$(grep -nE '^(if|elif) \./scripts/install-extensions\.sh "\$\{DEVKIT_EXTENSIONS\[@\]\}"; then' run.sh | head -1 | cut -d: -f1)"
if [ -n "$call" ]; then ok; else bad "no non-fatal call line"; fi

# bash 3.2 (macOS) under set -u calls "${arr[@]}" on an empty array an unbound variable and aborts run.sh, so an
# emptied list must be caught before the array is expanded.
GUARD_RE='^if \[ \${#DEVKIT_EXTENSIONS\[@\]} -eq 0 \]; then$'
t "empty_list_guarded: an emptied DEVKIT_EXTENSIONS is checked before it is expanded"
# The guard nearest above the call; the Extensions__DefaultIds write further up has its own.
guard="$(grep -n "$GUARD_RE" run.sh | cut -d: -f1 | awk -v c="${call:-0}" '$1 < c' | tail -1)"
if [ -n "$guard" ] && [ -n "$call" ] && [ "$guard" -lt "$call" ] && [ $((call - guard)) -le 3 ]; then ok
else bad "guard=$guard call=$call"; fi

# DUPLOAI-5854: the studio flags these ids isDefault for the portal's Get Started page. It reads .env only when its
# container is created, so the key has to be written before `compose up`, from the same list the install uses.
t "default_ids_before_up: Extensions__DefaultIds is written from DEVKIT_EXTENSIONS before compose up"
list="$(grep -n '^DEVKIT_EXTENSIONS=($' run.sh | head -1 | cut -d: -f1)"
ids="$(grep -n '^  setenv Extensions__DefaultIds "\$(IFS=,' run.sh | head -1 | cut -d: -f1)"
up="$(grep -n 'compose up -d$' run.sh | head -1 | cut -d: -f1)"
if [ -n "$list" ] && [ -n "$ids" ] && [ -n "$up" ] && [ "$list" -lt "$ids" ] && [ "$ids" -lt "$up" ]; then ok
else bad "list=$list ids=$ids up=$up"; fi

# Runs run.sh's own block (the first guard, the one ahead of compose up) with a stand-in setenv, under set -u like
# run.sh. Matched as a literal line: awk -v would read the backslashes in GUARD_RE as escapes.
default_ids_for() { # entries...
  local block
  block="$(tr -d '\r' < run.sh | awk -v g='if [ ${#DEVKIT_EXTENSIONS[@]} -eq 0 ]; then' '$0 == g {f=1} f {print} f && /^fi$/ {exit}')"
  bash -uc 'setenv() { printf "%s=%s" "$1" "$2"; }; DEVKIT_EXTENSIONS=(); [ $# -eq 0 ] || DEVKIT_EXTENSIONS=("$@"); eval "$0"' \
    "$block" "$@" 2>&1
}
t "default_ids_value: the ids are comma-joined, and an empty list writes a blank value"
two="$(default_ids_for a.one b.two)"
none="$(default_ids_for)"
if [ "$two" = "Extensions__DefaultIds=a.one,b.two" ] && [ "$none" = "Extensions__DefaultIds=" ]; then ok
else bad "two='$two' none='$none'"; fi

t "placed_after_kb_before_portal: after register-qdrant.sh, before portal_url()"
kb="$(grep -n '\./scripts/register-qdrant\.sh "\$WS"' run.sh | head -1 | cut -d: -f1)"
portal="$(grep -n '^portal_url() {' run.sh | head -1 | cut -d: -f1)"
if [ -n "$call" ] && [ -n "$kb" ] && [ -n "$portal" ] && [ "$kb" -lt "$call" ] && [ "$call" -lt "$portal" ]; then ok
else bad "kb=$kb call=$call portal=$portal"; fi

t "banner_shows_extensions: the banner line with \$KB_LINE also carries \$EXT_LINE"
if grep '\$KB_LINE' run.sh | grep -q '\$EXT_LINE'; then ok; else bad "$(grep -n '\$KB_LINE' run.sh | tail -1)"; fi

t "portal_message_still_last: tests/test-run-portal-message.sh still passes"
if bash tests/test-run-portal-message.sh >/dev/null 2>&1; then ok; else bad "test-run-portal-message.sh failed"; fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
