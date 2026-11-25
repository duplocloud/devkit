# shellcheck shell=bash
# Sourced by scripts/* — resolves BASE_URL + TOKEN from an env file per DUPLO_TARGET (local|remote).
# Overridable: real env vars win (DUPLO_BASE forces the URL; DUPLO_TARGET/DUPLO_HOST/DUPLO_TOKEN/
# DUPLO_ADMIN_TOKEN may all come straight from the environment — e.g. CI secrets — with no file at all).
# The env file is `.env` in the caller's cwd (the repo root) by default; set DUPLO_ENV_FILE=<path> to point
# elsewhere (e.g. your own repo's config when the dev-kit scripts run from a subdir).
# `|| true` so a missing var yields empty instead of a pipefail exit under the callers' `set -euo pipefail`
# (e.g. DUPLO_TARGET is absent after `./run.sh --reset`, and is optional — it defaults to local below).
_ENV_FILE="${DUPLO_ENV_FILE:-.env}"
_envv() { grep -E "^$1=" "$_ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true; }
_TARGET="${DUPLO_TARGET:-$(_envv DUPLO_TARGET)}"
# In-platform tickets export DUPLO_HOST + DUPLO_TOKEN (and no .env, no DUPLO_TARGET) — that pair IS the
# remote target, so default to it. An explicit DUPLO_TARGET (env or .env) still wins.
if [ -z "$_TARGET" ] && [ -n "${DUPLO_HOST:-}" ] && [ -n "${DUPLO_TOKEN:-}" ]; then _TARGET=remote; fi
_TARGET="${_TARGET:-local}"
if [ "$_TARGET" = remote ]; then
  BASE_URL="${DUPLO_BASE:-${DUPLO_HOST:-$(_envv DUPLO_HOST)}}"
  TOKEN="${DUPLO_TOKEN:-$(_envv DUPLO_TOKEN)}"
  [ -n "$BASE_URL" ] || { echo "DUPLO_TARGET=remote but DUPLO_HOST is unset in .env." >&2; exit 1; }
  [ -n "$TOKEN" ]    || { echo "DUPLO_TARGET=remote but DUPLO_TOKEN is unset in .env." >&2; exit 1; }
else
  _PORT="$(_envv STUDIO_PORT)"
  BASE_URL="${DUPLO_BASE:-http://localhost:${_PORT:-60021}}"
  TOKEN="${DUPLO_ADMIN_TOKEN:-$(_envv DUPLO_ADMIN_TOKEN)}"
fi
