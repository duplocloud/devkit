#!/usr/bin/env bash
# Build an extension into <dir>/dist/extension.zip, against the locally-running platform's SDK feed.
# Mirrors the duplo-extension-dev skill (fetch SDK → dotnet publish → npm build → zip).
#
# The build runs inside the builder container (.NET SDK 8 + Node 22) so Docker Compose is the only
# prerequisite. Pass --native, or set DUPLO_BUILD_NATIVE=1, to use a toolchain you installed yourself.
# A build already running inside a container (e.g. the agent's) stays native automatically — see
# scripts/_builder.sh.
#
# <extension-dir> must be INSIDE this checkout (no absolute path, no ../): only the checkout is mounted
# into the build container, so anything outside it does not exist in there. `--native` has no such limit
# and takes a path anywhere on disk.
#
# Usage: ./scripts/build-extension.sh [--native] [--validate-only] <extension-dir>   # e.g. ./extension or samples/helloworld
# --validate-only runs just the manifest/naming gate (no SDK fetch, no builder, no build) and exits.
set -euo pipefail
# _builder.sh is sourced before the cd so the license path resolves against the caller's directory, not the repo
# root. It defines functions only, and builder_dispatch (below) is what needs _target.sh sourced first.
# shellcheck source=scripts/_builder.sh
source "$(dirname "$0")/_builder.sh"  # → native, or re-launch this build in the builder container
builder_resolve_license || exit 1
cd "$(dirname "$0")/.."

# Strip --native before the positional arg is read, so it works in either order.
VALIDATE_ONLY=0
for a in "$@"; do shift; case "$a" in --native) DUPLO_BUILD_NATIVE=1 ;; --validate-only) VALIDATE_ONLY=1 ;; *) set -- "$@" "$a" ;; esac; done

DIR="${1:?usage: build-extension.sh [--native] [--validate-only] <extension-dir>}"
DIR="${DIR%/}"
if [ "$VALIDATE_ONLY" != 1 ]; then
# shellcheck source=scripts/_target.sh
source "$(dirname "$0")/_target.sh"   # → BASE_URL (+ TOKEN) from .env / env per DUPLO_TARGET
# shellcheck source=scripts/_sdk_digest.sh
source "$(dirname "$0")/_sdk_digest.sh"  # → sdk_digest, stamped into the bundle manifest beside sdkVersion
BASE_URL="${BASE_URL%/}"               # tolerate a trailing slash in DUPLO_HOST (avoids // in URLs)
fi
[ -f "$DIR/manifest.json" ] || { echo "No manifest.json in $DIR" >&2; exit 1; }

# Delegates to the builder container unless we're already native (see the header). Never returns in
# the container case.
[ "$VALIDATE_ONLY" = 1 ] || builder_dispatch scripts/build-extension.sh "$DIR"

# From here down we are native and the toolchain is present — builder_dispatch guarantees it.

# Naming gate — enforce the canonical convention BEFORE building (fails fast, no network needed). The platform
# shares one runtime across all extensions, so every customer-facing name MUST be namespaced under extensions/
# (and Mongo collections under extension_). A non-conforming bundle silently collides with built-ins at runtime
# (e.g. a clouds/ FE route resolves to the built-in module → blank page). See
# .claude/skills/duplo-extension-dev/reference/00-naming.md
echo "==> Validating extension naming (reference/00-naming.md)"
MANIFEST="$DIR/manifest.json"
viol=0
# Top-level resources must namespace their own restSegment. A nested child (has a `parent` block) is exempt: its
# restSegment is a leaf and the namespacing comes from parent.routeSegment (checked below) — its route is
# …/extensions/<parent>/{parentId}/<leaf>.
while IFS= read -r seg; do
  case "$seg" in extensions/*) ;; "") ;; *)
    echo "  ✗ resources[].restSegment '$seg' must start with 'extensions/' (e.g. extensions/$seg)" >&2; viol=1 ;;
  esac
done < <(jq -r '.resources[]? | select(.parent == null) | .restSegment // empty' "$MANIFEST")
while IFS= read -r seg; do
  case "$seg" in extensions/*) ;; "") ;; *)
    echo "  ✗ resources[].parent.routeSegment '$seg' must start with 'extensions/' (match the parent's restSegment)" >&2; viol=1 ;;
  esac
done < <(jq -r '.resources[]?.parent?.routeSegment // empty' "$MANIFEST")
while IFS= read -r p; do
  case "$p" in extensions/*) ;; "") ;; *)
    echo "  ✗ frontend.routes[].path '$p' must start with 'extensions/' (never 'clouds/')" >&2; viol=1 ;;
  esac
done < <(jq -r '.frontend.routes[]?.path // empty' "$MANIFEST")
while IFS= read -r u; do
  case "$u" in extensions/*) ;; "") ;; *)
    echo "  ✗ frontend.menus relativeUrl '$u' must start with 'extensions/' (never 'clouds/')" >&2; viol=1 ;;
  esac
done < <(jq -r '.frontend.menus // [] | .. | objects | .relativeUrl? // empty' "$MANIFEST")
if jq -e '.frontend.menu' "$MANIFEST" >/dev/null 2>&1; then
  echo "  ✗ legacy 'frontend.menu' is deprecated — use the 'frontend.menus' array" >&2; viol=1
fi
# shellcheck source=scripts/validate-header-actions.sh
source "$(dirname "$0")/validate-header-actions.sh"
validate_header_actions "$MANIFEST" || viol=1
while IFS= read -r m; do
  name=$(printf '%s' "$m" | sed -E 's/.*BsonCollection\("([^"]*)".*/\1/')
  case "$name" in extension_*) ;; *)
    echo "  ✗ [BsonCollection(\"$name\")] must be prefixed 'extension_' (e.g. extension_$name)" >&2; viol=1 ;;
  esac
