# shellcheck shell=bash
# Sourced by scripts/connect-cloud.sh — the cloud credential store.
#
# The store is the compose named volume mounted READ-ONLY into duplo-ai-studio at /devkit-auth from
# its first start (docker-compose.yml: `cloud_auth`). Writing into it never touches the studio or
# agent containers: a short-lived busybox helper mounts the same volume read-write, runs as uid 1001
# (the studio's user) with umask 077, and copies the file from ITS STDIN. The secret bytes therefore
# never appear in an argument list, an environment variable, or a host file this kit controls.
#
# WHICH volume is never guessed from a name: it is read from the running studio container's own
# /devkit-auth mount (`inspect`), so whatever project name compose used — from the environment, from
# .env, or from the directory — the helper writes where the studio reads. No running studio, or a
# studio without that mount (an older compose file), is a hard error: writing anywhere else would
# only create a credential nobody reads.
#
# WHY a volume and not a host directory: a 0700 host directory owned by you is unreadable by uid 1001
# inside the studio on Linux (rootful docker maps ids 1:1; rootless podman maps 1001 to a subuid), and
# the only ways to make it readable are a world-readable mode or chowning your files away — both
# unacceptable for credentials. init-perms chowns the volume to 1001 at every start.
#
# Expects RUNTIME to be resolved (scripts/_runtime.sh: runtime_resolve) and the compose project to be
# the caller's cwd (runtime_compose_project, which honours COMPOSE_PROJECT_NAME from the environment
# or .env).

_CLOUD_AUTH_IMAGE="busybox:1.36"       # same image init-perms already pulled, so nothing new is fetched
_CLOUD_AUTH_UID="1001:1001"
_CLOUD_AUTH_MOUNT="/devkit-auth"
_CLOUD_AUTH_SERVICE="duplo-ai-studio"

# cloud_auth_studio_container -> the id of this project's running studio container, or empty.
cloud_auth_studio_container() {
  "${RUNTIME:?}" ps -q \
      --filter "label=com.docker.compose.project=$(runtime_compose_project)" \
      --filter "label=com.docker.compose.service=$_CLOUD_AUTH_SERVICE" 2>/dev/null | head -1
}

# cloud_auth_volume -> the name of the volume the running studio has mounted at /devkit-auth.
# Memoised per process. Returns 1 (with a message on stderr) when it cannot be determined.
cloud_auth_volume() {
  if [ -n "${_CLOUD_AUTH_VOLUME:-}" ]; then printf '%s' "$_CLOUD_AUTH_VOLUME"; return 0; fi
  local cid vol
  cid="$(cloud_auth_studio_container)"
  if [ -z "$cid" ]; then
    echo "no running '$_CLOUD_AUTH_SERVICE' container in compose project '$(runtime_compose_project)' — start the stack with ./run.sh" >&2
    echo "(the project name comes from COMPOSE_PROJECT_NAME in the environment or .env, else this directory's name)" >&2
    return 1
  fi
  vol="$("${RUNTIME:?}" inspect --format '{{range .Mounts}}{{if eq .Destination "'"$_CLOUD_AUTH_MOUNT"'"}}{{.Name}}{{end}}{{end}}' "$cid" 2>/dev/null)"
  if [ -z "$vol" ]; then
    echo "the running studio ($cid) has no volume mounted at $_CLOUD_AUTH_MOUNT — its compose definition predates the cloud credential store; re-run ./run.sh with the current docker-compose.yml" >&2
    return 1
  fi
  _CLOUD_AUTH_VOLUME="$vol"
  printf '%s' "$vol"
}

# _cloud_auth_rel_ok <rel> -> 0 when <rel> is a safe relative path inside the store: lowercase segments
# of [a-z0-9_.-], no leading dot, no '..', no absolute path. The backend applies its own, stricter
# rule to the adcRef it is handed; this one only keeps the helper from writing outside the mount.
_cloud_auth_rel_ok() {
  printf '%s' "$1" | grep -qE '^[a-z0-9][a-z0-9_-]*(/[a-z0-9][a-z0-9_.-]*)*$'
}

# cloud_auth_exists -> 0 when the studio is running with the store mounted.
cloud_auth_exists() { cloud_auth_volume >/dev/null 2>&1; }

# _cloud_auth_run <extra run flags…> -- <sh -c script> <args…>
_cloud_auth_run() {
  local vol; vol="$(cloud_auth_volume)" || return 3
  local flags=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do flags+=("$1"); shift; done
  shift
  # ${flags[@]+"${flags[@]}"}: an EMPTY array expanded as "${flags[@]}" is an "unbound variable" under
  # `set -u` on bash 3.2 (macOS /bin/bash), which killed the flagless list/remove paths when the caller
  # runs with `set -euo pipefail`. This idiom expands to nothing for an empty array and to the exact,
  # individually quoted elements otherwise (so `-i` for the stdin write path is preserved as its own word).
  "${RUNTIME:?}" run --rm --user "$_CLOUD_AUTH_UID" ${flags[@]+"${flags[@]}"} \
      -v "$vol:$_CLOUD_AUTH_MOUNT" "$_CLOUD_AUTH_IMAGE" sh -c "$@"
}

# cloud_auth_write <rel>  (secret on stdin) -> writes <rel> into the store atomically (tmp + mv), mode 0600,
# owner 1001. Prints nothing on success. The helper is `run --rm`, so it leaves no container behind.
cloud_auth_write() {
  local rel="$1"
  _cloud_auth_rel_ok "$rel" || { echo "cloud_auth_write: refusing unsafe path '$rel'" >&2; return 2; }
  _cloud_auth_run -i -- \
      'umask 077; f="$1/$2"; d="$(dirname "$f")"; mkdir -p "$d" && cat > "$f.tmp" && chmod 0600 "$f.tmp" && mv -f "$f.tmp" "$f"' \
      sh "$_CLOUD_AUTH_MOUNT" "$rel"
}

# cloud_auth_remove <rel> -> deletes one file from the store (missing is not an error).
cloud_auth_remove() {
  local rel="$1"
  _cloud_auth_rel_ok "$rel" || { echo "cloud_auth_remove: refusing unsafe path '$rel'" >&2; return 2; }
  _cloud_auth_run -- 'rm -f "$1/$2"' sh "$_CLOUD_AUTH_MOUNT" "$rel"
}

# cloud_auth_list -> one "<mode> <readable|UNREADABLE> <rel>" line per file, as uid 1001 sees them. Names
# only, never contents — this is what `connect-cloud.sh status` prints to prove readability by the
# studio's uid.
cloud_auth_list() {
  _cloud_auth_run -- \
      'cd "$1" && find . -type f | sed "s|^\./||" | while read -r f; do if [ -r "$f" ]; then r=readable; else r=UNREADABLE; fi; printf "%s %s %s\n" "$(stat -c %a "$f" 2>/dev/null || echo ?)" "$r" "$f"; done' \
      sh "$_CLOUD_AUTH_MOUNT"
}
