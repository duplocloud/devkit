#!/usr/bin/env bash
# Tests for scripts/release-extensions.sh — the release job's publish step.
# Runs in a throwaway git repo with a stub `gh` on PATH; never touches GitHub. Usage: ./tests/test-release-extensions.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"

PASS=0; FAIL=0
t()   { printf '  %s … ' "$1"; }
ok()  { echo "ok"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Stub gh: every call is appended to $GH_LOG. `api` answers the release's immutable flag from $GH_IMMUTABLE.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$1" in
  api) printf '%s\n' "${GH_IMMUTABLE:-true}" ;;
  release) [ "$2" = create ] && exit "${GH_CREATE_RC:-0}" ;;
esac
exit 0
EOF
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

# new_repo: a git repo holding extensions/demo at version 0.1.0, committed.
new_repo() {
  REPO="$TMP/repo.$RANDOM"; mkdir -p "$REPO/extensions/demo"
  git -C "$REPO" init -q -b main
  git -C "$REPO" config user.email t@example.com; git -C "$REPO" config user.name t
  printf '{"id":"duplo.demo","name":"Demo","version":"%s"}\n' "${1:-0.1.0}" > "$REPO/extensions/demo/manifest.json"
  echo one > "$REPO/extensions/demo/code.txt"
  git -C "$REPO" add -A; git -C "$REPO" commit -qm init
  export GH_LOG="$REPO.gh.log"; : > "$GH_LOG"
}

# build_zip [sdkVersion]: the dist/extension.zip build-extension.sh would leave, with sdkVersion stamped.
# An empty argument leaves sdkVersion out of the bundle manifest.
build_zip() {
  local d="$REPO/extensions/demo" pkg; pkg="$(mktemp -d)"
  if [ -n "${1-}" ]; then jq --arg v "$1" '.sdkVersion = $v' "$d/manifest.json" > "$pkg/manifest.json"
  else cp "$d/manifest.json" "$pkg/manifest.json"; fi
  mkdir -p "$d/dist"; rm -f "$d/dist/extension.zip"
  ( cd "$pkg" && zip -qr "$d/dist/extension.zip" . ); rm -rf "$pkg"
}

commit_change() { echo "$1" > "$REPO/extensions/demo/code.txt"; git -C "$REPO" commit -qam "$1"; }

# The script resolves the repo from its own path, as it does when devkit copies it into an extension repo.
run() {
  mkdir -p "$REPO/scripts"; cp "$ROOT/scripts/release-extensions.sh" "$REPO/scripts/" 2>/dev/null
  GITHUB_SHA="$(git -C "$REPO" rev-parse HEAD)" "$REPO/scripts/release-extensions.sh" 2>&1
}

echo "release-extensions:"

t "publishes a new version under [slug]-v[version]-sdk-[sdkVersion], targeted at the built commit"
new_repo; build_zip 1.0.6; SHA="$(git -C "$REPO" rev-parse HEAD)"
OUT="$(run)"; RC=$?
if [ "$RC" = 0 ] && grep -q -- "release create demo-v0.1.0-sdk-1.0.6 extensions/demo/dist/extension.zip --target $SHA" "$GH_LOG"
then ok; else bad "rc=$RC log=$(cat "$GH_LOG") out=$OUT"; fi

t "skips when the -sdk tag exists and the extension is unchanged since it"
new_repo; build_zip 1.0.6; git -C "$REPO" tag demo-v0.1.0-sdk-1.0.6
OUT="$(run)"; RC=$?
if [ "$RC" = 0 ] && ! grep -q "release create" "$GH_LOG" && grep -q "already released" <<<"$OUT"
then ok; else bad "rc=$RC log=$(cat "$GH_LOG") out=$OUT"; fi

