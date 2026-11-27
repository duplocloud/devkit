#!/usr/bin/env bash
# Checks scripts/install-extensions.sh (DUPLOAI-4813): refreshes the registry catalog and uses that reply as the
# catalog (a GET only when the refresh fails), skips manifest ids that are not in it (or that the installer offers no
# version of), takes the version from the installer's mark, skips it when the row's installedVersion already is that
# version, otherwise POSTs the install with pin:false and polls the catalog's requests[] until the installer reports
# the request done or failed — surfacing the server's reason on every failure.
#
# Runs the script from a temp copy of the kit with a stub `curl` first on PATH, so it never reaches a real studio.
# The stub serves $STUB/catalog.json from both the refresh (unless $STUB/refresh.code says otherwise) and the GET,
# and $STUB/install.body (+ install.code); it logs "<METHOD> <URL> <BODY>" per call to
# $STUB/curl.log. Once an install has been POSTed, every later catalog read carries that request in requests[], its
# state taken from the first line of $STUB/states (a line is consumed per poll while more remain; default "done")
# and its reason from $STUB/fail.reason.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
PASS=0; FAIL=0
t()   { printf '  %s … ' "$1"; }
ok()  { echo "ok"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

command -v python3 >/dev/null 2>&1 || { echo "skipped: needs python3"; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
KIT="$TMP/kit"; STUB="$TMP/stub"
mkdir -p "$KIT/scripts" "$TMP/bin" "$STUB"
cp scripts/install-extensions.sh scripts/_target.sh "$KIT/scripts/" 2>/dev/null
printf 'DUPLO_ADMIN_TOKEN=fixture\n' > "$KIT/.env"
API=http://localhost:60021/v1/aiservicedesk/admin

cat > "$TMP/bin/curl" <<'SH'
#!/usr/bin/env bash
method=GET; url=""; body=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift ;;
    --data|-d) body="$2"; shift ;;
    http*) url="$1" ;;
  esac
  shift
done
echo "$method $url $body" >> "$STUB/curl.log"
reply() { printf '%s\n%s' "$1" "$2"; }
case "$url" in
  */extension-registry/catalog/refresh|*/extension-registry/catalog)
    case "$url" in */refresh)
      rc="$(cat "$STUB/refresh.code" 2>/dev/null || echo 200)"
      case "$rc" in 2*) ;; *) reply '{"message":"refresh failed"}' "$rc"; exit 0 ;; esac ;;
    esac
    [ -f "$STUB/catalog.json" ] || { reply oops 500; exit 0; }
    # $STUB/unsettled N → the next N catalog reads come from an installer whose last pass failed: no marks yet.
    if [ -f "$STUB/unsettled" ] && n="$(cat "$STUB/unsettled")" && [ "$n" -gt 0 ]; then
      echo $((n - 1)) > "$STUB/unsettled"
      reply "$(python3 -c 'import json, sys
c = json.load(open(sys.argv[1])); c["marks"] = []
c["installer"] = {"ready": True, "lastPassAt": "2026-11-24T16:43:30Z", "outcome": "error", "reason": "backend-call-failed"}
print(json.dumps(c))' "$STUB/catalog.json")" 200; exit 0
    fi
    if [ -f "$STUB/posted" ]; then
      reply "$(python3 - "$STUB" <<'PY'
import json, os, sys
d = sys.argv[1]
c = json.load(open(os.path.join(d, "catalog.json")))
req = json.load(open(os.path.join(d, "posted")))
sf = os.path.join(d, "states")
lines = open(sf).read().split() if os.path.exists(sf) else []
state = lines[0] if lines else "done"
if len(lines) > 1: open(sf, "w").write("\n".join(lines[1:]) + "\n")
rf = os.path.join(d, "fail.reason")
entry = {"requestId": "r1", "id": req["extensionId"], "version": req["version"], "state": state,
         "reason": open(rf).read().strip() if os.path.exists(rf) else None}
