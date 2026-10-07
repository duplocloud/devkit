#!/usr/bin/env bash
# Tail logs. Optional service name: duplo-ai-studio | claude-code-agent | dind | duplo-ui | mongo | xterm
set -euo pipefail
cd "$(dirname "$0")"
exec docker compose logs -f "$@"
