#!/usr/bin/env bash
# Tests for the ArmDot obfuscation switch in scripts/build-extension.sh: the publish flags it passes, the targets file
# it drops beside the csproj for one build, and the obfuscation stamp it writes into the bundle manifest.
# Runs the real script natively against a temp copy of samples/helloworld, with dotnet, npm and curl stubbed on PATH,
# so it needs no network, no SDK host and no .NET toolchain. Usage: ./tests/test-build-obfuscation.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

PASS=0; FAIL=0
t()   { printf '  %s … ' "$1"; }
ok()  { echo "ok"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/calls"
ROOT="$PWD"

# A real, small SDK bundle: the script unzips it and digests the extraction, so it has to be a valid zip.
mkdir -p "$TMP/sdkfeed" && echo pkg > "$TMP/sdkfeed/Duplocloud.AiHelpdesk.Sdk.1.0.6.nupkg"
( cd "$TMP/sdkfeed" && zip -q "$TMP/sdk.zip" ./*.nupkg )

# curl: sdk-version answers {"version":"1.0.6"} through -o and -w, sdk-bundle copies the zip above to -o.
cat > "$TMP/bin/curl" <<EOF
#!/usr/bin/env bash
out=""; url=""
while [ \$# -gt 0 ]; do case "\$1" in -o) out=\$2; shift ;; http*) url=\$1 ;; esac; shift; done
case "\$url" in
  */sdk-version) printf '{"version":"1.0.6"}' > "\$out"; printf 200 ;;
  */sdk-bundle)  cp "$TMP/sdk.zip" "\$out" ;;
esac
EOF

# dotnet: records each call's argv on one line, and on a publish writes the output the script reads next. The
# baseline publish leaves one host-provided DLL and the extension publish leaves that one plus its own, so the
# bundle ships exactly the extension's DLL. Each line also says whether Directory.Build.targets sat beside the
# project at publish time, since an obfuscation flag without that import would stamp a bundle ArmDot never touched,
# and a copy of that file is kept, since the script removes it before the build ends.
# DOTNET_FAIL_EXT=1 makes the extension publish fail, to exercise cleanup on the failure path.
cat > "$TMP/bin/dotnet" <<EOF
#!/usr/bin/env bash
echo "dotnet \$* targets=\$([ -f Directory.Build.targets ] && echo yes || echo no)" >> "$TMP/calls/dotnet"
[ -f Directory.Build.targets ] && cp Directory.Build.targets "$TMP/calls/Directory.Build.targets"
out=""; prev=""
for a in "\$@"; do [ "\$prev" = -o ] && out=\$a; prev=\$a; done
[ -n "\$out" ] || exit 0
case "\$*" in *_sdkbaseline.csproj*) ;; *) [ "\${DOTNET_FAIL_EXT:-}" = 1 ] && exit 1 ;; esac
mkdir -p "\$out" && echo dll > "\$out/Duplo.Ai.Common.dll"
case "\$*" in *_sdkbaseline.csproj*) ;; *) echo dll > "\$out/Duplo.Extension.HelloWorld.dll" ;; esac
exit 0
EOF

# npm: ci and install do nothing, run build writes the frontend dist the bundle copies.
cat > "$TMP/bin/npm" <<'EOF'
#!/usr/bin/env bash
[ "$1 $2" = "run build" ] && mkdir -p dist && echo js > dist/remoteEntry.js
exit 0
EOF
chmod +x "$TMP/bin/curl" "$TMP/bin/dotnet" "$TMP/bin/npm"
export PATH="$TMP/bin:$PATH"

echo k > "$TMP/lic.key"
ARMDOT_VERSION="$(sed -nE 's/.*<ArmDotEngineVersion>([^<]+)<.*/\1/p' build/ArmDot.Obfuscation.props)"

