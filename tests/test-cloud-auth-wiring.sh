#!/usr/bin/env bash
# Checks that docker-compose.yml, run.sh and the scripts wire the cloud credential store and the
# shell-shadow fix in.
#
# The static checks need nothing installed. The rendered checks run `$RUNTIME compose config` against a copy of
# the compose file and a fixture .env in a temp directory — never your .env, never a pull or a start. They need
# Docker Compose's `config --format json`, which podman-compose lacks, and are skipped without it.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
PASS=0; FAIL=0; SKIP=0
t()   { printf '  %s … ' "$1"; }
ok()  { echo "ok"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
skip(){ echo "skipped ($1)"; SKIP=$((SKIP+1)); }

COMPOSE=docker-compose.yml
studio() { awk '/^  duplo-ai-studio:$/{f=1;next} f&&/^  [a-z]/{exit} f' "$COMPOSE"; }
initperms() { awk '/^  init-perms:$/{f=1;next} f&&/^  [a-z]/{exit} f' "$COMPOSE"; }

echo "cloud credential store, static:"

t "compose declares the cloud_auth volume"
if awk '/^volumes:$/{f=1;next} f' "$COMPOSE" | grep -qx '  cloud_auth:'; then ok; else bad "no top-level cloud_auth volume"; fi

t "the studio mounts it READ-ONLY at /devkit-auth and points AIStudio__GcpAdcRoot inside it"
if studio | grep -qx '      - cloud_auth:/devkit-auth:ro' && studio | grep -qx '      - AIStudio__GcpAdcRoot=/devkit-auth/gcp'; then ok
else bad "studio mount or AIStudio__GcpAdcRoot missing"; fi

t "the agent does NOT mount the credential store (it only ever gets per-ticket files from the studio)"
if awk '/^  claude-code-agent:$/{f=1;next} f&&/^  [a-z]/{exit} f' "$COMPOSE" | grep -q cloud_auth; then bad "agent mounts cloud_auth"; else ok; fi

t "init-perms owns the store: uid 1001, mode 0700, gcp/ pre-created, no recursive chown of credential files"
IP="$(initperms)"
if grep -q 'cloud_auth:/cloudauth' <<<"$IP" \
   && grep -q 'mkdir -p /cloudauth/gcp && chown 1001:1001 /cloudauth /cloudauth/gcp && chmod 0700 /cloudauth /cloudauth/gcp' <<<"$IP" \
   && ! grep -q 'chown -R [0-9:]* [^&]*cloudauth' <<<"$IP"; then ok
else bad "init-perms store ownership line changed"; fi

t "run.sh and switch-llm.sh start/recreate through runtime_compose and no bare compose up/pull remains"
if grep -qE '^echo "==> Pulling images…"; runtime_compose pull$' run.sh \
   && grep -qE '^echo "==> Starting…"; runtime_compose up -d$' run.sh \
   && ! grep -qE '^[^#]*"\$RUNTIME" compose (up|pull)' run.sh \
   && grep -qx 'runtime_compose up -d claude-code-agent' scripts/switch-llm.sh; then ok
else bad "compose invocation"; fi

t ".gitignore keeps the non-secret connection records out of git; run.sh --reset drops them"
if grep -qx '\.devkit-cloud/' .gitignore && grep -q '^  rm -rf .devkit-cloud$' run.sh; then ok; else bad ".devkit-cloud handling"; fi

echo "runtime_compose behaviour (fake runtime):"
# $RT/rt drops the literal "compose" word and runs sh, so the compose child's view of the environment can be printed.
RT="$(mktemp -d)"; trap 'rm -rf "$RT"' EXIT
printf '#!/bin/sh\nshift\nexec sh "$@"\n' > "$RT/rt"; chmod +x "$RT/rt"
child_env() { # <env assignments> → what the compose child sees for the four keys, as "K=V|K=V|…" ("-" = unset)
  ( export DUPLO_ENV_FILE=/dev/null; eval "$1"
    . ./scripts/_runtime.sh
    RUNTIME="$RT/rt" runtime_compose -c 'for k in ANTHROPIC_API_KEY ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN; do eval "v=\${$k-}"; eval "s=\${$k+set}"; if [ "$s" = set ]; then printf "%s=%s|" "$k" "$v"; else printf "%s=-|" "$k"; fi; done' ) 2>&1
}

t "an exported NON-EMPTY key is removed from the compose child"
R="$(child_env 'export ANTHROPIC_API_KEY=shell-key')"
if [ "$R" = "ANTHROPIC_API_KEY=-|ANTHROPIC_BASE_URL=-|ANTHROPIC_AUTH_TOKEN=-|CLAUDE_CODE_OAUTH_TOKEN=-|" ]; then ok; else bad "got '$R'"; fi

t "an exported EMPTY key is removed too (compose would otherwise resolve it to '' and mask .env)"
R="$(child_env 'export ANTHROPIC_API_KEY= ANTHROPIC_BASE_URL=')"
if [ "$R" = "ANTHROPIC_API_KEY=-|ANTHROPIC_BASE_URL=-|ANTHROPIC_AUTH_TOKEN=-|CLAUDE_CODE_OAUTH_TOKEN=-|" ]; then ok; else bad "got '$R'"; fi

t "unrelated variables and an unset key are left alone; arguments pass through unchanged"
R="$( ( export DUPLO_ENV_FILE=/dev/null AWS_PROFILE=keep DUPLO_TOKEN=keep; unset ANTHROPIC_API_KEY
        . ./scripts/_runtime.sh
        RUNTIME="$RT/rt" runtime_compose -c 'printf "%s %s %s %s %s" "$AWS_PROFILE" "$DUPLO_TOKEN" "$0" "$1" "$2"' a b c ) 2>&1 )"
