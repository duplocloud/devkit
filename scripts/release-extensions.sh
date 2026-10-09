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
# Usage: ./scripts/release-extensions.sh
set -euo pipefail
cd "$(dirname "$0")/.."
shopt -s nullglob

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

  if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    echo "==> $tag already released — skipping (bump manifest.version to publish a new one)."
    skipped=$((skipped+1)); continue
  fi

  echo "==> Publishing release $tag ($name $version, SDK $sdk)"
  if ! gh release create "$tag" "$zip" --target "$sha" \
      --title "$name $version (SDK $sdk)" \
      --notes "Automated release of $name v$version from $slug, built against host SDK $sdk (extension.zip attached)."; then
    echo "::error::$dir — gh release create $tag failed."
    failed=$((failed+1)); continue
  fi
  published=$((published+1))

  # An asset replaced at a mutable tag no longer matches a digest pinned from it, so say so where the owner sees it.
  immutable="$(gh api "repos/{owner}/{repo}/releases/tags/$tag" --jq '.immutable' 2>/dev/null || true)"
  if [ "$immutable" != true ]; then
    echo "::warning::$tag landed mutable (immutable=${immutable:-unknown}). A repository admin turns on immutable releases under Settings → General → Releases; releases published before that stay mutable."
  fi
done

echo "==> Released $published, skipped $skipped, failed $failed."
[ "$failed" -eq 0 ]