done < <(grep -rhoE 'BsonCollection\("[^"]*"\)' "$DIR/backend" 2>/dev/null || true)
while IFS= read -r r; do
  printf '%s' "$r" | grep -qE 'environment/(extensions/|extension-studio)' && continue
  echo "  ✗ controller route not under 'environment/extensions/': $r" >&2; viol=1
done < <(grep -rhoE 'Route\("[^"]*environment/[^"]*"\)' "$DIR/backend" 2>/dev/null || true)
if [ -d "$DIR/skills" ]; then
  bad=$(grep -rnE 'environment/[a-z0-9-]+' "$DIR/skills" 2>/dev/null \
        | grep -vE 'environment/(extensions/|extension-studio)' | grep -vE 'environment/\{' || true)
  [ -n "$bad" ] && { echo "  ! skill callback URL(s) not under 'environment/extensions/' — confirm they target this extension's restSegment:" >&2; printf '%s\n' "$bad" | sed 's/^/      /' >&2; }
fi
# Admin extension scope (reference/21-admin-resources.md). An AdminResourcesController serves a route with no
# {workspaceId}, gated by the Admin Workspace's grants, and owns its rows in the system Admin Workspace; a workspace
# controller must never sit under the admin prefix. The manifest marks admin surfaces with "scope": "admin" on the top-level menu node + its routes.
has_admin=0; has_ws=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  # `|| true`: a file with no Route(" attribute (a child that only routes its actions via [HttpPost("~/…")], or
  # one that names ResourcesController< in a comment) must not abort the script under pipefail.
  route=$( { grep -oE 'Route\("[^"]*"\)' "$f" || true; } | head -1 | sed -E 's/Route\("([^"]*)"\)/\1/')
  # A child controller often has no class-level [Route] and roots its actions instead (03-base-classes).
  [ -n "$route" ] || route=$( { grep -oE 'Http[A-Za-z]+\("~/[^"]*"' "$f" || true; } | head -1 | sed -E 's/.*"~\/([^"]*)"/\1/')
  if grep -qE ':[[:space:]]*AdminResourcesController<' "$f"; then
    has_admin=1
    case "$route" in v1/aiservicedesk/admin/data/environment/extensions/*) ;; *)
      echo "  ✗ $(basename "$f"): an AdminResourcesController must be routed at 'v1/aiservicedesk/admin/data/environment/extensions/<…>' (got '$route')" >&2; viol=1 ;;
    esac
    # Mirrors the host's startup check: an admin controller whose entity is not a registered access node fails
    # the access registry rebuild, and the extension load is rolled back.
    grep -qE '^[[:space:]]*\[([^]/]*[,[:space:]])?AccessControl\(' "$f" || {
      echo "  ✗ $(basename "$f"): an AdminResourcesController must declare its access node — [AccessControl(Parent = typeof(Workspace), ParentIdProperty = \"OwnerWorkspaceId\")] — or the host rejects the load" >&2; viol=1; }
  elif grep -qE ':[[:space:]]*ChildResourceController<' "$f" && grep -qE 'override string GetWorkspaceIdFromRoute' "$f"; then
    # Admin child: the SDK has no admin ChildResourceController, so the extension's child controller
    # overrides GetWorkspaceIdFromRoute (+ the workspaceId actions) itself — see reference/21-admin-resources.md.
    has_admin=1
    case "$route" in v1/aiservicedesk/admin/data/environment/extensions/*) ;; *)
      echo "  ✗ $(basename "$f"): an admin child controller (overrides GetWorkspaceIdFromRoute) must be routed under 'v1/aiservicedesk/admin/data/environment/extensions/<…>' (got '$route')" >&2; viol=1 ;;
    esac
    for a in CanDeprovision Deprovision ForceReconcile CreateTicket GetTicketStatus; do
      grep -qE "override[[:space:]]+(async[[:space:]]+)?Task<IActionResult>[[:space:]]+$a\(" "$f" || {
        echo "  ✗ $(basename "$f"): admin child controller must override $a with a [BindNever] string? workspaceId (the admin route has no {workspaceId}; otherwise it returns 400)" >&2; viol=1; }
    done
  elif grep -qE ':[[:space:]]*(ResourcesController|ChildResourceController)<' "$f"; then
    has_ws=1
    case "$route" in *aiservicedesk/admin/*)
      echo "  ✗ $(basename "$f"): '$route' is an admin route — derive from AdminResourcesController (or, for a child, override GetWorkspaceIdFromRoute; see reference/21-admin-resources.md)" >&2; viol=1 ;;
    esac
  fi
done < <(grep -rlE 'Controller<' "$DIR/backend" --include='*.cs' 2>/dev/null | grep -vE '/(bin|obj)/' || true)
while IFS= read -r sc; do
  echo "  ✗ frontend extension scope '$sc' must be 'workspace' or 'admin' (this is not a Provider scope)" >&2; viol=1
done < <(jq -r '[.frontend.routes[]?.scope, .frontend.menus[]?.scope] | map(select(. != null and . != "workspace" and . != "admin")) | .[]' "$MANIFEST")
while IFS= read -r n; do
  echo "  ✗ frontend.menus node '$n' sets the extension 'scope' — only the TOP-LEVEL node of a menu tree may (the whole tree follows it)" >&2; viol=1
done < <(jq -r '.frontend.menus // [] | .[] | (.children // []) | .. | objects | select(has("scope")) | (.id // .title)' "$MANIFEST")
while IFS=$'\t' read -r u sc; do
  [ -n "$u" ] || continue
  echo "  ✗ menu link '$u' is in a '$sc'-extension-scope menu tree but no frontend.routes[] entry has path '$u' with that extension scope (omitted = workspace)" >&2; viol=1
done < <(jq -r '(.frontend.routes // []) as $r | .frontend.menus // [] | .[] | (.scope // "workspace") as $s
  | [.. | objects | .relativeUrl? // empty] | .[] as $u
  | select(([$r[] | select(.path == $u) | (.scope // "workspace")] | index($s)) == null) | "\($u)\t\($s)"' "$MANIFEST")
# A plain controller (ControllerBase/Controller, e.g. a read-only workspace view of an admin resource) gets no
# authorization unless it says so: the host has no fallback policy, and only [Authorize] runs the tenant policy
# (workspace membership; Admin Workspace grants on /aiservicedesk/admin). Resource controllers inherit it from their base.
while IFS= read -r f; do
  [ -n "$f" ] || continue
  # Attribute lines only (also `[ApiController, Authorize]`) — a doc comment mentioning [Authorize] must not count.
  grep -qE '^[[:space:]]*\[([^]/]*[,[:space:]])?Authorize([](,[:space:]]|$)' "$f" || {
    echo "  ✗ $(basename "$f"): a controller deriving from ControllerBase/Controller must carry [Authorize] — without it its routes are anonymous (see reference/21-admin-resources.md)" >&2; viol=1; }
done < <(grep -rlE ':[[:space:]]*(ControllerBase|Controller)[[:space:]]*($|\{|,)' "$DIR/backend" --include='*.cs' 2>/dev/null | grep -vE '/(bin|obj)/' || true)
if [ "$has_admin" = 1 ] && [ "$has_ws" = 0 ]; then
  if [ -d "$DIR/frontend/src" ] && ! grep -rqF 'admin/data/environment' "$DIR/frontend/src" 2>/dev/null; then
    echo "  ✗ the backend is admin-scoped but no frontend file calls '/v1/aiservicedesk/admin/data/environment/…' — point the FE service base() at the admin route" >&2; viol=1
  fi
  if [ -d "$DIR/skills" ] && grep -rqE 'user/data/workspaces/[^ ]*/environment/extensions/' "$DIR/skills" 2>/dev/null; then
    echo "  ! skill callback URL(s) use '…/user/data/workspaces/…' but the resource is admin-scoped — post to '…/admin/data/environment/extensions/<…>/{id}/status|results'" >&2
  fi
