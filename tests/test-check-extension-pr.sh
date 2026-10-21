#!/usr/bin/env bash
# Tests for scripts/check-extension-pr.sh — the PR-time warnings about what a release will need.
# Runs in a throwaway git repo; never touches GitHub. Usage: ./tests/test-check-extension-pr.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"

PASS=0; FAIL=0
t()   { printf '  %s … ' "$1"; }
ok()  { echo "ok"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# new_repo: extensions/demo at 0.1.0 declaring skill `provision-demo`, committed on main, then a `pr` branch.
new_repo() {
  REPO="$TMP/repo.$RANDOM"; D="$REPO/extensions/demo"; mkdir -p "$D/skills/provision-demo"
  git -C "$REPO" init -q -b main
  git -C "$REPO" config user.email t@example.com; git -C "$REPO" config user.name t
  set_manifest 0.1.0 '["duplo.demo/0.1.0/skills/provision-demo"]'
  echo skill > "$D/skills/provision-demo/SKILL.md"; echo one > "$D/code.txt"
  git -C "$REPO" add -A; git -C "$REPO" commit -qm init
  git -C "$REPO" switch -q -c pr
}

# set_manifest <version> <json array of skill folders>: also declares a resources entry, so only the test that
# removes it sees the no-resource warning.
set_manifest() {
  jq -n --arg v "$1" --argjson f "$2" \
    '{id:"duplo.demo",name:"Demo",version:$v,skills:[$f[]|{folder:.,isBuiltIn:true}],resources:[{subType:"demo"}]}' \
    > "$D/manifest.json"
}

change() { echo "$1" > "$D/code.txt"; git -C "$REPO" commit -qam "$1"; }

# bundle <fe entry file>: the dist/extension.zip a build leaves, with its frontend entry under fe/.
bundle() {
  local p; p="$(mktemp -d)"; mkdir -p "$p/fe"; cp "$D/manifest.json" "$p/"; echo x > "$p/fe/$1"
  mkdir -p "$D/dist"; rm -f "$D/dist/extension.zip"; ( cd "$p" && zip -qr "$D/dist/extension.zip" . ); rm -rf "$p"
}

# The script resolves the repo from its own path, as it does when devkit copies it into an extension repo, so its
# sourced helpers (_publishers.sh, _publish.sh) have to travel with it.
run() {
  mkdir -p "$REPO/scripts"; cp "$ROOT/scripts/check-extension-pr.sh" "$REPO/scripts/" 2>/dev/null
  cp "$ROOT"/scripts/_*.sh "$REPO/scripts/" 2>/dev/null
  "$REPO/scripts/check-extension-pr.sh" main 2>&1
}

echo "check-extension-pr:"

t "warns when a released extension changed with no manifest.version bump"
new_repo; git -C "$REPO" tag demo-v0.1.0-sdk-1.0.6 main; change two
OUT="$(run)"; RC=$?
if [ "$RC" = 0 ] && grep -q "::warning.*extensions/demo.*manifest.version" <<<"$OUT"; then ok; else bad "rc=$RC out=$OUT"; fi

t "is quiet about an unbumped version that has no release yet"
new_repo; change two
OUT="$(run)"; RC=$?
if [ "$RC" = 0 ] && ! grep -q "manifest.version" <<<"$OUT"; then ok; else bad "rc=$RC out=$OUT"; fi

t "is quiet about the version when it was bumped"
new_repo; set_manifest 0.1.1 '["duplo.demo/0.1.1/skills/provision-demo"]'; change two
OUT="$(run)"; RC=$?
if [ "$RC" = 0 ] && ! grep -q "::warning" <<<"$OUT"; then ok; else bad "rc=$RC out=$OUT"; fi

t "is quiet about an extension the PR does not touch"
new_repo; echo readme > "$REPO/README.md"; git -C "$REPO" add -A; git -C "$REPO" commit -qm readme
OUT="$(run)"; RC=$?
if [ "$RC" = 0 ] && ! grep -q "::warning" <<<"$OUT"; then ok; else bad "rc=$RC out=$OUT"; fi

t "is quiet about the version of an extension new in this PR"
new_repo; git -C "$REPO" switch -q main; git -C "$REPO" rm -rq extensions; git -C "$REPO" commit -qm empty
git -C "$REPO" switch -q -c pr2; git -C "$REPO" checkout -q pr -- extensions; git -C "$REPO" commit -qm add
OUT="$(run)"; RC=$?
if [ "$RC" = 0 ] && ! grep -q "::warning" <<<"$OUT"; then ok; else bad "rc=$RC out=$OUT"; fi

t "warns about a shipped skill the manifest does not declare"
new_repo; set_manifest 0.1.1 '["duplo.demo/0.1.1/skills/provision-demo"]'
mkdir -p "$D/skills/undeclared"; echo s > "$D/skills/undeclared/SKILL.md"; git -C "$REPO" add -A; git -C "$REPO" commit -qm skill
OUT="$(run)"; RC=$?
if [ "$RC" = 0 ] && grep -q "::warning.*skills/undeclared" <<<"$OUT" && ! grep -q "provision-demo" <<<"$OUT"
then ok; else bad "rc=$RC out=$OUT"; fi

t "warns about a webpack frontend (fe/remoteEntry.js) in the built bundle"
new_repo; set_manifest 0.1.1 '["duplo.demo/0.1.1/skills/provision-demo"]'; change two; bundle remoteEntry.js
OUT="$(run)"; RC=$?
if [ "$RC" = 0 ] && grep -q "::warning.*remoteEntry.js" <<<"$OUT"; then ok; else bad "rc=$RC out=$OUT"; fi

t "is quiet about a Native Federation frontend (fe/remoteEntry.json)"
new_repo; set_manifest 0.1.1 '["duplo.demo/0.1.1/skills/provision-demo"]'; change two; bundle remoteEntry.json
OUT="$(run)"; RC=$?
if [ "$RC" = 0 ] && ! grep -q "::warning" <<<"$OUT"; then ok; else bad "rc=$RC out=$OUT"; fi

t "warns about an id outside the publisher allowlist in a Duplo org"
new_repo; set_manifest 0.1.1 '["duplo.demo/0.1.1/skills/provision-demo"]'; change two
jq -n '{schemaVersion:1, publishers:[]}' > "$REPO/pub.json"
OUT="$(PUBLISHERS_FILE="$REPO/pub.json" GITHUB_REPOSITORY=duplocloud/demo GITHUB_REPOSITORY_OWNER=duplocloud run)"; RC=$?
if [ "$RC" = 0 ] && grep -q "::warning.*allowlist" <<<"$OUT"; then ok; else bad "rc=$RC out=$OUT"; fi

t "warns about a manifest that declares no resource"
new_repo; jq '.version="0.1.1" | .skills=[{folder:"duplo.demo/0.1.1/skills/provision-demo",isBuiltIn:true}] | del(.resources)' \
  "$D/manifest.json" > "$D/m" && mv "$D/m" "$D/manifest.json"; change two
OUT="$(run)"; RC=$?
if [ "$RC" = 0 ] && grep -q "::warning.*resource" <<<"$OUT"; then ok; else bad "rc=$RC out=$OUT"; fi

t "warns about a bundle over 268435456 bytes"
new_repo; set_manifest 0.1.1 '["duplo.demo/0.1.1/skills/provision-demo"]'; change two; bundle remoteEntry.json
truncate -s 268435457 "$D/dist/extension.zip"
OUT="$(run)"; RC=$?
if [ "$RC" = 0 ] && grep -q "::warning.*268435456" <<<"$OUT"; then ok; else bad "rc=$RC out=$OUT"; fi

t "warns about a version that cannot form a bucket key"
new_repo; set_manifest '0.1.1 beta' '["duplo.demo/0.1.1 beta/skills/provision-demo"]'; change two
OUT="$(run)"; RC=$?
if [ "$RC" = 0 ] && grep -q "::warning.*cannot form" <<<"$OUT"; then ok; else bad "rc=$RC out=$OUT"; fi

t "warns about a non-semver version in a Duplo org"
new_repo; set_manifest 'v1.0.0' '["duplo.demo/v1.0.0/skills/provision-demo"]'; change two
OUT="$(GITHUB_REPOSITORY_OWNER=duplocloud run)"; RC=$?
if [ "$RC" = 0 ] && grep -q "::warning.*not strict semver" <<<"$OUT"; then ok; else bad "rc=$RC out=$OUT"; fi

# frontend_lib <dependency spec>: the extension's frontend depends on ng-common-lib at that spec.
frontend_lib() {
  mkdir -p "$D/frontend"
  jq -n --arg v "$1" '{dependencies:{"@duplocloud-internal/ng-common-lib":$v}}' > "$D/frontend/package.json"
  git -C "$REPO" add -A; git -C "$REPO" commit -qm lib
}

t "warns about an ng-common-lib older than 0.5.1, naming the theme migration skill"
new_repo; set_manifest 0.1.1 '["duplo.demo/0.1.1/skills/provision-demo"]'
frontend_lib 'file:vendor/duplocloud-internal-ng-common-lib-0.4.0.tgz'
OUT="$(run)"; RC=$?
if [ "$RC" = 0 ] && grep -q "::warning.*0.4.0.*duplo-extension-theme-migration" <<<"$OUT"; then ok; else bad "rc=$RC out=$OUT"; fi

t "warns about ng-common-lib 0.5.0 for its missing token defaults, not as light-only"
new_repo; set_manifest 0.1.1 '["duplo.demo/0.1.1/skills/provision-demo"]'
frontend_lib 'file:vendor/duplocloud-internal-ng-common-lib-0.5.0.tgz'
OUT="$(run)"; RC=$?
if [ "$RC" = 0 ] && grep -q "::warning.*0.5.0.*defaults" <<<"$OUT" && ! grep -q "stays light" <<<"$OUT"; then ok; else bad "rc=$RC out=$OUT"; fi

t "is quiet about ng-common-lib 0.5.1 and later"
new_repo; set_manifest 0.1.1 '["duplo.demo/0.1.1/skills/provision-demo"]'
frontend_lib 'file:vendor/duplocloud-internal-ng-common-lib-0.5.1.tgz'
OUT1="$(run)"; frontend_lib '^0.10.0'; OUT2="$(run)"; RC=$?
if [ "$RC" = 0 ] && ! grep -q "::warning" <<<"$OUT1$OUT2"; then ok; else bad "rc=$RC out=$OUT1$OUT2"; fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