# run_build [env...]: copies the sample into the checkout (the script refuses paths outside it), builds it natively
# with the given environment, and leaves its exit code in RC and its bundle manifest at $TMP/manifest.json.
EXT="samples/.test-build-obfuscation"
# RUN_FROM=<dir> runs the script from that directory instead of the repo root, to test relative license paths.
# PRESET_REF=<include> adds a ProjectReference with that Include, as a csproj would write it, to the entry project and
# creates the referenced project unless it exists or the Include holds an MSBuild property; PRESET_REF_SUB=<include>
# does the same from that project, one level down. PRESET_REF_CHAIN='<include>;<include>…' adds each from the project
# the previous one created, for deeper trees. PRESET_REF_MULTILINE=1 writes the element across two lines, as a
# csproj with several attributes does. PRESET_REF_COMMENTED=1 writes the element inside an XML comment, as a reference
# left behind is. PRESET_REF_TARGETS=<dir> drops a Directory.Build.targets under backend/<dir>.
add_ref() {
  local from="$1" to
  to="$(dirname "$from")/$(printf '%s' "$2" | tr '\\' '/')"
  case "$2" in
    *'$('*|*'*'*|*'?'*|*';'*) ;;
    *) [ -f "$to" ] || { mkdir -p "$(dirname "$to")" && printf '%s\n' '<Project Sdk="Microsoft.NET.Sdk">' '</Project>' > "$to"; } ;;
  esac
  if [ -n "${PRESET_REF_COMMENTED:-}" ]; then
    INC="$2" awk '/<\/Project>/{print "  <ItemGroup>"; print "    <!-- <ProjectReference Include=\"" ENVIRON["INC"] "\" /> -->"; print "  </ItemGroup>"} {print}' \
      "$from" > "$from.tmp" && mv "$from.tmp" "$from"
  elif [ -n "${PRESET_REF_MULTILINE:-}" ]; then
    INC="$2" awk '/<\/Project>/{print "  <ItemGroup>"; print "    <ProjectReference"; print "      Include=\"" ENVIRON["INC"] "\""; print "      PrivateAssets=\"all\" />"; print "  </ItemGroup>"} {print}' \
      "$from" > "$from.tmp" && mv "$from.tmp" "$from"
  else
    INC="$2" awk '/<\/Project>/{print "  <ItemGroup>"; print "    <ProjectReference Include=\"" ENVIRON["INC"] "\" />"; print "  </ItemGroup>"} {print}' \
      "$from" > "$from.tmp" && mv "$from.tmp" "$from"
  fi
  REF_CREATED="$to"
}
run_build() {
  rm -rf "$EXT" "$TMP/manifest.json" "$TMP/calls/Directory.Build.targets"; : > "$TMP/calls/dotnet"
  cp -R samples/helloworld "$EXT"
  rm -rf "$EXT/dist" "$EXT/backend/obj" "$EXT/backend/bin" "$EXT/frontend/node_modules" "$EXT/frontend/dist"
  if [ -n "${PRESET_REF:-}" ]; then
    add_ref "$EXT/backend/Duplo.Extension.HelloWorld.csproj" "$PRESET_REF"
    [ -n "${PRESET_REF_SUB:-}" ] && add_ref "$REF_CREATED" "$PRESET_REF_SUB"
  fi
  if [ -n "${PRESET_REF_CHAIN:-}" ]; then
    REF_CREATED="$EXT/backend/Duplo.Extension.HelloWorld.csproj"
    while IFS= read -r inc; do [ -n "$inc" ] && add_ref "$REF_CREATED" "$inc"; done < <(printf '%s\n' "$PRESET_REF_CHAIN" | tr ';' '\n')
  fi
  [ -n "${PRESET_REF_TARGETS:-}" ] && mkdir -p "$EXT/backend/$PRESET_REF_TARGETS" \
    && echo '<Project />' > "$EXT/backend/$PRESET_REF_TARGETS/Directory.Build.targets"
  [ -n "${PRESET_TARGETS:-}" ] && echo "$PRESET_TARGETS" > "$EXT/backend/Directory.Build.targets"
  [ -n "${PRESET_MANIFEST_KEY:-}" ] && jq '.obfuscation = {tool: "armdot", version: "0.0.0"}' samples/helloworld/manifest.json \
    > "$EXT/manifest.json"
  ( cd "${RUN_FROM:-.}" && env -u ARMDOT_LICENSE_FILE_PATH DUPLO_TARGET=remote DUPLO_HOST=http://stub.invalid DUPLO_TOKEN=t "$@" \
    "$ROOT/scripts/build-extension.sh" --native "$EXT" ) > "$TMP/build.log" 2>&1
  RC=$?
  [ -f "$EXT/dist/pkg/manifest.json" ] && cp "$EXT/dist/pkg/manifest.json" "$TMP/manifest.json"
}
cleanup_ext() { rm -rf "$EXT"; }
trap 'rm -rf "$TMP"; cleanup_ext' EXIT

