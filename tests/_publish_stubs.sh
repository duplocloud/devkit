# shellcheck shell=bash
# Fakes for publish_build's dependencies (scripts/_publish.sh), shared by test-publish.sh and the resume tests in
# test-release-extensions.sh. Source this after creating "$TMP/bin" and putting it on PATH. It writes gh, aws and
# curl there and makes them executable. The caller exports ASSETS (a directory holding extension.zip and
# extension.zip.sig), S3 and CONSOLE (scratch directories standing in for the bucket and the console's records),
# and LOG (where every stubbed call is appended).
#
# gh also answers the release-lifecycle calls scripts/release-extensions.sh itself makes (create/view, and the
# immutable-flag api lookup), so one gh stub serves both test files. It tells that lookup apart from publish_build's
# digest lookup, which hits the same `gh api repos/{owner}/{repo}/releases/tags/<tag>` shape with a different --jq.

cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >> "$LOG"
case "$1 $2" in
  "release download")
    # Copies only the assets named by -p, so a test can tell which ones a run downloaded.
    pats=(); dest=""
    while [ $# -gt 0 ]; do case "$1" in -p) pats+=("$2"); shift ;; -D) dest=$2; shift ;; esac; shift; done
    for p in "${pats[@]}"; do cp "$ASSETS/$p" "$dest"/; done ;;
  "release create") exit "${GH_CREATE_RC:-0}" ;;
  "release view") [ "${GH_VIEW_RC:-0}" = 0 ] || exit "${GH_VIEW_RC}"
                   printf '%s\n' "${GH_ASSETS:-extension.zip,extension.zip.sig}" ;;
  "api repos/{owner}/{repo}/releases/tags/"*)
    [ "${GH_API_RC:-0}" = 0 ] || exit "${GH_API_RC}"
    if [[ "$*" == *'assets[]'* ]]; then printf '%s\n' "${GH_DIGEST-sha256:$ZSHA}"
    else printf '%s\n' "${GH_IMMUTABLE:-true}"; fi ;;
esac
EOF

cat > "$TMP/bin/aws" <<'EOF'
#!/usr/bin/env bash
echo "aws $*" >> "$LOG"
key=""; body=""; out=""; while [ $# -gt 0 ]; do case "$1" in --key) key=$2 ;; --body) body=$2 ;; esac; out=$1; shift; done
obj="$S3/$(echo "$key" | tr / _)"
if grep -q put-object <<<"$(tail -1 "$LOG")"; then
  [ -f "$obj" ] && { echo "An error occurred (PreconditionFailed) when calling the PutObject operation" >&2; exit 254; }
  cp "$body" "$obj"; echo '{}'
else cp "$obj" "$out"; fi
EOF

cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
# Console stub: versions and artifacts live as files under $CONSOLE. Prints body then a final line with the code.
# Logs raw argv, unmasked, so a key leaked onto the command line would show up here the way a real process listing
# or Action log would show it. The key only ever travels in an -H @file argument, so this also records whether this
# call's header file held it (HEADER_FILE_KEY=yes/no), letting a test prove that without the key itself in the log.
echo "curl $*" >> "$LOG"
url=""; data=""; method=GET; hdrfile=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method=$2; shift ;;
    --data|-d) data=$2; method=${method/GET/POST}; shift ;;
    -H) case "$2" in @*) hdrfile=${2#@} ;; esac; shift ;;
    http*) url=$1 ;;
  esac
  shift
done
if [ -n "$hdrfile" ] && grep -qF -- "$CONSOLE_API_KEY" "$hdrfile" 2>/dev/null
then echo "HEADER_FILE_KEY=yes" >> "$LOG"; else echo "HEADER_FILE_KEY=no" >> "$LOG"; fi
# CONSOLE_FAIL, a regex matched against the URL, makes that call fail the way curl --fail-with-body does.
if [ -n "${CONSOLE_FAIL:-}" ] && [[ "$url" =~ $CONSOLE_FAIL ]]; then echo '{"detail":"server error"}'; exit 22; fi
case "$method $url" in
  "GET "*"/versions/?version="*) cat "$CONSOLE/versions.json" 2>/dev/null || echo '[]' ;;
  "POST "*"/versions/")
    [ -n "${RACE:-}" ] && [ ! -f "$CONSOLE/raced" ] && { touch "$CONSOLE/raced"; echo '[{"uuid":"v-1"}]' > "$CONSOLE/versions.json"; echo '{"version":["1.0.0 already exists for this extension."]}'; exit 22; }
    [ -n "${VERSION_VANISHES:-}" ] && { echo '{"uuid":"v-1"}'; exit 0; }
    echo '[{"uuid":"v-1"}]' > "$CONSOLE/versions.json"; echo '{"uuid":"v-1"}' ;;
  "GET "*"/versions/v-1/")
    if [ -f "$CONSOLE/published" ]; then echo '{"uuid":"v-1","is_published":true}'; else echo '{"uuid":"v-1","is_published":false}'; fi ;;
  "PATCH "*"/versions/v-1/") echo "$data" > "$CONSOLE/published"; echo '{"uuid":"v-1","is_published":true}' ;;
  "GET "*"/artifacts/?sdk_version="*) cat "$CONSOLE/artifacts.json" 2>/dev/null || echo '[]' ;;
  "POST "*"/artifacts/") echo "[$data]" > "$CONSOLE/artifacts.json"; echo "$data" ;;
esac
EOF

chmod +x "$TMP/bin/gh" "$TMP/bin/aws" "$TMP/bin/curl"
