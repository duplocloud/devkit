#!/usr/bin/env bash
# Tests for the multi-SDK build path in scripts/build-extension.sh (DUPLOAI-4430): a non-empty DUPLO_SDK_VERSIONS
# builds one bundle per version from the package feed, with no host call, while an empty value keeps today's
# single host build. Runs the real script natively against a temp copy of samples/helloworld, with dotnet, npm and
# curl stubbed on PATH, so it needs no network, no SDK host and no .NET toolchain.
# Usage: ./tests/test-build-sdk-versions.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

PASS=0; FAIL=0
t()   { printf '  %s … ' "$1"; }
ok()  { echo "ok"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"; rm -rf "$EXT"' EXIT
mkdir -p "$TMP/bin" "$TMP/calls"
ROOT="$PWD"

# A real, small SDK bundle for the host path: the script unzips it and digests the extraction.
mkdir -p "$TMP/sdkfeed" && echo pkg > "$TMP/sdkfeed/Duplocloud.AiHelpdesk.Sdk.1.0.6.nupkg"
( cd "$TMP/sdkfeed" && zip -q "$TMP/sdk.zip" ./*.nupkg )

# curl: records every requested URL, so a feed build can be asserted to make no host call. Answers sdk-version and
# sdk-bundle for the host path.
cat > "$TMP/bin/curl" <<EOF
#!/usr/bin/env bash
out=""; url=""
while [ \$# -gt 0 ]; do case "\$1" in -o) out=\$2; shift ;; http*) url=\$1 ;; esac; shift; done
echo "\$url" >> "$TMP/calls/curl"
case "\$url" in
  */sdk-version) printf '{"version":"1.0.6"}' > "\$out"; printf 200 ;;
  */sdk-bundle)  cp "$TMP/sdk.zip" "\$out" ;;
esac
EOF

# dotnet: records each call, and on a publish writes the output the script reads next. The baseline leaves one
# host-provided DLL and the extension publish leaves that plus its own, so the bundle ships exactly the extension's.
# An extension publish fails as the real compiler does (CS0579, duplicate AssemblyInfo) when a baseline project is
# still under backend/, which a per-version build leaves behind unless it removes it before the next version.
cat > "$TMP/bin/dotnet" <<EOF
#!/usr/bin/env bash
echo "dotnet \$*" >> "$TMP/calls/dotnet"
case "\$*" in publish\ Duplo.Extension.HelloWorld.csproj*)
  [ ! -d _sdkbaseline ] || { echo "error CS0579: Duplicate 'AssemblyVersion' attribute" >&2; exit 1; } ;;
esac
out=""; prev=""
for a in "\$@"; do [ "\$prev" = -o ] && out=\$a; prev=\$a; done
[ -n "\$out" ] || exit 0
mkdir -p "\$out" && echo dll > "\$out/Duplo.Ai.Common.dll"
case "\$*" in *_sdkbaseline.csproj*) ;; *) echo dll > "\$out/Duplo.Extension.HelloWorld.dll" ;; esac
exit 0
EOF

# npm: records calls; run build writes the frontend dist the bundle copies.
cat > "$TMP/bin/npm" <<EOF
#!/usr/bin/env bash
echo "npm \$*" >> "$TMP/calls/npm"
[ "\$1 \$2" = "run build" ] && mkdir -p dist && echo js > dist/remoteEntry.js
exit 0
EOF
chmod +x "$TMP/bin/curl" "$TMP/bin/dotnet" "$TMP/bin/npm"
export PATH="$TMP/bin:$PATH"

EXT="samples/.test-build-sdk-versions"
# rebuild [env...]: builds the copy natively with the given environment, over whatever the last build left in dist/.
rebuild() {
  : > "$TMP/calls/dotnet"; : > "$TMP/calls/npm"; : > "$TMP/calls/curl"
  env -u ARMDOT_LICENSE_FILE_PATH DUPLO_TARGET=remote DUPLO_HOST=http://stub.invalid DUPLO_TOKEN=t "$@" \
    "$ROOT/scripts/build-extension.sh" --native "$EXT" > "$TMP/build.log" 2>&1
  RC=$?
}
# run_build [env...]: copies the sample into the checkout fresh, then builds it.
run_build() {
  rm -rf "$EXT"
  cp -R samples/helloworld "$EXT"
  rm -rf "$EXT/dist" "$EXT/backend/obj" "$EXT/backend/bin" "$EXT/frontend/node_modules" "$EXT/frontend/dist"
  rebuild "$@"
}
sdkver() { jq -r '.sdkVersion' "$EXT/dist/$1/pkg/manifest.json" 2>/dev/null; }

