#!/usr/bin/env bash
# Checks the GCP native-ADC wiring: docker-compose.yml, run.sh, scripts/_runtime.sh (the one gcloud-directory
# resolver) and scripts/_gcp_auth.sh (the runtime helper) — against a FAKE container CLI. Nothing here starts a
# container, reads a real ADC file, your .env or a cloud; the fake docker records exactly what it was asked to do.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
PASS=0; FAIL=0
t()   { printf '  %s … ' "$1"; }
ok()  { echo "ok"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/proj" "$TMP/home" "$TMP/fake"
PROJ_REAL="$(cd "$TMP/proj" && pwd -P)"

# ── fake container CLI ────────────────────────────────────────────────────────────────────────────
# ps -q → the backend id in $FAKE_DIR/cid (empty file = not running); inspect answers by the template's content
# (and, like a real Go template, emits ONLY the named env entry when the template filters by name — a template that
# does not filter leaks FAKE_LEAKED_SECRET, which the tests look for); cp → a tar of the image's passwd/group;
# run → logs argv and prints $FAKE_PROBE (what the busybox helper would print); compose up/restart → logged with the
# environment compose would see, and they change the backend's id / start marker.
cat > "$TMP/bin/docker" <<'EOF'
#!/usr/bin/env bash
D="$FAKE_DIR"
printf '%s\n' "$*" >> "$D/calls.log"
case "$1" in
  ps)
    proj=""; svc=""
    for a in "$@"; do case "$a" in
      label=com.docker.compose.project=*) proj="${a#label=com.docker.compose.project=}" ;;
      label=com.docker.compose.service=*) svc="${a#label=com.docker.compose.service=}" ;;
    esac; done
    [ "$proj" = "$FAKE_PROJECT" ] && [ "$svc" = duplo-ai-studio ] && cat "$D/cid" 2>/dev/null
    exit 0 ;;
  inspect)
    f="$3"
    case "$f" in
      *State.StartedAt*) cat "$D/started" ;;
      *Config.Env*)
        if grep -q 'eq (index $p 0) "GOOGLE_APPLICATION_CREDENTIALS"' <<<"$f"; then
          [ -n "${FAKE_ENV_VALUE-}" ] && printf 'GOOGLE_APPLICATION_CREDENTIALS=%s' "$FAKE_ENV_VALUE"
        else printf 'FAKE_LEAKED_SECRET=hunter2 GOOGLE_APPLICATION_CREDENTIALS=%s' "${FAKE_ENV_VALUE-}"; fi ;;
      *Destination*.Source*) printf '%s' "${FAKE_MOUNT_SRC-}" ;;
      *Destination*.RW*) printf '%s' "${FAKE_MOUNT_RW-false}" ;;
      *Destination*.Type*) [ -n "${FAKE_MOUNT_SRC-}" ] && printf bind ;;
      *Config.User*) printf '%s' "${FAKE_USER-}" ;;
      *working_dir*) printf '%s' "${FAKE_WORKDIR-}" ;;
    esac
    exit 0 ;;
  cp)
    case "$2" in *:/etc/passwd) tar -cf - -C "$D" passwd ;; *:/etc/group) tar -cf - -C "$D" group ;; *) exit 1 ;; esac
    exit 0 ;;
  run)
    printf 'run %s\n' "${*:2:8}" >> "$D/run.log"       # the flags and image; the script body is not logged
    printf '%b' "${FAKE_PROBE-}"; exit "${FAKE_RUN_RC:-0}" ;;
  compose)
    printf 'compose %s | COMPOSE_FILE=%s DEVKIT_GCLOUD_DIR=%s\n' "$*" "${COMPOSE_FILE-}" "${DEVKIT_GCLOUD_DIR-}" >> "$D/compose.log"
    printf '%s' "${DEVKIT_GCP_ADC_ENV-}" > "$D/adc.env"
    case "$2" in
      up) echo newbackend > "$D/cid"; date +%s%N > "$D/started" ;;
      restart) [ "${FAKE_RESTART_NOOP-}" = 1 ] || date +%s%N > "$D/started" ;;
    esac
    exit 0 ;;
  *) echo "unexpected docker call: $*" >&2; exit 2 ;;
