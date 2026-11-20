#!/usr/bin/env bash
# Adopt this dev-kit clone as YOUR OWN agent project repo.
#
# You clone the dev-kit once, run this, and from then on the repo is yours: your agents live in extensions/<name>/,
# the dev-kit framework (.claude, scripts, samples, pipelines …) rides along so Claude + CI work on a plain
# checkout, and `scripts/upgrade_dev_kit.sh` pulls newer framework versions without touching extensions/.
#
# Usage:
#   ./scripts/init-project.sh <your-git-remote-url> [--keep-history] [--no-sample] [--name <slug>]
#
#   <your-git-remote-url>   git remote to push YOUR repo to (e.g. git@github.com:me/my-agent.git)
#   --keep-history          keep the dev-kit's git history; just re-point 'origin' (default: start fresh history)
#   --no-sample             don't seed the first agent with a starter (leave a placeholder instead)
#   --name <slug>           name of the first agent dir under extensions/ (default: helloworld). A repo can
#                           hold many agents — each lives in its own extensions/<name>/.
set -euo pipefail
cd "$(dirname "$0")/.."   # repo root
. "$(dirname "$0")/_devkit.sh"   # DEVKIT_URL (fixed official source)

REMOTE="${1:-}"
KEEP_HISTORY=0; SEED_SAMPLE=1; EXT_NAME="helloworld"
args=("${@:2}")
i=0
while [ $i -lt ${#args[@]} ]; do
  a="${args[$i]}"
  case "$a" in
    --keep-history) KEEP_HISTORY=1 ;;
    --no-sample)    SEED_SAMPLE=0 ;;
    --name)         i=$((i + 1)); EXT_NAME="${args[$i]:-}";
                    [ -n "$EXT_NAME" ] || { echo "--name requires a value" >&2; exit 1; } ;;
    *) echo "Unknown option: $a" >&2; exit 1 ;;
  esac
  i=$((i + 1))
done
[ -n "$REMOTE" ] || { echo "usage: ./scripts/init-project.sh <your-git-remote-url> [--keep-history] [--no-sample]" >&2; exit 1; }

# Provenance: the FIXED official devkit url + the exact version (used for the echo below; change_git_owner.sh
# writes .devkit-version). The url is the hardcoded DEVKIT_URL, never origin-derived.
SRC_URL="$DEVKIT_URL"
SRC_REF=$(git rev-parse HEAD 2>/dev/null || echo "unknown")

echo "==> Adopting this dev-kit clone as your project"
echo "    your remote : $REMOTE"
echo "    devkit src  : $SRC_URL @ $SRC_REF"
echo "    history     : $([ "$KEEP_HISTORY" = 1 ] && echo 'kept (re-point origin)' || echo 'FRESH (rm -rf .git; new init)')"

# 1. Seed the first agent at extensions/<name>/ (a copy of the helloworld sample) unless told not to.
#    Agents are nested one-per-dir so the repo can hold many (extensions/<name1>/, extensions/<name2>/, …).
DEST="extensions/$EXT_NAME"
if [ ! -d extensions ] || [ -z "$(ls -A extensions 2>/dev/null)" ]; then
  if [ "$SEED_SAMPLE" = 1 ] && [ -d samples/helloworld ]; then
    mkdir -p extensions
    cp -r samples/helloworld "$DEST"
    rm -rf "$DEST"/dist "$DEST"/frontend/node_modules "$DEST"/backend/bin "$DEST"/backend/obj \
           "$DEST"/backend/sdk-packages "$DEST"/frontend/.angular 2>/dev/null || true
    echo "    seeded $DEST from samples/helloworld (run /duplo-extension to reshape it, or edit by hand)"
  else
    mkdir -p "$DEST"
    printf '%s\n' "# Your agent" "" "Run \`/duplo-extension\` in Claude Code to scaffold here, or copy a sample from \`samples/\`." > "$DEST/README.md"
    echo "    created empty $DEST (placeholder)"
  fi
fi

# 2. Change git ownership to the user's repo (records .devkit-version + commits the seeded agent).
"$(dirname "$0")/change_git_owner.sh" "$REMOTE" $([ "$KEEP_HISTORY" = 1 ] && echo --keep-history)

echo "==> Done. This repo is now yours."
echo "    • author your agent in $DEST  (or run /duplo-extension in Claude Code)"
echo "    • add more agents later under extensions/<another-name>/"
echo "    • build one:  ./scripts/build-extension.sh $DEST"
echo "    • build all:  ./scripts/build-all.sh"
echo "    • deploy all: ./scripts/deploy-all.sh"
echo "    • push:       git push -u origin main"
echo "    • update the framework later: ./scripts/upgrade_dev_kit.sh --version main"
