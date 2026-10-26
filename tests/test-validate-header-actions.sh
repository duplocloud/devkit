#!/usr/bin/env bash
# Checks scripts/validate-header-actions.sh (the build-time twin of the portal's header-action-registry)
# and its wiring into build-extension.sh --validate-only. No network, no real toolchain.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
PASS=0; FAIL=0
t()   { printf '  %s … ' "$1"; }
ok()  { echo "ok"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "header actions validation:"

[ -f scripts/validate-header-actions.sh ] || { t "scripts/validate-header-actions.sh exists"; bad "missing"; echo; echo "PASS=$PASS FAIL=$FAIL"; exit 1; }
# shellcheck source=scripts/validate-header-actions.sh
. ./scripts/validate-header-actions.sh

ACT='{"id":"a","label":"A","matIcon":"x","expose":"./A"}'
mk() { mkdir -p "$TMP/ext"; printf '%s' "$1" > "$TMP/ext/manifest.json"; }
wrap() { printf '{"id":"e","frontend":{"headerActions":%s}}' "$1"; }

# expect_pass <name> <headerActions-json> / expect_fail <name> <headerActions-json> <message substring>
expect_pass() {
  t "$1"; mk "$(wrap "$2")"
  local err; err="$(validate_header_actions "$TMP/ext/manifest.json" 2>&1)"; local rc=$?
  [ "$rc" = 0 ] && ok || bad "rc=$rc: $err"
}
expect_fail() {
  t "$1"; mk "$(wrap "$2")"
  local err; err="$(validate_header_actions "$TMP/ext/manifest.json" 2>&1 >/dev/null)"; local rc=$?
  if [ "$rc" != 1 ]; then bad "rc=$rc (want 1)"
  elif [[ "$err" != *"✗ frontend.headerActions"* ]]; then bad "no ✗ line: $err"
  elif [[ "$err" != *"$3"* ]]; then bad "missing '$3' in: $err"
  else ok; fi
}
# act '<json overrides merged into ACT>'
act() { jq -c ". + $1" <<<"$ACT"; }
grp() { printf '{"id":"g","label":"G","matIcon":"x","children":%s}' "$1"; }

# ── valid manifests ──────────────────────────────────────────────────────────────────────────────
t "passes when frontend.headerActions is absent"; mk '{"id":"e","frontend":{}}'
validate_header_actions "$TMP/ext/manifest.json" 2>/dev/null && ok || bad "rc!=0"
expect_pass "passes the issue reporter entry" '[{"id":"report-issue","label":"Report an issue","matIcon":"bug-outline","placement":"inline","order":10,"showInAdmin":true,"visibilityUrl":"/v1/aiservicedesk/extensions/duploai-issue-reporter/launcher","expose":"./HeaderActions","shortcut":"Mod+Shift+Period","isolatePointer":true,"preserveFocus":true}]'
expect_pass "passes a group with two children" "[$(grp '[{"id":"c1","label":"C1","expose":"./C1"},{"id":"c2","label":"C2","expose":"./C2","shortcut":"Alt+KeyK","roles":["admin"]}]')]"

# ── entry rules ──────────────────────────────────────────────────────────────────────────────────
expect_fail "rejects a blank id"            "[$(act '{"id":"  "}')]" "id"
expect_fail "rejects a blank label"         "[$(act '{"label":""}')]" "label"
expect_fail "rejects a non-string label"    "[$(act '{"label":5}')]" "label"
expect_fail "rejects a top-level without matIcon" "[$(act '{"matIcon":null}' | jq -c 'del(.matIcon)')]" "matIcon"
expect_fail "rejects placement side"        "[$(act '{"placement":"side"}')]" "placement"
expect_fail "rejects an action without expose" "[$(jq -c 'del(.expose)' <<<"$ACT")]" "expose"
for k in expose shortcut visibilityUrl isolatePointer preserveFocus; do
  case "$k" in isolatePointer|preserveFocus) v=true ;; shortcut) v='"Mod+KeyK"' ;; visibilityUrl) v='"/v1/aiservicedesk/x"' ;; *) v='"./X"' ;; esac
  expect_fail "rejects a group with $k" "[$(grp '[{"id":"c","label":"C","expose":"./C"}]' | jq -c ". + {\"$k\":$v}")]" "$k"
