#!/usr/bin/env bash
# Refresh the @duplocloud-internal/ng-common-lib tarball across every sample + the skill template.
#
# Two vendoring schemes coexist:
#   - Samples share ONE copy at the repo-root packages/ (they never leave this repo, so a shared
#     relative path is safe).
#   - The skill template keeps its OWN copy at
#     .claude/skills/duplo-extension-dev/templates/helloworld/frontend/vendor/ — it gets cp -r'd out
#     to extensions/<name>/ or a provisioning-ticket workdir, so it can't depend on reaching back to
#     repo-root packages/; it must stay self-contained.
#
# The library is built + packed from the platform UI repo (duplo-ui):
#     cd duplo-ui/portal && npm install && npm run pack:common-lib
# which produces duplocloud-internal-ng-common-lib-<ver>.tgz with ng-block-ui bundled inside it
# (see bundleDependencies in portal/common-lib/package.json), so the tarball installs with no
# registry access. Or download it from GitHub Packages with
# `npm pack @duplocloud-internal/ng-common-lib@<ver>`.
#
# Then point this script at the produced tgz; it drops it into packages/, the template's vendor/ and the
# vendor/ of any frontend copied from the template, removes the old lib tarball from each, and rewrites
# the `file:` dependency in each package.json.
# Commit the result.
#
# Usage: ./scripts/refresh-common-lib.sh /path/to/duplocloud-internal-ng-common-lib-<ver>.tgz
set -euo pipefail
cd "$(dirname "$0")/.."

TGZ="${1:?usage: refresh-common-lib.sh <path-to-duplocloud-internal-ng-common-lib-*.tgz>}"
[ -f "$TGZ" ] || { echo "No such file: $TGZ" >&2; exit 1; }
case "$(basename "$TGZ")" in
  duplocloud-internal-ng-common-lib-*.tgz) ;;
  *) echo "Refusing: '$(basename "$TGZ")' is not a duplocloud-internal-ng-common-lib-*.tgz" >&2; exit 1 ;;
esac
NAME="$(basename "$TGZ")"
TEMPLATE_VENDOR=".claude/skills/duplo-extension-dev/templates/helloworld/frontend/vendor"

# drop the new tarball into both locations; remove any older lib tarball from each
mkdir -p packages "$TEMPLATE_VENDOR"
for dir in packages "$TEMPLATE_VENDOR"; do
  find "$dir" -maxdepth 1 -name 'duplocloud-internal-ng-common-lib-*.tgz' ! -name "$NAME" -delete 2>/dev/null || true
  cp "$TGZ" "$dir/$NAME"
done

count=0
# Update package.json files that vendor this library via a file: tarball (packages/ or vendor/).
# -exec + never invokes grep at all when find matches nothing, so this can't stall waiting on stdin
# the way a `find | xargs grep` pipeline would if the file list came back empty.
while IFS= read -r pkg; do
  before="$(cat "$pkg")"
  # rewrite the file: dependency to point to the new tarball name, preserving the relative path
  # (either .../packages/ for samples or vendor/ for the self-contained skill template)
  perl -pi -e 's{"\@duplocloud-internal/ng-common-lib":\s*"([^"]*?(?:packages|vendor)/)duplocloud-internal-ng-common-lib-[^"]+"}{"\@duplocloud-internal/ng-common-lib": "${1}'"$NAME"'"}g' "$pkg"
  if [ "$before" != "$(cat "$pkg")" ]; then
    # Frontends copied out of the template keep their own vendor/; put the tarball where the dependency points.
    rel="$(jq -r '.dependencies["@duplocloud-internal/ng-common-lib"]' "$pkg")"
    lib_dir="$(dirname "$pkg")/$(dirname "${rel#file:}")"
    if [ -d "$lib_dir" ]; then
      find "$lib_dir" -maxdepth 1 -name 'duplocloud-internal-ng-common-lib-*.tgz' ! -name "$NAME" -delete
      [ -f "$lib_dir/$NAME" ] || cp "$TGZ" "$lib_dir/$NAME"
    fi
    count=$((count + 1))
    echo "  refreshed $(dirname "$pkg")"
  fi
done < <(find . -name 'package.json' -not -path '*/node_modules/*' -exec grep -lE '"@duplocloud-internal/ng-common-lib":\s*"file:[^"]*(packages|vendor)/' {} + 2>/dev/null | sort)

echo "==> Refreshed $count frontend(s) to $NAME."
echo "    Run 'npm install' in each affected frontend to regenerate its lockfile;"
echo "    commit the packages/*.tgz + vendor/*.tgz + package.json + package-lock.json changes."