t "fails, naming the version bump, when the extension changed since that version's -sdk release"
new_repo; git -C "$REPO" tag demo-v0.1.0-sdk-1.0.6; commit_change two; build_zip 1.0.6
OUT="$(run)"; RC=$?
if [ "$RC" != 0 ] && ! grep -q "release create" "$GH_LOG" && grep -q "manifest.version" <<<"$OUT"
then ok; else bad "rc=$RC log=$(cat "$GH_LOG") out=$OUT"; fi

t "fails when the extension changed since that version's legacy (no -sdk) release"
new_repo; git -C "$REPO" tag demo-v0.1.0; commit_change two; build_zip 1.0.6
OUT="$(run)"; RC=$?
if [ "$RC" != 0 ] && ! grep -q "release create" "$GH_LOG" && grep -q "demo-v0.1.0 " <<<"$OUT"
then ok; else bad "rc=$RC log=$(cat "$GH_LOG") out=$OUT"; fi

t "publishes the -sdk build of an unchanged version that has only a legacy release"
new_repo; git -C "$REPO" tag demo-v0.1.0; build_zip 1.0.6
OUT="$(run)"; RC=$?
if [ "$RC" = 0 ] && grep -q "release create demo-v0.1.0-sdk-1.0.6" "$GH_LOG"; then ok; else bad "rc=$RC log=$(cat "$GH_LOG") out=$OUT"; fi

t "publishes a build for a new SDK of an unchanged version"
new_repo; git -C "$REPO" tag demo-v0.1.0-sdk-1.0.6; build_zip 1.0.7
OUT="$(run)"; RC=$?
if [ "$RC" = 0 ] && grep -q "release create demo-v0.1.0-sdk-1.0.7" "$GH_LOG"; then ok; else bad "rc=$RC log=$(cat "$GH_LOG") out=$OUT"; fi

t "fails when the bundle manifest carries no sdkVersion"
new_repo; build_zip ""
OUT="$(run)"; RC=$?
if [ "$RC" != 0 ] && ! grep -q "release create" "$GH_LOG" && grep -q "sdkVersion" <<<"$OUT"
then ok; else bad "rc=$RC log=$(cat "$GH_LOG") out=$OUT"; fi

t "warns when the published release landed mutable"
new_repo; build_zip 1.0.6
OUT="$(GH_IMMUTABLE=false run)"; RC=$?
if [ "$RC" = 0 ] && grep -q "::warning::.*immutable" <<<"$OUT"; then ok; else bad "rc=$RC out=$OUT"; fi

t "does not warn when the published release is immutable"
new_repo; build_zip 1.0.6
OUT="$(GH_IMMUTABLE=true run)"; RC=$?
if [ "$RC" = 0 ] && ! grep -q "::warning::" <<<"$OUT"; then ok; else bad "rc=$RC out=$OUT"; fi

t "fails when gh release create fails"
new_repo; build_zip 1.0.6
OUT="$(GH_CREATE_RC=1 run)"; RC=$?
if [ "$RC" != 0 ] && grep -q "release create demo-v0.1.0-sdk-1.0.6" "$GH_LOG"; then ok; else bad "rc=$RC out=$OUT"; fi

t "still publishes the other extensions when one fails"
new_repo; git -C "$REPO" tag demo-v0.1.0-sdk-1.0.6; commit_change two; build_zip 1.0.6
mkdir -p "$REPO/extensions/other/dist"
printf '{"id":"duplo.other","name":"Other","version":"0.2.0"}\n' > "$REPO/extensions/other/manifest.json"
git -C "$REPO" add extensions/other/manifest.json; git -C "$REPO" commit -qm other
( p="$(mktemp -d)"; jq '.sdkVersion="1.0.6"' "$REPO/extensions/other/manifest.json" > "$p/manifest.json"
  cd "$p" && zip -qr "$REPO/extensions/other/dist/extension.zip" . )
OUT="$(run)"; RC=$?
if [ "$RC" != 0 ] && grep -q "release create other-v0.2.0-sdk-1.0.6" "$GH_LOG"; then ok; else bad "rc=$RC log=$(cat "$GH_LOG") out=$OUT"; fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
