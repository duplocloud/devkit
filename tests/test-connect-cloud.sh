#!/usr/bin/env bash
# Checks scripts/connect-cloud.sh, its credential-store helper and its python core against stubs — a fake
# studio + fake Google on loopback, a stub `aws`, a stub container CLI. Nothing here touches a cloud, a real
# container runtime, or your .env; it runs the same on a laptop and in CI. Behavioural, not grep-based:
# the store helper is exercised through a fake `docker` that records exactly what it was asked to do.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
PASS=0; FAIL=0
t()   { printf '  %s … ' "$1"; }
ok()  { echo "ok"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/proj"

# A fake container CLI. It answers `ps -q` with the id configured for the (project, service) pair, `inspect`
# with the configured mount, and records every `run` (argv + stdin bytes) so the write path can be asserted.
cat > "$TMP/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_LOG"
case "$1" in
  ps)
    proj=""; svc=""
    for a in "$@"; do case "$a" in
      label=com.docker.compose.project=*) proj="${a#label=com.docker.compose.project=}" ;;
      label=com.docker.compose.service=*) svc="${a#label=com.docker.compose.service=}" ;;
    esac; done
    [ "$proj" = "$FAKE_PROJECT" ] && [ "$svc" = duplo-ai-studio ] && [ -n "${FAKE_STUDIO_ID-}" ] && echo "$FAKE_STUDIO_ID"
    exit 0 ;;
  inspect)
    # the --format template asks for the volume mounted at /devkit-auth
    [ "${@: -1}" = "$FAKE_STUDIO_ID" ] && printf '%s' "${FAKE_MOUNT_VOLUME-}"
    exit 0 ;;
  run)
    cat > "$FAKE_STDIN" 2>/dev/null || true
    exit 0 ;;
  *) echo "unexpected: $*" >&2; exit 2 ;;
esac
EOF
chmod +x "$TMP/bin/docker"

# store <env assignments> <function and args> → runs in a subshell with the fake runtime; prints stdout+stderr
store() {
  ( export PATH="$TMP/bin:$PATH" RUNTIME=docker FAKE_LOG="$TMP/log" FAKE_STDIN="$TMP/stdin" DUPLO_ENV_FILE="$TMP/proj/.env"
    eval "$1"
    cd "$TMP/proj" || exit 9
    . "$OLDPWD/scripts/_runtime.sh"; . "$OLDPWD/scripts/_cloud_auth.sh"
    eval "$2" ) 2>&1
}

echo "connect-cloud, static:"
t "scripts are syntactically valid"
if bash -n scripts/connect-cloud.sh && bash -n scripts/_cloud_auth.sh && python3 -I -m py_compile scripts/connect_cloud.py; then ok
else bad "syntax"; fi

echo "credential store helper (fake runtime):"

t "the volume is read from the running studio's /devkit-auth mount, not guessed from a name"
: > "$TMP/log"; : > "$TMP/proj/.env"
R="$(store 'export FAKE_PROJECT=proj FAKE_STUDIO_ID=c0ffee FAKE_MOUNT_VOLUME=some-other-name_cloud_auth' 'cloud_auth_volume')"
if [ "$R" = "some-other-name_cloud_auth" ]; then ok; else bad "got '$R'"; fi

t "COMPOSE_PROJECT_NAME set ONLY in .env selects that project's studio (the reviewer's live reproduction)"
: > "$TMP/log"; printf 'COMPOSE_PROJECT_NAME=cloud-onboard-r1\n' > "$TMP/proj/.env"
R="$(store 'export FAKE_PROJECT=cloud-onboard-r1 FAKE_STUDIO_ID=abc123 FAKE_MOUNT_VOLUME=cloud-onboard-r1_cloud_auth; unset COMPOSE_PROJECT_NAME' 'cloud_auth_volume')"
if [ "$R" = "cloud-onboard-r1_cloud_auth" ] && grep -q 'label=com.docker.compose.project=cloud-onboard-r1' "$TMP/log"; then ok; else bad "got '$R'"; fi

t "an exported COMPOSE_PROJECT_NAME wins over .env, as it does for compose"
: > "$TMP/log"; printf 'COMPOSE_PROJECT_NAME=from-dotenv\n' > "$TMP/proj/.env"
R="$(store 'export FAKE_PROJECT=from-shell FAKE_STUDIO_ID=abc123 FAKE_MOUNT_VOLUME=from-shell_cloud_auth COMPOSE_PROJECT_NAME=from-shell' 'cloud_auth_volume')"
if [ "$R" = "from-shell_cloud_auth" ]; then ok; else bad "got '$R'"; fi

