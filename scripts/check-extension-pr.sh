#!/usr/bin/env bash
# Warn on a pull request about what each changed extension's release will need — the PR step of
# .github/workflows/extension-ci.yml. Warnings only, never a failure: authors should learn what shipping needs as
# early as possible without being blocked mid-development. The release action (duplocloud/actions/release-extension,
# run by .github/workflows/release.yml) is what refuses a release that cannot ship.
#
# For each extension the PR changes (anything under its directory since the merge base):
#   - manifest.version is unchanged, so the release job will refuse to publish the new content at the old version.
#   - a directory under skills/ has no matching skills[].folder in the manifest, so the host never registers it.
#   - the built bundle's frontend is webpack (fe/remoteEntry.js, no fe/remoteEntry.json), whose pages do not open on
#     hosts that load Native Federation remotes. Checked only when dist/extension.zip exists, i.e. after a build.
#   - the manifest id or version cannot form a bucket key, which the release action refuses.
#   - the manifest declares no resources, which the host refuses to install.
#   - the frontend depends on ng-common-lib older than 0.5.1: light-only below 0.5.0, and without the token defaults
#     older portals need below 0.5.1.
#   - the built bundle is over EXTENSION_MAX_BYTES bytes (default 268435456), which the release job refuses to
#     publish. Checked only after a build.
#   - in one of Duplo's organizations, manifest.version is not strict semver (MAJOR.MINOR.PATCH[-pre], no +build),
#     the same rule scripts/extension-sign.py enforces before it signs a build.
#
# Usage: ./scripts/check-extension-pr.sh <base-ref>   # e.g. origin/main; defaults to origin/$GITHUB_BASE_REF
set -euo pipefail
cd "$(dirname "$0")/.."
shopt -s nullglob

duplo_org() { case "${GITHUB_REPOSITORY_OWNER:-}" in duplocloud|duplocloud-internal) return 0 ;; *) return 1 ;; esac; }
max_bytes="${EXTENSION_MAX_BYTES:-268435456}"

base_ref="${1:-origin/${GITHUB_BASE_REF:?usage: check-extension-pr.sh <base-ref>}}"
base="$(git merge-base "$base_ref" HEAD)"
warned=0
warn() { echo "::warning file=$1::$2"; warned=$((warned+1)); }

for m in extensions/*/manifest.json extension/*/manifest.json extension/manifest.json; do
  [ -f "$m" ] || continue
  dir="$(dirname "$m")"
  git diff --quiet "$base" HEAD -- "$dir" && continue

  version="$(jq -r '.version' "$m")"
  base_version="$(git show "$base:$m" 2>/dev/null | jq -r '.version // empty' 2>/dev/null || true)"
  # The release job refuses only a version that already has a release tag, under either tag shape, so warn only then.
  slug="$(basename "$dir")"
  if [ -n "$base_version" ] && [ "$base_version" = "$version" ] && [ -n "$(git tag -l "$slug-v$version" "$slug-v$version-sdk-*")" ]; then
    warn "$m" "$dir changed but manifest.version is still $version, which is already released. Bump it, or the release job refuses to publish this content."
  fi

  for v in "$(jq -r '.id' "$m")" "$version"; do
    [[ "$v" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || warn "$m" "$dir — '$v' cannot form a bucket key, so the release job refuses to publish it."
  done
  if duplo_org && ! [[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?$ ]]; then
    warn "$m" "$dir — version '$version' is not strict semver (MAJOR.MINOR.PATCH[-pre], no +build), which scripts/extension-sign.py refuses to sign in Duplo's organizations."
  fi
  jq -e '(.resources // []) | length > 0' "$m" >/dev/null \
    || warn "$m" "$dir declares no resource, so the host refuses the bundle."

  for s in "$dir"/skills/*/; do
    s="$(basename "$s")"
    jq -e --arg s "$s" 'any(.skills[]?.folder // ""; endswith("/skills/" + $s))' "$m" >/dev/null \
      || warn "$m" "$dir ships skills/$s but the manifest declares no skills[].folder for it, so the host never registers it."
  done

  lib="$(jq -r '.dependencies["@duplocloud-internal/ng-common-lib"] // empty' "$dir/frontend/package.json" 2>/dev/null || true)"
  lib_version="$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' <<<"$lib" | head -1 || true)"
  if [ -n "$lib_version" ] && [ "$(printf '%s\n' "$lib_version" 0.5.1 | sort -V | head -1)" != 0.5.1 ]; then
    if [ "$(printf '%s\n' "$lib_version" 0.5.0 | sort -V | head -1)" != 0.5.0 ]; then
      why="stays light in the portal's dark mode and repaints the portal's tables"
    else
      why="lacks the theme token defaults, so its components lose their backgrounds on portals without the dark theme"
    fi
    warn "$dir/frontend/package.json" "$dir uses ng-common-lib $lib_version, which $why. Migrate with the duplo-extension-theme-migration skill."
  fi

  # A build leaves dist/extension.zip (host mode) or one dist/sdk-<v>/extension.zip per SDK version, so check each.
  for zip in "$dir/dist/extension.zip" "$dir"/dist/sdk-*/extension.zip; do
    [ -f "$zip" ] || continue
    [ "$(wc -c < "$zip")" -le "$max_bytes" ] \
      || warn "$m" "$dir builds a bundle over $max_bytes bytes ($zip), which the release job refuses."
    entries="$(unzip -Z1 "$zip")"
    if grep -qx 'fe/remoteEntry.js' <<<"$entries" && ! grep -qx 'fe/remoteEntry.json' <<<"$entries"; then
      warn "$m" "$dir builds a webpack frontend (fe/remoteEntry.js in $zip). Its pages do not open on hosts that load Native Federation remotes. \
Migrate with the duplo-extension-ng22-migration skill."
    fi
  done
done

echo "==> $warned release warning(s)."
