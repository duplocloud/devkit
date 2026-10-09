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

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