t "a project mismatch (studio runs under another project name) fails closed with the project named"
: > "$TMP/log"; printf 'COMPOSE_PROJECT_NAME=mine\n' > "$TMP/proj/.env"
R="$(store 'export FAKE_PROJECT=theirs FAKE_STUDIO_ID=abc123 FAKE_MOUNT_VOLUME=theirs_cloud_auth' 'cloud_auth_volume; echo rc=$?')"
if grep -q "no running 'duplo-ai-studio' container in compose project 'mine'" <<<"$R" && grep -q 'rc=1' <<<"$R"; then ok; else bad "got '$R'"; fi

t "a studio without the /devkit-auth mount (old compose) fails closed, never writes elsewhere"
: > "$TMP/log"; : > "$TMP/proj/.env"
R="$(store 'export FAKE_PROJECT=proj FAKE_STUDIO_ID=abc123 FAKE_MOUNT_VOLUME=' 'cloud_auth_write gcp/x.json <<<"secret"; echo rc=$?')"
if grep -q 'no volume mounted at /devkit-auth' <<<"$R" && grep -q 'rc=3' <<<"$R" && ! grep -q '^run ' "$TMP/log"; then ok; else bad "got '$R'"; fi

t "a write runs a throwaway helper as uid 1001 on the discovered volume, secret via stdin only"
: > "$TMP/log"; : > "$TMP/stdin"; : > "$TMP/proj/.env"
R="$(store 'export FAKE_PROJECT=proj FAKE_STUDIO_ID=abc123 FAKE_MOUNT_VOLUME=proj_cloud_auth' 'printf "%s" "REFRESH-TOKEN-BYTES" | cloud_auth_write gcp/conn.json; echo rc=$?')"
RUNLINE="$(grep '^run ' "$TMP/log")"
if grep -q 'rc=0' <<<"$R" \
   && grep -q -- '--rm --user 1001:1001 -i -v proj_cloud_auth:/devkit-auth busybox:1.36 sh -c' <<<"$RUNLINE" \
   && grep -q 'umask 077' <<<"$RUNLINE" && grep -q 'chmod 0600' <<<"$RUNLINE" && grep -q 'mv -f' <<<"$RUNLINE" \
   && [ "$(cat "$TMP/stdin")" = "REFRESH-TOKEN-BYTES" ] \
   && ! grep -q 'REFRESH-TOKEN-BYTES' "$TMP/log"; then ok
else bad "run line: $RUNLINE / out: $R"; fi

t "unsafe relative paths are refused before any runtime call"
: > "$TMP/log"
R="$(store 'export FAKE_PROJECT=proj FAKE_STUDIO_ID=abc123 FAKE_MOUNT_VOLUME=proj_cloud_auth' '
  for p in "../x" "/abs" "a/../b" ".hidden" "Upper"; do cloud_auth_write "$p" </dev/null >/dev/null 2>&1; printf "%s " $?; done')"
if [ "$R" = "2 2 2 2 2 " ] && ! grep -q '^run ' "$TMP/log"; then ok; else bad "got '$R'"; fi

echo "credential store helper under 'set -euo pipefail' on /bin/bash (connect-cloud.sh's real entrypoint mode):"
# `store` above sources the helper without strict mode, which masked a bash 3.2 (macOS /bin/bash) failure:
# expanding an EMPTY local array as "${flags[@]}" is an "unbound variable" under `set -u`, so the flagless
# list/remove paths died while the `-i` write path worked. These cases run the SAME helper functions in a
# fresh /bin/bash with exactly the options connect-cloud.sh sets, against the same fake runtime.
store_strict() { # <env assignments> <function and args> → stdout+stderr, then "rc=N" of the strict shell
  ( export PATH="$TMP/bin:$PATH" RUNTIME=docker FAKE_LOG="$TMP/log" FAKE_STDIN="$TMP/stdin" DUPLO_ENV_FILE="$TMP/proj/.env"
    eval "$1"
    cd "$TMP/proj" || exit 9
    /bin/bash -euo pipefail -c '. "$1/scripts/_runtime.sh"; . "$1/scripts/_cloud_auth.sh"; eval "$2"' strict "$OLDPWD" "$2"
    echo "rc=$?" ) 2>&1
}
STRICT_ENV='export FAKE_PROJECT=proj FAKE_STUDIO_ID=abc123 FAKE_MOUNT_VOLUME=proj_cloud_auth'

