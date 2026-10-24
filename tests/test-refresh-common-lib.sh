#!/usr/bin/env bash
# Tests for scripts/refresh-common-lib.sh. Runs in a throwaway copy; never touches this repo.
# Usage: ./tests/test-refresh-common-lib.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"

PASS=0; FAIL=0
t()   { printf '  %s … ' "$1"; }
ok()  { echo "ok"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
LIB=duplocloud-internal-ng-common-lib
OLD="$LIB-0.4.0.tgz"; NEW="$LIB-0.5.1.tgz"

# new_repo: a sample on packages/ and an extension scaffolded from the template, with its own vendor/, both on 0.4.0.
new_repo() {
  REPO="$TMP/repo.$RANDOM"; mkdir -p "$REPO/scripts" "$REPO/packages" "$REPO/samples/s/frontend" "$REPO/extensions/foo/frontend/vendor"
  cp "$ROOT/scripts/refresh-common-lib.sh" "$REPO/scripts/"
  echo old > "$REPO/packages/$OLD"; echo old > "$REPO/extensions/foo/frontend/vendor/$OLD"
  printf '{"dependencies":{"@duplocloud-internal/ng-common-lib":"file:../../../packages/%s"}}\n' "$OLD" > "$REPO/samples/s/frontend/package.json"
  printf '{"dependencies":{"@duplocloud-internal/ng-common-lib":"file:vendor/%s"}}\n' "$OLD" > "$REPO/extensions/foo/frontend/package.json"
  echo new > "$TMP/$NEW"
}

echo "refresh-common-lib:"

t "puts the new tarball where each rewritten package.json points, and removes the old one"
new_repo; OUT="$("$REPO/scripts/refresh-common-lib.sh" "$TMP/$NEW" 2>&1)"; RC=$?
V="$REPO/extensions/foo/frontend/vendor"
if [ "$RC" = 0 ] && [ -f "$V/$NEW" ] && [ ! -f "$V/$OLD" ] && grep -q "vendor/$NEW" "$REPO/extensions/foo/frontend/package.json" \
  && [ -f "$REPO/packages/$NEW" ] && [ ! -f "$REPO/packages/$OLD" ]; then ok; else bad "rc=$RC out=$OUT vendor=$(ls "$V")"; fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