echo "build obfuscation:"

t "the stamp version comes from the props pin"
[ -n "$ARMDOT_VERSION" ] && ok || bad "no ArmDotEngineVersion in build/ArmDot.Obfuscation.props"

t "plain build: succeeds with no DuploObfuscate=true, no obfuscation key, no targets file left"
run_build
[ "$RC" = 0 ] && ! grep -q 'DuploObfuscate=true' "$TMP/calls/dotnet" \
  && [ "$(jq -r '.obfuscation // "absent"' "$TMP/manifest.json" 2>/dev/null)" = absent ] \
  && [ ! -f "$EXT/backend/Directory.Build.targets" ] && ok || bad "rc=$RC $(tail -5 "$TMP/build.log")"

t "licensed build: the extension publish passes DuploObfuscate, ArmDotLicenseFile and DuploDevkitBuildDir"
run_build ARMDOT_LICENSE_FILE_PATH="$TMP/lic.key"
want="-p:DuploObfuscate=true -p:ArmDotLicenseFile=$TMP/lic.key -p:DuploDevkitBuildDir=$ROOT/build/"
[ "$RC" = 0 ] && grep 'publish Duplo.Extension.HelloWorld.csproj' "$TMP/calls/dotnet" | grep -qF -- "$want" \
  && ok || bad "rc=$RC $(cat "$TMP/calls/dotnet") $(tail -5 "$TMP/build.log")"

t "licensed build: Directory.Build.targets sits beside the csproj while the extension publishes"
grep 'publish Duplo.Extension.HelloWorld.csproj' "$TMP/calls/dotnet" | grep -q 'targets=yes' && ok || bad "$(cat "$TMP/calls/dotnet")"

# MSBuild imports only the nearest Directory.Build.targets, so the dropped file has to chain to the one above
# backend/ itself, or an extension's own build logic goes missing for the licensed build only. The stubbed dotnet
# never evaluates it, so this reads the file as dropped: the parent import first, found from the extension root up,
# with no DuploObfuscate condition on it.
t "licensed build: the dropped Directory.Build.targets imports the next one above backend/, unconditionally"
parent="$(grep -n "GetPathOfFileAbove('Directory.Build.targets', '\$(MSBuildThisFileDirectory)../')" "$TMP/calls/Directory.Build.targets" \
  | head -1 | cut -d: -f1)"
armdot="$(grep -n 'ArmDot.Obfuscation.targets' "$TMP/calls/Directory.Build.targets" | head -1 | cut -d: -f1)"
if [ -n "$parent" ] && [ -n "$armdot" ] && [ "$parent" -lt "$armdot" ] \
   && grep -q '<Import Project="$(DuploParentBuildTargets)" Condition="'"'"'$(DuploParentBuildTargets)'"'"' != '"''"'" />' "$TMP/calls/Directory.Build.targets" \
   && ! grep '<Import Project="$(DuploParentBuildTargets)"' "$TMP/calls/Directory.Build.targets" | grep -q DuploObfuscate; then ok
else bad "$(cat "$TMP/calls/Directory.Build.targets" 2>&1)"; fi

t "plain build: no Directory.Build.targets beside the csproj while the extension publishes"
run_build
grep 'publish Duplo.Extension.HelloWorld.csproj' "$TMP/calls/dotnet" | grep -q 'targets=no' && ok || bad "$(cat "$TMP/calls/dotnet")"
run_build ARMDOT_LICENSE_FILE_PATH="$TMP/lic.key"

