#!/usr/bin/env bash
# Checks scripts/validate-setup.sh: the frontend.setup rules the portal applies at runtime, enforced at build time.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
PASS=0; FAIL=0
t()   { printf '  %s … ' "$1"; }
ok()  { echo "ok"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
V=./scripts/validate-setup.sh

# run <json>: writes the manifest, sets RC and ERR from the validator.
run() { printf '%s' "$1" > "$TMP/manifest.json"; ERR="$("$V" "$TMP/manifest.json" 2>&1 >/dev/null)"; RC=$?; }
# expect_fail <json> <message fragment>
expect_fail() {
  run "$1"
  if [ "$RC" -ne 1 ]; then bad "exit $RC, want 1"
  else case "$ERR" in *"$2"*) ok ;; *) bad "stderr lacks '$2': $ERR" ;; esac; fi
}

ROUTES='"routes":[{"path":"extensions/foo/setup","scope":"admin"},{"path":"extensions/foo/ws"},{"path":"extensions/foo/ws2","scope":"workspace"}]'

echo "frontend.setup validation:"

t "no frontend.setup is OK"
run '{"frontend":{"routes":[]}}'; [ "$RC" -eq 0 ] && ok || bad "exit $RC: $ERR"

t "no frontend block at all is OK"
run '{}'; [ "$RC" -eq 0 ] && ok || bad "exit $RC: $ERR"

t "setup: null is OK"
run '{"frontend":{"setup":null}}'; [ "$RC" -eq 0 ] && ok || bad "exit $RC: $ERR"

t "valid setup matching an admin route is OK"
run '{"frontend":{"setup":{"relativeUrl":"extensions/foo/setup","title":"Set up Foo"},'"$ROUTES"'}}'
[ "$RC" -eq 0 ] && [ -z "$ERR" ] && ok || bad "exit $RC: $ERR"

t "valid setup without a title is OK"
run '{"frontend":{"setup":{"relativeUrl":"extensions/foo/setup"},'"$ROUTES"'}}'; [ "$RC" -eq 0 ] && ok || bad "exit $RC: $ERR"

t "blank title is OK"
run '{"frontend":{"setup":{"relativeUrl":"extensions/foo/setup","title":""},'"$ROUTES"'}}'; [ "$RC" -eq 0 ] && ok || bad "exit $RC: $ERR"

t "setup that is not an object fails"
expect_fail '{"frontend":{"setup":"extensions/foo/setup"}}' 'frontend.setup must be an object'

t "missing relativeUrl fails"
expect_fail '{"frontend":{"setup":{"title":"x"},'"$ROUTES"'}}' 'frontend.setup.relativeUrl is required'

t "empty relativeUrl fails"
expect_fail '{"frontend":{"setup":{"relativeUrl":""},'"$ROUTES"'}}' 'frontend.setup.relativeUrl is required'

t "non-string relativeUrl fails"
expect_fail '{"frontend":{"setup":{"relativeUrl":5},'"$ROUTES"'}}' 'frontend.setup.relativeUrl is required'

t "relativeUrl not under extensions/ fails"
expect_fail '{"frontend":{"setup":{"relativeUrl":"clouds/setup"},"routes":[{"path":"clouds/setup","scope":"admin"}]}}' \
  "frontend.setup.relativeUrl 'clouds/setup' must start with extensions/"

t "relativeUrl matching a route with no scope fails"
expect_fail '{"frontend":{"setup":{"relativeUrl":"extensions/foo/ws"},'"$ROUTES"'}}' 'must match an admin-scoped route'

t "relativeUrl matching a workspace-scoped route fails"
expect_fail '{"frontend":{"setup":{"relativeUrl":"extensions/foo/ws2"},'"$ROUTES"'}}' 'must match an admin-scoped route'

t "relativeUrl matching no route fails"
expect_fail '{"frontend":{"setup":{"relativeUrl":"extensions/foo/none"}}}' \
  "(add { \"path\": \"extensions/foo/none\", \"scope\": \"admin\" })"

t "non-string title fails"
expect_fail '{"frontend":{"setup":{"relativeUrl":"extensions/foo/setup","title":7},'"$ROUTES"'}}' 'frontend.setup.title must be a string'

t "every problem is reported, one line each"
run '{"frontend":{"setup":{"relativeUrl":"clouds/x","title":7}}}'
N="$(printf '%s\n' "$ERR" | grep -c '✗')"
[ "$RC" -eq 1 ] && [ "$N" -eq 3 ] && ok || bad "exit $RC, $N lines: $ERR"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