echo "build sdk versions:"

t "feed mode: two versions produce two bundles, each stamped with its own sdkVersion"
run_build DUPLO_SDK_VERSIONS=1.0.6,1.0.7
[ "$RC" = 0 ] \
  && [ -f "$EXT/dist/sdk-1.0.6/extension.zip" ] && [ -f "$EXT/dist/sdk-1.0.7/extension.zip" ] \
  && [ "$(sdkver sdk-1.0.6)" = 1.0.6 ] && [ "$(sdkver sdk-1.0.7)" = 1.0.7 ] \
  && ok || bad "rc=$RC $(tail -5 "$TMP/build.log")"

t "feed mode: makes no host sdk-version or sdk-bundle call"
[ ! -s "$TMP/calls/curl" ] && ok || bad "curl was called: $(cat "$TMP/calls/curl")"

t "feed mode: the frontend is built once, not once per version"
[ "$(grep -c 'run build' "$TMP/calls/npm")" = 1 ] && ok || bad "npm run build count: $(grep -c 'run build' "$TMP/calls/npm")"

t "feed mode: each backend publish targets its own SDK version"
grep 'publish Duplo.Extension.HelloWorld.csproj' "$TMP/calls/dotnet" | grep -q -- '-p:DuploSdkVersion=1.0.6' \
  && grep 'publish Duplo.Extension.HelloWorld.csproj' "$TMP/calls/dotnet" | grep -q -- '-p:DuploSdkVersion=1.0.7' \
  && ok || bad "$(grep publish "$TMP/calls/dotnet")"

t "feed mode: no sdkDigest is stamped (nothing fingerprints a feed build)"
[ "$(jq -r '.sdkDigest // "absent"' "$EXT/dist/sdk-1.0.6/pkg/manifest.json")" = absent ] \
  && ok || bad "sdkDigest present: $(jq -r '.sdkDigest' "$EXT/dist/sdk-1.0.6/pkg/manifest.json")"

t "feed mode: no single-bundle dist/extension.zip is produced"
[ ! -f "$EXT/dist/extension.zip" ] && ok || bad "unexpected dist/extension.zip in feed mode"

t "a trailing comma or spaces in the version list are ignored"
run_build DUPLO_SDK_VERSIONS=" 1.0.6 , "
[ "$RC" = 0 ] && [ -f "$EXT/dist/sdk-1.0.6/extension.zip" ] && [ ! -d "$EXT/dist/sdk-" ] \
  && ok || bad "rc=$RC $(tail -5 "$TMP/build.log")"

t "host mode (empty list): one bundle at dist/extension.zip from the host SDK, with a digest"
run_build
[ "$RC" = 0 ] && [ -f "$EXT/dist/extension.zip" ] \
  && [ "$(jq -r '.sdkVersion' "$EXT/dist/pkg/manifest.json")" = 1.0.6 ] \
  && [ "$(jq -r '.sdkDigest // "absent"' "$EXT/dist/pkg/manifest.json")" != absent ] \
  && ok || bad "rc=$RC $(tail -5 "$TMP/build.log")"

t "host mode: calls the host sdk-version endpoint"
grep -q 'sdk-version' "$TMP/calls/curl" && ok || bad "no sdk-version call: $(cat "$TMP/calls/curl")"

t "feed mode over a host build: the host bundle is removed, so only the per-version bundles are left"
rebuild DUPLO_SDK_VERSIONS=1.0.6
[ "$RC" = 0 ] && [ -f "$EXT/dist/sdk-1.0.6/extension.zip" ] && [ ! -f "$EXT/dist/extension.zip" ] \
  && ok || bad "rc=$RC stale=$(ls "$EXT/dist/extension.zip" 2>/dev/null) $(tail -5 "$TMP/build.log")"

t "feed mode with a shorter list: a bundle for a version no longer listed is removed"
rebuild DUPLO_SDK_VERSIONS=1.0.6,1.0.7
[ "$RC" = 0 ] && [ -f "$EXT/dist/sdk-1.0.6/extension.zip" ] && [ -f "$EXT/dist/sdk-1.0.7/extension.zip" ] || bad "setup rc=$RC"
rebuild DUPLO_SDK_VERSIONS=1.0.7
[ "$RC" = 0 ] && [ -f "$EXT/dist/sdk-1.0.7/extension.zip" ] && [ ! -d "$EXT/dist/sdk-1.0.6" ] \
  && ok || bad "rc=$RC stale=$(ls -d "$EXT/dist/sdk-1.0.6" 2>/dev/null) $(tail -5 "$TMP/build.log")"

echo ""
echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