t "licensed build: the baseline publish is told not to obfuscate"
grep 'publish _sdkbaseline.csproj' "$TMP/calls/dotnet" | grep -qF -- '-p:DuploObfuscate=false' && ok || bad "$(cat "$TMP/calls/dotnet")"

t "licensed build: the manifest carries the armdot stamp at the pinned version"
[ "$(jq -c '.obfuscation' "$TMP/manifest.json" 2>/dev/null)" = "{\"tool\":\"armdot\",\"version\":\"$ARMDOT_VERSION\"}" ] \
  && ok || bad "$(jq -c '.obfuscation' "$TMP/manifest.json" 2>&1)"

t "licensed build: the dropped Directory.Build.targets is removed afterwards"
[ ! -f "$EXT/backend/Directory.Build.targets" ] && ok || bad "left behind"

t "licensed build whose publish fails: the build fails and the dropped targets file is still removed"
run_build ARMDOT_LICENSE_FILE_PATH="$TMP/lic.key" DOTNET_FAIL_EXT=1
[ "$RC" != 0 ] && [ ! -f "$EXT/backend/Directory.Build.targets" ] && ok || bad "rc=$RC"

t "an empty license variable (as compose passes it) is a plain build"
run_build ARMDOT_LICENSE_FILE_PATH=
[ "$RC" = 0 ] && ! grep -q 'DuploObfuscate=true' "$TMP/calls/dotnet" \
  && [ "$(jq -r '.obfuscation // "absent"' "$TMP/manifest.json" 2>/dev/null)" = absent ] && ok || bad "rc=$RC"

t "a license path naming a missing file fails before any dotnet call"
run_build ARMDOT_LICENSE_FILE_PATH="$TMP/nope.key"
[ "$RC" != 0 ] && [ ! -s "$TMP/calls/dotnet" ] && grep -q 'ARMDOT_LICENSE_FILE_PATH names a missing or empty file' "$TMP/build.log" \
  && ok || bad "rc=$RC $(tail -3 "$TMP/build.log")"

t "a Directory.Build.targets the extension already owns is never overwritten"
PRESET_TARGETS='<Project/>' run_build ARMDOT_LICENSE_FILE_PATH="$TMP/lic.key"
[ "$RC" != 0 ] && [ "$(cat "$EXT/backend/Directory.Build.targets")" = '<Project/>' ] && [ ! -s "$TMP/calls/dotnet" ] \
  && ok || bad "rc=$RC"

t "a leftover Directory.Build.targets identical to the template is treated as ours and the build proceeds"
PRESET_TARGETS="$(cat build/Directory.Build.targets.template)" run_build ARMDOT_LICENSE_FILE_PATH="$TMP/lic.key"
[ "$RC" = 0 ] && grep 'publish Duplo.Extension.HelloWorld.csproj' "$TMP/calls/dotnet" | grep -q 'targets=yes' \
  && [ ! -f "$EXT/backend/Directory.Build.targets" ] && ok || bad "rc=$RC $(tail -3 "$TMP/build.log")"

t "a license path naming a directory is refused before any dotnet call"
run_build ARMDOT_LICENSE_FILE_PATH="$TMP"
[ "$RC" != 0 ] && [ ! -s "$TMP/calls/dotnet" ] && grep -q 'names a missing or empty file' "$TMP/build.log" \
  && ok || bad "rc=$RC $(tail -3 "$TMP/build.log")"

t "a relative license path is taken relative to where the script was run, not the repo root"
mkdir -p "$TMP/elsewhere" && echo k > "$TMP/elsewhere/rel.key"
RUN_FROM="$TMP/elsewhere" run_build ARMDOT_LICENSE_FILE_PATH=rel.key
[ "$RC" = 0 ] && grep 'publish Duplo.Extension.HelloWorld.csproj' "$TMP/calls/dotnet" \
  | grep -qF -- "-p:ArmDotLicenseFile=$TMP/elsewhere/rel.key" && ok || bad "rc=$RC $(cat "$TMP/calls/dotnet") $(tail -3 "$TMP/build.log")"