c["requests"] = [r for r in c.get("requests") or [] if r.get("requestId") != "r1"] + [entry]
print(json.dumps(c))
PY
)" 200
    else reply "$(cat "$STUB/catalog.json")" 200; fi ;;
  */extension-registry/install)
    code="$(cat "$STUB/install.code" 2>/dev/null || echo 202)"
    case "$code" in 2*) printf '%s' "$body" > "$STUB/posted" ;; esac
    reply "$(cat "$STUB/install.body" 2>/dev/null || echo '{"requestId":"r1","state":"accepted"}')" "$code" ;;
  *) exit 7 ;;
esac
SH
chmod +x "$TMP/bin/curl"

# catalog "id=v1,v2" … → $STUB/catalog.json, every id licensed and marked as offering its first version;
# "id=" gives that id no versions and no mark.
catalog() {
  python3 - "$STUB/catalog.json" "$@" <<'PY'
import json, sys
exts, marks = [], []
for spec in sys.argv[2:]:
    i, _, vs = spec.partition("=")
    vs = [v for v in vs.split(",") if v]
    exts.append({"id": i, "licensed": True, "versions": [{"version": v, "name": i, "changelog": ""} for v in vs]})
    if vs: marks.append({"id": i, "version": vs[0]})
json.dump({"libraryState": "ok", "extensions": exts, "marks": marks, "requests": []}, open(sys.argv[1], "w"))
PY
}
# patch_catalog PYTHON → runs PYTHON with `c` bound to the parsed $STUB/catalog.json, then writes it back.
patch_catalog() {
  python3 - "$STUB/catalog.json" "$1" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
exec(sys.argv[2])
json.dump(c, open(sys.argv[1], "w"))
PY
}
# reset → the default fixture: X in the catalog at 1.10.0, 1.9.3, 1.2.0, the installer offering 1.10.0, nothing
# installed; an install is accepted (202) and the first poll finds it done.
reset() { rm -f "$STUB"/*; catalog "com.example.x=1.10.0,1.9.3,1.2.0"; }

# run ARGS… → runs the copy with only the fixture .env and the stub; stdout in $OUT, stderr in $ERR, exit in $RC.
# Polls without sleeping; TIMEOUT (default 60) is the script's EXT_INSTALL_TIMEOUT.
run() {
  : > "$STUB/curl.log"
  OUT="$(cd "$KIT" && env -u DUPLO_TARGET -u DUPLO_HOST -u DUPLO_TOKEN -u DUPLO_BASE -u DUPLO_ADMIN_TOKEN \
    -u DUPLO_ENV_FILE PATH="$TMP/bin:$PATH" STUB="$STUB" EXT_INSTALL_POLL=0 EXT_INSTALL_TIMEOUT="${TIMEOUT:-60}" \
    EXT_CATALOG_WAIT="${CWAIT:-60}" \
    ./scripts/install-extensions.sh "$@" 2>"$TMP/err")"
  RC=$?
  ERR="$(cat "$TMP/err")"
}
# installs → one normalised JSON body per install POST, in call order.
installs() {
  sed -n 's#^POST [^ ]*/extension-registry/install ##p' "$STUB/curl.log" \
    | python3 -c 'import json,sys
for l in sys.stdin:
    if l.strip(): print(json.dumps(json.loads(l), sort_keys=True, separators=(",", ":")))'
}
# installed_versions → just the version of each install POST, one per line.
installed_versions() { installs | python3 -c 'import json,sys
for l in sys.stdin: print(json.loads(l)["version"])'; }
has()   { grep -qF -- "$2" <<<"$1"; }
calls() { awk '{print $1, $2}' "$STUB/curl.log"; }

echo "install-extensions.sh:"

reset; run com.example.x
t "offered_version_installed: installs the version the installer's mark offers, with pin:false"
if [ "$RC" = 0 ] && [ "$(installs)" = '{"extensionId":"com.example.x","pin":false,"version":"1.10.0"}' ] \
   && has "$OUT" "    ✔ com.example.x 1.10.0 — installed"; then ok; else bad "rc=$RC installs=$(installs) out=$OUT err=$ERR"; fi

t "pin_is_json_false: pin is a JSON boolean, not a string"
if grep -q '"pin": false' "$STUB/curl.log"; then ok; else bad "$(cat "$STUB/curl.log")"; fi

t "call_sequence: refresh (its reply is the catalog), install, then a catalog poll — no GET first, no /versions"
expected="POST $API/extension-registry/catalog/refresh
POST $API/extension-registry/install
GET $API/extension-registry/catalog"
if [ "$(calls)" = "$expected" ]; then ok; else bad "$(calls)"; fi

reset; patch_catalog 'c["marks"] = [{"id": "com.example.x", "version": "1.9.3"}]'; run com.example.x
t "mark_version_wins: installs the offered build, not the newest published"
if [ "$RC" = 0 ] && [ "$(installed_versions)" = 1.9.3 ]; then ok; else bad "rc=$RC installs=$(installs) err=$ERR"; fi

reset; catalog "com.example.x=1.0.0" "com.example.y=2.0.0"; run com.example.x com.example.y
t "catalog_read_once: two ids, one refresh and no catalog GET before the installs"
if [ "$(sed -n '1,/\/install /p' "$STUB/curl.log" | grep -c 'GET .*/extension-registry/catalog $')" = 0 ] \
   && [ "$(grep -c '/catalog/refresh' "$STUB/curl.log")" = 1 ] && [ "$(installed_versions | tr '\n' ' ')" = "1.0.0 2.0.0 " ]
then ok; else bad "$(calls)"; fi

reset; echo 500 > "$STUB/refresh.code"; run com.example.x
t "refresh_failure_warns: a failed refresh is a warning; the cached catalog is read with a GET instead"
if [ "$RC" = 0 ] && has "$ERR" "could not refresh the agent catalog: HTTP 500" && [ "$(installed_versions)" = 1.10.0 ] \
   && [ "$(sed -n '1,/\/install /p' "$STUB/curl.log" | grep -c 'GET .*/extension-registry/catalog $')" = 1 ]
then ok; else bad "rc=$RC out=$OUT err=$ERR log=$(calls)"; fi

reset; patch_catalog 'c["extensions"][0].update(installed=True, installedVersion="1.10.0")'; run com.example.x
t "current_version_skipped: no install when the row's installedVersion is the offered version"
if [ "$RC" = 0 ] && ! grep -q /install "$STUB/curl.log" && has "$OUT" "    ✔ com.example.x 1.10.0 — already installed"
then ok; else bad "rc=$RC out=$OUT log=$(calls)"; fi

t "no_versions_call: installed state comes from the catalog row; /versions is never called"
if ! grep -q '/versions' "$STUB/curl.log"; then ok; else bad "$(calls)"; fi

reset; patch_catalog 'c["extensions"][0].update(installed=True, installedVersion="1.9.3")'; run com.example.x
t "older_current_upgraded: current 1.9.3 → installs the offered 1.10.0"
if [ "$RC" = 0 ] && [ "$(installed_versions)" = 1.10.0 ]; then ok; else bad "rc=$RC installs=$(installs)"; fi

reset; run com.example.y com.example.x
t "unknown_id_skipped: an id not in the catalog is skipped, the next id still installs, exit 0"
if [ "$RC" = 0 ] && has "$OUT" "    ↷ com.example.y — not in the agent catalog, skipped" \
   && [ "$(installed_versions)" = 1.10.0 ] && ! grep -q com.example.y "$STUB/curl.log"; then ok
else bad "rc=$RC out=$OUT err=$ERR log=$(calls)"; fi

reset; patch_catalog 'c["marks"] = []'; run com.example.x
t "no_offer_skipped: no mark means no installable version — skipped with the license hint, no fallback"
if [ "$RC" = 0 ] && has "$OUT" "    ↷ com.example.x — the installer offers no version (does the license list it?), skipped" \
   && ! grep -q /install "$STUB/curl.log" && ! has "$OUT$ERR" Traceback; then ok; else bad "rc=$RC out=$OUT err=$ERR"; fi

reset; rm -f "$STUB/catalog.json"; run com.example.x
t "catalog_unreachable: exit 1 with the server's reason, nothing after the catalog GET"
if [ "$RC" = 1 ] && has "$ERR" "    ✗ could not read the agent catalog: HTTP 500: oops" \
   && [ "$(calls | grep -vc refresh)" = 1 ]; then ok; else bad "rc=$RC err=$ERR log=$(calls)"; fi

reset; echo 400 > "$STUB/install.code"
echo '{"message":"license has expired","code":"license_limit_exceeded"}' > "$STUB/install.body"; run com.example.x
t "install_http_error_message: the studio's message and code reach the user"
if [ "$RC" = 1 ] && has "$ERR" "    ✗ com.example.x 1.10.0 — install failed: HTTP 400: license has expired (license_limit_exceeded)"
then ok; else bad "rc=$RC err=$ERR"; fi

reset; echo 502 > "$STUB/install.code"; echo '<html>Bad Gateway</html>' > "$STUB/install.body"; run com.example.x
t "install_non_json_error: a non-JSON body is shown raw, no traceback"
if [ "$RC" = 1 ] && has "$ERR" "install failed: HTTP 502: <html>Bad Gateway</html>" && ! has "$OUT$ERR" Traceback
then ok; else bad "rc=$RC err=$ERR"; fi

reset; run '../etc' '..' com.example.x@1.10.0 com.example.x
t "invalid_id_rejected: path-escaping ids and id@version are refused and never sent"
if [ "$RC" = 1 ] && has "$ERR" "    ✗ '../etc' — invalid agent id" && has "$ERR" "    ✗ '..' — invalid agent id" \
   && has "$ERR" "    ✗ 'com.example.x@1.10.0' — invalid agent id" \
   && ! grep -qE 'etc|/extensions/\.\./|@' "$STUB/curl.log" && [ "$(installed_versions)" = 1.10.0 ]; then ok
else bad "rc=$RC err=$ERR log=$(calls)"; fi

reset; run
t "no_args_usage: exit 2 with usage on stderr"
if [ "$RC" = 2 ] && [ "${ERR%%:*}" = Usage ]; then ok; else bad "rc=$RC err=$ERR"; fi

echo "against the studio's real catalog shape:"

# The catalog's `id` is the console's renameable display slug; the manifest id the installer keys on is `manifestId`.
reset; patch_catalog 'c["extensions"][0].update(id="cloud-deploy", manifestId="com.example.x")'; run com.example.x
t "matches_manifest_id: an id given as the manifest id is found even when the display id differs"
if [ "$RC" = 0 ] && [ "$(installs)" = '{"extensionId":"com.example.x","pin":false,"version":"1.10.0"}' ]; then ok
else bad "rc=$RC out=$OUT err=$ERR"; fi

# A missing/invalid/unreachable license answers 200 with libraryState set and no extensions at all.
reset; echo '{"libraryState":"missing","extensions":[],"marks":[],"requests":[]}' > "$STUB/catalog.json"; run com.example.x
t "library_state_not_ok: an unusable catalog is an error, not a quiet skip"
if [ "$RC" = 1 ] && has "$ERR" '    ✗ could not read the agent catalog: library state "missing" (no license is configured)' \
   && [ "$(calls | grep -vc refresh)" = 0 ]; then ok; else bad "rc=$RC out=$OUT err=$ERR log=$(calls)"; fi

reset; patch_catalog 'c["extensions"][0].update(licensed=False, versions=[]); c["marks"] = []'; run com.example.x
t "unlicensed_skipped: a row this license doesn't cover says so"
if [ "$RC" = 0 ] && has "$OUT" "    ↷ com.example.x — not licensed for this install, skipped" && ! grep -q /install "$STUB/curl.log"
then ok; else bad "rc=$RC out=$OUT err=$ERR"; fi

reset; patch_catalog 'c["marks"] = [{"id": "com.example.x", "version": None, "reason": "sdk-mismatch"}]'; run com.example.x
t "mark_blocked: a mark with a reason and no version is reported, nothing sent"
if [ "$RC" = 1 ] && has "$ERR" "    ✗ com.example.x — the installer can't install it here: sdk-mismatch" \
   && ! grep -q /install "$STUB/curl.log"; then ok; else bad "rc=$RC out=$OUT err=$ERR"; fi

# An unpinned install clears a pin, and a rollback always pins — so a re-run must not undo either.
reset; patch_catalog 'c["marks"] = [{"id": "com.example.x", "version": "1.10.0", "pinnedVersion": "1.9.3"}]'; run com.example.x
t "pinned_left_alone: an agent an admin pinned or rolled back is not re-installed"
if [ "$RC" = 0 ] && has "$OUT" "    ↷ com.example.x — pinned at 1.9.3, left alone" && ! grep -q /install "$STUB/curl.log"
then ok; else bad "rc=$RC out=$OUT err=$ERR log=$(calls)"; fi

reset; patch_catalog 'c["requests"] = [{"requestId": "r9", "id": "com.example.x", "version": "1.10.0", "state": "downloading"}]'
run com.example.x
t "in_progress_skipped: an install the installer is still working on is not requested again"
if [ "$RC" = 0 ] && has "$OUT" "    ↷ com.example.x — an install is already in progress (downloading)" \
   && ! grep -q /install "$STUB/curl.log"; then ok; else bad "rc=$RC out=$OUT err=$ERR"; fi

reset; patch_catalog 'c["requests"] = [{"requestId": "r0", "id": "com.example.x", "version": "1.10.0", "state": "failed"}]'
run com.example.x
t "finished_request_ignored: a failed earlier request doesn't block a new one"
if [ "$RC" = 0 ] && [ "$(installed_versions)" = 1.10.0 ]; then ok; else bad "rc=$RC out=$OUT err=$ERR"; fi

reset; echo 409 > "$STUB/install.code"; echo '{"reason":"version-not-offered","offeredVersion":"1.9.3"}' > "$STUB/install.body"
run com.example.x
t "installer_reason_shown: an installer refusal shows its reason slug, not raw JSON"
if [ "$RC" = 1 ] && grep -qxF "    ✗ com.example.x 1.10.0 — install failed: HTTP 409: version-not-offered" <<<"$ERR"
then ok; else bad "rc=$RC err=$ERR"; fi

echo "pre-install: waiting for the installer's first good pass:"

# Fresh `docker compose up`: the installer's first pass fails (studio not up yet) and marks[] is empty until it retries.
reset; echo 3 > "$STUB/unsettled"; run com.example.x
t "installer_unsettled_waited: a failed last pass is waited out, then the offered version installs"
if [ "$RC" = 0 ] && has "$OUT" "    … the installer has no offers yet (last pass failed: backend-call-failed) — waiting up to 60s (EXT_CATALOG_WAIT)" \
   && has "$OUT" "    ✔ the installer is ready" && [ "$(installed_versions)" = 1.10.0 ] \
   && [ "$(sed -n '1,/\/install /p' "$STUB/curl.log" | grep -c 'GET .*/extension-registry/catalog $')" = 3 ]
then ok; else bad "rc=$RC out=$OUT err=$ERR log=$(calls)"; fi

reset; echo 999 > "$STUB/unsettled"; CWAIT=0 run com.example.x
t "installer_never_settles: no offers by EXT_CATALOG_WAIT is an error naming the installer, not the license"
if [ "$RC" = 1 ] && has "$ERR" "    ! the installer still has no offers after 0s (last pass failed: backend-call-failed)" \
   && has "$ERR" "    ✗ com.example.x — the installer has made no offers yet (last pass failed: backend-call-failed); re-run" \
   && ! has "$OUT$ERR" "does the license list it" && ! grep -q /install "$STUB/curl.log"
then ok; else bad "rc=$RC out=$OUT err=$ERR log=$(calls)"; fi

reset; patch_catalog 'c["installer"] = {"ready": True, "lastPassAt": "2026-11-24T16:44:28Z", "outcome": "skipped"}; c["marks"] = []'
run com.example.x
t "installer_settled_no_wait: a good last pass with no mark is the plain license skip, with no extra catalog reads"
if [ "$RC" = 0 ] && has "$OUT" "    ↷ com.example.x — the installer offers no version (does the license list it?), skipped" \
   && ! has "$OUT" "waiting up to" && [ "$(calls)" = "POST $API/extension-registry/catalog/refresh" ]
then ok; else bad "rc=$RC out=$OUT err=$ERR log=$(calls)"; fi

reset; patch_catalog 'c["installer"] = {"ready": False}; c["marks"] = []'; CWAIT=0 run com.example.x
t "installer_not_ready: an installer reporting ready:false is waited for too"
if [ "$RC" = 1 ] && has "$OUT" "the installer has no offers yet (not ready)" \
   && has "$ERR" "    ✗ com.example.x — the installer has made no offers yet (not ready); re-run"
then ok; else bad "rc=$RC out=$OUT err=$ERR"; fi

echo "post-install: waiting for the installer:"

reset; printf 'accepted\ndownloading\ninstalling\ndone\n' > "$STUB/states"; run com.example.x
t "install_202_polled_to_done: an accepted install is polled through its states until done"
if [ "$RC" = 0 ] && has "$OUT" "    … com.example.x 1.10.0 — install requested (HTTP 202), waiting for the installer" \
   && has "$OUT" "    ✔ com.example.x 1.10.0 — installed" \
   && [ "$(sed -n '/\/install /,$p' "$STUB/curl.log" | grep -c 'GET .*/extension-registry/catalog $')" = 4 ]
then ok; else bad "rc=$RC out=$OUT err=$ERR log=$(calls)"; fi

# 200 means the installer already holds a pending request for it — not that it is installed.
reset; echo 200 > "$STUB/install.code"; echo '{"requestId":"r1","state":"downloading"}' > "$STUB/install.body"
printf 'downloading\ndone\n' > "$STUB/states"; run com.example.x
t "install_200_is_pending: a 200 is polled like a 202, not reported as installed straight away"
if [ "$RC" = 0 ] && has "$OUT" "install requested (HTTP 200), waiting for the installer" \
   && has "$OUT" "    ✔ com.example.x 1.10.0 — installed" \
   && [ "$(sed -n '/\/install /,$p' "$STUB/curl.log" | grep -c 'GET .*/extension-registry/catalog $')" = 2 ]
then ok; else bad "rc=$RC out=$OUT err=$ERR log=$(calls)"; fi

reset; printf 'downloading\nfailed\n' > "$STUB/states"; echo not-entitled > "$STUB/fail.reason"; run com.example.x
t "install_failed_reason: a request that ends failed is an error with the installer's reason"
if [ "$RC" = 1 ] && has "$ERR" "    ✗ com.example.x 1.10.0 — install failed: failed (not-entitled)" && ! has "$OUT" "— installed"
then ok; else bad "rc=$RC out=$OUT err=$ERR"; fi

reset; echo backed-out > "$STUB/states"; run com.example.x
t "install_backed_out: a backed-out install is an error"
if [ "$RC" = 1 ] && has "$ERR" "    ✗ com.example.x 1.10.0 — install failed: backed-out"; then ok; else bad "rc=$RC out=$OUT err=$ERR"; fi

reset; echo downloading > "$STUB/states"; TIMEOUT=0 run com.example.x
t "install_timeout: still running when the wait ends → error naming the last state and the timeout"
if [ "$RC" = 1 ] && has "$ERR" "    ✗ com.example.x 1.10.0 — still downloading after 0s (EXT_INSTALL_TIMEOUT); check the Marketplace"
then ok; else bad "rc=$RC out=$OUT err=$ERR"; fi

# Without a requestId in the reply, the request is found by id and version.
reset; echo '{"state":"accepted"}' > "$STUB/install.body"; run com.example.x
t "poll_without_request_id: the request is matched on id and version"
if [ "$RC" = 0 ] && has "$OUT" "    ✔ com.example.x 1.10.0 — installed"; then ok; else bad "rc=$RC out=$OUT err=$ERR"; fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
