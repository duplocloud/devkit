#!/usr/bin/env bash
# Checks that docker-compose.yml, .env.example, run.sh and the README wire the extension installer in.
#
# The static checks need nothing installed. The rendered checks run `$RUNTIME compose config` against a copy of the
# compose file and a fixture .env in a temp directory, so they never read your .env, pull or start anything. They need
# Docker Compose's `config --format json`, which podman-compose lacks, and are skipped without it.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
PASS=0; FAIL=0; SKIP=0
t()   { printf '  %s … ' "$1"; }
ok()  { echo "ok"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

COMPOSE=docker-compose.yml

echo "installer wiring, static:"

TAG="$(grep -E '^INSTALLER_TAG=' .env.example | head -1 | cut -d= -f2-)"

# The compose default is what a `docker compose up` runs until run.sh adopts INSTALLER_TAG into .env, so it has to stay
# .env.example's pin.
t "compose defines an installer service on the published installer image, defaulting to .env.example's pin"
IMAGE="quay.io/duplocloud/helpdesk-installer:\${INSTALLER_TAG:-$TAG}"
if awk '/^  installer:$/{f=1;next} f&&/^  [a-z]/{exit} f' "$COMPOSE" | grep -qxF "    image: $IMAGE"; then ok
else bad "no installer service with image $IMAGE"; fi

# A floating tag would move under a developer with every compose pull, and run.sh's adoption could never tell a new
# default from an old one.
t ".env.example pins INSTALLER_TAG to an immutable build"
case "$TAG" in
  ""|latest|main) bad "INSTALLER_TAG is '${TAG:-unset}'" ;;
  *) ok ;;
esac

t "run.sh adopts INSTALLER_TAG through DEFAULT_KEYS"
if grep -E '^DEFAULT_KEYS=' run.sh | grep -qw INSTALLER_TAG; then ok; else bad "INSTALLER_TAG is not in DEFAULT_KEYS"; fi

t "the image architecture check covers the installer image"
if grep -q '"duplocloud/helpdesk-installer:INSTALLER_TAG"' scripts/check-image-arches.sh; then ok
else bad "scripts/check-image-arches.sh IMAGES has no helpdesk-installer line"; fi

# A bind source the runtime has to create comes out root-owned under rootful docker on Linux, and then neither
# fetch-terraform-extension.sh nor a build can write extensions/.
t "run.sh creates extensions/ before the stack starts"
MK="$(grep -n '^mkdir -p extensions$' run.sh | head -1 | cut -d: -f1)"
UP="$(grep -n 'compose up -d$' run.sh | head -1 | cut -d: -f1)"
if [ -n "$MK" ] && [ -n "$UP" ] && [ "$MK" -lt "$UP" ]; then ok; else bad "no 'mkdir -p extensions' ahead of compose up"; fi

t "README covers installing a local build and from the Available tab"
if grep -q 'extensions/\[name\]/dist/' README.md && grep -q 'Available' README.md \
    && grep -q 'LICENSE_SERVER_URL' README.md; then ok
else bad "README lacks the extensions/[name]/dist/ build, the Available tab or the catalog keys"; fi

# in_readme TEXT -> whether README.md holds TEXT, with its prose line breaks read as spaces.
in_readme() { tr '\n' ' ' < README.md | grep -qF -- "$1"; }

# A zip deploy-extension.sh posts itself leaves the installer no digest to compare, so a same-version rebuild of it
# reads as already installed. The hints name the installer as the load step, and the README says how to get past that.
t "build hints load through the installer, and deploy-extension.sh only without it"
STALE=""
for f in run.sh docs/troubleshooting.md; do
  if ! grep -q 'installer service loads each build' "$f" \
      || grep 'deploy-extension.sh extensions/<name>/dist/extension.zip' "$f" | grep -qv 'without the installer'; then
    STALE="$STALE $f"
  fi
done
if [ -z "$STALE" ]; then ok; else bad "deploy-extension.sh is still the load step in:$STALE"; fi

# The installer bind-mounts extensions/ only, so a sample zip at samples/helloworld/dist never reaches it.
t "a bundled sample still names deploy-extension.sh"
SAMPLE_STALE=""
for f in run.sh docs/getting-started/install.md; do
  grep -q 'deploy-extension.sh samples/helloworld/dist/extension.zip' "$f" || SAMPLE_STALE="$SAMPLE_STALE $f"