t "flagless cloud_auth_list survives set -u (no 'flags[@]: unbound variable'); argv has no stray word"
: > "$TMP/log"; : > "$TMP/proj/.env"
R="$(store_strict "$STRICT_ENV" 'cloud_auth_list')"
RUNLINE="$(grep '^run ' "$TMP/log")"
if grep -q '^rc=0$' <<<"$R" && ! grep -q 'unbound variable' <<<"$R" \
   && grep -q -- '^run --rm --user 1001:1001 -v proj_cloud_auth:/devkit-auth busybox:1.36 sh -c ' <<<"$RUNLINE" \
   && grep -q 'find \. -type f' <<<"$RUNLINE" && grep -q ' sh /devkit-auth$' <<<"$RUNLINE"; then ok
else bad "out: $R / run line: $RUNLINE"; fi

t "flagless cloud_auth_remove survives set -u; argv is exactly rm -f on the mount + rel"
: > "$TMP/log"
R="$(store_strict "$STRICT_ENV" 'cloud_auth_remove gcp/conn.json')"
RUNLINE="$(grep '^run ' "$TMP/log")"
if grep -q '^rc=0$' <<<"$R" && ! grep -q 'unbound variable' <<<"$R" \
   && [ "$RUNLINE" = 'run --rm --user 1001:1001 -v proj_cloud_auth:/devkit-auth busybox:1.36 sh -c rm -f "$1/$2" sh /devkit-auth gcp/conn.json' ]; then ok
else bad "out: $R / run line: $RUNLINE"; fi

t "cloud_auth_write under set -u still passes -i as its own word and the secret via stdin only"
: > "$TMP/log"; : > "$TMP/stdin"
R="$(store_strict "$STRICT_ENV" 'printf "%s" "STRICT-SECRET-BYTES" | cloud_auth_write gcp/conn.json')"
RUNLINE="$(grep '^run ' "$TMP/log")"
if grep -q '^rc=0$' <<<"$R" && ! grep -q 'unbound variable' <<<"$R" \
   && grep -q -- '^run --rm --user 1001:1001 -i -v proj_cloud_auth:/devkit-auth busybox:1.36 sh -c ' <<<"$RUNLINE" \
   && grep -q ' sh /devkit-auth gcp/conn.json$' <<<"$RUNLINE" \
   && [ "$(cat "$TMP/stdin")" = "STRICT-SECRET-BYTES" ] && ! grep -q 'STRICT-SECRET-BYTES' "$TMP/log"; then ok
else bad "out: $R / run line: $RUNLINE"; fi

t "strict-mode failure path: no studio → rc=3 from the helper, not a shell abort"
: > "$TMP/log"
R="$(store_strict 'export FAKE_PROJECT=other FAKE_STUDIO_ID=abc123 FAKE_MOUNT_VOLUME=proj_cloud_auth' 'cloud_auth_list || echo "helper-rc=$?"')"
if grep -q 'helper-rc=3' <<<"$R" && grep -q '^rc=0$' <<<"$R" && ! grep -q '^run ' "$TMP/log"; then ok; else bad "got '$R'"; fi

echo "local-only target guard (fake tokens, no network):"
# The wrapper is run for real with a temp .env and a fake container CLI on PATH; a rejected run must stop
# before python, the runtime, or any socket. The accepted run proceeds to the studio call, which fails on a
# closed loopback port — proof that only the guard, not the network, decided.
# The connection records are pointed at a path under $TMP that never exists: `status` must then print
# "no connections recorded" instead of probing whatever scopes a real onboarding left in the checkout's
# .devkit-cloud/connections.json (which turned the accepted-URL check into a GET against the closed port).
: > "$TMP/guard.env"
guard() { # <env assignments> → stderr+stdout, then "rc=N"
  ( export PATH="$TMP/bin:$PATH" DUPLO_ENV_FILE="$TMP/guard.env" CONNECT_CLOUD_STORE_CMD="true" RUNTIME=docker
    export CONNECT_CLOUD_STATE="$TMP/guard-state/connections.json"
    unset DUPLO_TARGET DUPLO_HOST DUPLO_TOKEN DUPLO_BASE DUPLO_ADMIN_TOKEN
    eval "$1"; ./scripts/connect-cloud.sh status 2>&1; echo "rc=$?" ) 2>&1
}
t "an inferred remote target (DUPLO_HOST + DUPLO_TOKEN in the environment, no DUPLO_TARGET) is rejected"
R="$(guard 'export DUPLO_HOST=https://remote.invalid DUPLO_TOKEN=fake-token')"
if grep -q "resolved target is 'remote'" <<<"$R" && grep -q 'rc=1' <<<"$R"; then ok; else bad "got: $R"; fi

