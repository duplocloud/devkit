# shellcheck shell=bash
# Sourced by scripts/connect-cloud.sh — the GCP runtime helper (`connect-cloud.sh _gcp <op>`).
#
# WHY this exists. The published backend resolves Google credentials with its stock
# GoogleCredential.GetApplicationDefaultAsync and impersonates the credential's cloudRoleToAssume. So the
# only thing a GCP connection needs from this kit is that the RUNNING backend can read your normal ADC file
# at the standard place. That is arranged by docker-compose.yml: the WHOLE host gcloud directory is bound
# read-only at /devkit-gcloud and GOOGLE_APPLICATION_CREDENTIALS points at
# /devkit-gcloud/application_default_credentials.json. Nothing is copied, nothing is chmod'd or chown'd.
#
# This file answers, with real facts and never guesses, whether that wiring is live and usable, and applies
# the two backend-only repairs the design needs. Every operation prints ONE JSON object on stdout (the
# Python core and its tests parse it; announcements go to stderr) and exits non-zero with a message on stderr
# when the question could not be answered at all.
#
#   dir        the host directory compose binds (runtime_gcloud_dir) and where that came from. No runtime call.
#   inspect    READ-ONLY. The backend container's id/start marker, its /devkit-gcloud mount source + mode, the
#              value of GOOGLE_APPLICATION_CREDENTIALS and its user — and nothing else. The environment is
#              filtered by name inside the inspect template: only that one variable is ever emitted.
#   probe      Can the backend's EXACT uid read the file? A disposable busybox helper runs --volumes-from the
#              backend (read-only), as the backend's numeric uid:gid, with no network, and reports one of
#              ok | no-mount | dir-not-traversable | missing | not-regular | unreadable, the JSON "type"
#              field's verdict and the file's sha256. It never prints, copies or logs file bytes.
#   prepare    mkdir -p the host directory (no copy, no chmod/chown). Idempotent.
#   reconcile  prepare, then `compose up -d --no-deps --no-build --pull never duplo-ai-studio` under the
#              current checkout/COMPOSE_FILE/.env — recreates the backend ONLY, then waits (bounded) for health.
#   restart    `compose restart duplo-ai-studio` — backend ONLY — then waits (bounded) for a NEW start and health.
#
# Why a restart is ever needed: Google.Apis.Auth's DefaultCredentialProvider caches the FIRST lookup Task for
# the life of the process — a "no ADC" failure included, and a UserCredential read before a new login. Changing
# the file cannot clear it; the process must start again. reconcile/restart act on the studio container of THIS
# checkout's compose project only; a container whose compose working directory is another checkout is refused.
#
# Expects RUNTIME resolved (scripts/_runtime.sh: runtime_resolve) and the cwd to be the checkout root.

_GCP_SERVICE="duplo-ai-studio"
_GCP_MOUNT="/devkit-gcloud"
_GCP_FILE_NAME="application_default_credentials.json"
_GCP_ENV_NAME="GOOGLE_APPLICATION_CREDENTIALS"
_GCP_HELPER_IMAGE="busybox:1.36"

