#!/usr/bin/env bash
# Tests for scripts/_extension_id.sh — the manifest `id` format gate in build-extension.sh. The id becomes the
# analytics event namespace, so it must be lowercase reverse-DNS with at least 3 segments.
# No docker/runtime needed. Usage: ./tests/test-build-extension-id.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
PASS=0; FAIL=0
t()   { printf '  %s … ' "$1"; }
ok()  { echo "ok"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# shellcheck source=scripts/_extension_id.sh
source scripts/_extension_id.sh 2>/dev/null || { echo "FAIL: cannot source scripts/_extension_id.sh"; exit 1; }

echo "extension id format:"
for id in duplo.examples.helloworld com.duplocloud.eks-installer com.acme.a1; do
  t "accepts '$id'"; extension_id_valid "$id" && ok || bad "rejected"
done
for id in duplo.helloworld Com.acme.x com.acme.eks_installer com..acme "" com.acme. .com.acme.x; do
  t "rejects '$id'"; extension_id_valid "$id" && bad "accepted" || ok
done

t "error message names the id, pattern and example"
msg=$(extension_id_error "Bad_Id")
if [[ "$msg" == *"'Bad_Id'"* && "$msg" == *"com.acme.my-extension"* && "$msg" == *"$EXTENSION_ID_REGEX"* ]]; then ok; else bad "got: $msg"; fi

t "all samples/*/manifest.json ids pass"
sbad=0
for m in samples/*/manifest.json; do
  id=$(jq -r '.id // empty' "$m"); extension_id_valid "$id" || { sbad=1; echo -n "[$m: $id] "; }
done
[ "$sbad" = 0 ] && ok || bad "sample id invalid"

t "build-extension.sh uses the helper (single regex source)"
grep -q 'extension_id_valid' scripts/build-extension.sh && ! grep -q 'a-z0-9-\]+)' scripts/build-extension.sh && ok || bad "not wired"

echo "frontend EXTENSION_ID parity:"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/match" "$tmp/stale" "$tmp/none"
echo "export const EXTENSION_ID = 'com.acme.my-ext';" > "$tmp/match/analytics.ts"
echo "export const EXTENSION_ID = 'duplo.examples.helloworld';" > "$tmp/stale/analytics.ts"
echo "export const X = 1;" > "$tmp/none/a.ts"
mkdir -p "$tmp/dq" "$tmp/ty" "$tmp/bt" "$tmp/dqm" "$tmp/tym" "$tmp/btm"
echo 'export const EXTENSION_ID = "duplo.examples.helloworld";' > "$tmp/dq/a.ts"
echo "export const EXTENSION_ID: string = 'duplo.examples.helloworld';" > "$tmp/ty/a.ts"
echo 'export const EXTENSION_ID = `duplo.examples.helloworld`;' > "$tmp/bt/a.ts"
echo 'export const EXTENSION_ID = "com.acme.my-ext";' > "$tmp/dqm/a.ts"
echo "export const EXTENSION_ID: string = 'com.acme.my-ext';" > "$tmp/tym/a.ts"
echo 'export const EXTENSION_ID = `com.acme.my-ext`;' > "$tmp/btm/a.ts"
for f in dq ty bt; do
  t "$f form mismatch fails"; [ "$(extension_id_fe_mismatches "$tmp/$f" com.acme.my-ext)" = "duplo.examples.helloworld" ] && ok || bad "not flagged"
done
for f in dqm tym btm; do
  t "$f form match passes"; [ -z "$(extension_id_fe_mismatches "$tmp/$f" com.acme.my-ext)" ] && ok || bad "flagged"
done
t "matching EXTENSION_ID passes"; [ -z "$(extension_id_fe_mismatches "$tmp/match" com.acme.my-ext)" ] && ok || bad "flagged"
t "stale EXTENSION_ID fails"; [ "$(extension_id_fe_mismatches "$tmp/stale" com.acme.my-ext)" = "duplo.examples.helloworld" ] && ok || bad "not flagged"
t "no EXTENSION_ID declaration passes"; [ -z "$(extension_id_fe_mismatches "$tmp/none" com.acme.my-ext)" ] && ok || bad "flagged"
t "missing dir passes"; [ -z "$(extension_id_fe_mismatches "$tmp/nope" com.acme.my-ext)" ] && ok || bad "flagged"
t "template analytics.ts matches template manifest id"
[ -z "$(extension_id_fe_mismatches .claude/skills/duplo-extension-dev/templates/helloworld/frontend/src "$(jq -r .id .claude/skills/duplo-extension-dev/templates/helloworld/manifest.json)")" ] && ok || bad "drift"
t "build-extension.sh wires the parity check"
grep -q 'extension_id_fe_mismatches' scripts/build-extension.sh && ok || bad "not wired"

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
