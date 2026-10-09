#!/usr/bin/env bash
# Checks deploy-extension.sh's hand-off to the installer service, and the cases that still POST the zip.
#
# Runs the script from a temp copy of the kit with stub `docker` and `curl` first on PATH, so it never reaches a real
# runtime or studio. The stub `docker` reports an installer container while $STUB/up exists, and `cp` returns
# $STUB/status.json as the tar stream the real one writes.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
PASS=0; FAIL=0
t()   { printf '  %s … ' "$1"; }
ok()  { echo "ok"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

command -v python3 >/dev/null 2>&1 || { echo "skipped: needs python3"; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
KIT="$TMP/kit"; STUB="$TMP/stub"
mkdir -p "$KIT/scripts" "$KIT/extensions/demo/dist" "$TMP/bin" "$STUB"
cp scripts/deploy-extension.sh scripts/_target.sh scripts/_runtime.sh "$KIT/scripts/"
printf 'DUPLO_ADMIN_TOKEN=fixture\nRUNTIME=docker\n' > "$KIT/.env"

ZIP=extensions/demo/dist/extension.zip
python3 - "$KIT/$ZIP" <<'PY'
import json, sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.writestr("manifest.json", json.dumps({"id": "x.demo", "version": "1.0.0"}))
PY
cp "$KIT/$ZIP" "$KIT/outside.zip"
SHA="$(python3 -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$KIT/$ZIP")"

cat > "$TMP/bin/docker" <<'SH'
#!/usr/bin/env bash
case "$1" in
  ps) [ -f "$STUB/up" ] && echo stub-installer ;;
  cp) [ -f "$STUB/status.json" ] || exit 1
      python3 -c 'import sys, tarfile
with tarfile.open(fileobj=sys.stdout.buffer, mode="w|") as t:
    t.add(sys.argv[1], arcname="installer-status.json")' "$STUB/status.json" ;;
esac
SH
cat > "$TMP/bin/curl" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$STUB/curl.log"
case "$*" in *load-bundle*) printf 200 ;; esac
SH
chmod +x "$TMP/bin/docker" "$TMP/bin/curl"

# status OUTCOME [REASON] [APPLIED_SHA] [ENABLED] -> a status record holding one x.demo item at this zip's digest.
status() {
  python3 - "$STUB/status.json" "$SHA" "$@" <<'PY'
import json, sys
path, sha, outcome = sys.argv[1], sys.argv[2], sys.argv[3]
extra = sys.argv[4:]
reason, applied, enabled = extra + ["", "", "true"][len(extra):]
item = {"id": "x.demo", "declaredVersion": "1.0.0", "bundleSha256": sha if outcome != "other-digest" else "f" * 64,
        "outcome": "converged" if outcome == "other-digest" else outcome, "reason": reason, "detail": ""}
res = {"outcome": item["outcome"], "reason": "", "effective": {"enabled": enabled}, "items": [item]}
st = {"applied": [{"id": "x.demo", "version": "1.0.0", "bundleSha256": applied}] if applied else []}
json.dump({"extensions": json.dumps(res), "extensionsState": json.dumps(st)}, open(path, "w"))
PY
}

# run ZIP [VAR=value…] -> runs the copy with only the fixture .env and the stubs, leaving stdout+stderr in $OUT.
run() {
  local zip="$1"; shift
  : > "$STUB/curl.log"
  OUT="$(cd "$KIT" && env -u DUPLO_TARGET -u DUPLO_HOST -u DUPLO_TOKEN -u DUPLO_BASE -u DUPLO_ADMIN_TOKEN \
    -u DUPLO_ENV_FILE -u RUNTIME -u COMPOSE_PROJECT_NAME PATH="$TMP/bin:$PATH" STUB="$STUB" INSTALLER_WAIT_SECONDS=0 \
    "$@" ./scripts/deploy-extension.sh "$zip" 2>&1)"
  RC=$?
}
posted() { grep -q load-bundle "$STUB/curl.log"; }

echo "deploy-extension.sh installer hand-off:"

touch "$STUB/up"

t "a build the installer reports converged exits 0 without a POST"
status converged; run "$ZIP"
if [ "$RC" = 0 ] && grep -q 'Installed x.demo v1.0.0' <<<"$OUT" && ! posted; then ok; else bad "rc=$RC: $OUT"; fi

t "a build already installed from this digest exits 0"
status already "" "$SHA"; run "$ZIP"
if [ "$RC" = 0 ] && ! posted; then ok; else bad "rc=$RC: $OUT"; fi

t "a same-version rebuild over a load the installer did not make fails naming the bump"
status already; run "$ZIP"
if [ "$RC" = 1 ] && grep -q 'Bump manifest.version' <<<"$OUT" && ! posted; then ok; else bad "rc=$RC: $OUT"; fi

t "a held build fails with the installer's reason"
status skipped held-after-failure; run "$ZIP"
if [ "$RC" = 1 ] && grep -q 'skipped: held-after-failure' <<<"$OUT" && ! posted; then ok; else bad "rc=$RC: $OUT"; fi

t "a build the installer never reports times out pointing at the troubleshooting entry"
status other-digest; run "$ZIP"
if [ "$RC" = 1 ] && grep -q 'has not reported this build' <<<"$OUT" && grep -q 'docs/troubleshooting.md' <<<"$OUT" \
    && ! posted; then ok; else bad "rc=$RC: $OUT"; fi

echo
echo "deploy-extension.sh posts the zip itself:"

t "with EXTENSIONS_ENABLED=false"
status converged "" "" false; run "$ZIP"
if [ "$RC" = 0 ] && posted; then ok; else bad "rc=$RC: $OUT"; fi

t "for an id in EXTENSIONS_EXCLUDE"
status skipped excluded-by-customer-file; run "$ZIP"
if [ "$RC" = 0 ] && posted; then ok; else bad "rc=$RC: $OUT"; fi

t "for a build the installer does not take as an install request"
status skipped install-not-requested; run "$ZIP"
if [ "$RC" = 0 ] && posted; then ok; else bad "rc=$RC: $OUT"; fi

t "for a zip outside extensions/"
status converged; run outside.zip
if [ "$RC" = 0 ] && posted; then ok; else bad "rc=$RC: $OUT"; fi

t "on a remote target"
run "$ZIP" DUPLO_TARGET=remote DUPLO_HOST=https://remote.example DUPLO_TOKEN=fixture
if [ "$RC" = 0 ] && grep -q 'https://remote.example/v1/aiservicedesk/admin/extensions/load-bundle' "$STUB/curl.log"
then ok; else bad "rc=$RC: $OUT"; fi

rm -f "$STUB/up"
t "with no installer container running"
run "$ZIP"
if [ "$RC" = 0 ] && posted; then ok; else bad "rc=$RC: $OUT"; fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
