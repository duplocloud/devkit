#!/usr/bin/env bash
# Publish every built extension in this repo as a GitHub Release — the publish step of .github/workflows/release.yml,
# kept as a script so tests/test-release-extensions.sh can exercise it.
#
# One release per build, tagged <slug>-v<version>-sdk-<sdkVersion>. <slug> is the extension directory's basename, and
# sdkVersion is read from the BUILT bundle's manifest (build-extension.sh stamps it from the host it built against),
# so builds of one version for different SDKs share the version and differ only in the tag.
#
# A version that already has a release, under that tag shape or the legacy <slug>-v<version>, is compared with the
# built commit. If the extension is unchanged, an existing build for this SDK is skipped and a missing one is
# published. If it changed, the extension fails rather than skipping green: two different bundles would otherwise
# share one version, and whatever consumes the release could not tell them apart. Legacy tags were cut at main's HEAD
# at publish time rather than at the built commit, so one can report a change that a version bump then clears.
#
# Needs the repo's tags and the history they point at (actions/checkout with fetch-depth: 0), gh authenticated with
# contents: write, jq and unzip. GITHUB_SHA is the built commit; it defaults to HEAD.
#
# Signing: a run in one of Duplo's own organizations (duplo_org in scripts/_publish.sh) always signs the built zip
# with EXTENSION_SIGNING_KEY and EXTENSION_SIGNING_CERT before the release is created, and ships extension.zip.sig
# alongside it; a run anywhere else releases the zip alone, as a customer's copy of this workflow carries no Duplo
# signing credential. Within a Duplo organization, the manifest id also has to be in the extension publisher
# allowlist (scripts/_publishers.sh) for the repository, or the release still ships signed but scripts/_publish.sh's
# publish_build is never called for it. An allowlisted id with no CONSOLE_API_KEY fails before it is signed or
# released, since that build could be released but never registered. A registered version stays unpublished unless
# its allowlist entry sets "publish": true, which publishes only a build this run newly registers, or
# EXTENSION_PUBLISH=true (a manual run's publish input) asks to publish it.
#
# Resuming: a tag that already has a release is never rebuilt, re-signed or re-released. Its own assets, read back
# with gh release view, decide what happens next: a signed release calls publish_build again so a run that stopped
# between releasing and publishing still finishes, and a release that predates signing stays flagged rather than
# retrofitted, since a tag's assets can't gain one after the fact. A new manifest.version is the only way forward.
#
# Two checks run for every build, in every organization, right after confirming the build produced a zip. A missing
# resources entry refuses the build, and so does a bundle over EXTENSION_MAX_BYTES bytes (default 268435456). Either
# failure counts against just that extension and the run moves on, matching scripts/check-extension-pr.sh's PR-time
# warning for the same two rules.
#
# Usage: ./scripts/release-extensions.sh
set -euo pipefail
cd "$(dirname "$0")/.."
shopt -s nullglob

# shellcheck source=scripts/_publishers.sh
. "$(dirname "$0")/_publishers.sh"
# shellcheck source=scripts/_publish.sh
. "$(dirname "$0")/_publish.sh"
publishers_file="${PUBLISHERS_FILE:-$publishers_file}"
sign_cmd="${EXTENSION_SIGN:-python3 $(dirname "$0")/extension-sign.py}"
repo="${GITHUB_REPOSITORY:-}"
max_bytes="${EXTENSION_MAX_BYTES:-268435456}"

sha="${GITHUB_SHA:-$(git rev-parse HEAD)}"
published=0; skipped=0; failed=0

