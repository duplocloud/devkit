# shellcheck shell=bash
# Sourced by run.sh — the one way it POSTs a record to the local studio and reads back data.id.
#
# WHY: `curl -fsS … | python3 -c 'json.load(sys.stdin)["data"]["id"]'` hides every failure. -f makes
# curl drop the body on a 4xx/5xx, so the studio's reason (e.g. "license has expired … renew it from the
# License page", code license_limit_exceeded) never reaches the user — they get a bare `curl: (22) … 400`
# followed by a JSONDecodeError traceback from python reading empty stdin. This helper keeps the body,
# prints the server's message on stderr, and returns non-zero so the caller can stop cleanly.
# Expects the caller to define TOK (bearer token).

studio_create_id() { # url json-body → prints data.id on stdout; rc 1 + message on stderr otherwise
  local url="$1" body="$2" resp http
  resp="$(curl -sS --max-time 10 -w '\n%{http_code}' -X POST "$url" \
      -H "Authorization: Bearer $TOK" -H "Content-Type: application/json" --data "$body" 2>&1)" || {
    echo "    ✗ POST $url failed: ${resp:-<no response>}" >&2; return 1; }
  http="${resp##*$'\n'}"; resp="${resp%$'\n'*}"
  printf '%s' "$resp" | H="$http" U="$url" python3 -c '
import sys,json,os
raw=sys.stdin.read(); http=os.environ["H"]; url=os.environ["U"]
try: d=json.loads(raw)
except Exception: d=None
if http.startswith("2") and isinstance(d,dict) and isinstance(d.get("data"),dict) and d["data"].get("id"):
    print(d["data"]["id"]); raise SystemExit(0)
msg=""
if isinstance(d,dict):
    errs=d.get("errors")
    if isinstance(errs,(list,dict)): errs=json.dumps(errs)
    msg=" ".join(str(x) for x in (d.get("message"), errs) if x)
    if d.get("code"): msg+=" (%s)"%d["code"]
msg=msg or raw.strip() or "<empty body>"
print("    ✗ POST %s → HTTP %s: %s"%(url,http,msg),file=sys.stderr); raise SystemExit(1)'
}