done
if [ -z "$SAMPLE_STALE" ]; then ok; else bad "sample load step missing in:$SAMPLE_STALE"; fi

t "README says deploy-extension.sh hands a local build to the installer"
if in_readme "\`./scripts/deploy-extension.sh extensions/[name]/dist/extension.zip\` hands that build to the installer"
then ok; else bad "README lacks the deploy-extension.sh hand-off"; fi

t "README says how a rebuild installs after a load the installer did not make"
if in_readme "After a load it did not make," \
    && in_readme "bump the version or run \`./scripts/remove-extension.sh [id]\` before relying on the installer"
then ok; else bad "README lacks the bump-or-remove step after a load the installer did not make"; fi

t "README says which builds the installer leaves alone and that deploy-extension.sh loads them"
if in_readme "A build already in \`dist/\` when the installer starts, as after \`./run.sh --reset\`, waits for its next rebuild" \
    && in_readme "The installer also leaves alone a build older than the installed version" \
    && in_readme "For a build the installer leaves alone, with the installer stopped"
then ok; else bad "README lacks the builds the installer leaves alone or the deploy-extension.sh fallback for them"; fi

t "README gives the manual recovery for a load that hangs the studio"
if in_readme "docker compose stop duplo-ai-studio" \
    && in_readme "docker compose exec mongo mongosh -u authuser -p \"\$(grep '^MONGO_ROOT_PASSWORD=' .env | cut -d= -f2-)\" \\" \
    && in_readme "--authenticationDatabase admin duplo-ai-helpdesk \\" \
    && in_readme "db.loaded_extensions.updateOne({ExtensionId: \"[id]\", IsCurrent: true}, {\$set: {Status: NumberInt(1)}})" \
    && in_readme "docker compose start duplo-ai-studio" \
    && in_readme 'The rebuild has to differ in content'
then ok; else bad "README lacks the stop, disable-the-row, restart or fixed-rebuild steps"; fi

# The agent API checks a bearer token when CCA_API_AUTH_TOKEN is set and accepts every caller when it is not, so the
# devkit has to mint one. The studio reads the same value as Agent__ApiAuthToken through its env_file.
t "run.sh mints Agent__ApiAuthToken once and --reset blanks it"
if grep -qF '[ -n "$(getenv Agent__ApiAuthToken)" ] || setenv Agent__ApiAuthToken "$(openssl rand -hex 32)"' run.sh \
    && awk '/^if \[ "\$RESET" = 1 \]; then$/{f=1} f&&/^  done$/{exit} f' run.sh | grep -qw Agent__ApiAuthToken; then ok
else bad "run.sh does not mint Agent__ApiAuthToken, or --reset keeps it"; fi

t ".env.example lists Agent__ApiAuthToken for run.sh to fill"
if grep -qx 'Agent__ApiAuthToken=' .env.example; then ok; else bad "no Agent__ApiAuthToken= line"; fi

t "nothing still says the agent API has no authentication"
STALE="$(grep -lE 'API has no authentication|has no authentication and its exec' docker-compose.yml docs/*.md README.md 2>/dev/null | tr '\n' ' ')"
if [ -z "$STALE" ]; then ok; else bad "stale in: $STALE"; fi

echo
t "run.sh generates MONGO_ROOT_PASSWORD once and blanks it on --reset"
grep -qE 'getenv MONGO_ROOT_PASSWORD\)" \] \|\| setenv MONGO_ROOT_PASSWORD "\$\(openssl rand' run.sh \
  && sed -n '/^if \[ "\$RESET" = 1 \]; then/,/^fi/p' run.sh | grep -q 'MONGO_ROOT_PASSWORD' && ok || bad "run.sh"

t "run.sh rotates the password in place over a mongo volume initialised with the old one, and no longer offers keeping it"
grep -q 'rotate_old_mongo_password' run.sh && ! grep -q 'MONGO_ROOT_PASSWORD=authpass' run.sh \
  && sed -n '/^if \[ "\$RESET" = 1 \]; then/,/^fi/p' run.sh | grep -q 'MONGO_ROOT_PASSWORD_PENDING' && ok || bad "run.sh"

