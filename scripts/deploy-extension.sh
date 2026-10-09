#!/usr/bin/env bash
# Hot-load a built extension.zip into the running platform (no restart). A local build under extensions/ goes through
# the installer service instead while it runs (installer_handoff below).
# Usage: ./scripts/deploy-extension.sh <extension-dir>/dist/extension.zip   # e.g. extension/dist/extension.zip
set -euo pipefail
cd "$(dirname "$0")/.."

ZIP="${1:?usage: deploy-extension.sh <extension.zip>}"
[ -f "$ZIP" ] || { echo "No such file: $ZIP" >&2; exit 1; }

source "$(dirname "$0")/_target.sh"   # → BASE_URL + TOKEN from .env / env per DUPLO_TARGET
BASE_URL="${BASE_URL%/}"               # tolerate a trailing slash in DUPLO_HOST
[ -n "$TOKEN" ] || { echo "No token resolved — set DUPLO_ADMIN_TOKEN (local) or DUPLO_TOKEN (remote)." >&2; exit 1; }

# Warn on a SAME-VERSION redeploy: the studio only best-effort-unloads the old AssemblyLoadContext, so re-loading
# the same manifest.version can keep running the previous backend DLL. Best-effort + non-blocking (needs unzip+jq).
if command -v unzip >/dev/null && command -v jq >/dev/null; then
  _meta=$(unzip -p "$ZIP" manifest.json 2>/dev/null || true)
  _id=$(printf '%s' "$_meta" | jq -r '.id // empty' 2>/dev/null || true)
  _ver=$(printf '%s' "$_meta" | jq -r '.version // empty' 2>/dev/null || true)
  if [ -n "$_id" ] && [ -n "$_ver" ]; then
    _loaded=$(curl -sSL -m 20 "$BASE_URL/v1/aiservicedesk/admin/extensions" -H "Authorization: Bearer $TOKEN" 2>/dev/null \
      | jq -r --arg id "$_id" --arg v "$_ver" '(.data? // .)[]? | select((.extensionId==$id) and (.version==$v)) | .version' 2>/dev/null || true)
    if [ -n "$_loaded" ]; then
      echo "WARNING: '$_id' v$_ver is already loaded. A same-version reload may run STALE backend code" >&2
      echo "         (best-effort ALC unload). Bump manifest.version on backend changes to guarantee fresh code." >&2
    fi
  fi
fi

# Prints one decision from the installer's status record, read as the tar stream `cp ... -` writes: ok, fail, wait, or
# off when the installer leaves this build to the POST. Matches on the zip's digest, since a same-version rebuild shares
# id and version.
STATUS_PY='
import json, sys, tarfile
want_id, want_sha = sys.argv[1], sys.argv[2]
try:
    with tarfile.open(fileobj=sys.stdin.buffer, mode="r|") as tf:
        rec = next(json.load(tf.extractfile(m)) for m in tf if m.isfile())
    res, st = json.loads(rec.get("extensions") or "{}"), json.loads(rec.get("extensionsState") or "{}")
except Exception:
    print("wait|it has written no status yet")
    sys.exit()
if (res.get("effective") or {}).get("enabled") == "false":
    print("off|")
    sys.exit()
it = next((i for i in res.get("items") or [] if i.get("id") == want_id and i.get("bundleSha256") == want_sha), None)
if it is None:
    print("wait|its last pass ended %s %s without it" % (res.get("outcome") or "unfinished", res.get("reason") or ""))
    sys.exit()
o, ver = it.get("outcome") or "", it.get("declaredVersion") or "?"
why = ": ".join(x for x in (it.get("reason"), it.get("detail") or it.get("lastError")) if x)
mine = any(a.get("id") == want_id and a.get("bundleSha256") == want_sha for a in st.get("applied") or [])
if o == "skipped" and it.get("reason") in ("excluded-by-customer-file", "install-not-requested"):
    print("off|")
elif o == "converged" or (o == "already" and mine):
    print("ok|Installed %s v%s." % (want_id, ver))
elif o == "already":
    print("fail|%s v%s is installed from a load the installer did not make, so it keeps that one. Bump manifest.version, "
          "or run ./scripts/remove-extension.sh %s and build again." % (want_id, ver, want_id))
elif o in ("skipped", "error", "backed-out"):
    print("fail|the installer did not install this build, %s%s." % (o, ": " + why if why else ""))