t "a stale obfuscation key in the source manifest is dropped by a plain build"
PRESET_MANIFEST_KEY=1 run_build
[ "$RC" = 0 ] && [ "$(jq -r '.obfuscation // "absent"' "$TMP/manifest.json" 2>/dev/null)" = absent ] && ok || bad "rc=$RC"

t "a stale obfuscation key is replaced by a licensed build"
PRESET_MANIFEST_KEY=1 run_build ARMDOT_LICENSE_FILE_PATH="$TMP/lic.key"
got="$(jq -r '.obfuscation.version' "$TMP/manifest.json" 2>/dev/null)"
[ "$got" = "$ARMDOT_VERSION" ] && ok || bad "$(jq -c .obfuscation "$TMP/manifest.json" 2>&1)"

# Only projects under backend/ import the dropped targets file, so a reference that leads outside it would ship a
# plain assembly in a bundle stamped obfuscated. The Include paths use backslashes, as a csproj written on Windows does.
t "licensed build: a reference outside backend/ fails before any dotnet call and names the project"
PRESET_REF='..\shared\Shared.csproj' run_build ARMDOT_LICENSE_FILE_PATH="$TMP/lic.key"
[ "$RC" != 0 ] && [ ! -s "$TMP/calls/dotnet" ] && grep -q 'lead to projects that do not' "$TMP/build.log" \
  && grep -q 'Duplo.Extension.HelloWorld.csproj -> .*/shared/Shared.csproj' "$TMP/build.log" \
  && [ ! -f "$EXT/backend/Directory.Build.targets" ] && ok || bad "rc=$RC $(cat "$TMP/calls/dotnet") $(tail -4 "$TMP/build.log")"

t "plain build: the same reference outside backend/ builds, with no obfuscation key"
PRESET_REF='..\shared\Shared.csproj' run_build
[ "$RC" = 0 ] && [ "$(jq -r '.obfuscation // "absent"' "$TMP/manifest.json" 2>/dev/null)" = absent ] && ok || bad "rc=$RC $(tail -4 "$TMP/build.log")"

t "licensed build: a reference inside backend/ builds and carries the stamp"
PRESET_REF='Shared\Shared.csproj' run_build ARMDOT_LICENSE_FILE_PATH="$TMP/lic.key"
[ "$RC" = 0 ] && [ "$(jq -r '.obfuscation.version' "$TMP/manifest.json" 2>/dev/null)" = "$ARMDOT_VERSION" ] \
  && ok || bad "rc=$RC $(tail -4 "$TMP/build.log")"

t "licensed build: a reference that leaves backend/ from a referenced project is caught too"
PRESET_REF='Shared\Shared.csproj' PRESET_REF_SUB='..\..\common\Common.csproj' run_build ARMDOT_LICENSE_FILE_PATH="$TMP/lic.key"
[ "$RC" != 0 ] && [ ! -s "$TMP/calls/dotnet" ] && grep -q 'Shared.csproj -> .*/common/Common.csproj' "$TMP/build.log" \
  && ok || bad "rc=$RC $(tail -4 "$TMP/build.log")"

t "licensed build: a reference that leaves backend/ three projects down is caught"
PRESET_REF_CHAIN='Api\Api.csproj;..\Services\Services.csproj;..\..\shared\Domain.csproj' run_build ARMDOT_LICENSE_FILE_PATH="$TMP/lic.key"
[ "$RC" != 0 ] && [ ! -s "$TMP/calls/dotnet" ] && grep -q 'Services.csproj -> .*/shared/Domain.csproj' "$TMP/build.log" \
  && ok || bad "rc=$RC $(tail -4 "$TMP/build.log")"

