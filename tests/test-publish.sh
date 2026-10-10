#!/usr/bin/env bash
# Tests for publish_build in scripts/_publish.sh. Usage: ./tests/test-publish.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
PASS=0; FAIL=0
t()   { printf '  %s … ' "$1"; }
ok()  { echo "ok"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/s3" "$TMP/assets"; export PATH="$TMP/bin:$PATH" LOG="$TMP/log"
printf 'ZIPBYTES' > "$TMP/assets/extension.zip"; printf 'SIGBYTES' > "$TMP/assets/extension.zip.sig"
ZSHA=$(shasum -a 256 "$TMP/assets/extension.zip" | cut -d' ' -f1)

# shellcheck source=tests/_publish_stubs.sh
. "$(dirname "$0")/_publish_stubs.sh"
export S3="$TMP/s3" ASSETS="$TMP/assets" ZSHA CONSOLE="$TMP/console" CONSOLE_API_KEY=secret-key uuid=ext-1
. ./scripts/_publish.sh
fresh() { rm -rf "$S3"/* "$CONSOLE"; mkdir -p "$CONSOLE"; : > "$LOG"; }

echo "publish:"

t "uploads both objects create-only and registers version and artifact with the signature"
fresh; OUT=$(publish_build demo-v1.0.0-sdk-1.0.6 duplo.demo 1.0.0 1.0.6 extensions/demo 2>&1); RC=$?
if [ $RC = 0 ] && [ "$(grep -c "put-object.*--if-none-match \*" "$LOG")" = 2 ] \
   && jq -e --arg s "$ZSHA" '.[0] | .sha256 == $s and .signature == "SIGBYTES" and (.s3_path | endswith("bundles/duplo.demo/1.0.0/sdk-1.0.6/extension.zip"))' "$CONSOLE/artifacts.json" >/dev/null
then ok; else bad "rc=$RC out=$OUT"; fi

t "never sets is_published and never logs the key"
if grep -q is_published "$LOG"; then bad "is_published sent"
elif grep -q secret-key "$LOG" "$TMP"/console/* 2>/dev/null; then bad "key logged"
elif ! grep -q "HEADER_FILE_KEY=yes" "$LOG"; then bad "the header file never carried the key, so this test could not prove a leak"
else ok
fi

t "a re-run of a finished build stops at the console lookup, with no zip download and no aws call"
: > "$LOG"  # Keep S3/CONSOLE state from the prior run. Clear only the log, so this run's own calls are what we check.
OUT=$(publish_build demo-v1.0.0-sdk-1.0.6 duplo.demo 1.0.0 1.0.6 extensions/demo 2>&1); RC=$?
[ $RC = 0 ] && grep -q "already uploaded and registered" <<<"$OUT" && ! grep -q "^aws " "$LOG" && ! grep -q "POST" <<<"$(grep curl "$LOG")" \
  && grep -q -- "-p extension.zip.sig" "$LOG" && ! grep -qE -- "-p extension\.zip( |$)" "$LOG" && ok || bad "rc=$RC out=$OUT log=$(cat "$LOG")"

t "a console lookup failure on a finished build fails the job, with no aws call"
: > "$LOG"
OUT=$(CONSOLE_FAIL='/versions/\?version=' publish_build demo-v1.0.0-sdk-1.0.6 duplo.demo 1.0.0 1.0.6 extensions/demo 2>&1); RC=$?
[ $RC != 0 ] && grep -q "::error::.*lookup of the version failed" <<<"$OUT" && ! grep -q "^aws " "$LOG" && ok || bad "rc=$RC out=$OUT"

t "an artifact lookup failure on a finished build fails the job, with no aws call"
: > "$LOG"
OUT=$(CONSOLE_FAIL='/artifacts/\?sdk_version=' publish_build demo-v1.0.0-sdk-1.0.6 duplo.demo 1.0.0 1.0.6 extensions/demo 2>&1); RC=$?
[ $RC != 0 ] && grep -q "::error::.*lookup of the artifact failed" <<<"$OUT" && ! grep -q "^aws " "$LOG" && ok || bad "rc=$RC out=$OUT"

t "a registered artifact that differs from the release takes the full path and fails there"
: > "$LOG"; jq '.[0].signature = "OTHERSIG"' "$CONSOLE/artifacts.json" > "$TMP/a.json" && mv "$TMP/a.json" "$CONSOLE/artifacts.json"
OUT=$(publish_build demo-v1.0.0-sdk-1.0.6 duplo.demo 1.0.0 1.0.6 extensions/demo 2>&1); RC=$?
[ $RC != 0 ] && grep -q "differs" <<<"$OUT" && grep -qE -- "-p extension\.zip( |$)" "$LOG" && ok || bad "rc=$RC out=$OUT"

t "a re-run after only the zip uploaded uploads the signature"
fresh; cp "$ASSETS/extension.zip" "$S3/bundles_duplo.demo_1.0.0_sdk-1.0.6_extension.zip"
OUT=$(publish_build demo-v1.0.0-sdk-1.0.6 duplo.demo 1.0.0 1.0.6 extensions/demo 2>&1); RC=$?
[ $RC = 0 ] && [ -f "$S3/bundles_duplo.demo_1.0.0_sdk-1.0.6_extension.zip.sig" ] && ok || bad "rc=$RC out=$OUT"

t "different bytes already at a key fail the job"
fresh; printf 'OTHER' > "$S3/bundles_duplo.demo_1.0.0_sdk-1.0.6_extension.zip"
OUT=$(publish_build demo-v1.0.0-sdk-1.0.6 duplo.demo 1.0.0 1.0.6 extensions/demo 2>&1); RC=$?
[ $RC != 0 ] && grep -q "different bytes" <<<"$OUT" && ok || bad "rc=$RC out=$OUT"

t "a version created by a concurrent run is looked up again"
fresh; OUT=$(RACE=1 publish_build demo-v1.0.0-sdk-1.0.6 duplo.demo 1.0.0 1.0.6 extensions/demo 2>&1); RC=$?
[ $RC = 0 ] && [ -f "$CONSOLE/artifacts.json" ] && ok || bad "rc=$RC out=$OUT"

t "an existing artifact with a different sha256 fails the job"
fresh; echo '[{"uuid":"v-1"}]' > "$CONSOLE/versions.json"
echo '[{"sdk_version":"1.0.6","s3_path":"s3://duplo-helpdesk-channels/bundles/duplo.demo/1.0.0/sdk-1.0.6/extension.zip","sha256":"0000","signature":"SIGBYTES"}]' \
  > "$CONSOLE/artifacts.json"
OUT=$(publish_build demo-v1.0.0-sdk-1.0.6 duplo.demo 1.0.0 1.0.6 extensions/demo 2>&1); RC=$?
[ $RC != 0 ] && grep -q "differs" <<<"$OUT" && ok || bad "rc=$RC out=$OUT"

t "a missing GitHub digest falls back to hashing the downloaded asset"
fresh; OUT=$(GH_DIGEST="" publish_build demo-v1.0.0-sdk-1.0.6 duplo.demo 1.0.0 1.0.6 extensions/demo 2>&1); RC=$?
[ $RC = 0 ] && jq -e --arg s "$ZSHA" '.[0].sha256 == $s' "$CONSOLE/artifacts.json" >/dev/null && ok || bad "rc=$RC out=$OUT"

t "a release digest that does not match the downloaded zip fails the job before any upload"
fresh; OUT=$(GH_DIGEST="sha256:deadbeef" publish_build demo-v1.0.0-sdk-1.0.6 duplo.demo 1.0.0 1.0.6 extensions/demo 2>&1); RC=$?
[ $RC != 0 ] && grep -q "deadbeef" <<<"$OUT" && grep -q "$ZSHA" <<<"$OUT" && ! grep -q "put-object" "$LOG" && ok || bad "rc=$RC out=$OUT"

t "a failed release-digest lookup fails the job before any upload"
fresh; OUT=$(GH_API_RC=1 publish_build demo-v1.0.0-sdk-1.0.6 duplo.demo 1.0.0 1.0.6 extensions/demo 2>&1); RC=$?
[ $RC != 0 ] && grep -q "::error::" <<<"$OUT" && ! grep -q "put-object" "$LOG" && ok || bad "rc=$RC out=$OUT"

t "an artifact lookup failure on a new build fails the job"
fresh; OUT=$(CONSOLE_FAIL='/artifacts/\?sdk_version=' publish_build demo-v1.0.0-sdk-1.0.6 duplo.demo 1.0.0 1.0.6 extensions/demo 2>&1); RC=$?
[ $RC != 0 ] && grep -q "::error::.*lookup of the artifact failed" <<<"$OUT" && [ ! -f "$CONSOLE/artifacts.json" ] && ok || bad "rc=$RC out=$OUT"

t "publishes a fresh build when asked, after its artifact is registered"
fresh; OUT=$(publish_version=new publish_build demo-v1.0.0-sdk-1.0.6 duplo.demo 1.0.0 1.0.6 extensions/demo 2>&1); RC=$?
[ $RC = 0 ] && jq -e '.is_published == true' "$CONSOLE/published" >/dev/null && grep -q "published demo-v1.0.0-sdk-1.0.6" <<<"$OUT" \
  && [ "$(grep -n 'curl -sS --fail-with-body -X PATCH' "$LOG" | cut -d: -f1)" -gt "$(grep -n '/versions/v-1/artifacts/$' "$LOG" | tail -1 | cut -d: -f1)" ] \
  && ok || bad "rc=$RC out=$OUT"

t "a re-run that asks to publish an already published version sends no PATCH"
: > "$LOG"; OUT=$(publish_version=any publish_build demo-v1.0.0-sdk-1.0.6 duplo.demo 1.0.0 1.0.6 extensions/demo 2>&1); RC=$?
[ $RC = 0 ] && ! grep -q "X PATCH" "$LOG" && ! grep -q "^aws " "$LOG" && ok || bad "rc=$RC out=$OUT"

t "a manual run publishes a finished, unpublished build, with no aws call"
fresh; publish_build demo-v1.0.0-sdk-1.0.6 duplo.demo 1.0.0 1.0.6 extensions/demo >/dev/null 2>&1; : > "$LOG"
OUT=$(publish_version=any publish_build demo-v1.0.0-sdk-1.0.6 duplo.demo 1.0.0 1.0.6 extensions/demo 2>&1); RC=$?
[ $RC = 0 ] && [ "$(grep -c "X PATCH" "$LOG")" = 1 ] && ! grep -q "^aws " "$LOG" && ok || bad "rc=$RC out=$OUT"

t "a failed publish fails the job"
fresh; OUT=$(CONSOLE_FAIL='/versions/v-1/$' publish_version=new publish_build demo-v1.0.0-sdk-1.0.6 duplo.demo 1.0.0 1.0.6 extensions/demo 2>&1); RC=$?
[ $RC != 0 ] && grep -q "::error::.*publish" <<<"$OUT" && ok || bad "rc=$RC out=$OUT"

t "a version unpublished after an opted-in push is not published again by the next push"
fresh; publish_version=new publish_build demo-v1.0.0-sdk-1.0.6 duplo.demo 1.0.0 1.0.6 extensions/demo >/dev/null 2>&1
rm -f "$CONSOLE/published"; : > "$LOG"
OUT=$(publish_version=new publish_build demo-v1.0.0-sdk-1.0.6 duplo.demo 1.0.0 1.0.6 extensions/demo 2>&1); RC=$?
[ $RC = 0 ] && ! grep -q "X PATCH" "$LOG" && [ ! -f "$CONSOLE/published" ] && ok || bad "rc=$RC out=$OUT"

t "a push resuming a build an earlier run registered does not publish it"
fresh; publish_build demo-v1.0.0-sdk-1.0.6 duplo.demo 1.0.0 1.0.6 extensions/demo >/dev/null 2>&1; : > "$LOG"
OUT=$(publish_version=new publish_build demo-v1.0.0-sdk-1.0.6 duplo.demo 1.0.0 1.0.6 extensions/demo 2>&1); RC=$?
[ $RC = 0 ] && ! grep -q "X PATCH" "$LOG" && ok || bad "rc=$RC out=$OUT"

t "a version lookup that still comes back empty after the POST fails the job"
fresh; OUT=$(VERSION_VANISHES=1 publish_build demo-v1.0.0-sdk-1.0.6 duplo.demo 1.0.0 1.0.6 extensions/demo 2>&1); RC=$?
[ $RC != 0 ] && grep -q "no version uuid" <<<"$OUT" && ok || bad "rc=$RC out=$OUT"

echo; echo "passed $PASS, failed $FAIL"; [ "$FAIL" -eq 0 ]
