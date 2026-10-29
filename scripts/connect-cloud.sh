#!/usr/bin/env bash
# connect-cloud.sh — connect an AWS account or a GCP project to the running dev kit, deterministically.
#
# Creates (or reuses) the Provider → Credential → Scope chain the backend resolves for a ticket and
# attaches the scope to a workspace, without restarting anything. Re-running with the same --name is
# idempotent; re-running after credentials changed rotates them in place. Every conflict (another
# account under the same name, a credential or scope this tool did not create, a different region, a
# duplicate name, a missing workspace) is detected BEFORE anything is written.
#
#   ./scripts/connect-cloud.sh aws --name test21 --profile test21 [--region us-east-1]
#       Resolves the profile ONCE (`aws configure export-credentials`, which runs the profile's
#       credential_process — e.g. duplo-jit — so it may open a browser), verifies the identity with STS
#       using those same in-memory credentials, and stores them on the provider credential. Temporary
#       credentials expire; re-run the same command (or `refresh --name test21`) to reconnect. No
#       automatic renewal.
#   ./scripts/connect-cloud.sh gcp --name gcp-test9 --project gcp-test9 \
#       --service-account helpdesk-test@gcp-test9.iam.gserviceaccount.com [--adc-source <file>]
#       Keyless: copies your user ADC file (default ~/.config/gcloud/application_default_credentials.json,
#       the one `gcloud auth application-default login` writes) into the credential store under THIS
#       connection's name, after proving — with that exact file — that it can mint an impersonated token
#       for the service account and list the project's buckets. The studio then impersonates per
#       connection (dataEx adcRef), so two connections can carry two Google identities.
#   ./scripts/connect-cloud.sh refresh --name <name>     re-resolve credentials and update in place; prints
#                                                        the studio + agent container ids and start times
#                                                        before and after (fails if either is not running)
#   ./scripts/connect-cloud.sh verify  --name <name>     prove the backend can expand the scope (AWS) / the
#                                                        bootstrap still works (GCP); no ticket, no LLM
#   ./scripts/connect-cloud.sh status [--json]           every connection: ids, expiry, store readability
#
# Common flags: --workspace <id> (default EXTENSION_DEV_WORKSPACE_ID from .env; required unless
# --no-workspace), --json (machine output), --dry-run (print what would change, write nothing). Secrets
# never appear in arguments, logs or the connection records (.devkit-cloud/connections.json); they
# travel on stdin and in request bodies only.
#
# The credential store is whatever volume the RUNNING studio has mounted at /devkit-auth (read from the
# container, never guessed from a name), so a checkout that sets COMPOSE_PROJECT_NAME in .env works
# unchanged. No running studio is a hard error.
#
# Backend verification scope: `verify` for AWS calls the studio's own scope endpoint
# (GET …/admin/data/Scopes/{id}/aws/resources), which runs the backend's credential population for the
# scope. There is no backend endpoint that expands a GCP scope outside a ticket, so GCP's end-to-end
# proof is the ticket harness: tests/e2e/cloud_onboarding_e2e.py.
set -euo pipefail
cd "$(dirname "$0")/.."

. ./scripts/_runtime.sh
. ./scripts/_cloud_auth.sh
source ./scripts/_target.sh            # → BASE_URL + TOKEN + _TARGET (resolved: env, .env, or inferred remote)
_envv() { grep -E "^$1=" "${DUPLO_ENV_FILE:-.env}" 2>/dev/null | head -1 | cut -d= -f2- || true; }

# ── local-only guard, before any probe or write ──────────────────────────────────
# This command posts REAL cloud credentials to a studio and writes into a local Docker volume. It must
# never do that against a remote platform — not an explicit DUPLO_TARGET=remote, not the remote
# _target.sh infers from an inherited DUPLO_HOST + DUPLO_TOKEN pair (an in-platform ticket shell), and
# not a DUPLO_BASE override pointing off this machine while the target still says local. Only plain
# http on a loopback host, with no credentials in the URL, is accepted.
if [ "$_TARGET" != local ]; then
  echo "connect-cloud.sh manages the LOCAL stack only; the resolved target is '$_TARGET'" >&2
  echo "(DUPLO_TARGET=remote, or DUPLO_HOST + DUPLO_TOKEN inherited from the environment). Unset them, or run this from the dev-kit checkout." >&2
  exit 1
fi
# Anchored match of the WHOLE URL: scheme http, one of three loopback hosts, an optional all-digit
# port, an optional single trailing slash, and nothing else — no userinfo ('@'), path, query or
# fragment. A glob such as http://localhost:[0-9]* would accept http://localhost:1234@evil.invalid,
# which urllib sends to evil.invalid. The rejected value is NOT echoed: it may carry credentials.
_LOOPBACK_URL_RE='^http://(localhost|127\.0\.0\.1|\[::1\])(:[0-9]{1,5})?/?$'
if ! [[ "$BASE_URL" =~ $_LOOPBACK_URL_RE ]]; then
  echo "connect-cloud.sh refuses the studio URL from DUPLO_BASE/.env (not shown — it may contain credentials):" >&2
  echo "only exactly http://localhost, http://127.0.0.1 or http://[::1], with an optional port and nothing after it, is accepted," >&2
  echo "because this command would otherwise post cloud credentials to a platform other than your local stack. Unset DUPLO_BASE." >&2
  exit 1
fi
[ -n "$TOKEN" ] || { echo "No token resolved — run ./run.sh first (it writes DUPLO_ADMIN_TOKEN to .env)." >&2; exit 1; }
runtime_resolve || exit 1

# Store operations are exposed to python as a tiny CLI over this same file, so the write path is the
# one documented in _cloud_auth.sh and nothing else: `<this script> _store write|remove|list|exists|volume <rel>`.
if [ "${1-}" = _store ]; then
  case "${2-}" in
    write)  cloud_auth_write "${3:?}" ;;
    remove) cloud_auth_remove "${3:?}" ;;
    list)   cloud_auth_list ;;
    exists) cloud_auth_exists ;;
    volume) cloud_auth_volume ;;
    *) echo "unknown _store op '${2-}'" >&2; exit 2 ;;
  esac
  exit $?
fi

# The python module does the work. Everything it needs that could be sensitive goes through the
# environment of THIS process (the admin token already lives in .env; it is never put on a command
# line) and stdin; the store helper is reached through CONNECT_CLOUD_STORE_CMD so tests can stub it.
export DUPLO_BASE="$BASE_URL"
export DUPLO_TOKEN="$TOKEN"
export CONNECT_CLOUD_WORKSPACE_DEFAULT="${CONNECT_CLOUD_WORKSPACE_DEFAULT:-$(_envv EXTENSION_DEV_WORKSPACE_ID)}"
export CONNECT_CLOUD_STATE="${CONNECT_CLOUD_STATE:-.devkit-cloud/connections.json}"
export CONNECT_CLOUD_PROJECT="${CONNECT_CLOUD_PROJECT:-$(runtime_compose_project)}"
export CONNECT_CLOUD_STORE_CMD="${CONNECT_CLOUD_STORE_CMD:-$0 _store}"
export RUNTIME

# -I: isolated mode — no site customizations, no PYTHON* env, no cwd on sys.path; the script's own
# directory (scripts/) is the only import location, which is exactly where connect_cloud.py lives.
exec python3 -I ./scripts/connect_cloud.py "$@"