# The rotation runs against a stub runtime and a scratch .env, so every branch is taken without a database. The stub
# answers `volume` by whether VOL is set, records `compose up` with the password it was given, and plays mongosh: a password is accepted when it
# equals the one in the state file, and a changeUserPassword eval moves the state file to the value passed in
# MONGO_NEW_PASSWORD. getenv, setenv, compose_project and sleep are stubbed around the functions under test.
rotate_case() {  # rotate_case <VOL:0|1> <accepted password> [pending in .env]
  local d; d="$(mktemp -d)"; R_DIR="$d"
  printf '%s\n' "$2" > "$d/pw"; : > "$d/calls"; : > "$d/env"
  [ -n "${3:-}" ] && printf 'MONGO_ROOT_PASSWORD_PENDING=%s\n' "$3" > "$d/env"
  cat > "$d/rt" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$d/calls"
case "\$1 \$2" in
  "volume ls") exit 0 ;;
  "volume inspect") [ "$1" = 1 ] && [ "\$3" = devkit_mongo_data ] && exit 0; exit 1 ;;
  "compose up") echo "up-env:\${MONGO_ROOT_PASSWORD:-}" >> "$d/calls"; exit 0 ;;
  "compose exec")
    pw=""; new=""; js=""
    while [ \$# -gt 0 ]; do case "\$1" in -p) pw="\$2"; shift ;; -e) new="\${2#MONGO_NEW_PASSWORD=}"; shift ;; --eval) js="\$2"; shift ;; esac; shift; done
    [ "\$pw" = "\$(cat "$d/pw")" ] || exit 1
    case "\$js" in *changeUserPassword*) printf '%s\n' "\$new" > "$d/pw"; echo "change:\$new" >> "$d/calls" ;; esac
    exit 0 ;;
esac
exit 1
EOF
  chmod +x "$d/rt"
  ( RUNTIME="$d/rt"; ENV="$d/env"
    getenv() { grep -E "^$1=" "$ENV" 2>/dev/null | head -1 | cut -d= -f2- || true; }
    setenv() { grep -vE "^$1=" "$ENV" > "$ENV.n" 2>/dev/null || true; printf '%s=%s\n' "$1" "$2" >> "$ENV.n"; mv "$ENV.n" "$ENV"; }
    compose_project() { printf devkit; }; sleep() { :; }
    eval "$(sed -n '/^MONGO_OLD_PASSWORD=/p; /^mongo_eval()/,/^}/p; /^rotate_old_mongo_password()/,/^}/p' run.sh)"
    rotate_old_mongo_password ) >"$d/out" 2>"$d/err"
  R_RC=$?; R_ERR="$(cat "$d/err")"; R_CALLS="$(cat "$d/calls")"
  R_PW="$(grep -E '^MONGO_ROOT_PASSWORD=' "$d/env" | cut -d= -f2-)"; R_PENDING="$(grep -E '^MONGO_ROOT_PASSWORD_PENDING=' "$d/env" | cut -d= -f2-)"
  R_DB="$(cat "$d/pw")"; rm -rf "$d"
}

t "rotation: the run stops when the runtime cannot list volumes"
d="$(mktemp -d)"; printf '%s\n' '#!/bin/sh' 'echo "Cannot connect to the daemon" >&2; exit 1' > "$d/rt"; chmod +x "$d/rt"
( RUNTIME="$d/rt"; getenv() { :; }; compose_project() { printf devkit; }
  eval "$(sed -n '/^rotate_old_mongo_password()/,/^}/p' run.sh)"; rotate_old_mongo_password ) 2>"$d/err"
rc=$?; [ "$rc" -ne 0 ] && grep -q 'Cannot connect to the daemon' "$d/err" && ok || bad "rc=$rc $(cat "$d/err")"; rm -rf "$d"

t "rotation: no such volume leaves .env alone and starts nothing"
rotate_case 0 authpass
[ "$R_RC" -eq 0 ] && [ -z "$R_PW" ] && ! grep -q 'compose up' <<<"$R_CALLS" && ok || bad "rc=$R_RC $R_CALLS"

t "rotation: an old volume gets a generated password applied through the old one, then written to .env"
rotate_case 1 authpass
[ "$R_RC" -eq 0 ] && grep -qE '^change:[0-9a-f]{64}$' <<<"$R_CALLS" && [ "$R_PW" = "$R_DB" ] && [ -n "$R_PW" ] && [ -z "$R_PENDING" ] \
  && grep -q 'compose up -d mongo' <<<"$R_CALLS" && grep -q '^up-env:authpass$' <<<"$R_CALLS" \
  && ok || bad "rc=$R_RC pw=$R_PW db=$R_DB pending=$R_PENDING calls=$R_CALLS $R_ERR"