esac
EOF
printf '#!/usr/bin/env bash\n[ "${FAKE_HEALTH:-1}" = 1 ]\n' > "$TMP/bin/curl"
chmod +x "$TMP/bin/docker" "$TMP/bin/curl"
printf 'root:x:0:0::/root:/bin/sh\nbackenduser:x:1001:1002::/app:/sbin/nologin\n' > "$TMP/fake/passwd"
printf 'root:x:0:\nbackendgrp:x:1002:\n' > "$TMP/fake/group"

reset_fake() {
  : > "$TMP/fake/calls.log"; : > "$TMP/fake/compose.log"; : > "$TMP/fake/run.log"
  echo oldbackend > "$TMP/fake/cid"; echo 2026-11-03T09:00:00Z > "$TMP/fake/started"
  : > "$TMP/proj/.env"
}
# gcp <env assignments> <shell snippet> → stdout+stderr of the snippet, run with the fake runtime in the project dir
gcp() {
  ( export PATH="$TMP/bin:$PATH" RUNTIME=docker HOME="$TMP/home" DUPLO_ENV_FILE="$TMP/proj/.env" FAKE_DIR="$TMP/fake" \
           FAKE_PROJECT=proj FAKE_WORKDIR="$PROJ_REAL" FAKE_USER=backenduser FAKE_MOUNT_SRC="$TMP/home/.config/gcloud" FAKE_MOUNT_RW=false \
           FAKE_ENV_VALUE=/devkit-gcloud/application_default_credentials.json DUPLO_BASE=http://127.0.0.1:9 \
           CONNECT_CLOUD_GCP_WAIT_SECONDS=2 CONNECT_CLOUD_GCP_WAIT_INTERVAL=1
    unset DEVKIT_GCLOUD_DIR CLOUDSDK_CONFIG COMPOSE_PROJECT_NAME COMPOSE_FILE
    eval "$1"
    cd "$TMP/proj" || exit 9
    . "$ROOT/scripts/_runtime.sh"; . "$ROOT/scripts/_gcp_auth.sh"
    eval "$2" ) 2>&1
}
# gcp_strict: the same, in a fresh /bin/bash with the options connect-cloud.sh's real entrypoint sets (bash 3.2 on macOS)
gcp_strict() {
  ( export PATH="$TMP/bin:$PATH" RUNTIME=docker HOME="$TMP/home" DUPLO_ENV_FILE="$TMP/proj/.env" FAKE_DIR="$TMP/fake" \
           FAKE_PROJECT=proj FAKE_WORKDIR="$PROJ_REAL" FAKE_USER=backenduser FAKE_MOUNT_SRC="$TMP/home/.config/gcloud" FAKE_MOUNT_RW=false \
           FAKE_ENV_VALUE=/devkit-gcloud/application_default_credentials.json
    unset DEVKIT_GCLOUD_DIR CLOUDSDK_CONFIG COMPOSE_PROJECT_NAME COMPOSE_FILE
    cd "$TMP/proj" || exit 9
    /bin/bash -euo pipefail -c '. "$1/scripts/_runtime.sh"; . "$1/scripts/_gcp_auth.sh"; eval "$2"' strict "$ROOT" "$2"
    echo "rc=$?" ) 2>&1
}
json_get() { python3 -I -c 'import json,sys; d=json.load(sys.stdin)
for k in sys.argv[1].split("."): d=d[int(k)] if isinstance(d,list) else d.get(k) if isinstance(d,dict) else None
print("None" if d is None else d)' "$1"; }

echo "GCP native ADC, static:"
t "scripts are syntactically valid under bash"
if bash -n scripts/_gcp_auth.sh && bash -n scripts/_runtime.sh && bash -n scripts/connect-cloud.sh && bash -n run.sh; then ok; else bad "syntax"; fi

COMPOSE=docker-compose.yml
studio() { awk '/^  duplo-ai-studio:$/{f=1;next} f&&/^  [a-z]/{exit} f' "$COMPOSE"; }

t "the studio binds the WHOLE gcloud directory read-only at /devkit-gcloud and sets GOOGLE_APPLICATION_CREDENTIALS"
if studio | grep -qx '        source: ${DEVKIT_GCLOUD_DIR:-/var/empty}' && studio | grep -qx '        target: /devkit-gcloud' \
   && studio | grep -qx '        read_only: true' && studio | grep -qx '          create_host_path: false' \
   && studio | grep -qx '      - GOOGLE_APPLICATION_CREDENTIALS=${DEVKIT_GCP_ADC_ENV:-}'; then ok
else bad "studio mount or env missing"; fi

t "GOOGLE_APPLICATION_CREDENTIALS is never hard-coded (it would disable the SDK's metadata fallback)"
if ! grep -q 'GOOGLE_APPLICATION_CREDENTIALS=/' "$COMPOSE"; then ok; else bad "hard-coded ADC env"; fi

t "no service other than the studio mounts it (agent, installer, builder, dind, xterm unchanged)"
if [ "$(grep -c 'target: /devkit-gcloud' "$COMPOSE")" = 1 ] && ! grep -q 'application_default_credentials.json:/' "$COMPOSE"; then ok; else bad "other mounts"; fi

t "the legacy cloud_auth volume and its mount stay (rollback data intact); no new volume is declared for ADC"
if studio | grep -qx '      - cloud_auth:/devkit-auth:ro' && awk '/^volumes:$/{f=1;next} f' "$COMPOSE" | grep -qx '  cloud_auth:' \
   && ! awk '/^volumes:$/{f=1;next} f' "$COMPOSE" | grep -qi 'gcloud'; then ok; else bad "legacy store changed"; fi

t "run.sh creates the selected directory with plain mkdir -p BEFORE compose up, and never chmods/chowns it"
L_MK="$(grep -n 'mkdir -p "\$GCLOUD_DIR"' run.sh | head -1 | cut -d: -f1)"; L_UP="$(grep -n '^echo "==> Starting…"; runtime_compose up -d$' run.sh | cut -d: -f1)"
if [ -n "$L_MK" ] && [ -n "$L_UP" ] && [ "$L_MK" -lt "$L_UP" ] && grep -q 'GCLOUD_DIR="\$(runtime_gcloud_dir)"' run.sh \
   && ! grep -E '^[^#]*(chmod|chown)[^#]*GCLOUD_DIR' run.sh >/dev/null; then ok; else bad "run.sh mkdir wiring"; fi

t "the helper never chmods, chowns or copies credentials, and its probe helper mounts nothing writable"
if ! grep -E '^[^#]*\b(chmod|chown)\b' scripts/_gcp_auth.sh >/dev/null \
   && grep -q -- '--volumes-from "\$cid:ro"' scripts/_gcp_auth.sh && grep -q -- '--network none' scripts/_gcp_auth.sh \
   && ! grep -E '^[^#]*run .* -v ' scripts/_gcp_auth.sh >/dev/null && ! grep -E '^[^#]*\bcp\b[^#]*devkit-gcloud' scripts/_gcp_auth.sh >/dev/null \
   && ! grep -E '\{\{ *\.Config\.Env *\}\}|json \.Config' scripts/_gcp_auth.sh >/dev/null; then ok; else bad "helper static rules"; fi

echo "one resolver for the gcloud directory (script, compose and runtime_compose agree):"
reset_fake
t "default is \$HOME/.config/gcloud"
R="$(gcp '' 'runtime_gcloud_dir')"
if [ "$R" = "$TMP/home/.config/gcloud" ]; then ok; else bad "got '$R'"; fi

t "an explicitly selected CLOUDSDK_CONFIG (environment) wins over the default"
R="$(gcp "export CLOUDSDK_CONFIG=$TMP/cfg" 'runtime_gcloud_dir')"
if [ "$R" = "$TMP/cfg" ]; then ok; else bad "got '$R'"; fi

t "CLOUDSDK_CONFIG written only in .env is NOT honoured (gcloud itself ignores it, so the mount would not match where login writes)"
printf 'CLOUDSDK_CONFIG=%s/from-dotenv\n' "$TMP" > "$TMP/proj/.env"
R="$(gcp '' 'runtime_gcloud_dir')"
if [ "$R" = "$TMP/home/.config/gcloud" ]; then ok; else bad "got '$R'"; fi

t "DEVKIT_GCLOUD_DIR: environment beats .env beats CLOUDSDK_CONFIG; quotes/CR/trailing slash cleaned"
printf 'DEVKIT_GCLOUD_DIR="%s/dotenv/"\r\n' "$TMP" > "$TMP/proj/.env"
A="$(gcp "export CLOUDSDK_CONFIG=$TMP/cfg" 'runtime_gcloud_dir')"
B="$(gcp "export CLOUDSDK_CONFIG=$TMP/cfg DEVKIT_GCLOUD_DIR=$TMP/shell" 'runtime_gcloud_dir')"
if [ "$A" = "$TMP/dotenv" ] && [ "$B" = "$TMP/shell" ]; then ok; else bad "A='$A' B='$B'"; fi

t "a relative path is refused (it would mean 'relative to wherever compose ran')"
R="$(gcp 'export DEVKIT_GCLOUD_DIR=relative/dir' 'runtime_gcloud_dir; echo rc=$?')"
if grep -q 'not an absolute path' <<<"$R" && grep -q 'rc=1' <<<"$R"; then ok; else bad "got '$R'"; fi

t "runtime_compose hands compose the SAME directory the helper and run.sh resolve (.env override, compose never recomputes)"
reset_fake; printf 'DEVKIT_GCLOUD_DIR=%s/dotenv\n' "$TMP" > "$TMP/proj/.env"
gcp '' 'runtime_compose config >/dev/null' >/dev/null
D1="$(grep -o 'DEVKIT_GCLOUD_DIR=.*' "$TMP/fake/compose.log" | tail -1)"
D2="$(gcp '' 'gcp_auth_dir' | json_get dir)"
if [ "$D1" = "DEVKIT_GCLOUD_DIR=$TMP/dotenv" ] && [ "$D2" = "$TMP/dotenv" ]; then ok; else bad "compose '$D1' helper '$D2'"; fi

reset_fake
t "gcp_auth_dir reports the directory, the file and where the choice came from"
R="$(gcp "export CLOUDSDK_CONFIG=$TMP/cfg" 'gcp_auth_dir')"
if [ "$(json_get file <<<"$R")" = "$TMP/cfg/application_default_credentials.json" ] && grep -q 'CLOUDSDK_CONFIG' <<<"$(json_get source <<<"$R")"; then ok; else bad "got '$R'"; fi

echo "runtime inspect (fake runtime):"
reset_fake
t "inspect reports id, start marker, mount source/mode, the ONE env variable and the user — and nothing else"
R="$(gcp '' 'gcp_auth_inspect')"
if [ "$(json_get containerId <<<"$R")" = oldbackend ] && [ "$(json_get mount.source <<<"$R")" = "$TMP/home/.config/gcloud" ] \
   && [ "$(json_get mount.readOnly <<<"$R")" = True ] && [ "$(json_get env.GOOGLE_APPLICATION_CREDENTIALS <<<"$R")" = /devkit-gcloud/application_default_credentials.json ] \
   && [ "$(json_get user <<<"$R")" = backenduser ] && ! grep -q 'hunter2\|FAKE_LEAKED' <<<"$R"; then ok; else bad "got '$R'"; fi

t "an old backend (no mount, no env) is reported as absent, not guessed"
R="$(gcp 'export FAKE_MOUNT_SRC= FAKE_ENV_VALUE=' 'gcp_auth_inspect')"
if [ "$(json_get mount.present <<<"$R")" = False ] && [ "$(json_get env.GOOGLE_APPLICATION_CREDENTIALS <<<"$R")" = None ]; then ok; else bad "got '$R'"; fi

t "no running backend → {running:false}, with the project named; no other call is made"
: > "$TMP/fake/cid"; : > "$TMP/fake/calls.log"
R="$(gcp '' 'gcp_auth_inspect')"
if [ "$(json_get running <<<"$R")" = False ] && [ "$(json_get project <<<"$R")" = proj ] && ! grep -q '^inspect' "$TMP/fake/calls.log"; then ok; else bad "got '$R'"; fi

t "a project/service mismatch (backend belongs to another compose project) is invisible to this checkout"
reset_fake
R="$(gcp 'export FAKE_PROJECT=somebody-else' 'gcp_auth_inspect')"
if [ "$(json_get running <<<"$R")" = False ]; then ok; else bad "got '$R'"; fi

echo "runtime probe (fake runtime):"
reset_fake
t "the probe runs as the backend's NUMERIC uid:gid (from the image's passwd), read-only volumes-from, no network, no mounts"
: > "$TMP/fake/run.log"
R="$(gcp 'export FAKE_PROBE="state=ok\ntype=authorized_user\nsha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n"' 'gcp_auth_probe')"
RUN="$(cat "$TMP/fake/run.log")"
if [ "$(json_get state <<<"$R")" = ok ] && [ "$(json_get uid <<<"$R")" = 1001:1002 ] && [ "$(json_get type <<<"$R")" = authorized_user ] \
   && grep -q -- 'run --rm --user 1001:1002 --network none --volumes-from oldbackend:ro busybox:1.36' <<<"$RUN" \
   && ! grep -q -- ' -v \|--privileged\|--user 0\|--user root' <<<"$RUN" && [ "$(wc -l < "$TMP/fake/run.log" | tr -d ' ')" = 1 ]; then ok
else bad "got '$R' / run '$RUN'"; fi

t "every helper verdict is carried through; an unknown or failing helper is 'helper-failed', never a pass"
BADS=""
for st in no-mount dir-not-traversable missing not-regular unreadable; do
  R="$(gcp "export FAKE_PROBE='state=$st\n'" 'gcp_auth_probe')"; [ "$(json_get state <<<"$R")" = "$st" ] || BADS="$BADS $st"
done
R="$(gcp 'export FAKE_PROBE="garbage\n" FAKE_RUN_RC=125' 'gcp_auth_probe')"; [ "$(json_get state <<<"$R")" = helper-failed ] || BADS="$BADS garbage"
R="$(gcp 'export FAKE_PROBE="state=ok\ntype=authorized_user\nsha256=nothex\n"' 'gcp_auth_probe')"; [ "$(json_get sha256 <<<"$R")" = None ] || BADS="$BADS badsha"
if [ -z "$BADS" ]; then ok; else bad "wrong:$BADS"; fi

t "a user name that the image's passwd cannot resolve is 'user-unresolved' — never probed as root, never guessed"
: > "$TMP/fake/run.log"
R="$(gcp 'export FAKE_USER=ghost FAKE_PROBE="state=ok\n"' 'gcp_auth_probe')"
if [ "$(json_get state <<<"$R")" = user-unresolved ] && [ ! -s "$TMP/fake/run.log" ]; then ok; else bad "got '$R'"; fi

t "a numeric user:group is used as given, with no passwd lookup"
: > "$TMP/fake/run.log"
gcp 'export FAKE_USER=1001:1001 FAKE_PROBE="state=ok\n"' 'gcp_auth_probe' >/dev/null
if grep -q -- '--user 1001:1001 ' "$TMP/fake/run.log"; then ok; else bad "run $(cat "$TMP/fake/run.log")"; fi

t "the helper never emits file bytes: only state, type, sha256 keys reach the JSON"
R="$(gcp 'export FAKE_PROBE="state=ok\ntype=authorized_user\nsha256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\nrefresh_token=SHOULD-NOT-APPEAR\n"' 'gcp_auth_probe')"
if ! grep -q 'SHOULD-NOT-APPEAR' <<<"$R"; then ok; else bad "leaked: $R"; fi

echo "reconcile / restart (backend only, current checkout, current COMPOSE_FILE):"
reset_fake
t "reconcile: mkdir of the selected directory, then EXACTLY compose up -d --no-deps --no-build --pull never duplo-ai-studio"
rm -rf "$TMP/home/.config"
R="$(gcp 'export COMPOSE_FILE=docker-compose.yml:my-override.yml' 'gcp_auth_reconcile')"
LINE="$(grep '^compose' "$TMP/fake/compose.log")"
if [ -d "$TMP/home/.config/gcloud" ] && [ "$(wc -l < "$TMP/fake/compose.log" | tr -d ' ')" = 1 ] \
   && grep -q '^compose compose up -d --no-deps --no-build --pull never duplo-ai-studio |' <<<"$LINE" \
   && grep -q "COMPOSE_FILE=docker-compose.yml:my-override.yml DEVKIT_GCLOUD_DIR=$TMP/home/.config/gcloud\$" <<<"$LINE" \
   && grep -q '"action":"recreated"' <<<"$R"; then ok
else bad "line '$LINE' out '$R'"; fi

t "reconcile preserves a .env-selected directory and a user COMPOSE_FILE (compose sees both unchanged)"
reset_fake; printf 'DEVKIT_GCLOUD_DIR=%s/dotenv\nCOMPOSE_FILE=a.yml:b.yml\n' "$TMP" > "$TMP/proj/.env"
gcp '' 'gcp_auth_reconcile' >/dev/null
if grep -q "DEVKIT_GCLOUD_DIR=$TMP/dotenv\$" "$TMP/fake/compose.log" && [ -d "$TMP/dotenv" ]; then ok; else bad "$(cat "$TMP/fake/compose.log")"; fi

t "reconcile waits for a NEW backend start AND /healthz, bounded: a backend that never gets healthy fails after the limit"
reset_fake; S=$SECONDS
R="$(gcp 'export FAKE_HEALTH=0' 'gcp_auth_reconcile; echo rc=$?')"
if grep -q 'did not become healthy within 2s' <<<"$R" && grep -q 'rc=1' <<<"$R" && [ $((SECONDS - S)) -lt 15 ]; then ok; else bad "got '$R'"; fi

t "restart is EXACTLY compose restart duplo-ai-studio (no recreate, no other service)"
reset_fake
R="$(gcp '' 'gcp_auth_restart')"
if [ "$(wc -l < "$TMP/fake/compose.log" | tr -d ' ')" = 1 ] && grep -q '^compose compose restart duplo-ai-studio |' "$TMP/fake/compose.log" && grep -q '"action":"restarted"' <<<"$R"; then ok; else bad "got '$R' / $(cat "$TMP/fake/compose.log")"; fi

t "a restart whose start marker never changes is not accepted as ready (a stale process would pass /healthz)"
reset_fake
R="$(gcp 'export FAKE_RESTART_NOOP=1' 'gcp_auth_restart; echo rc=$?')"
if grep -q 'rc=1' <<<"$R" && grep -q 'did not become healthy' <<<"$R"; then ok; else bad "got '$R'"; fi

t "a backend that compose started from ANOTHER checkout is refused: no compose call at all"
reset_fake
R="$(gcp 'export FAKE_WORKDIR=/some/other/checkout' 'gcp_auth_reconcile; echo rc=$?; gcp_auth_restart; echo rc=$?')"
if [ "$(grep -c 'belongs to the compose project in /some/other/checkout' <<<"$R")" = 2 ] && [ ! -s "$TMP/fake/compose.log" ]; then ok; else bad "got '$R'"; fi

t "no running backend → rc 3 and no compose call (the helper never starts a stack)"
reset_fake; : > "$TMP/fake/cid"
R="$(gcp '' 'gcp_auth_reconcile; echo rc=$?; gcp_auth_restart; echo rc=$?; gcp_auth_probe; echo rc=$?')"
if [ "$(grep -c 'rc=3' <<<"$R")" = 3 ] && [ ! -s "$TMP/fake/compose.log" ]; then ok; else bad "got '$R'"; fi

t "prepare: creates the directory (no chmod), is idempotent, and refuses a path that is a file"
reset_fake; rm -rf "$TMP/home/.config"
R1="$(gcp '' 'gcp_auth_prepare')"; R2="$(gcp '' 'gcp_auth_prepare')"
: > "$TMP/filedir"; R3="$(gcp "export DEVKIT_GCLOUD_DIR=$TMP/filedir" 'gcp_auth_prepare; echo rc=$?')"
if [ "$(json_get created <<<"$R1")" = True ] && [ "$(json_get created <<<"$R2")" = False ] && grep -q 'is not a directory' <<<"$R3" && grep -q 'rc=1' <<<"$R3"; then ok; else bad "$R1 / $R2 / $R3"; fi

echo "bash 3.2 portability (/bin/bash with set -euo pipefail):"
reset_fake
t "dir, inspect and probe run under strict mode with the real entrypoint's options"
R="$(gcp_strict '' 'gcp_auth_dir >/dev/null; gcp_auth_inspect >/dev/null; FAKE_PROBE="state=ok\n" gcp_auth_probe >/dev/null')"
if grep -q '^rc=0$' <<<"$R" && ! grep -q 'unbound variable' <<<"$R"; then ok; else bad "got '$R'"; fi

echo "connect-cloud.sh wiring (real wrapper, fake runtime):"
t "_gcp <op> is dispatched by the real wrapper after the local-only guard, and prints one JSON object"
reset_fake
R="$( export PATH="$TMP/bin:$PATH" RUNTIME=docker HOME="$TMP/home" DUPLO_ENV_FILE="$TMP/proj/.env" FAKE_DIR="$TMP/fake" FAKE_PROJECT=proj \
        DUPLO_TARGET=local DUPLO_BASE=http://127.0.0.1:9 DUPLO_ADMIN_TOKEN=fake-token
      unset DEVKIT_GCLOUD_DIR CLOUDSDK_CONFIG
      "$ROOT/scripts/connect-cloud.sh" _gcp dir 2>&1 )"
