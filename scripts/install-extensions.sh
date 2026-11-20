#!/usr/bin/env bash
# Install extensions from the studio's extension registry by manifest id (e.g. com.duplocloud.demo-cloud-deployment).
#
# WHY: a fresh dev kit should come up with the agents people start from (DUPLOAI-4813: the Cloud Deployment
# Agent first) already installed, rather than leaving every developer to find them in the registry by hand.
# run.sh calls this with its DEVKIT_EXTENSIONS list; it also works on its own, against a local or remote target.
#
# The registry catalog is read once. Its rows are matched on manifestId (falling back to id): a row's `id` is the
# console's renameable display slug, while the installer — and this script's arguments — use the manifest id.
# Per id, in order:
#   - not in the catalog, not licensed for this install, or no version to install → skipped (not an error)
#   - pinned by an admin (a pin, or a rollback, which always pins) → left alone: an unpinned install would clear it
#   - an install request the installer is still working on → left alone, not requested twice
#   - the version: the one the installer's mark offers (without a pin the installer accepts no other), else, with
#     no mark, the semver-highest stable catalog version. id@version must match the offered build.
#   - already current per /extensions/{id}/versions → nothing to do; otherwise POST the install with pin:false.
# The installer answers 202 when it takes the request and finishes in the background, so that is reported as
# "install requested", not as installed.
#
# Idempotent: re-running installs nothing that is current, pinned or in progress. Every failure prints the server's
# own reason and the remaining ids are still processed.
#
# Usage: ./scripts/install-extensions.sh <extension-id>[@<version>] [...]
# Exit:  0 every id installed, requested, already current, or skipped
#        1 at least one id failed, no token, or the catalog could not be read
#        2 usage
set -euo pipefail
cd "$(dirname "$0")/.."

[ $# -gt 0 ] || { echo "Usage: $0 <extension-id>[@<version>] [...]" >&2; exit 2; }

source "$(dirname "$0")/_target.sh"   # → BASE_URL + TOKEN from .env per DUPLO_TARGET
[ -n "$TOKEN" ] || { echo "No token resolved — set DUPLO_ADMIN_TOKEN (local) or DUPLO_TOKEN (remote) in .env." >&2; exit 1; }
ADMIN="$BASE_URL/v1/aiservicedesk/admin"

# api METHOD URL [BODY] → the response body, then a last line holding the HTTP status (000: no response at all).
# Never curl -f: on a 4xx/5xx the body is the only place the studio says why (see scripts/_studio_api.sh).
api() {
  local args=(-sS --max-time 30 -w '\n%{http_code}' -X "$1" "$2" -H "Authorization: Bearer $TOKEN")
  [ $# -lt 3 ] || args+=(-H "Content-Type: application/json" --data "$3")
  curl "${args[@]}" 2>/dev/null || printf '\n000'
}
status_of() { printf '%s' "${1##*$'\n'}"; }   # last line of an api() reply
body_of()   { printf '%s' "${1%$'\n'*}"; }    # everything before it

# err_msg BODY → the server's reason: message + errors, tagged with its code or reason slug; else the raw text.
err_msg() {
  printf '%s' "$1" | python3 -c '
import sys, json
raw = sys.stdin.read()
try: d = json.loads(raw)
except Exception: d = None
msg = ""
if isinstance(d, dict):
    errs = d.get("errors")
    if isinstance(errs, (list, dict)): errs = json.dumps(errs)
    msg = " ".join(str(x) for x in (d.get("message"), errs) if x)
    tag = d.get("code") or d.get("reason")
    if tag: msg = "%s (%s)" % (msg, tag) if msg else str(tag)
print(msg or raw.strip() or "<empty body>")'
}

# ── validate every argument before calling anything ─────────────────────────────────────────────
# The id goes into a URL path, so it must start alphanumeric and hold only [A-Za-z0-9._-] — no '/', no '..'.
FAILED=0; IDS=(); WANTS=()
for arg in "$@"; do
  id="${arg%%@*}"; want=""
  [ "$id" = "$arg" ] || want="${arg#*@}"
  if [[ "$id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] && { [ "$id" = "$arg" ] || [ -n "$want" ]; }; then
    IDS+=("$id"); WANTS+=("$want")
  else
    echo "    ✗ '$arg' — invalid extension id" >&2; FAILED=1
  fi
done
[ ${#IDS[@]} -gt 0 ] || exit 1

# ── the registry catalog, read once ─────────────────────────────────────────────────────────────
# A license problem still answers 200, with libraryState saying which and no extensions: that must read as an
# error, never as "every id is missing".
REPLY_="$(api GET "$ADMIN/extension-registry/catalog")"
CODE="$(status_of "$REPLY_")"; CATALOG="$(body_of "$REPLY_")"
STATE="bad"
[[ "$CODE" != 2* ]] || STATE="$(printf '%s' "$CATALOG" | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: d = None
if not isinstance(d, dict) or not isinstance(d.get("extensions"), list): print("bad")
else: print(d.get("libraryState") or "ok")' 2>/dev/null)" || STATE="bad"
case "$STATE" in
  ok) ;;
  bad) echo "    ✗ could not read the extension catalog: HTTP $CODE: $(err_msg "$CATALOG")" >&2; exit 1 ;;
  *)
    case "$STATE" in
      missing)     why="no license is configured" ;;
      invalid)     why="the license server refused this install's license" ;;
      unavailable) why="the license server could not be reached" ;;
      *)           why="see the Extension Library page" ;;
    esac
    echo "    ✗ could not read the extension catalog: library state \"$STATE\" ($why)" >&2; exit 1 ;;