done
expect_fail "rejects empty children"        "[$(grp '[]')]" "children"
expect_fail "rejects string children"       "[$(grp '"x"')]" "children"
expect_fail "rejects a child with children" "[$(grp '[{"id":"c","label":"C","children":[]}]')]" "children"
expect_fail "rejects a child with placement" "[$(grp '[{"id":"c","label":"C","expose":"./C","placement":"menu"}]')]" "placement"
expect_fail "rejects a child with showInAdmin" "[$(grp '[{"id":"c","label":"C","expose":"./C","showInAdmin":true}]')]" "showInAdmin"
expect_fail "rejects non-array headerActions" '{"id":"a"}' "array"
for v in false 0 '""'; do
  expect_fail "rejects headerActions $v" "$v" "array"
done
expect_fail "rejects a null entry"          '[null]' "object"
expect_fail "rejects a string order"        "[$(act '{"order":"1"}')]" "order"
expect_fail "rejects non-array roles"       "[$(act '{"roles":"admin"}')]" "roles"
for f in showInAdmin isolatePointer preserveFocus; do
  expect_fail "rejects a non-boolean $f"    "[$(act "{\"$f\":\"yes\"}")]" "$f"
done
expect_fail "rejects a duplicate id (top-level vs child)" "[$(act '{"id":"g"}'),$(grp '[{"id":"c","label":"C","expose":"./C"}]')]" "duplicate"
expect_fail "rejects a child reusing its group id" "[$(grp '[{"id":"g","label":"C","expose":"./C"}]')]" "duplicate"

# ── shortcut ─────────────────────────────────────────────────────────────────────────────────────
for s in "Ctrl+Shift" "Alt+Mod" "Shift+Shift" 'Mod+KeyK\n' "Shift+" "Shift+Shift+KeyK" "Mod+Ctrl+KeyK" "KeyK" "Mod+k" "Mod+KeyK+KeyL"; do
  expect_fail "rejects shortcut '$s'" "[$(act "{\"shortcut\":\"$s\"}")]" "shortcut"
done
expect_fail "rejects a non-string shortcut" "[$(act '{"shortcut":5}')]" "shortcut"
expect_pass "accepts shortcut Ctrl+Alt+Digit1" "[$(act '{"shortcut":"Ctrl+Alt+Digit1"}')]"

# ── visibilityUrl ────────────────────────────────────────────────────────────────────────────────
for u in "https://evil.example/x" "//evil.example/x" "/v1/other/launcher" "/v1/aiservicedesk/../x" "/v1/aiservicedesk/%2E%2e/x" "/v1/aiservicedesk//x" '/v1/aiservicedesk/a\\b' "/v1/aiservicedesk/./x"; do
  expect_fail "rejects visibilityUrl '$u'" "[$(act "{\"visibilityUrl\":\"$u\"}")]" "visibilityUrl"
done
expect_pass "accepts visibilityUrl with a query" "[$(act '{"visibilityUrl":"/v1/aiservicedesk/x/launcher?a=b//c"}')]"

# ── build-extension.sh --validate-only wiring ────────────────────────────────────────────────────
# Failing shims prepended to PATH: any call to the real toolchain or network marks and exits 99.
SHIMS="$TMP/shims"; MARK="$TMP/marker"; mkdir -p "$SHIMS"
for c in curl docker dotnet npm npx; do
  printf '#!/bin/sh\necho "%s" >> "%s"\nexit 99\n' "$c" "$MARK" > "$SHIMS/$c"; chmod +x "$SHIMS/$c"
done
run_build() { rm -f "$MARK"; PATH="$SHIMS:$PATH" bash scripts/build-extension.sh --validate-only "$1" 2>&1; }

mk "$(wrap "[$ACT]")"
t "--validate-only passes a valid manifest and prints naming OK"
OUT="$(run_build "$TMP/ext")"; RC=$?
if [ "$RC" != 0 ]; then bad "rc=$RC: $OUT"
elif [[ "$OUT" != *"naming OK"* ]]; then bad "no 'naming OK': $OUT"
elif [ -e "$MARK" ]; then bad "toolchain invoked: $(cat "$MARK")"
else ok; fi

mk "$(wrap "[$(act '{"placement":"side"}')]")"
t "--validate-only fails an invalid manifest with the ✗ line"
OUT="$(run_build "$TMP/ext")"; RC=$?
if [ "$RC" = 0 ] || [ "$RC" = 99 ]; then bad "rc=$RC: $OUT"
elif [[ "$OUT" != *"✗ frontend.headerActions"* ]]; then bad "no ✗ line: $OUT"
elif [ -e "$MARK" ]; then bad "toolchain invoked: $(cat "$MARK")"
else ok; fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
