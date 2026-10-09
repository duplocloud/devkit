#!/usr/bin/env bash
# Checks that the UI's nginx config is runtime-agnostic — specifically that the DNS resolver it proxies
# through is discovered at run time rather than hard-coded to one container runtime's address.
#
# Static checks only: nothing here starts the stack or needs docker/podman installed, so it runs the
# same on a docker laptop, a podman box and CI.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
PASS=0; FAIL=0
t()   { printf '  %s … ' "$1"; }
ok()  { echo "ok"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

CONF=nginx/default.conf
COMPOSE=docker-compose.yml

echo "UI nginx resolver is runtime-agnostic:"

# 127.0.0.11 is Docker's embedded DNS and does not exist under podman, whose aardvark-dns sits on the
# network gateway (10.89.0.1 on a default install, but it varies by network). Hard-coding either one
# breaks the other runtime: the SPA still serves, every proxied API call fails, and the login page is
# simply inert — the worst shape of broken.
t "nginx conf does not hard-code a runtime-specific DNS address"
if grep -qE 'resolver[[:space:]]+(127\.0\.0\.11|10\.[0-9]+\.[0-9]+\.[0-9]+)' "$CONF"; then
  bad "resolver is pinned to one runtime's DNS: $(grep -E '^[[:space:]]*resolver' "$CONF" | tr -d ' ')"
else ok; fi

t "nginx conf carries a resolver placeholder for substitution"
grep -qE '^[[:space:]]*resolver[[:space:]]+__RESOLVER__' "$CONF" && ok || bad "no __RESOLVER__ placeholder"

t "compose defines an init service that renders the conf"
grep -qE '^[[:space:]]*init-nginx-conf:' "$COMPOSE" && ok || bad "no init-nginx-conf service"

# Extract ONLY the service definition, from its own key to the next top-level service. A plain
# `grep -A<n>` also matches the depends_on reference in duplo-ui and runs off the end into the next
# service, which made this file's first draft report xterm's ${XTERM_TAG} as an unescaped variable.
svc_block() { awk '/^  init-nginx-conf:$/{f=1;next} f&&/^  [a-z]/{exit} f' "$COMPOSE"; }

t "the init service discovers DNS from its own resolv.conf, not a literal"
if svc_block | grep -q '/etc/resolv.conf'; then ok
else bad "init does not read /etc/resolv.conf"; fi

t "duplo-ui waits for the render to complete before starting"
if grep -A22 'duplo-ui:' "$COMPOSE" | grep -A2 'init-nginx-conf:' | grep -q 'service_completed_successfully'; then ok
else bad "duplo-ui does not depend on init-nginx-conf completing"; fi

# Compose interpolates $VAR inside `command:` before the shell ever sees it, so a shell variable must be
# written $$VAR. Getting this wrong yields an empty resolver and nginx fails to load the conf at all.
t "shell variables in the init command are escaped for compose interpolation"
BLOCK="$(svc_block)"
if printf '%s' "$BLOCK" | grep -qE '(^|[^$])\$[A-Za-z{(]'; then
  bad "unescaped \$ in the init command — compose will interpolate it away"
else ok; fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
