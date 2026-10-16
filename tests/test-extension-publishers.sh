#!/usr/bin/env bash
# Tests for .github/extension-publishers.json and scripts/_publishers.sh. Usage: ./tests/test-extension-publishers.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
PASS=0; FAIL=0
t()   { printf '  %s … ' "$1"; }
ok()  { echo "ok"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
. ./scripts/_publishers.sh
REAL=.github/extension-publishers.json
FIXTURE=tests/fixtures/extension-publishers.json
echo "extension-publishers:"

# Structural checks run against both files: the real allowlist can never gain a malformed entry either.
for F in "$REAL" "$FIXTURE"; do
  t "$F parses with schemaVersion 1"
  [ "$(jq -r .schemaVersion "$F")" = 1 ] && ok || bad "schemaVersion"
  t "$F: each manifest id appears once"
  [ "$(jq '[.publishers[].manifestId] | length == (unique | length)' "$F")" = true ] && ok || bad "duplicate id"
  t "$F: each entry names one repository and a console UUID"
  jq -e 'all(.publishers[]; (.repository | test("^[^/]+/[^/]+$")) and (.consoleExtension | test("^[0-9a-f-]{36}$")))' \
    "$F" >/dev/null && ok || bad "shape"
done

t "publish, where an entry sets it, is a boolean"
jq -e 'all(.publishers[]; (has("publish") | not) or (.publish | type == "boolean"))' "$REAL" >/dev/null && ok || bad "publish is not a boolean"

t "publisher_auto_publish is true only for an entry that sets publish true"
jq '.publishers[0].publish = true' "$FIXTURE" > "$TMP/auto.json"
id="$(jq -r '.publishers[0].manifestId' "$FIXTURE")"; repo="$(jq -r '.publishers[0].repository' "$FIXTURE")"
id2="$(jq -r '.publishers[1].manifestId' "$FIXTURE")"; repo2="$(jq -r '.publishers[1].repository' "$FIXTURE")"
( publishers_file="$TMP/auto.json"; publisher_auto_publish "$id" "$repo" && ! publisher_auto_publish "$id2" "$repo2" \
  && ! publisher_auto_publish "$id" "other/repo" ) && ok || bad "auto-publish lookup"

t "the real file is empty or every entry passes the shape check"
jq -e '(.publishers | length == 0) or
  all(.publishers[]; (.repository | test("^[^/]+/[^/]+$")) and (.consoleExtension | test("^[0-9a-f-]{36}$")))' \
  "$REAL" >/dev/null && ok || bad "placeholder in the real file"

publishers_file="$FIXTURE"
t "a mapped id and repository yield the UUID"
id=$(jq -r '.publishers[0].manifestId' "$FIXTURE"); repo=$(jq -r '.publishers[0].repository' "$FIXTURE")
[ "$(publisher_extension_uuid "$id" "$repo")" = "$(jq -r '.publishers[0].consoleExtension' "$FIXTURE")" ] && ok || bad "lookup"
t "an id mapped to another repository is refused"
! publisher_extension_uuid "$id" "someone/else" >/dev/null && ok || bad "accepted another repo"
t "an unknown id is refused"
! publisher_extension_uuid "duplo.nope" "$repo" >/dev/null && ok || bad "accepted unknown id"

# Exit-status contract: callers key off exit 1 meaning "not allowed to publish." jq -e itself exits 4 when its
# filter produces no output at all, so the function must capture the lookup rather than pass that code through.
t "an unknown id exits exactly 1"
publisher_extension_uuid "duplo.nope" "$repo" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok || bad "exit $rc"
t "a wrong repository exits exactly 1"
publisher_extension_uuid "$id" "someone/else" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok || bad "exit $rc"
publishers_file="$REAL"
t "the empty real file exits exactly 1"
publisher_extension_uuid "duplo.anything" "duplocloud/anything" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok || bad "exit $rc"
publishers_file="$TMP/missing.json"
t "a missing file exits exactly 1"
publisher_extension_uuid "duplo.anything" "duplocloud/anything" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok || bad "exit $rc"
printf '{not valid json' > "$TMP/malformed.json"
publishers_file="$TMP/malformed.json"
t "a malformed allowlist file exits exactly 1, not a jq error code"
publisher_extension_uuid "duplo.anything" "duplocloud/anything" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok || bad "exit $rc"

echo; echo "passed $PASS, failed $FAIL"; [ "$FAIL" -eq 0 ]
