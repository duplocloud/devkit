# shellcheck shell=bash
# Sourced by scripts/release-extensions.sh and scripts/check-extension-pr.sh. The allowlist names which repository may
# publish each Duplo extension and which console extension record it registers under. ai-release's extension-publisher
# role trusts the same repositories, which is the boundary that matters. This file decides only whether a run tries.
#
# .github/extension-publishers.json ships empty: an entry is added once its extension's console record exists, and
# its repository must already be in ai-release's extension-publisher role trust list.

publishers_file=".github/extension-publishers.json"

# publisher_extension_uuid <manifest-id> <org/repo>: the console extension UUID when the allowlist maps the id to
# that repository, else nothing and exit 1. The lookup is captured rather than let `jq -e` report its own exit
# status, because that status is not 1 for every miss (no match, an empty list and a malformed file each land on a
# different jq exit code) and callers key off exit 1 specifically to mean "not allowed to publish."
publisher_extension_uuid() {
  [ -f "$publishers_file" ] || return 1
  local uuid
  uuid="$(jq -r --arg id "$1" --arg repo "$2" \
    '.publishers[] | select(.manifestId == $id and .repository == $repo) | .consoleExtension' "$publishers_file")" || true
  [ -n "$uuid" ] || return 1
  printf '%s\n' "$uuid"
}

# publisher_auto_publish <manifest-id> <org/repo>: exit 0 when that repository's entry for the id sets "publish": true,
# so a build the release job newly registers for it is also published. The job reads the extension repository's own
# copy of this file, so the flag is gated by that repository's branch protection, not by devkit's review.
publisher_auto_publish() {
  [ -f "$publishers_file" ] || return 1
  jq -e --arg id "$1" --arg repo "$2" \
    'any(.publishers[]; .manifestId == $id and .repository == $repo and .publish == true)' "$publishers_file" >/dev/null 2>&1
}