fi
# Frontend ↔ backend route parity: the FE service builds its data URL from REST_SEGMENT, which MUST be the full
# 'extensions/<…>' path AND (for a single top-level resource) equal the manifest restSegment. A bare leaf 404s
# every list/get/create/view-template call — the #1 scaffolding pitfall. See reference/00-naming.md.
if [ -d "$DIR/frontend/src" ]; then
  # `|| true`: a frontend with no REST_SEGMENT constant must not abort the script silently under pipefail.
  fe_segs=$( { grep -rhoE "REST_SEGMENT[[:space:]]*=[[:space:]]*'[^']+'" "$DIR/frontend/src" 2>/dev/null || true; } \
            | sed -E "s/.*'([^']+)'.*/\1/" | sort -u)
  while IFS= read -r seg; do
    [ -n "$seg" ] || continue
    case "$seg" in extensions/*) ;; *)
      echo "  ✗ frontend REST_SEGMENT '$seg' must be the full 'extensions/<…>' path (== manifest restSegment), not a bare leaf — it 404s" >&2; viol=1 ;;
    esac
  done <<EOF
$fe_segs
EOF
  nres=$(jq -r '[.resources[]? | select(.parent == null)] | length' "$MANIFEST")
  if [ "$nres" = "1" ] && [ -n "$fe_segs" ]; then
    want=$(jq -r '[.resources[]? | select(.parent == null)][0].restSegment' "$MANIFEST")
    while IFS= read -r seg; do
      [ -n "$seg" ] || continue
      [ "$seg" = "$want" ] || { echo "  ✗ frontend REST_SEGMENT '$seg' != manifest restSegment '$want' (they must be identical)" >&2; viol=1; }
    done <<EOF
$fe_segs
EOF
  fi
fi

# No leftover template identifiers in a renamed extension. Samples/templates may keep 'Hello' names (reference
# code), but a real extension under extensions/<name>/ must rename the FE off the template (see the FE rename
# table in reference/02-authoring-guide.md).
case "$DIR" in
  *samples/*|*templates/*) ;;
  *)
    if [ -d "$DIR/frontend/src" ]; then
      hits=$(grep -rnE 'HelloService|HelloWorld|hw-(add|list|view|root)|hello\.service' "$DIR/frontend/src" 2>/dev/null || true)
      if [ -n "$hits" ]; then
        echo "  ✗ frontend still has template 'Hello'/'hw-' identifiers — rename them to your resource:" >&2
        printf '%s\n' "$hits" | head -8 | sed 's/^/      /' >&2; viol=1
      fi
    fi ;;
esac

if [ "$viol" -ne 0 ]; then
  echo "ERROR: extension naming validation failed — fix the ✗ items above (reference/00-naming.md)." >&2
  exit 1
fi
echo "    naming OK"
[ "$VALIDATE_ONLY" != 1 ] || exit 0

# --- Which SDKs to build against. ----------------------------------------------------------------------------
# Empty (the default) keeps today's single build from the running host's SDK, stamped with its digest, at
# dist/extension.zip. A non-empty DUPLO_SDK_VERSIONS (one per line, or comma-separated) builds one bundle per
# version, each restored from the package feed (nuget.config's nuget.org source) rather than a host, so no
# DUPLO_HOST is needed to build. Each goes to dist/sdk-<version>/extension.zip, which is what the release action
# walks. The release action hands the list over one per line, so a repository variable holds that form too.
SDK_VERSIONS=()
for v in $(printf '%s' "${DUPLO_SDK_VERSIONS:-}" | tr ',' ' '); do
  [ -n "$v" ] && SDK_VERSIONS+=("$v")
done

CSPROJ=$(find "$DIR/backend" -maxdepth 1 -name '*.csproj' | head -1)
[ -n "$CSPROJ" ] || { echo "No .csproj under $DIR/backend" >&2; exit 1; }
# The nuget.config local SDK source resolves against backend/, so the directory has to exist even in feed mode
# (where it stays empty and restore falls through to nuget.org).
mkdir -p "$DIR/backend/sdk-packages"

# --- Frontend: built once and shared by every SDK bundle (it is SDK-independent). ----------------------------
echo "==> Building frontend"
# Strict install, matching the host portal. npm ci when a lock exists (deterministic), plain npm install only as
# the no-lock fallback. NEVER delete package-lock.json, and NOT `npm ci || npm install`: a failing ci must fail
# the build rather than silently fall back and rewrite the lock.
( cd "$DIR/frontend" \
  && if [ -f package-lock.json ]; then npm ci; else npm install; fi \
  && npm run build )

# --- Obfuscation setup: once, SDK-independent (it depends only on ARMDOT_LICENSE_FILE_PATH). -----------------
# The baseline (built per version inside build_one) lives under backend/, inside the compile root. A copy left by
# a prior interrupted run, or by the previous version of a feed build, would dupe AssemblyInfo and fail the publish
# with CS0579, so purge it up-front, after each version's use, and on exit via the trap. ArmDot obfuscation of the
# extension's own assembly is on only when ARMDOT_LICENSE_FILE_PATH names a license. The import rides in through a
# Directory.Build.targets dropped beside the csproj for this build, so the extension's own project file never changes.
BASELINE="$DIR/backend/_sdkbaseline"
rm -rf "$BASELINE"
OBFUSCATE=0
OBFUSCATE_PROPS=(-p:DuploObfuscate=false)
OBF_TARGETS="$DIR/backend/Directory.Build.targets"
trap 'rm -rf "$BASELINE" 2>/dev/null || true' EXIT
# project_refs <csproj>: the projects it references, one absolute path per line. An Include is written with either
# separator and, when relative, is relative to the csproj's directory. The directory part is resolved on disk so a
# ../ segment compares against backend/ by location; one that does not exist is left as written for dotnet to report.
# The file is read as one line first, since an element with several attributes puts Include on its own line, and
# XML comments are dropped so a reference left commented out is not read. An Include that holds an MSBuild property,
# a wildcard or a list has no directory on disk as written, so it is printed as written, with no prefix, and the
# caller reads it as outside.
project_refs() {
  local csproj="$1" dir ref
  dir="$(cd "$(dirname "$csproj")" && pwd -P)"
  { tr '\n' ' ' < "$csproj" 2>/dev/null | sed -E 's/<!--([^-]|-[^-])*-->//g' \
      | grep -oE '<ProjectReference[^>]*Include="[^"]+"' || true; } \
    | sed -E 's/.*Include="([^"]+)".*/\1/' | tr '\\' '/' \
    | while IFS= read -r ref; do
        case "$ref" in
          *'$('*|*'*'*|*'?'*|*';'*) printf '%s\n' "$ref"; continue ;;
          /*) ;;
          *) ref="$dir/$ref" ;;
        esac
        [ -d "$(dirname "$ref")" ] && ref="$(cd "$(dirname "$ref")" && pwd -P)/$(basename "$ref")"
        printf '%s\n' "$ref"
      done
}
# targets_above <csproj>: the Directory.Build.targets MSBuild would import for it instead of the one dropped at
# backend/, if any: the nearest one from the project's own directory up to, but not including, backend/.
targets_above() {
  local d; d="$(dirname "$1")"
  while [ "$d" != "$BACKEND_ROOT" ] && [ "${d#"$BACKEND_ROOT"/}" != "$d" ]; do
    [ -f "$d/Directory.Build.targets" ] && { printf '%s\n' "$d/Directory.Build.targets"; return; }
    d="$(dirname "$d")"
  done
}
# check_refs <csproj>: walks its references and theirs, appending to $unprotected each one that would publish plain:
# a project outside backend/, or one inside whose own Directory.Build.targets replaces the dropped import. A project
# already walked is skipped, so a reference cycle ends the walk.
check_refs() {
  local from="$1" ref above
  case "$seen" in *"|$from|"*) return ;; esac
  seen="$seen|$from|"
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    case "$ref" in
      "$BACKEND_ROOT"/*)
        above="$(targets_above "$ref")"
        if [ -n "$above" ]; then unprotected="$unprotected  $(basename "$from") -> $ref, which imports backend/${above#"$BACKEND_ROOT"/} instead"$'\n'
        else check_refs "$ref"; fi ;;
      *) unprotected="$unprotected  $(basename "$from") -> $ref"$'\n' ;;
    esac
  done < <(project_refs "$from")
}
if [ -n "${ARMDOT_LICENSE_FILE_PATH:-}" ]; then
  ARMDOT_VERSION="$(sed -nE 's/.*<ArmDotEngineVersion>([^<]+)<.*/\1/p' build/ArmDot.Obfuscation.props)"
  [ -n "$ARMDOT_VERSION" ] || { echo "ERROR: no ArmDotEngineVersion in build/ArmDot.Obfuscation.props" >&2; exit 1; }
  # Only a project that imports the targets file dropped below is obfuscated, so a referenced project outside backend/,
  # or one whose own Directory.Build.targets shadows the dropped file, publishes plain into a bundle whose manifest
  # says obfuscated. Refuse that rather than overclaim. Every reference reachable from the entry project is checked.
  BACKEND_ROOT="$(cd "$DIR/backend" && pwd -P)"
  unprotected=""; seen=""
  check_refs "$(cd "$(dirname "$CSPROJ")" && pwd -P)/$(basename "$CSPROJ")"
  if [ -n "$unprotected" ]; then
    echo "ERROR: a licensed build obfuscates only the projects under $DIR/backend/ that import its Directory.Build.targets," >&2
    echo "       and these references lead to projects that do not:" >&2
    printf '%s' "$unprotected" >&2
    echo "  Their assemblies would ship plain in a bundle stamped as obfuscated. Move each project into its own folder" >&2
    echo "  under backend/, add that folder to the entry project's DefaultItemExcludes so its sources are not compiled" >&2
    echo "  twice, and keep no Directory.Build.targets between it and backend/. Or unset ARMDOT_LICENSE_FILE_PATH to" >&2
    echo "  build without obfuscation." >&2
    exit 1
  fi
  # A file identical to the template is this script's own leftover from a killed build, so it is replaced.
  # Anything else is the extension's own and is never overwritten.
  if [ -e "$OBF_TARGETS" ] && ! cmp -s build/Directory.Build.targets.template "$OBF_TARGETS"; then
    echo "ERROR: $OBF_TARGETS already exists. The obfuscation import is dropped there for the build," >&2
    echo "       so move the extension's own targets into its csproj first." >&2
    exit 1
  fi
  trap 'rm -rf "$BASELINE" 2>/dev/null || true; rm -f "$OBF_TARGETS"' EXIT
  cp build/Directory.Build.targets.template "$OBF_TARGETS"
  OBFUSCATE=1
  OBFUSCATE_PROPS=(-p:DuploObfuscate=true -p:ArmDotLicenseFile="$ARMDOT_LICENSE_FILE_PATH" -p:DuploDevkitBuildDir="$PWD/build/")