# _gcp_esc <text> -> text safe inside a JSON string (backslash, quote escaped; control characters dropped).
_gcp_esc() { printf '%s' "$1" | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g'; }
# _gcp_q <text> -> a JSON string, or null when empty.
_gcp_q() { if [ -z "$1" ]; then printf 'null'; else printf '"%s"' "$(_gcp_esc "$1")"; fi; }

_gcp_die() { echo "$*" >&2; return 1; }

gcp_auth_container() {
  "${RUNTIME:?}" ps -q \
      --filter "label=com.docker.compose.project=$(runtime_compose_project)" \
      --filter "label=com.docker.compose.service=$_GCP_SERVICE" 2>/dev/null | head -1
}

# _gcp_inspect_field <cid> <go template> -> the template's output (empty on any failure).
_gcp_inspect_field() { "${RUNTIME:?}" inspect --format "$2" "$1" 2>/dev/null || true; }

gcp_auth_dir() {
  local r d src
  r="$(runtime_gcloud_dir_source)" || return 1
  d="${r%%$'\t'*}"; src="${r#*$'\t'}"
  printf '{"dir":"%s","file":"%s/%s","source":"%s"}\n' "$(_gcp_esc "$d")" "$(_gcp_esc "$d")" "$_GCP_FILE_NAME" "$(_gcp_esc "$src")"
}

gcp_auth_inspect() {
  local cid started src rw mtype env user wd
  cid="$(gcp_auth_container)"
  if [ -z "$cid" ]; then
    printf '{"running":false,"service":"%s","project":"%s"}\n' "$_GCP_SERVICE" "$(_gcp_esc "$(runtime_compose_project)")"
    return 0
  fi
  started="$(_gcp_inspect_field "$cid" '{{.State.StartedAt}}')"
  src="$(_gcp_inspect_field "$cid" '{{range .Mounts}}{{if eq .Destination "'"$_GCP_MOUNT"'"}}{{.Source}}{{end}}{{end}}')"
  rw="$(_gcp_inspect_field "$cid" '{{range .Mounts}}{{if eq .Destination "'"$_GCP_MOUNT"'"}}{{.RW}}{{end}}{{end}}')"
  mtype="$(_gcp_inspect_field "$cid" '{{range .Mounts}}{{if eq .Destination "'"$_GCP_MOUNT"'"}}{{.Type}}{{end}}{{end}}')"
  # Only the one variable's entry is emitted; every other Config.Env entry is dropped inside the template.
  env="$(_gcp_inspect_field "$cid" '{{range .Config.Env}}{{$p := split . "="}}{{if eq (index $p 0) "'"$_GCP_ENV_NAME"'"}}{{.}}{{end}}{{end}}')"
  env="${env#"$_GCP_ENV_NAME"=}"
  user="$(_gcp_inspect_field "$cid" '{{.Config.User}}')"
  wd="$(_gcp_inspect_field "$cid" '{{index .Config.Labels "com.docker.compose.project.working_dir"}}')"
  local present=false ro=false
  [ -n "$src" ] && present=true
  [ "$rw" = false ] && ro=true
  printf '{"running":true,"service":"%s","containerId":"%s","startedAt":"%s","workingDir":%s,"mount":{"present":%s,"source":%s,"readOnly":%s,"type":%s},"env":{"%s":%s},"user":%s}\n' \
    "$_GCP_SERVICE" "$(_gcp_esc "$cid")" "$(_gcp_esc "$started")" "$(_gcp_q "$wd")" "$present" "$(_gcp_q "$src")" "$ro" \
    "$(_gcp_q "$mtype")" "$_GCP_ENV_NAME" "$(_gcp_q "$env")" "$(_gcp_q "$user")"
}

# _gcp_container_file <cid> <path> -> the file's bytes via `cp … -`. Used ONLY for /etc/passwd and /etc/group
# of the backend image (to turn "backenduser" into numbers) — never for anything under /devkit-gcloud.
_gcp_container_file() { "${RUNTIME:?}" cp "$1:$2" - 2>/dev/null | tar -xOf - 2>/dev/null; }

# _gcp_resolve_user <cid> <Config.User> -> "uid:gid" on stdout, or return 1 when it cannot be resolved.
# The helper's own passwd is busybox's, so a NAME would resolve to nothing (or to another uid) there; the
# numbers must come from the backend image's own files.
_gcp_resolve_user() {
  local cid="$1" spec="$2" u g pw gr
  u="${spec%%:*}"; g=""
  [ "$u" != "$spec" ] && g="${spec#*:}"
  [ -n "$u" ] || u=0
  if ! printf '%s' "$u" | grep -qE '^[0-9]+$'; then
    pw="$(_gcp_container_file "$cid" /etc/passwd | awk -F: -v n="$u" '$1==n{print $3":"$4; exit}')"
    [ -n "$pw" ] || return 1
    u="${pw%%:*}"
    [ -n "$g" ] || g="${pw#*:}"
  fi
  if [ -z "$g" ]; then
    g="$(_gcp_container_file "$cid" /etc/passwd | awk -F: -v u="$u" '$3==u{print $4; exit}')"
    [ -n "$g" ] || g=0
  elif ! printf '%s' "$g" | grep -qE '^[0-9]+$'; then
    g="$(_gcp_container_file "$cid" /etc/group | awk -F: -v n="$g" '$1==n{print $3; exit}')"
    [ -n "$g" ] || return 1
  fi
  printf '%s:%s' "$u" "$g"
}

# The probe script runs in busybox sh as the backend's uid:gid. It prints key=value lines and NEVER file bytes:
# grep -q is silent, sha256sum prints only the digest.
_GCP_PROBE_SCRIPT='d="$1"; f="$1/$2"
if [ ! -d "$d" ]; then echo state=no-mount; exit 0; fi
if [ ! -x "$d" ]; then echo state=dir-not-traversable; exit 0; fi
if [ ! -e "$f" ]; then echo state=missing; exit 0; fi
if [ ! -f "$f" ]; then echo state=not-regular; exit 0; fi
if [ ! -r "$f" ]; then echo state=unreadable; exit 0; fi
echo state=ok
if grep -q "\"type\"[[:space:]]*:[[:space:]]*\"authorized_user\"" "$f" 2>/dev/null; then echo type=authorized_user; else echo type=other; fi
echo "sha256=$(sha256sum "$f" 2>/dev/null | cut -d" " -f1)"'

gcp_auth_probe() {
  local cid user ug out st ty sh detail rc
  cid="$(gcp_auth_container)"
  [ -n "$cid" ] || { _gcp_die "no running '$_GCP_SERVICE' container in compose project '$(runtime_compose_project)' — start the stack with ./run.sh"; return 3; }
  user="$(_gcp_inspect_field "$cid" '{{.Config.User}}')"
  if ! ug="$(_gcp_resolve_user "$cid" "$user")"; then
    printf '{"state":"user-unresolved","user":%s,"uid":null,"sha256":null,"type":null}\n' "$(_gcp_q "$user")"
    return 0
  fi
  rc=0
  out="$("$RUNTIME" run --rm --user "$ug" --network none --volumes-from "$cid:ro" "$_GCP_HELPER_IMAGE" \
         sh -c "$_GCP_PROBE_SCRIPT" sh "$_GCP_MOUNT" "$_GCP_FILE_NAME" 2>/dev/null)" || rc=$?
  st="$(printf '%s\n' "$out" | sed -n 's/^state=//p' | head -1)"
  ty="$(printf '%s\n' "$out" | sed -n 's/^type=//p' | head -1)"
  sh="$(printf '%s\n' "$out" | sed -n 's/^sha256=//p' | head -1)"
  case "$st" in ok|no-mount|dir-not-traversable|missing|not-regular|unreadable) ;; *) st=helper-failed; detail="the helper container exited $rc without a verdict" ;; esac
  case "$ty" in authorized_user|other) ;; *) ty="" ;; esac
  printf '%s' "$sh" | grep -qE '^[0-9a-f]{64}$' || sh=""
  printf '{"state":"%s","user":%s,"uid":"%s","type":%s,"sha256":%s,"detail":%s}\n' \
    "$st" "$(_gcp_q "$user")" "$(_gcp_esc "$ug")" "$(_gcp_q "$ty")" "$(_gcp_q "$sh")" "$(_gcp_q "${detail-}")"
}