t "rotation: a pending password the database already answers to is promoted without another change"
rotate_case 1 pend1234 pend1234
[ "$R_RC" -eq 0 ] && ! grep -q '^change:' <<<"$R_CALLS" && [ "$R_PW" = pend1234 ] && [ -z "$R_PENDING" ] \
  && ok || bad "rc=$R_RC pw=$R_PW pending=$R_PENDING calls=$R_CALLS"

t "rotation: a pending password the database does not know yet is applied as is, never replaced by a third"
rotate_case 1 authpass pend1234
[ "$R_RC" -eq 0 ] && grep -q '^change:pend1234$' <<<"$R_CALLS" && [ "$R_PW" = pend1234 ] && [ "$R_DB" = pend1234 ] \
  && ok || bad "rc=$R_RC pw=$R_PW db=$R_DB calls=$R_CALLS"

t "rotation: a database answering to neither password stops the run, writes no password and names --reset"
rotate_case 1 somethingelse
[ "$R_RC" -ne 0 ] && [ -z "$R_PW" ] && ! grep -q '^change:' <<<"$R_CALLS" && grep -qF -- '--reset' <<<"$R_ERR" \
  && ok || bad "rc=$R_RC pw=$R_PW calls=$R_CALLS $R_ERR"

t "rotation: a failed password change writes nothing to .env"
d="$(mktemp -d)"; : > "$d/env"
cat > "$d/rt" <<EOF
#!/usr/bin/env bash
case "\$1 \$2" in "volume ls"|"compose up") exit 0 ;; "volume inspect") exit 0 ;;
  "compose exec") case "\$*" in *changeUserPassword*) exit 1 ;; *" -p authpass "*) exit 0 ;; esac; exit 1 ;; esac; exit 1
EOF
chmod +x "$d/rt"
( RUNTIME="$d/rt"; ENV="$d/env"
  getenv() { grep -E "^$1=" "$ENV" 2>/dev/null | head -1 | cut -d= -f2- || true; }
  setenv() { grep -vE "^$1=" "$ENV" > "$ENV.n" 2>/dev/null || true; printf '%s=%s\n' "$1" "$2" >> "$ENV.n"; mv "$ENV.n" "$ENV"; }
  compose_project() { printf devkit; }; sleep() { :; }
  eval "$(sed -n '/^MONGO_OLD_PASSWORD=/p; /^mongo_eval()/,/^}/p; /^rotate_old_mongo_password()/,/^}/p' run.sh)"
  rotate_old_mongo_password ) >/dev/null 2>"$d/err"
rc=$?; [ "$rc" -ne 0 ] && ! grep -q '^MONGO_ROOT_PASSWORD=.' "$d/env" && grep -q '^MONGO_ROOT_PASSWORD_PENDING=.' "$d/env" \
  && ok || bad "rc=$rc $(cat "$d/env") $(cat "$d/err")"; rm -rf "$d"

t ".env.example lists MONGO_ROOT_PASSWORD with the stable secrets"
grep -qE '^MONGO_ROOT_PASSWORD=$' .env.example && ok || bad ".env.example"

t "no file carries the old fixed mongo password, except as the constant the rotation tries"
left="$(grep -rIn --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=dist 'authpass' . \
  | grep -v '^./run.sh:[0-9]*:MONGO_OLD_PASSWORD=authpass' | grep -v '^./tests/test-installer-wiring.sh:')"
[ -z "$left" ] && ok || bad "$(printf '%s' "$left" | cut -d: -f1,2 | tr '\n' ' ')"

t "README's mongosh recovery reads the password from .env"
in_readme 'mongosh -u authuser -p "$(grep' && in_readme 'MONGO_ROOT_PASSWORD' && ok || bad "README.md"

t "configuration.md and cli-reference.md list MONGO_ROOT_PASSWORD with the generated secrets"
grep -q '`MONGO_ROOT_PASSWORD`' docs/configuration.md && grep -q '`MONGO_ROOT_PASSWORD`' docs/cli-reference.md && ok || bad "docs"

echo "installer wiring, rendered:"

. scripts/_runtime.sh
if ! runtime_resolve 2>/dev/null || ! "$RUNTIME" compose version 2>/dev/null | grep -q 'Docker Compose' \
    || ! command -v python3 >/dev/null 2>&1; then
  echo "  skipped: needs a Docker Compose implementation and python3"
  SKIP=1
