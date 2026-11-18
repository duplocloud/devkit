#!/usr/bin/env bash
# Tests for scripts/_naming.sh — the extension naming gate build-extension.sh runs before building, including the
# naming.legacy opt-out. Usage: ./tests/test-naming-gate.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=../scripts/_naming.sh
source scripts/_naming.sh

PASS=0; FAIL=0
t()   { printf '  %s … ' "$1"; }
ok()  { echo "ok"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# new_ext <naming json or null> <restSegment> <route path> <collection>: an extension dir with a manifest and
# one backend file carrying the collection name.
new_ext() {
  D="$TMP/extensions/ext.$RANDOM"; mkdir -p "$D/backend"
  jq -n --argjson naming "$1" --arg seg "$2" --arg path "$3" \
    '{id:"duplo.demo",version:"1.0.0",resources:[{restSegment:$seg}],frontend:{routes:[{path:$path}]}}
     + (if $naming == null then {} else {naming:$naming} end)' > "$D/manifest.json"
  printf '[BsonCollection("%s")]\npublic class Thing {}\n' "$4" > "$D/backend/Thing.cs"
}
run() { OUT="$(naming_gate "$D" "$D/manifest.json" 2>&1)"; RC=$?; }

t "a compliant extension passes"
new_ext null extensions/things extensions/things extension_things; run
if [ "$RC" = 0 ]; then ok; else bad "rc=$RC out=$OUT"; fi

t "non-namespaced names fail without the opt-out"
new_ext null Networks clouds/network-baselines networks; run
if [ "$RC" = 1 ] && grep -q "restSegment 'Networks' must start with 'extensions/'" <<<"$OUT" \
   && grep -q "frontend.routes\[\].path 'clouds/network-baselines'" <<<"$OUT" \
   && grep -q "BsonCollection(\"networks\")\] must be prefixed 'extension_'" <<<"$OUT"; then ok; else bad "rc=$RC out=$OUT"; fi

t "naming.legacy with a reason skips the namespacing rules and prints the reason"
new_ext '{"legacy":true,"reason":"Live customer data predates extension naming"}' Networks clouds/network-baselines networks; run
if [ "$RC" = 0 ] && grep -q "naming.legacy: Live customer data predates extension naming" <<<"$OUT" \
   && ! grep -q "✗" <<<"$OUT"; then ok; else bad "rc=$RC out=$OUT"; fi

t "naming.legacy with an empty reason fails"
new_ext '{"legacy":true,"reason":"   "}' Networks clouds/network-baselines networks; run
if [ "$RC" = 1 ] && grep -q "naming.reason is empty" <<<"$OUT"; then ok; else bad "rc=$RC out=$OUT"; fi

t "naming.legacy still rejects the deprecated frontend.menu key"
new_ext '{"legacy":true,"reason":"keeps built-in URLs"}' Networks clouds/network-baselines networks
jq '.frontend.menu = {title:"x"}' "$D/manifest.json" > "$D/m.json" && mv "$D/m.json" "$D/manifest.json"; run
if [ "$RC" = 1 ] && grep -q "legacy 'frontend.menu' is deprecated" <<<"$OUT"; then ok; else bad "rc=$RC out=$OUT"; fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