for m in extensions/*/manifest.json extension/*/manifest.json extension/manifest.json; do
  [ -f "$m" ] || continue
  dir="$(dirname "$m")"
  zip="$dir/dist/extension.zip"
  if [ ! -f "$zip" ]; then
    echo "::warning::$dir — no dist/extension.zip (build produced nothing); skipping."
    continue
  fi
  if ! jq -e '(.resources // []) | length > 0' "$m" >/dev/null; then
    echo "::error::$dir — the manifest declares no resource, so the host refuses the bundle."
    failed=$((failed+1)); continue
  fi
  if [ "$(wc -c < "$zip")" -gt "$max_bytes" ]; then
    echo "::error::$dir — the bundle is over $max_bytes bytes, which the release job refuses to publish."
    failed=$((failed+1)); continue
  fi
  name="$(jq -r '.name // .id' "$m")"
  version="$(jq -r '.version' "$m")"
  slug="$(basename "$dir")"
  sdk="$(unzip -p "$zip" manifest.json | jq -r '.sdkVersion // empty')"
  if [ -z "$sdk" ]; then
    echo "::error::$dir — the bundle's manifest.json carries no sdkVersion, so its release cannot be tagged. Build it with scripts/build-extension.sh."
    failed=$((failed+1)); continue
  fi
  base="${slug}-v${version}"
  tag="${base}-sdk-${sdk}"

  changed_since=""
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    git diff --quiet "$t^{commit}" "$sha" -- "$dir" || { changed_since="$t"; break; }
  done < <(git tag -l "$base" "$base-sdk-*")
  if [ -n "$changed_since" ]; then
    echo "::error::$dir — $version is already released as $changed_since and the extension changed since. Bump manifest.version to publish it."
    failed=$((failed+1)); continue
  fi

  id="$(unzip -p "$zip" manifest.json | jq -r '.id')"
  uuid=""
  if duplo_org; then
    if ! uuid="$(publisher_extension_uuid "$id" "$repo")"; then
      uuid=""
      echo "::notice::$dir — $id is not in the extension publisher allowlist for $repo, so it is released but not published to the license server."
    fi
  fi
  # Publishing is opt-in. An allowlist entry's "publish" publishes only a build this run newly registers, and a manual
  # run's publish input (EXTENSION_PUBLISH) also publishes one an earlier run registered. publish_build reads
  # publish_version, and _publish.sh's maybe_publish has the rule.
  publish_version=""
  if [ -n "$uuid" ]; then
    if [ "${EXTENSION_PUBLISH:-}" = true ]; then publish_version=any
    elif publisher_auto_publish "$id" "$repo"; then publish_version=new; fi
  fi
  # Registration needs the console key, so a missing one fails here, before a release that could never be registered.
  if [ -n "$uuid" ] && [ -z "${CONSOLE_API_KEY:-}" ]; then
    echo "::error::$dir — $id is allowlisted for $repo, but CONSOLE_API_KEY is not set, so it cannot be registered."
    failed=$((failed+1)); continue
  fi

  if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    if [ -n "$uuid" ]; then
      if ! assets="$(gh release view "$tag" --json assets --jq '[.assets[].name] | join(",")')"; then
        echo "::error::$dir — gh release view $tag failed."
        failed=$((failed+1)); continue
      fi
      if [[ ",$assets," != *",extension.zip.sig,"* ]]; then
        echo "::warning::$tag was released with no extension.zip.sig, and an immutable release cannot gain one. Bump manifest.version to publish this extension."
        skipped=$((skipped+1)); continue
      fi
      publish_build "$tag" "$id" "$version" "$sdk" "$dir" || { failed=$((failed+1)); continue; }
    else
      echo "==> $tag already released — skipping (bump manifest.version to publish a new one)."
    fi
    skipped=$((skipped+1)); continue
  fi

  assets=("$zip")
  if duplo_org; then
    if [ -z "${EXTENSION_SIGNING_KEY:-}" ] || [ -z "${EXTENSION_SIGNING_CERT:-}" ]; then
      echo "::error::$dir — EXTENSION_SIGNING_KEY and EXTENSION_SIGNING_CERT must be set in $GITHUB_REPOSITORY_OWNER. Duplo releases are always signed."
      failed=$((failed+1)); continue
    fi
    # shellcheck disable=SC2086 # sign_cmd is a command plus its interpreter
    if ! $sign_cmd sign "$zip"; then failed=$((failed+1)); continue; fi
    assets+=("$zip.sig")
  fi

  echo "==> Publishing release $tag ($name $version, SDK $sdk)"
  if ! gh release create "$tag" "${assets[@]}" --target "$sha" \
      --title "$name $version (SDK $sdk)" \
      --notes "Automated release of $name v$version from $slug, built against host SDK $sdk."; then
    echo "::error::$dir — gh release create $tag failed."
    failed=$((failed+1)); continue
  fi
  published=$((published+1))

  # An asset replaced at a mutable tag no longer matches a digest pinned from it, so say so where the owner sees it.
  immutable="$(gh api "repos/{owner}/{repo}/releases/tags/$tag" --jq '.immutable' 2>/dev/null || true)"
  if [ "$immutable" != true ]; then
    echo "::warning::$tag landed mutable (immutable=${immutable:-unknown}). A repository admin turns on immutable releases under Settings → General → Releases; releases published before that stay mutable."
  fi

  if [ -n "$uuid" ]; then
    publish_build "$tag" "$id" "$version" "$sdk" "$dir" || failed=$((failed+1))
  fi
done

echo "==> Released $published, skipped $skipped, failed $failed."
[ "$failed" -eq 0 ]