esac

# plan_install ID WANT → one line from $CATALOG: "ok <version>" | "missing" | "unlicensed" | "noversion" |
# "pinned <version>" | "busy <state>" | "blocked <reason>" | "notoffered <version>" | "absent <v1, v2, …>".
plan_install() {
  printf '%s' "$CATALOG" | ID="$1" WANT="$2" python3 -c '
import sys, json, os
def key(v):  # semver-ish: numeric core, stable above its pre-releases, pre-release parts compared numerically
    core, _, pre = v.partition("-")
    nums = tuple(int(p) if p.isdigit() else 0 for p in core.split("."))
    pre_key = tuple((0, int(p), "") if p.isdigit() else (1, 0, p) for p in pre.split(".")) if pre else ()
    return (nums, 0 if pre else 1, pre_key)
def rows(name): return [r for r in c.get(name) or [] if isinstance(r, dict)]
c = json.load(sys.stdin); id_, want = os.environ["ID"], os.environ["WANT"]
ext = next((e for e in rows("extensions") if (e.get("manifestId") or e.get("id")) == id_), None)
mark = next((m for m in rows("marks") if m.get("id") == id_), None) or {}
busy = next((r for r in rows("requests") if r.get("id") == id_ and r.get("state") not in ("done", "backed-out", "failed")), None)
vs = [v["version"] for v in (ext or {}).get("versions") or [] if isinstance(v, dict) and v.get("version")]
if ext is None: out = "missing"
elif ext.get("licensed") is False: out = "unlicensed"
elif mark.get("pinnedVersion"): out = "pinned " + mark["pinnedVersion"]
elif busy: out = "busy " + (busy.get("state") or "pending")
elif mark.get("version"): out = ("ok " if want in ("", mark["version"]) else "notoffered ") + mark["version"]
elif mark.get("reason"): out = "blocked " + mark["reason"]
elif not vs: out = "noversion"
elif want: out = "ok " + want if want in vs else "absent " + ", ".join(sorted(vs, key=key, reverse=True))
else: out = "ok " + max([v for v in vs if "-" not in v] or vs, key=key)
print(out)'
}

# is_current BODY VERSION → rc 0 when the /versions reply marks VERSION as the current one.
is_current() {
  printf '%s' "$1" | V="$2" python3 -c '
import sys, json, os
try: d = json.load(sys.stdin)
except Exception: d = []
cur = any(isinstance(e, dict) and e.get("isCurrent") and e.get("version") == os.environ["V"] for e in (d if isinstance(d, list) else []))
raise SystemExit(0 if cur else 1)'
}

# ── per id: decide, skip if current, else install ───────────────────────────────────────────────
for i in "${!IDS[@]}"; do
  id="${IDS[$i]}"; want="${WANTS[$i]}"
  pick="$(plan_install "$id" "$want")" || pick=""
  case "$pick" in
    "ok "?*)       ver="${pick#ok }" ;;
    missing)       echo "    ↷ $id — not in the extension catalog, skipped"; continue ;;
    unlicensed)    echo "    ↷ $id — not licensed for this install, skipped"; continue ;;
    noversion)     echo "    ↷ $id — no version to install, skipped"; continue ;;
    "pinned "*)    echo "    ↷ $id — pinned at ${pick#pinned }, left alone"; continue ;;
    "busy "*)      echo "    ↷ $id — an install is already in progress (${pick#busy })"; continue ;;
    "blocked "*)   echo "    ✗ $id — the installer can't install it here: ${pick#blocked }" >&2; FAILED=1; continue ;;
    "notoffered "*) echo "    ✗ $id@$want — the registry offers ${pick#notoffered }; installing another version needs a pin" >&2
                   FAILED=1; continue ;;
    "absent "*)    echo "    ✗ $id@$want — version not in the catalog (available: ${pick#absent })" >&2; FAILED=1; continue ;;
    *)             echo "    ✗ $id — could not read its catalog entry" >&2; FAILED=1; continue ;;
  esac

  REPLY_="$(api GET "$ADMIN/extensions/$id/versions")"; CODE="$(status_of "$REPLY_")"; BODY="$(body_of "$REPLY_")"
  if [[ "$CODE" == 2* ]] && is_current "$BODY" "$ver"; then
    echo "    ✔ $id $ver — already installed"; continue
  elif [[ "$CODE" != 2* && "$CODE" != 404 ]]; then
    echo "    ✗ $id — could not read installed versions: HTTP $CODE: $(err_msg "$BODY")" >&2; FAILED=1; continue
  fi

  REQ="$(ID="$id" V="$ver" python3 -c 'import json,os;print(json.dumps({"extensionId":os.environ["ID"],"version":os.environ["V"],"pin":False}))')"
  REPLY_="$(api POST "$ADMIN/extension-registry/install" "$REQ")"; CODE="$(status_of "$REPLY_")"
  case "$CODE" in
    202) echo "    ✔ $id $ver — install requested (HTTP 202); the installer finishes it in the background" ;;
    2*)  echo "    ✔ $id $ver — installed" ;;
    *)   echo "    ✗ $id $ver — install failed: HTTP $CODE: $(err_msg "$(body_of "$REPLY_")")" >&2; FAILED=1 ;;
  esac
done
exit "$FAILED"