if [ "$R" = "keep keep a b c" ]; then ok; else bad "got '$R'"; fi

t "the caller's own variable survives (only the compose process loses it)"
R="$( ( export DUPLO_ENV_FILE=/dev/null ANTHROPIC_API_KEY=shell-key
        . ./scripts/_runtime.sh
        RUNTIME="$RT/rt" runtime_compose -c 'true'; printf '%s' "${ANTHROPIC_API_KEY-unset}" ) 2>&1 )"
if [ "$R" = "shell-key" ]; then ok; else bad "got '$R'"; fi

echo "runtime_compose_project behaviour:"
PJ="$(mktemp -d)/My Project"; mkdir -p "$PJ"
proj() { ( cd "$PJ" && export DUPLO_ENV_FILE="$PJ/.env"; eval "$1"; . "$OLDPWD/scripts/_runtime.sh"; runtime_compose_project ) 2>&1; }
t "defaults to the directory name, compose-sanitized"
: > "$PJ/.env"; R="$(proj 'unset COMPOSE_PROJECT_NAME')"
if [ "$R" = "myproject" ]; then ok; else bad "got '$R'"; fi
t "COMPOSE_PROJECT_NAME from .env only (not exported) is honoured, like compose does"
printf 'COMPOSE_PROJECT_NAME="cloud-onboard-r1"\r\n' > "$PJ/.env"; R="$(proj 'unset COMPOSE_PROJECT_NAME')"
if [ "$R" = "cloud-onboard-r1" ]; then ok; else bad "got '$R'"; fi
t "an exported COMPOSE_PROJECT_NAME wins over .env"
R="$(proj 'export COMPOSE_PROJECT_NAME=from-shell')"
if [ "$R" = "from-shell" ]; then ok; else bad "got '$R'"; fi
rm -rf "$(dirname "$PJ")"

echo "cloud credential store, rendered:"
. ./scripts/_runtime.sh
if ! runtime_resolve 2>/dev/null || ! "$RUNTIME" compose version >/dev/null 2>&1; then
  t "rendering"; skip "no compose"
else
  TMP="$(mktemp -d)"
  cp "$COMPOSE" "$TMP/docker-compose.yml"; mkdir -p "$TMP/nginx" "$TMP/extensions"; cp nginx/default.conf "$TMP/nginx/default.conf"
  render() { # <.env content> <shell env assignments> → agent's ANTHROPIC_API_KEY as compose renders it, or "<<error>>"
    printf '%s\n' "$1" > "$TMP/.env"
    ( cd "$TMP" && eval "$2" && runtime_compose config --format json 2>/dev/null ) \
      | python3 -c 'import sys,json
try: print(json.load(sys.stdin)["services"]["claude-code-agent"]["environment"].get("ANTHROPIC_API_KEY"))
except Exception: print("<<error>>")'
  }
  BASE=$'STUDIO_TAG=t\nUI_TAG=t\nAGENT_TAG=t'
  if [ "$(render "$BASE" 'true')" = "<<error>>" ]; then
    t "rendering"; skip "compose config --format json unavailable"
  else
    t "rendered: shell NON-EMPTY key vs .env configured → .env wins"
    V="$(render "$BASE"$'\nANTHROPIC_API_KEY=from-dotenv' 'export ANTHROPIC_API_KEY=from-shell')"
    if [ "$V" = from-dotenv ]; then ok; else bad "got '$V'"; fi

    t "rendered: shell EMPTY key vs .env configured → .env wins"
    V="$(render "$BASE"$'\nANTHROPIC_API_KEY=from-dotenv' 'export ANTHROPIC_API_KEY=')"
    if [ "$V" = from-dotenv ]; then ok; else bad "got '$V'"; fi

    t "rendered: shell NON-EMPTY key vs .env blank → the agent gets no key (gateway/subscription/bedrock stay in charge)"
    V="$(render "$BASE"$'\nANTHROPIC_API_KEY=' 'export ANTHROPIC_API_KEY=from-shell')"
    if [ "$V" = "" ] || [ "$V" = None ]; then ok; else bad "got '$V'"; fi

    t "rendered: the studio has the read-only /devkit-auth mount and the ADC root; the volume is project-scoped"
    printf '%s\n' "$BASE" > "$TMP/.env"
    R="$( (cd "$TMP" && COMPOSE_PROJECT_NAME=wiringtest runtime_compose config --format json 2>/dev/null) | python3 -c 'import sys,json
d=json.load(sys.stdin); s=d["services"]["duplo-ai-studio"]
m=[v for v in s["volumes"] if v.get("target")=="/devkit-auth"]
print(("ro" if m and m[0].get("read_only") else "rw-or-missing"), s["environment"].get("AIStudio__GcpAdcRoot"), d["volumes"]["cloud_auth"].get("name"))')"
    if [ "$R" = "ro /devkit-auth/gcp wiringtest_cloud_auth" ]; then ok; else bad "got '$R'"; fi
  fi
  rm -rf "$TMP"
fi

echo; echo "cloud auth wiring: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" = 0 ]
