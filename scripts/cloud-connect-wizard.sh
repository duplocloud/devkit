#!/usr/bin/env bash
# cloud-connect-wizard.sh — interactive cloud onboarding for the running dev kit.
#
#   ./scripts/cloud-connect-wizard.sh          ask "connect now?", then the questions below
#   ./scripts/cloud-connect-wizard.sh --yes    skip that first question (run.sh does, after asking it itself)
#
# Asks which cloud (AWS or GCP — Azure is listed as not supported yet), then how you sign in, then only the
# profile or project that method needs, and runs the deterministic connector for you:
#
#   AWS   ./scripts/connect-cloud.sh aws --name <profile> --profile <profile> --region <profile region | us-east-1>
#   GCP   ./scripts/connect-cloud.sh gcp --project <project-id>
#   then  ./scripts/connect-cloud.sh verify --name <same name>
#
# It needs a terminal (browser sign-ins run in it) and never prompts without one. It needs no LLM and no
# agent: the /duplo-cloud-connect skill is the conversational alternative over the same connector. Use it
# again any time to add an account or to reconnect one whose credentials expired. It asks for no secret,
# stores nothing itself, and starts, stops or restarts nothing itself (the GCP connector may restart only
# the backend — see connect-cloud.sh).
#
# Exit: 0 connected and verified · 1 failed (reason printed) · 2 usage / no terminal · 130 cancelled.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v python3 >/dev/null 2>&1 || { echo "python3 is required for the cloud-connect wizard (connect-cloud.sh needs it too)." >&2; exit 1; }
# -I: isolated mode, as connect-cloud.sh runs its own python — no site customizations, no PYTHON* env,
# no cwd on sys.path.
exec python3 -I ./scripts/cloud_connect_wizard.py "$@"