gcp_auth_prepare() {
  local d created=false
  d="$(runtime_gcloud_dir)" || return 1
  if [ -e "$d" ] && [ ! -d "$d" ]; then _gcp_die "$d exists but is not a directory; set DEVKIT_GCLOUD_DIR to your gcloud config directory"; return 1; fi
  if [ ! -d "$d" ]; then mkdir -p "$d" || { _gcp_die "cannot create $d"; return 1; }; created=true; fi
  printf '{"dir":"%s","created":%s}\n' "$(_gcp_esc "$d")" "$created"
}

# _gcp_assert_ours <cid> -> refuse to act on a studio container that compose started from ANOTHER checkout
# (two checkouts with the same directory name share a default project name).
_gcp_assert_ours() {
  local wd here
  wd="$(_gcp_inspect_field "$1" '{{index .Config.Labels "com.docker.compose.project.working_dir"}}')"
  [ -n "$wd" ] || return 0                       # a runtime that does not label the directory: nothing to compare
  here="$(pwd -P)"
  if [ "$wd" != "$here" ] && [ "$(cd "$wd" 2>/dev/null && pwd -P)" != "$here" ]; then
    _gcp_die "the running $_GCP_SERVICE belongs to the compose project in $wd, not this checkout ($here); refusing to recreate or restart it. Run connect-cloud from that checkout."
    return 1
  fi
}

