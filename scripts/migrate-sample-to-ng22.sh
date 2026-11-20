#!/usr/bin/env bash
# Project the migrated samples/helloworld frontend scaffolding onto another sample.
#
#   ./scripts/migrate-sample-to-ng22.sh samples/<name>
#
# Copies the six scaffolding files from helloworld, then restores the three per-sample values that
# must NOT be shared: the federation container name (REMOTE_NAME), the npm package name, and the
# description. The only files it touches under src/app/** are the two dev-shell files app.module.ts
# and app.component.ts, which it DELETES — a Native Federation remote has no standalone dev shell.
# Everything else under src/app/** is the sample's own code and is left alone. Point this at a real
# agent whose app.module.ts holds production code and you WILL lose it; move that code out first.
#
# REMOTE_NAME is read from the sample's OWN manifest (frontend.remote.remoteName) rather than from
# its webpack.config.js, so this still works if the Webpack config was already removed. A duplicate
# container name across two installed agents makes the second alias to the first at runtime.
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="samples/helloworld/frontend"
DIR="${1:?usage: migrate-sample-to-ng22.sh samples/<name>}"
DIR="${DIR%/}"
FE="$DIR/frontend"

[ -d "$FE" ] || { echo "No such frontend: $FE" >&2; exit 1; }
# Compare resolved paths, not the strings: './samples/helloworld', a trailing-slash spelling or a
# symlink would all slip past a literal compare and reach the destructive rm -f below.
[ "$(cd "$DIR" && pwd -P)" != "$(cd samples/helloworld && pwd -P)" ] \
  || { echo "Refusing: helloworld is the source of truth" >&2; exit 1; }
[ -f "$SRC/federation.config.js" ] || { echo "helloworld is not migrated yet — run Task 5 first" >&2; exit 1; }

# Capture the values that must survive the projection.
REMOTE_NAME="$(jq -r '.frontend.remote.remoteName' "$DIR/manifest.json")"
PKG_NAME="$(jq -r '.name' "$FE/package.json")"
PKG_DESC="$(jq -r '.description' "$FE/package.json")"
[ "$REMOTE_NAME" != "null" ] && [ -n "$REMOTE_NAME" ] \
  || { echo "No frontend.remote.remoteName in $DIR/manifest.json" >&2; exit 1; }

# Remove the Webpack + dev-shell files (idempotent).
rm -f "$FE/webpack.config.js" "$FE/webpack-shared-lib.js" \
      "$FE/src/index.html" "$FE/src/polyfills.ts" "$FE/src/bootstrap.ts" \
      "$FE/src/app/app.module.ts" "$FE/src/app/app.component.ts"

# Project the scaffolding.
for f in federation.config.js angular.json tsconfig.json tsconfig.app.json src/main.ts package.json; do
  mkdir -p "$(dirname "$FE/$f")"
  cp "$SRC/$f" "$FE/$f"
done

# Restore the per-sample identity. The Angular project key inside angular.json is derived from the
# npm package name (duplo-extension-<x>-remote -> <x>-remote) so build/esbuild target refs stay valid.
PROJECT_KEY="${PKG_NAME#duplo-extension-}"     # duplo-extension-network-stack-remote -> network-stack-remote
perl -pi -e "s/duploExtensionHelloworld/$REMOTE_NAME/g" "$FE/federation.config.js"
perl -pi -e "s/helloworld-remote/$PROJECT_KEY/g" "$FE/angular.json"
jq --arg n "$PKG_NAME" --arg d "$PKG_DESC" '.name = $n | .description = $d' \
  "$FE/package.json" > "$FE/package.json.tmp" && mv "$FE/package.json.tmp" "$FE/package.json"

# Flip the manifest's remoteEntry to the Native Federation entry. Targeted substitution, NOT a jq
# round-trip: jq's pretty-printer reflows the whole document (compact records exploded onto separate
# lines, blank-line grouping stripped), and these manifests are hand-authored reference material that
# people read and copy. One semantic line changes; the rest of the file must stay byte-identical.
perl -pi -e 's{/remoteEntry\.js"}{/remoteEntry.json"}' "$DIR/manifest.json"

echo "==> Projected NG22 scaffolding onto $DIR"
echo "    container name : $REMOTE_NAME"
echo "    project key    : $PROJECT_KEY"
echo "    next: add 'standalone: false' to every @Component in $FE/src/app (Angular 19+ flipped the"
echo "          default; without it the build dies with NG6008), then:"
echo "          (cd $FE && rm -rf node_modules package-lock.json && npm install && npm run build)"