fi

# build_one <sdk-version> <sdk-digest> <out-dir>: publish the backend against one SDK version (obfuscated when a
# license is set), compute the host-provided assembly set for that version, and assemble <out-dir>/extension.zip
# with the shared frontend. The SDK is resolved through nuget.config: the host bundle under backend/sdk-packages
# in host mode, else nuget.org. An empty digest is omitted from the manifest; nothing consumes sdkDigest, and a
# feed build has no host bundle to fingerprint.
build_one() {
  local sdk_ver="$1" sdk_digest="$2" out="$3"
  # The backend publish runs from backend/, so its -o has to be absolute, not relative to the repo root.
  case "$out" in /*) ;; *) out="$PWD/$out" ;; esac
  rm -rf "$out"; mkdir -p "$out"

  [ "$OBFUSCATE" = 1 ] && echo "==> [$sdk_ver] Obfuscating the extension assembly with ArmDot $ARMDOT_VERSION"
  echo "==> [$sdk_ver] Building backend ($(basename "$CSPROJ"))"
  ( cd "$DIR/backend" && dotnet publish "$(basename "$CSPROJ")" -c Release -o "$out/backend" -p:DuploSdkVersion="$sdk_ver" \
      "${OBFUSCATE_PROPS[@]}" )

  # The extension is hot-loaded into a child AssemblyLoadContext that serves the whole SDK closure from the host's
  # Default context, so those DLLs must not ship in the bundle (they only bloat it past the ingress limit). Compute
  # the host-provided set by publishing a project that references only the SDK meta-package against the same feed.
  echo "==> [$sdk_ver] Computing host-provided assembly set"
  rm -rf "$BASELINE"; mkdir -p "$BASELINE"
  cat > "$BASELINE/_sdkbaseline.csproj" <<CSPROJ_EOF
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net8.0</TargetFramework>
    <UseAppHost>false</UseAppHost>
  </PropertyGroup>
  <ItemGroup>
    <FrameworkReference Include="Microsoft.AspNetCore.App" />
    <PackageReference Include="Duplocloud.AiHelpdesk.Sdk" Version="[$sdk_ver]" />
  </ItemGroup>
</Project>
CSPROJ_EOF
  echo 'namespace _SdkBaseline; internal sealed class _ {}' > "$BASELINE/_.cs"
  # Never obfuscated: the baseline only lists what the host provides. It sits under backend/, so the dropped
  # Directory.Build.targets reaches it unless told otherwise.
  if ! ( cd "$BASELINE" && dotnet publish _sdkbaseline.csproj -c Release -o ./out -p:DuploSdkVersion="$sdk_ver" \
           -p:DuploObfuscate=false ) > "$BASELINE/publish.log" 2>&1; then
    echo "ERROR: [$sdk_ver] failed to compute the host-provided SDK closure (baseline publish):" >&2
    tail -20 "$BASELINE/publish.log" >&2
    return 1
  fi
  local provided; provided=$(mktemp)
  ( cd "$BASELINE/out" && ls -1 ./*.dll 2>/dev/null | sed 's|^\./||' ) | sort -u > "$provided"
  echo "    host provides $(wc -l < "$provided" | tr -d ' ') assemblies (excluded from the bundle)"

  echo "==> [$sdk_ver] Assembling bundle"
  local pkg="$out/pkg"
  rm -rf "$pkg"; mkdir -p "$pkg/backend" "$pkg/fe" "$pkg/skills"
  # Stamp the real SDK version and digest, the obfuscation marker, and the id/version-derived paths the loader
  # reads (backend.assemblyDir and skills[].folder), computed here so they never drift from id+version.
  jq --arg v "$sdk_ver" --arg d "$sdk_digest" --arg ob "$([ "$OBFUSCATE" = 1 ] && echo "$ARMDOT_VERSION")" '
      .sdkVersion = $v
    | if $d != "" then .sdkDigest = $d else del(.sdkDigest) end
    | if $ob != "" then .obfuscation = {tool: "armdot", version: $ob} else del(.obfuscation) end
    | .backend.assemblyDir = (.id + "/" + .version + "/backend")
    | .id as $i | .version as $r
    | if (.skills | type) == "array" then
        .skills = [ .skills[]
          | if ((.folder | split("/") | length) > 2)
            then .folder = ($i + "/" + $r + "/" + (.folder | split("/") | .[2:] | join("/")))
            else . end ]
      else . end
  ' "$MANIFEST" > "$pkg/manifest.json"

  # Ship only backend assemblies the host does NOT provide, plus each kept DLL's sidecars.
  local kept=0 dropped=0 f base stem side
  shopt -s nullglob
  for f in "$out"/backend/*.dll; do
    base=$(basename "$f")
    if grep -qxF "$base" "$provided"; then dropped=$((dropped+1)); continue; fi
    cp "$f" "$pkg/backend/"; kept=$((kept+1))
    stem="${base%.dll}"
    for side in "$stem.pdb" "$stem.deps.json" "$stem.runtimeconfig.json"; do
      [ -f "$out/backend/$side" ] && cp "$out/backend/$side" "$pkg/backend/"
    done
  done
  shopt -u nullglob
  rm -f "$provided"; rm -rf "$BASELINE"
  [ "$kept" -gt 0 ] || { echo "ERROR: [$sdk_ver] nothing left to ship after excluding host-provided assemblies (the extension's own DLL was treated as host-provided)." >&2; return 1; }
  echo "    backend: shipped $kept assembly file(s), dropped $dropped host-provided"
  if [ -d "$pkg/backend/runtimes" ]; then
    echo "    WARNING: [$sdk_ver] native runtimes/ present in the bundle backend/ — the host usually provides these." >&2
  fi

  cp -r "$DIR/frontend/dist/." "$pkg/fe/"
  [ -d "$DIR/skills" ] && cp -r "$DIR/skills/." "$pkg/skills/"
  [ -d "$DIR/resources-frontend-templates" ] && cp -r "$DIR/resources-frontend-templates" "$pkg/resources-frontend-templates"
  # Replace, don't append: zip updates in place, so a stale archive would keep entries no longer in $pkg.
  rm -f "$out/extension.zip"
  ( cd "$pkg" && zip -rq "$out/extension.zip" . )
  echo "==> [$sdk_ver] Done: $out/extension.zip"
  du -sh "$pkg/backend" "$pkg/fe" "$out/extension.zip" 2>/dev/null | sed 's/^/    /'
}

if [ "${#SDK_VERSIONS[@]}" -eq 0 ]; then
  # Host mode (unchanged behaviour): fetch the running host's SDK, stamp its digest, write dist/extension.zip.
  echo "==> Fetching SDK feed from $BASE_URL"
  auth=()
  [ -n "${TOKEN:-}" ] && auth=(-H "Authorization: Bearer $TOKEN")
  # Capture the response first (don't pipe to jq) so a non-JSON body gives a clear error. No -f: the body + status
  # are the diagnostic. -L follows http->https redirects.
  SDK_CODE=$(curl -sSL -m 30 -o /tmp/sdk-version-resp.$$ -w '%{http_code}' "${auth[@]}" \
    "$BASE_URL/v1/aiservicedesk/extensions/sdk-version" 2>/dev/null || echo 000)
  SDK_RESP=$(cat /tmp/sdk-version-resp.$$ 2>/dev/null || true); rm -f /tmp/sdk-version-resp.$$
  SDK_VER=$(printf '%s' "$SDK_RESP" | jq -r '.version // empty' 2>/dev/null || true)
  if [ -z "$SDK_VER" ]; then
    echo "ERROR: could not read the host SDK version from $BASE_URL/v1/aiservicedesk/extensions/sdk-version" >&2
    echo "       HTTP $SDK_CODE — response (first 300 chars): $(printf '%s' "$SDK_RESP" | tr -d '\r' | head -c 300)" >&2
    echo "       Check DUPLO_HOST is the AI Helpdesk studio base URL (serving /v1/aiservicedesk), is reachable," >&2
    echo "       has no trailing path, and that TOKEN is set. To build without a host, set DUPLO_SDK_VERSIONS." >&2
    exit 1
  fi
  echo "    host SDK version: $SDK_VER"
  curl -fsSL -m 120 "${auth[@]}" "$BASE_URL/v1/aiservicedesk/extensions/sdk-bundle" -o "$DIR/dist-sdk.zip" \
    || { echo "ERROR: failed to download the SDK bundle from $BASE_URL/v1/aiservicedesk/extensions/sdk-bundle" >&2; exit 1; }
  unzip -oq "$DIR/dist-sdk.zip" -d "$DIR/backend/sdk-packages" \
    || { echo "ERROR: SDK bundle is not a valid zip — got $(file -b "$DIR/dist-sdk.zip" 2>/dev/null). Check DUPLO_HOST." >&2; exit 1; }
  # Digest a fresh extraction, not sdk-packages/, which accumulates packages from earlier builds.
  SDK_FEED="$(mktemp -d)"
  unzip -oq "$DIR/dist-sdk.zip" -d "$SDK_FEED"
  SDK_DIGEST="$(sdk_digest "$SDK_FEED")" || { rm -rf "$SDK_FEED"; echo "ERROR: the SDK bundle from $BASE_URL is empty." >&2; exit 1; }
  # Admin scope needs a host SDK that ships AdminResourcesController. Probe for the type rather than compare
  # version numbers: the loader pins an extension to exactly the version the host reports, so a minimum-version
  # check says nothing about whether the feature is there. (Whole-archive unzip -p: path globs are not portable.
  # Not grep -q: it would stop reading early, SIGPIPE unzip, and pipefail would report a miss.)
  if [ "$has_admin" = 1 ]; then
    found=0
    for n in "$SDK_FEED"/Duplo.Ai.DataManagement.*.nupkg; do
      [ -f "$n" ] && unzip -p "$n" 2>/dev/null | grep -a 'AdminResourcesController' >/dev/null && found=1
    done
    [ "$found" = 1 ] || { rm -rf "$SDK_FEED"; echo "ERROR: the host SDK ($SDK_VER) has no AdminResourcesController — this host cannot load admin-scoped extensions (reference/21-admin-resources.md)." >&2; exit 1; }
    echo "    host SDK supports admin-scoped resources"
  fi
  rm -rf "$SDK_FEED" "$DIR/dist-sdk.zip"
  echo "    host SDK digest: $SDK_DIGEST"

  build_one "$SDK_VER" "$SDK_DIGEST" "$DIR/dist"
else
  # Feed mode: one bundle per listed SDK version, restored from nuget.org (nuget.config), no host needed. The
  # admin-scope probe above is host-mode only, since here the owner names the SDK versions to compile against.
  echo "==> Building ${#SDK_VERSIONS[@]} bundle(s) from the SDK feed: ${SDK_VERSIONS[*]}"
  # Start from an empty dist/, as build_one does in host mode, so a host bundle or a per-version bundle from a
  # version no longer listed cannot survive and be deployed by deploy-all.sh.
  rm -rf "$DIR/dist"
  for v in "${SDK_VERSIONS[@]}"; do
    build_one "$v" "" "$DIR/dist/sdk-$v"
  done
fi