if [ "$(json_get dir <<<"$R")" = "$TMP/home/.config/gcloud" ]; then ok; else bad "got '$R'"; fi

t "the same guard still rejects a non-loopback URL before the helper runs"
R="$( export PATH="$TMP/bin:$PATH" RUNTIME=docker DUPLO_ENV_FILE="$TMP/proj/.env" FAKE_DIR="$TMP/fake" DUPLO_TARGET=local DUPLO_BASE=https://x.invalid DUPLO_ADMIN_TOKEN=t
      "$ROOT/scripts/connect-cloud.sh" _gcp dir 2>&1; echo "rc=$?" )"
if grep -q 'refuses the studio URL' <<<"$R" && grep -q 'rc=1' <<<"$R"; then ok; else bad "got '$R'"; fi

echo "runtime_compose ADC env:"
mkdir -p "$TMP/adc_absent" "$TMP/adc_present"; echo '{}' > "$TMP/adc_present/application_default_credentials.json"
adc_env() { # <gcloud dir> [stale env value] -> DEVKIT_GCP_ADC_ENV that compose receives
  rm -f "$TMP/fake/adc.env"
  gcp "export DEVKIT_GCLOUD_DIR='$1' DEVKIT_GCP_ADC_ENV='${2-}'" 'runtime_compose config >/dev/null; cat "$FAKE_DIR/adc.env"'
}
t "no ADC file in the selected directory -> empty ADC env"
if [ -z "$(adc_env "$TMP/adc_absent")" ]; then ok; else bad "got '$(adc_env "$TMP/adc_absent")'"; fi
t "ADC file present in the selected directory -> the container path"
if [ "$(adc_env "$TMP/adc_present")" = /devkit-gcloud/application_default_credentials.json ]; then ok; else bad "got '$(adc_env "$TMP/adc_present")'"; fi
t "a stale DEVKIT_GCP_ADC_ENV in the caller's environment is ignored (absent file stays empty)"
if [ -z "$(adc_env "$TMP/adc_absent" /stale/path)" ]; then ok; else bad "got '$(adc_env "$TMP/adc_absent" /stale/path)'"; fi
t "a stale DEVKIT_GCP_ADC_ENV is overridden when the file is present"
if [ "$(adc_env "$TMP/adc_present" /stale/path)" = /devkit-gcloud/application_default_credentials.json ]; then ok; else bad "got '$(adc_env "$TMP/adc_present" /stale/path)'"; fi

echo; echo "gcp native ADC wiring: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
