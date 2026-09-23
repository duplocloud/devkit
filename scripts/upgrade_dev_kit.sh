#!/usr/bin/env bash
# Upgrade the embedded dev-kit FRAMEWORK to a version, preserving YOUR code and config.
#
# Clones the dev-kit from the FIXED official URL (scripts/_devkit.sh — never a user-supplied source) into a
# cache, then refreshes ONLY the framework-owned paths listed below (allowlist). Everything else in this repo —
# extensions/, .env, docker-compose-overrides, and any other file you add — is left untouched.
#
# Usage:
#   ./scripts/upgrade_dev_kit.sh [--version <branch|tag|commit>] [--yes]
#     --version <ref>   dev-kit version to move to (branch / tag / commit). Default: main
#     --yes             apply without the interactive confirmation (for scripted/CI use)
set -euo pipefail
cd "$(dirname "$0")/.."   # repo root
. "$(dirname "$0")/_devkit.sh"   # DEVKIT_URL (fixed official source)

# Framework-owned paths (allowlist). ONLY these are refreshed; anything else is preserved.
#   FRAMEWORK_DIRS   — wholly framework-owned: mirrored with an intra-dir --delete (stale files inside go).
#   FRAMEWORK_MERGE_DIRS — SHARED with the user (e.g. docs/, where authors add their own docs): framework files
#                    are overwritten/added but NO --delete, so user files in them are preserved.
#   FRAMEWORK_FILES  — individual files, overwritten in place (never deleted).
# Keep these lists in sync when adding framework paths.
FRAMEWORK_DIRS=( .agents .claude .github nginx packages samples scripts )
# build/ holds only the extension build toolchain's Dockerfile, but `build` is a near-universal name for
# a project's own output/scripts — so it is merged, NOT mirrored. An adopted repo that already has a
# build/ keeps everything in it; a --delete here would reap a user directory on an upgrade they asked
# for. (It can't go in FRAMEWORK_FILES: rsync won't create the missing parent for a single file.)
FRAMEWORK_MERGE_DIRS=( docs build )
FRAMEWORK_FILES=( .env.example .gitignore docker-compose.yml logs.sh PRIVACY.md README.md run.sh stop.sh todo.md )

REF="main"; ASSUME_YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --version) REF="${2:?--version needs a value}"; shift ;;
    --yes|-y)  ASSUME_YES=1 ;;
    *) echo "Unknown option: $1 (usage: --version <ref> [--yes])" >&2; exit 1 ;;
  esac
  shift
done

command -v rsync >/dev/null 2>&1 || { echo "rsync is required." >&2; exit 1; }

# Only the ref is read from .devkit-version (for the display below). The URL is ALWAYS the fixed official
# DEVKIT_URL — never taken from the file or `git remote`, so an adopted repo can't redirect the upgrade source.
CUR_REF=""
[ -f .devkit-version ] && CUR_REF=$(grep -E '^ref=' .devkit-version | cut -d= -f2- || true)

CACHE=$(mktemp -d)
trap 'rm -rf "$CACHE"' EXIT
echo "==> Cloning $DEVKIT_URL (version: $REF) → cache"
# Private repo → prefer gh (authenticated) and fall back to git.
if command -v gh >/dev/null 2>&1; then
  gh repo clone "$DEVKIT_URL" "$CACHE" -- -q 2>/dev/null || git clone -q "$DEVKIT_URL" "$CACHE"
else
  git clone -q "$DEVKIT_URL" "$CACHE"
fi
git -C "$CACHE" checkout -q "$REF"
NEW_REF=$(git -C "$CACHE" rev-parse HEAD)

echo "    current framework : ${CUR_REF:-unknown}"
echo "    new framework     : $NEW_REF (version $REF)"
[ "$CUR_REF" = "$NEW_REF" ] && { echo "==> Already up to date — nothing to do."; exit 0; }

# Refresh ONLY the framework-owned paths (allowlist). No repo-root --delete, so any file NOT listed above —
# extensions/, extension/, .env, .env.defaults, docker-compose-overrides, and anything else you added — is
# left completely untouched. Framework dirs use an intra-dir --delete so stale framework files inside them go.
sync_framework() {
  local dryrun="$1" d f
  # Wholly-owned dirs: mirror with --delete (removes stale framework files inside).
  for d in "${FRAMEWORK_DIRS[@]}"; do
    [ -d "$CACHE/$d" ] || continue
    rsync -a --delete $dryrun "$CACHE/$d/" "./$d/"
  done
  # Shared dirs (docs/): overwrite/add framework files, NO --delete → user files here are preserved.
  for d in "${FRAMEWORK_MERGE_DIRS[@]}"; do
    [ -d "$CACHE/$d" ] || continue
    rsync -a $dryrun "$CACHE/$d/" "./$d/"
  done
  for f in "${FRAMEWORK_FILES[@]}"; do
    [ -f "$CACHE/$f" ] || continue
    rsync -a $dryrun "$CACHE/$f" "./$f"
  done
}

echo "==> Changes to apply (preview; only framework paths — your extensions/, .env and other files are preserved):"
sync_framework "--itemize-changes --dry-run" | grep -vE '^\.[fd]' | head -80 || true

if [ "$ASSUME_YES" != 1 ]; then
  printf "Apply these framework updates? [y/N] "
  read -r ans || ans=""
  case "$ans" in y|Y|yes|YES) ;; *) echo "Aborted (no changes made)."; exit 1 ;; esac
fi

sync_framework ""
# Record provenance: the FIXED official url + the new ref. url is never user-derived.
printf 'url=%s\nref=%s\n' "$DEVKIT_URL" "$NEW_REF" > .devkit-version
echo "==> Framework upgraded: ${CUR_REF:-unknown} → $NEW_REF"
echo "    Review with 'git status' / 'git diff', then commit. Only framework paths were touched."