# gcp_auth_wait <previous container id> <previous startedAt> -> 0 once the backend is running (and, when a
# previous marker is given, is a NEW start) and answers /healthz; 1 after a bounded wait.
gcp_auth_wait() {
  local prev_id="${1-}" prev_start="${2-}" limit="${CONNECT_CLOUD_GCP_WAIT_SECONDS:-120}" step="${CONNECT_CLOUD_GCP_WAIT_INTERVAL:-3}"
  local base="${DUPLO_BASE:-http://localhost:$(_runtime_envv STUDIO_PORT)}" waited=0 cid started
  base="${base%/}"
  while :; do
    cid="$(gcp_auth_container)"
    if [ -n "$cid" ]; then
      started="$(_gcp_inspect_field "$cid" '{{.State.StartedAt}}')"
      if { [ -z "$prev_id" ] || [ "$cid" != "$prev_id" ] || [ "$started" != "$prev_start" ]; } \
         && curl -fsS --max-time 4 "$base/healthz" >/dev/null 2>&1; then
        return 0
      fi
    fi
    [ "$waited" -ge "$limit" ] && break
    sleep "$step"; waited=$((waited + step))
  done
  _gcp_die "the backend did not become healthy within ${limit}s (waited on $base/healthz); check: $RUNTIME logs <$_GCP_SERVICE container>. Only this service was touched."
}

gcp_auth_reconcile() {
  local cid started
  cid="$(gcp_auth_container)"
  [ -n "$cid" ] || { _gcp_die "no running '$_GCP_SERVICE' container in compose project '$(runtime_compose_project)' — start the stack with ./run.sh"; return 3; }
  _gcp_assert_ours "$cid" || return 1
  started="$(_gcp_inspect_field "$cid" '{{.State.StartedAt}}')"
  gcp_auth_prepare >/dev/null || return 1
  echo "==> Recreating ONLY $_GCP_SERVICE so it binds the gcloud directory (compose up -d --no-deps --no-build --pull never)…" >&2
  runtime_compose up -d --no-deps --no-build --pull never "$_GCP_SERVICE" >&2 || { _gcp_die "compose could not recreate $_GCP_SERVICE"; return 1; }
  gcp_auth_wait "$cid" "$started" || return 1
  printf '{"ok":true,"action":"recreated"}\n'
}

gcp_auth_restart() {
  local cid started
  cid="$(gcp_auth_container)"
  [ -n "$cid" ] || { _gcp_die "no running '$_GCP_SERVICE' container in compose project '$(runtime_compose_project)' — start the stack with ./run.sh"; return 3; }
  _gcp_assert_ours "$cid" || return 1
  started="$(_gcp_inspect_field "$cid" '{{.State.StartedAt}}')"
  echo "==> Restarting ONLY $_GCP_SERVICE so its Google credential lookup starts fresh…" >&2
  runtime_compose restart "$_GCP_SERVICE" >&2 || { _gcp_die "compose could not restart $_GCP_SERVICE"; return 1; }
  gcp_auth_wait "$cid" "$started" || return 1
  printf '{"ok":true,"action":"restarted"}\n'
}

gcp_auth_main() {
  case "${1-}" in
    dir)       gcp_auth_dir ;;
    inspect)   gcp_auth_inspect ;;
    probe)     gcp_auth_probe ;;
    prepare)   gcp_auth_prepare ;;
    reconcile) gcp_auth_reconcile ;;
    restart)   gcp_auth_restart ;;
    *) echo "unknown _gcp op '${1-}' (dir|inspect|probe|prepare|reconcile|restart)" >&2; return 2 ;;
  esac
}
