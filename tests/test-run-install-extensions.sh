#!/usr/bin/env bash
# Checks run.sh installs its default extensions (DUPLOAI-4813): DEVKIT_EXTENSIONS holds the Cloud Deployment Agent,
# scripts/install-extensions.sh is called with it after the Knowledge Base step and before the portal step, a failure
# can't stop run.sh, and the "Platform ready" banner reports it.
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

t "list_defined: DEVKIT_EXTENSIONS holds the Cloud Deployment Agent, every entry a valid id[@version]"
DEVKIT_EXTENSIONS=()
eval "$(awk '/^DEVKIT_EXTENSIONS=\(/,/^\)/' run.sh | tr -d '\r')"
okids=1
for e in "${DEVKIT_EXTENSIONS[@]}"; do [[ "$e" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*(@[A-Za-z0-9._+-]+)?$ ]] || okids=0; done
if [ "${#DEVKIT_EXTENSIONS[@]}" -gt 0 ] && [ "$okids" = 1 ] \
   && printf '%s\n' "${DEVKIT_EXTENSIONS[@]}" | grep -qx 'com.duplocloud.demo-cloud-deployment'; then ok
else bad "DEVKIT_EXTENSIONS=(${DEVKIT_EXTENSIONS[*]})"; fi

t "call_is_non_fatal: the install runs as an if/elif-condition, so set -e can't stop run.sh"
call="$(grep -nE '^(if|elif) \./scripts/install-extensions\.sh "\$\{DEVKIT_EXTENSIONS\[@\]\}"; then' run.sh | head -1 | cut -d: -f1)"
if [ -n "$call" ]; then ok; else bad "no non-fatal call line"; fi

# bash 3.2 (macOS) under set -u calls "${arr[@]}" on an empty array an unbound variable and aborts run.sh, so an
# emptied list must be caught before the array is expanded.
t "empty_list_guarded: an emptied DEVKIT_EXTENSIONS is checked before it is expanded"
guard="$(grep -n '^if \[ \${#DEVKIT_EXTENSIONS\[@\]} -eq 0 \]; then' run.sh | head -1 | cut -d: -f1)"
if [ -n "$guard" ] && [ -n "$call" ] && [ "$guard" -lt "$call" ] && [ $((call - guard)) -le 3 ]; then ok
else bad "guard=$guard call=$call"; fi

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