t "licensed build: two projects inside backend/ that reference each other build, so a cycle ends the walk"
PRESET_REF_CHAIN='Shared\Shared.csproj;..\Duplo.Extension.HelloWorld.csproj' run_build ARMDOT_LICENSE_FILE_PATH="$TMP/lic.key"
[ "$RC" = 0 ] && [ "$(jq -r '.obfuscation.version' "$TMP/manifest.json" 2>/dev/null)" = "$ARMDOT_VERSION" ] \
  && ok || bad "rc=$RC $(tail -4 "$TMP/build.log")"

# MSBuild imports the nearest Directory.Build.targets above a project, so one between a referenced project and backend/
# replaces the dropped import for that project and it publishes plain.
t "licensed build: a Directory.Build.targets between a referenced project and backend/ is refused and named"
PRESET_REF='Shared\Impl\Impl.csproj' PRESET_REF_TARGETS=Shared run_build ARMDOT_LICENSE_FILE_PATH="$TMP/lic.key"
[ "$RC" != 0 ] && [ ! -s "$TMP/calls/dotnet" ] && grep -q 'Impl.csproj, which imports .*Shared/Directory.Build.targets' "$TMP/build.log" \
  && ok || bad "rc=$RC $(tail -4 "$TMP/build.log")"

t "licensed build: an Include built from an MSBuild property is refused rather than read as inside"
PRESET_REF='$(MSBuildProjectDirectory)\..\..\shared\Shared.csproj' run_build ARMDOT_LICENSE_FILE_PATH="$TMP/lic.key"
[ "$RC" != 0 ] && [ ! -s "$TMP/calls/dotnet" ] && grep -qF 'HelloWorld.csproj -> $(MSBuildProjectDirectory)/../../shared/Shared.csproj' "$TMP/build.log" \
  && ok || bad "rc=$RC $(tail -4 "$TMP/build.log")"

t "licensed build: a ProjectReference written across lines is still read"
PRESET_REF='..\shared\Shared.csproj' PRESET_REF_MULTILINE=1 run_build ARMDOT_LICENSE_FILE_PATH="$TMP/lic.key"
[ "$RC" != 0 ] && [ ! -s "$TMP/calls/dotnet" ] && grep -q 'HelloWorld.csproj -> .*/shared/Shared.csproj' "$TMP/build.log" \
  && ok || bad "rc=$RC $(tail -4 "$TMP/build.log")"

t "licensed build: an Include with a wildcard is refused as written rather than read as inside"
PRESET_REF='..\libs\*\Lib.csproj' run_build ARMDOT_LICENSE_FILE_PATH="$TMP/lic.key"
[ "$RC" != 0 ] && [ ! -s "$TMP/calls/dotnet" ] && grep -qF 'HelloWorld.csproj -> ../libs/*/Lib.csproj' "$TMP/build.log" \
  && ok || bad "rc=$RC $(tail -4 "$TMP/build.log")"

t "licensed build: an Include listing several projects is refused as written"
PRESET_REF='Shared\Shared.csproj;..\other\Other.csproj' run_build ARMDOT_LICENSE_FILE_PATH="$TMP/lic.key"
[ "$RC" != 0 ] && [ ! -s "$TMP/calls/dotnet" ] && grep -qF 'HelloWorld.csproj -> Shared/Shared.csproj;../other/Other.csproj' "$TMP/build.log" \
  && ok || bad "rc=$RC $(tail -4 "$TMP/build.log")"

t "licensed build: a commented-out reference to a project still on disk is not read"
PRESET_REF='..\old\Old.csproj' PRESET_REF_COMMENTED=1 run_build ARMDOT_LICENSE_FILE_PATH="$TMP/lic.key"
[ "$RC" = 0 ] && [ -s "$TMP/calls/dotnet" ] && ! grep -q 'Old.csproj' "$TMP/build.log" \
  && ok || bad "rc=$RC $(tail -4 "$TMP/build.log")"

t "the refusal says to exclude the moved folder from the entry project's default items"
PRESET_REF='..\shared\Shared.csproj' run_build ARMDOT_LICENSE_FILE_PATH="$TMP/lic.key"
grep -q 'DefaultItemExcludes' "$TMP/build.log" && ok || bad "$(tail -4 "$TMP/build.log")"

echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
