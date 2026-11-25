#!/usr/bin/env bash
# Checks which bundle deploy-all.sh hands to deploy-extension.sh: the host-mode dist/extension.zip, or for a
# per-SDK-version build the dist/sdk-<v>/extension.zip whose sdkVersion equals the host's.
#
# Runs from a temp copy of the kit with a stub deploy-extension.sh that records its argument and a stub curl that
# answers the sdk-version endpoint, or fails under HOST_DOWN=1, so it never reaches a studio. Usage: ./tests/test-deploy-all.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
PASS=0; FAIL=0
t()   { printf '  %s … ' "$1"; }
ok()  { echo "ok"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
command -v python3 >/dev/null 2>&1 || { echo "skipped: needs python3"; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
KIT="$TMP/kit"
mkdir -p "$KIT/scripts" "$TMP/bin"
cp scripts/deploy-all.sh scripts/_target.sh "$KIT/scripts/"
printf 'DUPLO_ADMIN_TOKEN=fixture\n' > "$KIT/.env"
cat > "$KIT/scripts/deploy-extension.sh" <<'SH'
#!/usr/bin/env bash
echo "$1" >> "$DEPLOY_LOG"
SH
cat > "$TMP/bin/curl" <<'SH'
#!/usr/bin/env bash
[ "${HOST_DOWN:-}" = 1 ] && exit 7
case "$*" in *sdk-version*) printf '{"version":"%s"}' "${HOST_SDK:-1.0.6}" ;; esac
SH
chmod +x "$KIT/scripts/deploy-extension.sh" "$TMP/bin/curl"
export PATH="$TMP/bin:$PATH" DEPLOY_LOG="$TMP/deployed"

# bundle <dir> <sdkVersion> [subdir]: a zip whose manifest carries sdkVersion, at dist/[subdir/]extension.zip.
bundle() {
  mkdir -p "$KIT/$1/dist/${3:-}"
  python3 - "$KIT/$1/dist/${3:+$3/}extension.zip" "$2" <<'PY'
import json, sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.writestr("manifest.json", json.dumps({"id": "x.demo", "version": "1.0.0", "sdkVersion": sys.argv[2]}))
PY
}
reset() {
  rm -rf "$KIT/extensions" "$DEPLOY_LOG"; mkdir -p "$KIT/extensions/demo"
  echo '{"id":"x.demo"}' > "$KIT/extensions/demo/manifest.json"
}
run() { ( cd "$KIT" && ./scripts/deploy-all.sh ) 2>&1; }

echo "deploy-all:"

t "host mode: deploys dist/extension.zip without asking the host its SDK version"
reset; bundle extensions/demo 1.0.6
OUT="$(HOST_SDK='' run)"; RC=$?
if [ "$RC" = 0 ] && [ "$(cat "$DEPLOY_LOG")" = "extensions/demo/dist/extension.zip" ]; then ok; else bad "rc=$RC out=$OUT"; fi

t "per-version build: deploys the bundle whose sdkVersion equals the host's"
reset; bundle extensions/demo 1.0.6 sdk-1.0.6; bundle extensions/demo 1.0.7 sdk-1.0.7
OUT="$(HOST_SDK=1.0.7 run)"; RC=$?
if [ "$RC" = 0 ] && [ "$(cat "$DEPLOY_LOG")" = "extensions/demo/dist/sdk-1.0.7/extension.zip" ]; then ok
else bad "rc=$RC out=$OUT"; fi

t "per-version build: fails naming the host SDK when no bundle matches it"
reset; bundle extensions/demo 1.0.6 sdk-1.0.6
OUT="$(HOST_SDK=1.0.8 run)"; RC=$?
if [ "$RC" != 0 ] && grep -q "no bundle for the host's SDK 1.0.8" <<<"$OUT" && [ ! -f "$DEPLOY_LOG" ]; then ok
else bad "rc=$RC out=$OUT"; fi

t "per-version build: an unreadable host SDK version fails with that error alone"
reset; bundle extensions/demo 1.0.6 sdk-1.0.6
OUT="$(HOST_DOWN=1 run)"; RC=$?
if [ "$RC" != 0 ] && grep -q "could not read the host SDK version" <<<"$OUT" && ! grep -q "no bundle for the host's SDK" <<<"$OUT" \
  && [ ! -f "$DEPLOY_LOG" ]; then ok
else bad "rc=$RC out=$OUT"; fi

t "fails when nothing is built"
reset
OUT="$(run)"; RC=$?
if [ "$RC" != 0 ] && grep -q "No built bundles" <<<"$OUT"; then ok; else bad "rc=$RC out=$OUT"; fi

echo; echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
