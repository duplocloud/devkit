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
# Usage: ./scripts/build-extension.sh [--native] <extension-dir>   # e.g. ./extension or samples/helloworld
set -euo pipefail
cd "$(dirname "$0")/.."

# Strip --native before the positional arg is read, so it works in either order.
for a in "$@"; do shift; case "$a" in --native) DUPLO_BUILD_NATIVE=1 ;; *) set -- "$@" "$a" ;; esac; done

DIR="${1:?usage: build-extension.sh [--native] <extension-dir>}"
DIR="${DIR%/}"
# shellcheck source=scripts/_target.sh
source "$(dirname "$0")/_target.sh"   # → BASE_URL (+ TOKEN) from .env / env per DUPLO_TARGET
# shellcheck source=scripts/_builder.sh
source "$(dirname "$0")/_builder.sh"  # → native, or re-launch this build in the builder container
BASE_URL="${BASE_URL%/}"               # tolerate a trailing slash in DUPLO_HOST (avoids // in URLs)
[ -f "$DIR/manifest.json" ] || { echo "No manifest.json in $DIR" >&2; exit 1; }

# Delegates to the builder container unless we're already native (see the header). Never returns in
# the container case.
builder_dispatch scripts/build-extension.sh "$DIR"

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
# Frontend ↔ backend route parity: the FE service builds its data URL from REST_SEGMENT, which MUST be the full
# 'extensions/<…>' path AND (for a single top-level resource) equal the manifest restSegment. A bare leaf 404s
# every list/get/create/view-template call — the #1 scaffolding pitfall. See reference/00-naming.md.
if [ -d "$DIR/frontend/src" ]; then
  fe_segs=$(grep -rhoE "REST_SEGMENT[[:space:]]*=[[:space:]]*'[^']+'" "$DIR/frontend/src" 2>/dev/null \
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

echo "==> Fetching SDK feed from $BASE_URL"
auth=()
[ -n "${TOKEN:-}" ] && auth=(-H "Authorization: Bearer $TOKEN")
# Capture the response first (don't pipe straight to jq) so a non-JSON body yields a clear error, not a
# cryptic "jq: parse error". No -f: an HTTP error's body + status are the diagnostic, keep them.
# -L follows http→https redirects.
SDK_CODE=$(curl -sSL -m 30 -o /tmp/sdk-version-resp.$$ -w '%{http_code}' "${auth[@]}" \
  "$BASE_URL/v1/aiservicedesk/extensions/sdk-version" 2>/dev/null || echo 000)
SDK_RESP=$(cat /tmp/sdk-version-resp.$$ 2>/dev/null || true); rm -f /tmp/sdk-version-resp.$$
SDK_VER=$(printf '%s' "$SDK_RESP" | jq -r '.version // empty' 2>/dev/null || true)
if [ -z "$SDK_VER" ]; then
  echo "ERROR: could not read the host SDK version from $BASE_URL/v1/aiservicedesk/extensions/sdk-version" >&2
  echo "       HTTP $SDK_CODE — response (first 300 chars): $(printf '%s' "$SDK_RESP" | tr -d '\r' | head -c 300)" >&2
  echo "       Check DUPLO_HOST is the AI Helpdesk studio base URL (serving /v1/aiservicedesk), is reachable," >&2
  echo "       has no trailing path — and that TOKEN is set: in a platform ticket that means DUPLO_TOKEN in the" >&2
  echo "       env plus DUPLO_TARGET=remote (auto-detected when DUPLO_HOST+DUPLO_TOKEN are both set)." >&2
  exit 1
fi
echo "    host SDK version: $SDK_VER"
mkdir -p "$DIR/backend/sdk-packages"
curl -fsSL -m 120 "${auth[@]}" "$BASE_URL/v1/aiservicedesk/extensions/sdk-bundle" -o "$DIR/dist-sdk.zip" \
  || { echo "ERROR: failed to download the SDK bundle from $BASE_URL/v1/aiservicedesk/extensions/sdk-bundle" >&2; exit 1; }
unzip -oq "$DIR/dist-sdk.zip" -d "$DIR/backend/sdk-packages" \
  || { echo "ERROR: SDK bundle is not a valid zip — got $(file -b "$DIR/dist-sdk.zip" 2>/dev/null). Check DUPLO_HOST." >&2; exit 1; }
rm -f "$DIR/dist-sdk.zip"

CSPROJ=$(find "$DIR/backend" -maxdepth 1 -name '*.csproj' | head -1)
[ -n "$CSPROJ" ] || { echo "No .csproj under $DIR/backend" >&2; exit 1; }

# The host-provided-assembly baseline (created later) lives under backend/, inside this extension's compile
# root. A copy left by a prior interrupted run would dupe AssemblyInfo and fail the publish below with CS0579,
# so purge any leftover up-front and guarantee removal on exit (success OR failure) via a trap.
BASELINE="$DIR/backend/_sdkbaseline"
rm -rf "$BASELINE"
trap 'rm -rf "$BASELINE" 2>/dev/null || true' EXIT

echo "==> Building backend ($(basename "$CSPROJ"))"
( cd "$DIR/backend" && dotnet publish "$(basename "$CSPROJ")" -c Release -o ../dist/backend -p:DuploSdkVersion="$SDK_VER" )

echo "==> Building frontend"
# Strict install, matching the host portal. Where a dependency has no Angular 22 release (ngx-toastr,
# at time of writing), the frontend's package.json pins it with an `overrides` block rather than
# loosening the whole install. If a new conflict appears, add an override; do not restore the
# legacy peer-deps flag.
# npm ci when a lock exists (deterministic — the committed lock is what makes the strict install
# reproducible); plain npm install only as the no-lock fallback. NEVER delete package-lock.json.
( cd "$DIR/frontend" \
  && if [ -f package-lock.json ]; then npm ci; else npm install; fi \
  && npm run build )
# (if/else, NOT `npm ci || npm install`: a FAILING npm ci must fail the build, never silently fall back
#  to npm install and rewrite the lock.)

# The extension is hot-loaded into a child AssemblyLoadContext whose Resolving hook serves any assembly the
# host already has (the WHOLE SDK closure — Duplo.Ai.*, Mongo, AWS, AspNetCore, …) from the host's Default
# context, for shared type identity. Those DLLs in the publish output are therefore never loaded from the
# bundle; shipping them only bloats it past the load-bundle ingress body limit (HTTP 413). Compute the
# host-provided set by publishing a minimal project that references ONLY the SDK meta-package (full runtime
# closure) against the same feed, then ship just the assemblies the host does NOT provide.
echo "==> Computing host-provided assembly set (to keep the bundle to extension-private DLLs)"
rm -rf "$BASELINE"; mkdir -p "$BASELINE"   # BASELINE defined + trap-guarded near the top
cat > "$BASELINE/_sdkbaseline.csproj" <<EOF
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net8.0</TargetFramework>
    <UseAppHost>false</UseAppHost>
  </PropertyGroup>
  <ItemGroup>
    <FrameworkReference Include="Microsoft.AspNetCore.App" />
    <PackageReference Include="Duplocloud.AiHelpdesk.Sdk" Version="[$SDK_VER]" />
  </ItemGroup>
</Project>
EOF
echo 'namespace _SdkBaseline; internal sealed class _ {}' > "$BASELINE/_.cs"
if ! ( cd "$BASELINE" && dotnet publish _sdkbaseline.csproj -c Release -o ./out -p:DuploSdkVersion="$SDK_VER" ) > "$BASELINE/publish.log" 2>&1; then
  echo "ERROR: failed to compute the host-provided SDK closure (baseline publish):" >&2
  tail -20 "$BASELINE/publish.log" >&2
  exit 1
fi
PROVIDED=$(mktemp)
( cd "$BASELINE/out" && ls -1 *.dll 2>/dev/null ) | sort -u > "$PROVIDED"
echo "    host provides $(wc -l < "$PROVIDED" | tr -d ' ') assemblies (excluded from the bundle)"

echo "==> Assembling bundle"
PKG="$DIR/dist/pkg"
rm -rf "$PKG"; mkdir -p "$PKG/backend" "$PKG/fe" "$PKG/skills"
# Bundle manifest with the real host SDK version pinned in, and backend.assemblyDir derived from id+version.
# The host stages the bundle to <ExtensionStudioPath>/<id>/<version>/ but loads the entry assembly from
# assemblyDir, so the two have to agree. Maintained by hand they drift as soon as you bump version alone, and
# what that breaks depends on the target. A host that still has the old version on disk keeps running the OLD
# backend DLL and says nothing. A host that's never seen it refuses the install with "Extension entry assembly
# not found: .../<old version>/backend/<dll>". It's always <id>/<version>/backend, so compute it here instead
# of trusting the checked-in value.
jq --arg v "$SDK_VER" \
   '.sdkVersion = $v | .backend.assemblyDir = (.id + "/" + .version + "/backend")' \
   "$DIR/manifest.json" > "$PKG/manifest.json"
_ad_src=$(jq -r '.backend.assemblyDir // ""' "$MANIFEST")
_ad_out=$(jq -r '.backend.assemblyDir' "$PKG/manifest.json")
[ "$_ad_src" = "$_ad_out" ] || echo "    NOTE: stale backend.assemblyDir '$_ad_src' in $MANIFEST — bundled as '$_ad_out'"
# Ship only backend assemblies the host does NOT already provide, plus each kept DLL's sidecars. Native
# runtimes/ are host-provided too (Mongo/AWS natives load via the host's Default-ALC copies), so skip them.
kept=0; dropped=0
shopt -s nullglob
for f in "$DIR"/dist/backend/*.dll; do
  base=$(basename "$f")
  if grep -qxF "$base" "$PROVIDED"; then dropped=$((dropped+1)); continue; fi
  cp "$f" "$PKG/backend/"; kept=$((kept+1))
  stem="${base%.dll}"
  for side in "$stem.pdb" "$stem.deps.json" "$stem.runtimeconfig.json"; do
    [ -f "$DIR/dist/backend/$side" ] && cp "$DIR/dist/backend/$side" "$PKG/backend/"
  done
done
shopt -u nullglob
rm -f "$PROVIDED"; rm -rf "$BASELINE"
[ "$kept" -gt 0 ] || { echo "ERROR: nothing left to ship after excluding host-provided assemblies — aborting (the extension's own DLL was unexpectedly treated as host-provided)." >&2; exit 1; }
echo "    backend: shipped $kept assembly file(s), dropped $dropped host-provided"
# Sanity check: native runtimes/ (5x libmongocrypt ≈ 33MB, AWS/Mongo natives) are host-provided and
# normally should not ship — their presence usually means an old/untrimmed publish leaked in and the
# bundle balloons. Warn (do not fail) so the bundle still builds; investigate with a sample if it appears.
if [ -d "$PKG/backend/runtimes" ]; then
  echo "    WARNING: native runtimes/ present in the bundle backend/ — the host usually provides these." >&2
  echo "             If the bundle is unexpectedly large, check <ExcludeAssets>runtime</ExcludeAssets> on the SDK ref." >&2
fi
cp -r "$DIR/frontend/dist/." "$PKG/fe/"
[ -d "$DIR/skills" ] && cp -r "$DIR/skills/." "$PKG/skills/"
# LEGACY: declarative Result view-templates are not supported (reference/09-result-templates.md); an older
# extension may still carry a resources-frontend-templates/ dir, so keep copying it to the bundle root where the loader's
# RegisterViewTemplatesRoot registers {Type}/{subType}.view-template.json for the inherited
# GET …/view-template endpoint (otherwise that endpoint 404s and the FE only has its
# local fallback). See reference/09-result-templates.md.
[ -d "$DIR/resources-frontend-templates" ] && cp -r "$DIR/resources-frontend-templates" "$PKG/resources-frontend-templates"
# Replace, don't append — `zip` updates in place, so a stale archive from a prior build keeps entries no
# longer in $PKG (e.g. the old full backend closure) and the bundle never shrinks.
rm -f "$DIR/dist/extension.zip"
( cd "$PKG" && zip -rq ../extension.zip . )

# Size report — a healthy bundle is single-digit MB. If the zip is hundreds of MB, the backend closure or
# natives leaked in (rebuild with this script; keep <ExcludeAssets>runtime</ExcludeAssets> on the SDK ref).
echo "==> Bundle size"
du -sh "$PKG/backend" "$PKG/fe" "$DIR/dist/extension.zip" 2>/dev/null | sed 's/^/    /'

echo "==> Done: $DIR/dist/extension.zip"