else
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  cp "$COMPOSE" "$TMP/docker-compose.yml"

  # render [.env lines…] -> the resolved config as JSON, from the fixture alone, never the caller's environment.
  render() {
    printf '%s\n' "$@" > "$TMP/.env"
    (cd "$TMP" && env -i PATH="$PATH" HOME="$HOME" ${XDG_RUNTIME_DIR:+"XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR"} \
      "$RUNTIME" compose config --format json 2>"$TMP/err")
  }

  # check MODE < json -> one "PASS|label" or "FAIL|label|detail" line per check.
  check() {
    python3 -c '
import json, sys
mode = sys.argv[1]
d = json.load(sys.stdin)
svc = d.get("services", {})
inst, studio, perms = svc.get("installer", {}), svc.get("duplo-ai-studio", {}), svc.get("init-perms", {})
env = inst.get("environment") or {}
def out(label, good, detail=""):
    print(("PASS|%s" % label) if good else ("FAIL|%s|%s" % (label, detail)))
def unset(k):
    return env.get(k) in (None, "")
if mode == "set":
    out("installer image follows INSTALLER_TAG", inst.get("image") == "quay.io/duplocloud/helpdesk-installer:fixture-tag",
        inst.get("image"))
    for k, v in (("INSTALLER_PLATFORM", "compose"), ("INSTALLER_BACKEND_URL", "http://duplo-ai-studio:60021"),
                 ("INSTALLER_STATE_DIR", "/var/lib/installer"), ("INSTALLER_LOCAL_DIR", "/extensions")):
        out("installer %s=%s" % (k, v), env.get(k) == v, env.get(k))
    out("installer reports the image the studio runs", env.get("INSTALLER_BACKEND_IMAGE") == studio.get("image"),
        "%s vs %s" % (env.get("INSTALLER_BACKEND_IMAGE"), studio.get("image")))
    out("JWT secret comes from .env", env.get("Authentication__JwtSharedSecret") == "fixture-secret",
        env.get("Authentication__JwtSharedSecret"))
    out("license token comes from .env", env.get("Licensing__Token") == "fixture-license", env.get("Licensing__Token"))
    out("an optional selection key passes through from .env", env.get("EXTENSIONS_EXCLUDE") == "[\"a.b\"]",
        env.get("EXTENSIONS_EXCLUDE"))
    out("a catalog key passes through from .env", env.get("LICENSE_SERVER_URL") == "https://license.example",
        env.get("LICENSE_SERVER_URL"))
    leaked = [k for k in ("ANTHROPIC_API_KEY", "AWS_SECRET_ACCESS_KEY", "Authentication__LocalAdminPassword",
                          "Encryption__MasterKey") if k in env]
    out("installer receives no LLM or admin credentials", not leaked and not inst.get("env_file"), ",".join(leaked))
    mounts = inst.get("volumes") or []
    state = [m for m in mounts if m.get("target") == "/var/lib/installer"]
    out("state lives on a named volume", len(state) == 1 and state[0].get("type") == "volume"
        and state[0].get("source") in (d.get("volumes") or {}), state)
    src = state[0].get("source") if state else None
    pm = [m.get("target") for m in perms.get("volumes") or [] if m.get("source") == src]
    cmd = " ".join(perms.get("command") or [])
    out("init-perms chowns the state volume to the distroless nonroot user",
        len(pm) == 1 and ("chown -R 65532:65532 %s" % pm[0]) in cmd, "%s / %s" % (pm, cmd))
    dep = (inst.get("depends_on") or {}).get("init-perms") or {}
    out("installer waits for init-perms", dep.get("condition") == "service_completed_successfully", dep)
    local = [m for m in mounts if m.get("target") == "/extensions"]
    out("extensions/ is mounted read-only", len(local) == 1 and local[0].get("type") == "bind"
        and local[0].get("read_only") is True and local[0].get("source", "").endswith("/extensions"), local)
    out("installer publishes no host port", not inst.get("ports"), inst.get("ports"))
    agent = svc.get("claude-code-agent", {})
    out("agent publishes no host port", not agent.get("ports"), agent.get("ports"))
    mports = svc.get("mongo", {}).get("ports") or []
    out("mongo publishes on loopback only", bool(mports) and all(p.get("host_ip") == "127.0.0.1" for p in mports), mports)
    xterm = svc.get("xterm", {})
    xports = xterm.get("ports") or []
    out("xterm publishes on loopback only", bool(xports) and all(p.get("host_ip") == "127.0.0.1" for p in xports), xports)
    xenv = xterm.get("environment") or {}
    out("xterm allows only the portal origins on UI_PORT and sets no CORS_ORIGIN",
        xenv.get("ALLOWED_ORIGINS") == "http://localhost:4321,http://127.0.0.1:4321" and "CORS_ORIGIN" not in xenv, xenv)
    senv = studio.get("environment") or {}
    out("studio calls the installer on the compose network", senv.get("Extensions__InstallerUrl") == "http://installer:8080",
        senv.get("Extensions__InstallerUrl"))
    menv = svc.get("mongo", {}).get("environment") or {}
    out("mongo root password comes from .env", menv.get("MONGO_INITDB_ROOT_PASSWORD") == "fixture-mongo",
        menv.get("MONGO_INITDB_ROOT_PASSWORD"))
    out("studio connects to mongo with the generated password",
        senv.get("MongoDB__ConnectionString") == "mongodb://authuser:fixture-mongo@mongo:27017/?retryWrites=false",
        senv.get("MongoDB__ConnectionString"))
    out("installer never receives the mongo password", unset("MONGO_ROOT_PASSWORD"), env.get("MONGO_ROOT_PASSWORD"))
    aenv = agent.get("environment") or {}
    out("agent enforces the API token from .env", aenv.get("CCA_API_AUTH_TOKEN") == "fixture-agent-token",
        aenv.get("CCA_API_AUTH_TOKEN"))
    out("studio sends the same API token", senv.get("Agent__ApiAuthToken") == "fixture-agent-token",
        senv.get("Agent__ApiAuthToken"))
    out("installer receives no agent API token", "Agent__ApiAuthToken" not in env and "CCA_API_AUTH_TOKEN" not in env, env.keys())
else:
    out("EXTENSIONS_ENABLED defaults to true", env.get("EXTENSIONS_ENABLED") == "true", env.get("EXTENSIONS_ENABLED"))
    out("EXTENSIONS_SOURCE defaults to customer", env.get("EXTENSIONS_SOURCE") == "customer", env.get("EXTENSIONS_SOURCE"))
    for k in ("LICENSE_SERVER_URL", "URL_ROUTE_URL", "CHANNELS_BASE_URL", "CHANNELS_BUCKET", "EXTENSIONS_EXCLUDE",
              "EXTENSIONS_ENROLLMENT_ID"):
        out("%s stays unset by default" % k, unset(k), env.get(k))
    xenv = svc.get("xterm", {}).get("environment") or {}
    out("xterm origins default to the unoffset portal port", xenv.get("ALLOWED_ORIGINS") == "http://localhost:4200,http://127.0.0.1:4200",
        xenv.get("ALLOWED_ORIGINS"))
' "$1"
  }

  tally() {
    local line label detail
    while IFS= read -r line; do
      label="${line#*|}"; label="${label%%|*}"
      t "$label"
      case "$line" in
        PASS\|*) ok ;;
        *) detail="${line#FAIL|*|}"; bad "$detail" ;;
      esac
    done
  }

  if J="$(render INSTALLER_TAG=fixture-tag STUDIO_TAG=studio-fixture UI_PORT=4321 Authentication__JwtSharedSecret=fixture-secret \
        Agent__ApiAuthToken=fixture-agent-token Licensing__Token=fixture-license 'EXTENSIONS_EXCLUDE=["a.b"]' LICENSE_SERVER_URL=https://license.example \
        ANTHROPIC_API_KEY=sk-fixture AWS_SECRET_ACCESS_KEY=aws-fixture Authentication__LocalAdminPassword=pw \
        Encryption__MasterKey=mk MONGO_ROOT_PASSWORD=fixture-mongo)"; then
    tally < <(printf '%s' "$J" | check set)
  else
    t "compose config renders with every key set"; bad "$(head -3 "$TMP/err" | tr '\n' ' ')"
  fi

  if J="$(render INSTALLER_TAG=fixture-tag STUDIO_TAG=studio-fixture)"; then
    tally < <(printf '%s' "$J" | check unset)
  else
    t "compose config renders with the optional keys unset"; bad "$(head -3 "$TMP/err" | tr '\n' ' ')"
  fi
fi

echo
echo "$PASS passed, $FAIL failed$([ "$SKIP" = 1 ] && echo ', rendered checks skipped')"
[ "$FAIL" -eq 0 ]