t "an explicit DUPLO_TARGET=remote is rejected"
R="$(guard 'export DUPLO_TARGET=remote DUPLO_HOST=https://remote.invalid DUPLO_TOKEN=fake-token')"
if grep -q "resolved target is 'remote'" <<<"$R" && grep -q 'rc=1' <<<"$R"; then ok; else bad "got: $R"; fi

t "a non-loopback DUPLO_BASE while the target is local is rejected, and the URL itself is not echoed"
R="$(guard 'export DUPLO_TARGET=local DUPLO_BASE=https://test21.duplocloud.net DUPLO_ADMIN_TOKEN=fake-token')"
if grep -q 'refuses the studio URL' <<<"$R" && grep -q 'rc=1' <<<"$R" && ! grep -q 'test21.duplocloud.net' <<<"$R"; then ok; else bad "got: $R"; fi

t "loopback-prefixed userinfo bypasses (host:port@evil, IPv6@evil, user:pw@localhost) are rejected before any request"
BADS=""
for u in 'http://localhost:1234@evil.invalid' 'http://localhost:1234@evil.invalid:60231/' 'http://127.0.0.1:60231@evil.invalid' \
         'http://[::1]:60231@evil.invalid' 'http://[::1]@evil.invalid' 'http://user:pw@localhost:60231' 'http://localhost@evil.invalid'; do
  R="$(guard "export DUPLO_TARGET=local DUPLO_BASE='$u' DUPLO_ADMIN_TOKEN=fake-token")"
  { grep -q 'refuses the studio URL' <<<"$R" && grep -q 'rc=1' <<<"$R" && ! grep -q 'evil.invalid' <<<"$R" && ! grep -q 'no connections recorded' <<<"$R"; } || BADS="$BADS $u"
done
if [ -z "$BADS" ]; then ok; else bad "accepted or echoed:$BADS"; fi

t "path, query, fragment, double-slash, https, non-digit port and non-loopback hosts are rejected"
BADS=""
for u in 'http://localhost:60231/api' 'http://localhost:60231?x=1' 'http://localhost:60231#f' 'http://localhost:60231//' \
         'https://localhost:60231' 'http://localhost:60231a' 'http://localhost.evil.invalid:60231' 'http://10.0.0.5:60231' \
         'http://127.0.0.1.evil.invalid' 'http://localhost:' ' http://localhost:60231' 'http://localhost:60231 '; do
  R="$(guard "export DUPLO_TARGET=local DUPLO_BASE='$u' DUPLO_ADMIN_TOKEN=fake-token")"
  { grep -q 'refuses the studio URL' <<<"$R" && grep -q 'rc=1' <<<"$R"; } || BADS="$BADS [$u]"
done
if [ -z "$BADS" ]; then ok; else bad "accepted:$BADS"; fi

t "a legitimate loopback override on a custom port passes the guard and reaches the python core"
for u in 'http://127.0.0.1:9' 'http://localhost:60231' 'http://localhost:60231/' 'http://[::1]:60231/' 'http://[::1]' 'http://localhost'; do
  R="$(guard "export DUPLO_TARGET=local DUPLO_BASE='$u' DUPLO_ADMIN_TOKEN=fake-token")"
  if grep -q 'refuses the studio URL' <<<"$R" || grep -q 'resolved target' <<<"$R" || ! grep -q 'no connections recorded' <<<"$R"; then
    bad "url $u: $R"; u=""; break; fi
done
[ -n "$u" ] && ok

echo "connect-cloud, behaviour (python stubs):"
OUT="$(python3 -I tests/test_connect_cloud.py 2>&1)"
if printf '%s\n' "$OUT" | tail -1 | grep -q '^OK'; then t "tests/test_connect_cloud.py"; ok
else t "tests/test_connect_cloud.py"; bad "see: python3 -I tests/test_connect_cloud.py"; printf '%s\n' "$OUT" | tail -30; fi

echo; echo "connect-cloud: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
