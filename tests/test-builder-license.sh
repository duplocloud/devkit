#!/usr/bin/env bash
# Tests for the ArmDot license hand-off in scripts/_builder.sh: builder_resolve_license and builder_run_direct.
# Uses a stub `docker` on PATH that records its arguments; never runs a container. Usage: ./tests/test-builder-license.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

PASS=0; FAIL=0
t()   { printf '  %s … ' "$1"; }
ok()  { echo "ok"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
printf '#!/usr/bin/env bash\necho "$*" >> "%s/docker.args"\nexit 0\n' "$TMP" > "$TMP/bin/docker"; chmod +x "$TMP/bin/docker"
export PATH="$TMP/bin:$PATH"

ENV="$TMP/.env"; : > "$ENV"
_envv() { grep -E "^$1=" "$ENV" 2>/dev/null | head -1 | cut -d= -f2- || true; }

. ./scripts/_builder.sh || { echo "scripts/_builder.sh not found"; exit 1; }
RUNTIME=docker BUILDER_IMAGE=img DUPLO_UID=1 DUPLO_GID=1

echo "builder license:"

t "no license variable: no mount and no ARMDOT variable reach the container"
: > "$TMP/docker.args"
( unset ARMDOT_LICENSE_FILE_PATH; builder_run_direct scripts/build-extension.sh x ) >/dev/null 2>&1
if [ -s "$TMP/docker.args" ] && ! grep -q -e 'ARMDOT_LICENSE_FILE_PATH' -e '/run/armdot' "$TMP/docker.args"; then
  ok
else
  bad "$(cat "$TMP/docker.args")"
fi

t "license variable set: the file is mounted read-only and the in-container path is exported"
echo k > "$TMP/lic.key"; : > "$TMP/docker.args"
( ARMDOT_LICENSE_FILE_PATH="$TMP/lic.key" builder_run_direct scripts/build-extension.sh x ) >/dev/null 2>&1
if grep -q -- "-v $TMP/lic.key:/run/armdot/license.key:ro" "$TMP/docker.args" \
  && grep -q -- '-e ARMDOT_LICENSE_FILE_PATH=/run/armdot/license.key' "$TMP/docker.args"; then ok; else bad "$(cat "$TMP/docker.args")"; fi

t "license variable set to a relative path: mounted by its absolute form"
: > "$TMP/docker.args"
( cd "$TMP" && ARMDOT_LICENSE_FILE_PATH="lic.key" builder_run_direct scripts/build-extension.sh x ) >/dev/null 2>&1
if grep -q -- " -v $TMP/lic.key:/run/armdot/license.key:ro" "$TMP/docker.args"; then ok; else bad "$(cat "$TMP/docker.args")"; fi

t "license variable set to a missing file: the launch refuses before docker runs"
: > "$TMP/docker.args"
( ARMDOT_LICENSE_FILE_PATH="$TMP/nope.key" builder_run_direct scripts/build-extension.sh x ) >/dev/null 2>"$TMP/err"
rc=$?
msg="ERROR: ARMDOT_LICENSE_FILE_PATH names a missing or empty file: $TMP/nope.key"
if [ "$rc" -ne 0 ] && [ ! -s "$TMP/docker.args" ] && grep -q "$msg" "$TMP/err"; then
  ok
else
  bad "rc=$rc $(cat "$TMP/docker.args" "$TMP/err")"
fi

# builder_resolve_license is the one host-side check both container paths share, so the compose path (which never
# reaches builder_run_direct) is covered by testing the function and builder_dispatch's call to it.
t "resolve: a directory is refused, not just a missing file"
( ARMDOT_LICENSE_FILE_PATH="$TMP" builder_resolve_license ) >/dev/null 2>"$TMP/err"
if [ $? -ne 0 ] && grep -q 'names a missing or empty file' "$TMP/err"; then ok; else bad "$(cat "$TMP/err")"; fi

t "resolve: a relative path becomes absolute against the current directory and is exported"
got="$(cd "$TMP" && export ARMDOT_LICENSE_FILE_PATH=lic.key && builder_resolve_license && printf %s "$ARMDOT_LICENSE_FILE_PATH")"
if [ "$got" = "$TMP/lic.key" ]; then ok; else bad "got '$got'"; fi

t "resolve: an empty value is left alone, since compose passes one for a plain build"
got="$(ARMDOT_LICENSE_FILE_PATH= builder_resolve_license && printf 'rc0:%s' "${ARMDOT_LICENSE_FILE_PATH:-}")"
if [ "$got" = "rc0:" ]; then ok; else bad "got '$got'"; fi

t "dispatch: a license named only in .env is checked on the host before any runtime is chosen"
printf 'ARMDOT_LICENSE_FILE_PATH=%s\n' "$TMP/nope2.key" > "$ENV"
( unset ARMDOT_LICENSE_FILE_PATH; builder_dispatch scripts/build-extension.sh x ) >/dev/null 2>"$TMP/err"
if [ $? -ne 0 ] && grep -q "names a missing or empty file: $TMP/nope2.key" "$TMP/err"; then ok; else bad "$(cat "$TMP/err")"; fi
: > "$ENV"

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