else:
    print("wait|it is still installing it")
'

# Hands a build in extensions/[name]/dist/ to the installer service rather than POSTing it, since a POST beside the
# installer races its pass and leaves it no digest to compare, so a same-version rebuild afterwards reads as already
# installed. Returns 0 once the installer reports this zip installed, 1 with its reason when it refuses the build or
# does not report it within INSTALLER_WAIT_SECONDS, and 2 when the installer leaves this build alone and the POST should
# run.
installer_handoff() {
  local root abs name cid meta id sha deadline res
  [ "$_TARGET" = local ] && command -v python3 >/dev/null || return 2
  root="$(pwd -P)"
  abs="$(cd "$(dirname "$ZIP")" && pwd -P)/$(basename "$ZIP")"
  name="${abs#"$root/extensions/"}"; name="${name%/dist/extension.zip}"
  case "$name" in ''|*/*) return 2 ;; esac
  # shellcheck source=scripts/_runtime.sh
  . scripts/_runtime.sh
  runtime_resolve >/dev/null 2>&1 || return 2
  cid="$("$RUNTIME" ps -q --filter "label=com.docker.compose.project=$(runtime_compose_project)" \
    --filter label=com.docker.compose.service=installer 2>/dev/null | head -1)"
  [ -n "$cid" ] || return 2
  meta="$(python3 -c '
import hashlib, json, sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    print(json.loads(z.read("manifest.json")).get("id") or "-", hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())
' "$ZIP" 2>/dev/null)" || return 2
  read -r id sha <<<"$meta"
  [ "$id" != - ] || return 2
  echo "==> The installer service loads extensions/$name/dist/ on this target. Waiting for it to install $id"
  deadline=$((SECONDS + ${INSTALLER_WAIT_SECONDS:-240}))
  while :; do
    res="$("$RUNTIME" cp "$cid:/var/lib/installer/installer-status.json" - 2>/dev/null \
      | python3 -c "$STATUS_PY" "$id" "$sha" || true)"
    case "$res" in
      ok\|*)   echo "==> ${res#ok|}"; echo "    Refresh the UI. The new resource type should appear in the left nav."; return 0 ;;
      fail\|*) echo "ERROR: ${res#fail|}" >&2; break ;;
      off\|*)  return 2 ;;
    esac
    if [ "$SECONDS" -ge "$deadline" ]; then
      echo "ERROR: the installer has not reported this build after ${INSTALLER_WAIT_SECONDS:-240}s, ${res#wait|}." >&2
      break
    fi
    sleep 3
  done
  echo "       See ./logs.sh installer, and 'A build in extensions/ never loads' in docs/troubleshooting.md." >&2
  return 1
}
HANDOFF=0; installer_handoff || HANDOFF=$?
case "$HANDOFF" in 0) exit 0 ;; 1) exit 1 ;; esac

echo "==> Loading $ZIP ($(du -h "$ZIP" | cut -f1)) → $BASE_URL"
RESP_FILE=$(mktemp)
HTTP=$(curl -sSL -m 180 -o "$RESP_FILE" -w '%{http_code}' -X POST \
  "$BASE_URL/v1/aiservicedesk/admin/extensions/load-bundle" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/zip" --data-binary @"$ZIP" || echo 000)
BODY=$(tr -d '\r' < "$RESP_FILE"); rm -f "$RESP_FILE"
if [ "$HTTP" -ge 200 ] && [ "$HTTP" -lt 300 ]; then
  echo "==> Loaded (HTTP $HTTP)$(printf '%s' "$BODY" | jq -r '" — " + (.data.extensionId // .extensionId // "")' 2>/dev/null)."
  echo "    Refresh the UI — the new resource type should appear in the left nav."
else
  echo "ERROR: load-bundle failed (HTTP $HTTP) at $BASE_URL/v1/aiservicedesk/admin/extensions/load-bundle" >&2
  echo "       Response: $(printf '%s' "$BODY" | head -c 300)" >&2
  if [ "$HTTP" = 413 ]; then
    echo "       413 = the bundle is larger than the proxy in front of DUPLO_HOST allows. Raise the request body" >&2
    echo "       limit on that ingress (e.g. nginx 'client_max_body_size 1g;') — the studio itself accepts 1GB." >&2
  fi
  exit 1
fi
