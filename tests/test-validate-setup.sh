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

t "scope 'Admin' (wrong case) is rejected"
expect_fail '{"frontend":{"setup":{"relativeUrl":"extensions/foo/setup"},"routes":[{"path":"extensions/foo/setup","scope":"Admin"}]}}' 'must match an admin-scoped route'

t "relativeUrl with surrounding spaces is rejected"
expect_fail '{"frontend":{"setup":{"relativeUrl":" extensions/foo/setup "},'"$ROUTES"'}}' 'must start with extensions/'

t "a non-object routes entry beside a valid admin route is accepted, no jq noise"
run '{"frontend":{"setup":{"relativeUrl":"extensions/foo/setup"},"routes":["x",null,{"path":"extensions/foo/setup","scope":"admin"}]}}'
[ "$RC" -eq 0 ] && [ -z "$ERR" ] && ok || bad "exit $RC: $ERR"

t "routes given as an object is rejected, no jq noise"
expect_fail '{"frontend":{"setup":{"relativeUrl":"extensions/foo/setup"},"routes":{"k":{"path":"extensions/foo/setup","scope":"admin"}}}}' 'must match an admin-scoped route'

t "routes given as an object prints no jq noise"
case "$ERR" in *jq:*) bad "jq noise: $ERR" ;; *) ok ;; esac

t "frontend that is not an object is OK with no stderr"
run '{"frontend":"x"}'; [ "$RC" -eq 0 ] && [ -z "$ERR" ] && ok || bad "exit $RC: $ERR"

t "top-level manifest that is not an object is OK with no stderr"
run '[]'; [ "$RC" -eq 0 ] && [ -z "$ERR" ] && ok || bad "exit $RC: $ERR"

echo "frontend SETUP_PATH parity:"
SETUP_OK='{"frontend":{"setup":{"relativeUrl":"extensions/foo/setup"},'"$ROUTES"'}}'
mkdir -p "$TMP/frontend/src/app"
R="$TMP/frontend/src/app/extension.routes.ts"

t "SETUP_PATH equal to relativeUrl is OK"
printf "export const SETUP_PATH = 'extensions/foo/setup';\n" > "$R"
run "$SETUP_OK"; [ "$RC" -eq 0 ] && [ -z "$ERR" ] && ok || bad "exit $RC: $ERR"

t "double-quoted SETUP_PATH is OK"
printf 'export const SETUP_PATH = "extensions/foo/setup";\n' > "$R"
run "$SETUP_OK"; [ "$RC" -eq 0 ] && [ -z "$ERR" ] && ok || bad "exit $RC: $ERR"

t "SETUP_PATH different from relativeUrl fails and names the found value"
printf "export const SETUP_PATH = 'extensions/helloworld-setup';\n" > "$R"
expect_fail "$SETUP_OK" "found: extensions/helloworld-setup"

t "no SETUP_PATH in frontend/src fails"
printf "export const Extension = [];\n" > "$R"
expect_fail "$SETUP_OK" "frontend/src has no SETUP_PATH = 'extensions/foo/setup'"

t "a regex-like relativeUrl is compared literally"
printf "export const SETUP_PATH = 'extensions/fooXsetup';\n" > "$R"
expect_fail '{"frontend":{"setup":{"relativeUrl":"extensions/foo.setup"},"routes":[{"path":"extensions/foo.setup","scope":"admin"}]}}' 'has no SETUP_PATH'

t "a stale comment or other-named constant does not satisfy the SETUP_PATH check"
printf "// const SETUP_PATH = 'extensions/foo/setup';\nconst OLD_SETUP_PATH = 'extensions/foo/setup';\nexport const SETUP_PATH = 'extensions/other';\n" > "$R"
expect_fail "$SETUP_OK" "found: extensions/other"

t "a SETUP_PATH in another file under frontend/src counts (e.g. setup-mount.ts)"
printf "export const SETUP_PATH = 'extensions/foo/setup';\n" > "$TMP/frontend/src/app/setup-mount.ts"
printf "export const Extension = [];\n" > "$R"
run "$SETUP_OK"; [ "$RC" -eq 0 ] && [ -z "$ERR" ] && ok || bad "exit $RC: $ERR"
rm -f "$TMP/frontend/src/app/setup-mount.ts"

t "no frontend.setup skips the frontend check"
run '{"frontend":{"routes":[]}}'; [ "$RC" -eq 0 ] && ok || bad "exit $RC: $ERR"
rm -rf "$TMP/frontend"

t "every problem is reported, one line each"
run '{"frontend":{"setup":{"relativeUrl":"clouds/x","title":7}}}'
N="$(printf '%s\n' "$ERR" | grep -c '✗')"
[ "$RC" -eq 1 ] && [ "$N" -eq 3 ] && ok || bad "exit $RC, $N lines: $ERR"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
