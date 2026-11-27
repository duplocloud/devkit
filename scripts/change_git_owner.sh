#!/usr/bin/env bash
# Change the git owner of THIS dev-kit clone to YOUR own repo, so the checkout becomes yours.
# Use it the first time you adopt the dev-kit (you cloned duplocloud/devkit and now want it
# under your own remote). Your agents live in ./extensions/<name>/; the dev-kit framework rides along and is
# upgradable later with ./scripts/upgrade_dev_kit.sh.
#
# Usage:
#   ./scripts/change_git_owner.sh <your-git-remote-url> [--keep-history]
#     <your-git-remote-url>   git remote to own this repo (e.g. git@github.com:me/my-agents.git)
#     --keep-history          keep the dev-kit's git history; just re-point 'origin' (default: FRESH history)
set -euo pipefail
cd "$(dirname "$0")/.."   # repo root
. "$(dirname "$0")/_devkit.sh"   # DEVKIT_URL (fixed official source)

REMOTE="${1:-}"
[ -n "$REMOTE" ] || { echo "usage: ./scripts/change_git_owner.sh <your-git-remote-url> [--keep-history]" >&2; exit 1; }
KEEP=0; [ "${2:-}" = "--keep-history" ] && KEEP=1

# Provenance: the FIXED official devkit url + the exact version, so upgrade_dev_kit.sh can pull updates.
# The url is the hardcoded DEVKIT_URL — NEVER `git remote get-url origin` (which is the user's own repo after
# adoption), so the recorded source can't be redirected.
SRC_URL="$DEVKIT_URL"
SRC_REF=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
printf 'url=%s\nref=%s\n' "$SRC_URL" "$SRC_REF" > .devkit-version

echo "==> Changing git owner → $REMOTE"
echo "    devkit src : $SRC_URL @ $SRC_REF"
echo "    history    : $([ "$KEEP" = 1 ] && echo 'kept (re-point origin)' || echo 'FRESH (rm -rf .git; new init)')"

if [ "$KEEP" = 1 ]; then
  git remote set-url origin "$REMOTE" 2>/dev/null || git remote add origin "$REMOTE"
  git add -A
  git commit -q -m "Adopt devkit as project (devkit @ ${SRC_REF})" || echo "    (nothing to commit)"
else
  rm -rf .git
  git init -q -b main
  git remote add origin "$REMOTE"
  git add -A
  git commit -q -m "Initialize from devkit @ ${SRC_REF}"
fi

echo "==> Done. This repo is now yours."
echo "    • author agents under extensions/<name>/  (or run /duplo-extension in Claude Code)"
echo "    • build:   ./scripts/build-extension.sh extensions/<name>   (or ./scripts/build-all.sh)"
echo "    • upgrade the framework later: ./scripts/upgrade_dev_kit.sh --version <branch|tag|commit>"
echo "    • push:    git push -u origin main"
