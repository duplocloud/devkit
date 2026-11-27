#!/usr/bin/env bash
# Vendor the DuploCloud Terraform agent's SOURCE into extensions/terraform.
#
# The Terraform agent is a real, shipping DuploCloud agent, open-sourced at
# $TF_EXT_REPO. That repository is itself a full copy of this dev kit; the only part we want is its
# extensions/terraform subdirectory. So we do a blobless partial fetch with a sparse path — nothing
# outside that subdirectory is ever downloaded — then move the subdirectory into place and delete the
# throwaway repo.
#
# What lands in extensions/terraform is PLAIN SOURCE: no .git, no remote, no upstream, no submodule.
# You never pull it and it never updates itself. It is yours to read and to change, exactly like an
# agent you wrote — which is the point.
#
#   ./scripts/fetch-terraform-extension.sh            # fetch if absent; keep what's there otherwise
#   ./scripts/fetch-terraform-extension.sh --force    # re-fetch, moving any existing copy to .bak
#
# Overrides (developers pointing at a fork or a different pin):
#   TF_EXT_REPO=<git url>   TF_EXT_REF=<branch|tag|sha>   TF_EXT_PATH=<subdir>   TF_EXT_DEST=<dir>
set -euo pipefail
cd "$(dirname "$0")/.."

# The upstream source. Pinned to a ref so the walkthrough in docs/getting-started/ — its file paths,
# its diffs, its screenshots — cannot drift out from under the reader. Bump deliberately.
TF_EXT_REPO="${TF_EXT_REPO:-https://github.com/duplocloud/duploai-extension-terraform}"
TF_EXT_REF="${TF_EXT_REF:-main}"
TF_EXT_PATH="${TF_EXT_PATH:-extensions/terraform}"
TF_EXT_DEST="${TF_EXT_DEST:-extensions/terraform}"

FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=1 ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | grep -E '^#( |$)' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
  shift
done

# ── already here? ────────────────────────────────────────────────────────────
# Idempotent by default. run.sh calls this on EVERY run, and the getting-started guide has the reader
# edit this directory — so re-running the dev kit must never overwrite their work.
if [ -d "$TF_EXT_DEST" ]; then
  if [ "$FORCE" = 0 ]; then
    echo "==> $TF_EXT_DEST already present — keeping it (yours to edit)."
    echo "    To replace it with a fresh copy: ./scripts/fetch-terraform-extension.sh --force"
    exit 0
  fi
  BAK="$TF_EXT_DEST.bak"
  i=1; while [ -e "$BAK" ]; do BAK="$TF_EXT_DEST.bak.$i"; i=$((i+1)); done
  echo "==> --force: moving the existing copy to $BAK"
  mv "$TF_EXT_DEST" "$BAK"
fi

# ── prerequisites ────────────────────────────────────────────────────────────
command -v git >/dev/null || { echo "Missing required tool: git" >&2; exit 1; }
# sparse-checkout and partial-clone filters both landed by git 2.25 (Jan 2020).
GIT_VER="$(git --version | awk '{print $3}')"
GIT_MAJ="${GIT_VER%%.*}"; GIT_REST="${GIT_VER#*.}"; GIT_MIN="${GIT_REST%%.*}"
if [ "$GIT_MAJ" -lt 2 ] || { [ "$GIT_MAJ" -eq 2 ] && [ "$GIT_MIN" -lt 25 ]; }; then
  echo "git $GIT_VER is too old — need 2.25+ for sparse-checkout and partial-clone filters." >&2
  exit 1
fi

# ── fetch just the one subdirectory ──────────────────────────────────────────
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> Fetching $TF_EXT_PATH from $TF_EXT_REPO ($TF_EXT_REF)…"
git init -q "$TMP/src"
git -C "$TMP/src" remote add origin "$TF_EXT_REPO"
# --no-cone takes the path as a literal pattern, so we get exactly this subtree and nothing else.
git -C "$TMP/src" sparse-checkout set --no-cone "$TF_EXT_PATH"
# init+fetch rather than `clone --branch`, because one fetch handles a branch, a tag OR a commit SHA
# identically — which is what lets TF_EXT_REF be pinned to a commit.
# --filter=blob:none means only the blobs under the sparse path are ever transferred.
# GIT_TERMINAL_PROMPT=0 is load-bearing: run.sh calls this unattended, and without it a repo we
# cannot read would sit at a username prompt forever instead of failing.
if ! GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=true \
     git -C "$TMP/src" fetch --depth 1 --filter=blob:none -q origin "$TF_EXT_REF" 2>/dev/null; then
  echo "Could not fetch '$TF_EXT_REF' from $TF_EXT_REPO." >&2
  echo "  • If the repository is private, this needs credentials git can use unattended." >&2
  echo "  • If you are offline or behind a proxy, that would do it too." >&2
  echo "  • Check the ref exists:  git ls-remote $TF_EXT_REPO $TF_EXT_REF" >&2
  exit 1
fi
git -C "$TMP/src" checkout -q FETCH_HEAD

[ -d "$TMP/src/$TF_EXT_PATH" ] || {
  echo "'$TF_EXT_PATH' does not exist at $TF_EXT_REF in $TF_EXT_REPO." >&2; exit 1; }

# ── move it into place, disconnected from git ────────────────────────────────
# Only the subdirectory moves; $TMP (and with it the entire .git) is removed by the EXIT trap. There
# is never a .git inside $TF_EXT_DEST to forget about.
mkdir -p "$(dirname "$TF_EXT_DEST")"
mv "$TMP/src/$TF_EXT_PATH" "$TF_EXT_DEST"

echo "    $TF_EXT_DEST — $(find "$TF_EXT_DEST" -type f | wc -l | tr -d ' ') files, not a git repo. Yours to edit."
echo "    Build + load it:  ./scripts/build-extension.sh $TF_EXT_DEST && ./scripts/deploy-extension.sh $TF_EXT_DEST/dist/agent.zip"
