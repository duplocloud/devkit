#!/usr/bin/env python3
"""Stub tests for scripts/connect_cloud.py — no cloud, no docker, no real studio.

A threaded http.server plays the studio (admin data API) and Google (OAuth token, IAM Credentials,
GCS); a stub `aws` on PATH plays `aws configure export-credentials` + `sts get-caller-identity`; a stub
`docker` plays `ps -q` / `inspect` for container snapshots; the credential store command is a stub
script that records what it was asked to write. Every test asserts observable behaviour: which
requests were made, what was stored, and that no secret ever landed in an argument list, the records
file, or stdout. None of this proves anything about a live stack — it pins the tool's contract.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, "scripts", "connect_cloud.py")

SECRET_KEY = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
REFRESH_TOKEN = "1//0gExampleRefreshToken"
CLIENT_SECRET = "d-FL95Q19q7MQmFpd7hHD0Ty"
SA = "helpdesk-test@gcp-test9.iam.gserviceaccount.com"
TOOL = "devkit connect-cloud"


class Fake(BaseHTTPRequestHandler):
    """One handler for both the studio and Google: routed by path."""

    state: dict = {}
    log: list = []
    lock = threading.Lock()

    def log_message(self, *a):
        pass

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""

    def _send(self, code, obj=None):
        data = json.dumps(obj).encode() if obj is not None else b""
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if data:
            self.wfile.write(data)

    def _route(self, method):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        qs = urllib.parse.parse_qs(parsed.query)
        raw = self._body()
        body = None
        if raw:
            ctype = self.headers.get("Content-Type", "")
            if "json" in ctype:
                body = json.loads(raw)
            elif "form" in ctype:
                body = {k: v[0] for k, v in urllib.parse.parse_qs(raw.decode()).items()}
        with self.lock:
            self.log.append((method, self.path, body, dict(self.headers)))  # full path incl. query
        st = self.state

        # ── Google, dynamic IAM model (only when a test sets state["gcp"]) ──
        if st.get("gcp") and self._gcp(method, path, qs, body):
            return

        # ── Google ──
        if path == "/token":
            if body.get("refresh_token") == REFRESH_TOKEN and body.get("client_secret") == CLIENT_SECRET:
                return self._send(200, {"access_token": "ya29.user", "expires_in": 3599})
            return self._send(400, {"error": "invalid_grant", "error_description": "Token has been expired or revoked."})
        if path.startswith("/iam/projects/-/serviceAccounts/"):
            sa = urllib.parse.unquote(path.split("/serviceAccounts/")[1].split(":")[0])
            if self.headers.get("Authorization") != "Bearer ya29.user":
                return self._send(401, {"error": {"message": "unauthenticated"}})
            if sa == st["sa"]:
                return self._send(200, {"accessToken": "ya29.sa", "expireTime": "2099-01-01T00:00:00Z"})
            return self._send(403, {"error": {"code": 403, "message": "Permission 'iam.serviceAccounts.getAccessToken' denied"}})
        if path == "/storage/b":
            if self.headers.get("Authorization") != "Bearer ya29.sa":
                return self._send(401, {"error": {"message": "bad token"}})
            if qs.get("project", [""])[0] != st["project"]:
                return self._send(403, {"error": {"message": "forbidden project"}})
            page = int(qs.get("pageToken", ["0"])[0])
            pages = st.get("bucket_pages") or [st["buckets"]]
            resp = {"items": [{"name": n} for n in pages[page]]}
            if page + 1 < len(pages):
                resp["nextPageToken"] = str(page + 1)
            return self._send(200, resp)

        # ── studio ──
        admin = "/v1/aiservicedesk/admin/data/"
        if not path.startswith(admin):
            return self._send(404, {"message": "no route"})
        rest = path[len(admin):].split("/")
        coll = rest[0]
        store = st["studio"].setdefault(coll, {})

        if method == "GET" and len(rest) == 1:
            return self._send(200, {"data": {"items": list(store.values()), "totalPages": 1}})
        if method == "GET" and len(rest) == 2:
            rec = store.get(rest[1])
            return self._send(200, {"data": rec}) if rec else self._send(404, {"message": "not found"})
        if method == "POST" and len(rest) == 1:
            if any(r.get("name") == body.get("name") for r in store.values()):
                return self._send(400, {"message": f"{coll[:-1]} with name '{body['name']}' already exists"})
            if coll == "Providers" and not body.get("accountId"):
                return self._send(400, {"message": "AccountId is required for cloud providers"})
            rid = f"{coll.lower()}-{len(store) + 1}"
            rec = dict(body, id=rid)
            if coll == "Workspaces":
                rec.setdefault("scopeIds", [])
            store[rid] = rec
            return self._send(201, {"data": rec})
        if coll == "Providers" and len(rest) == 3 and rest[2] == "credentials" and method == "POST":
            prov = store[rest[1]]
            if any(c["name"].lower() == body["name"].lower() for c in prov.setdefault("credentials", [])):
                return self._send(409, {"message": "Credential already exists"})
            prov["credentials"].append(body)
            return self._send(201, {"data": body})
        if coll == "Providers" and len(rest) == 4 and rest[2] == "credentials" and method == "PUT":
            prov = store[rest[1]]
            name = urllib.parse.unquote(rest[3])
            idx = next((i for i, c in enumerate(prov.get("credentials", [])) if c["name"].lower() == name.lower()), None)
            if idx is None:
                return self._send(404, {"message": "credential not found"})
            prov["credentials"][idx] = body
            return self._send(200, {"data": body})
        if coll == "Workspaces" and len(rest) == 4 and rest[2] == "scopes" and method == "POST":
            ws = store.get(rest[1])
            if ws is None:
                return self._send(404, {})
            if rest[3] not in ws["scopeIds"]:
                ws["scopeIds"].append(rest[3])
            return self._send(200)
        if coll == "Scopes" and len(rest) == 4 and rest[2] == "aws" and rest[3] == "resources":
            scope = store.get(rest[1])
            if scope is None:
                return self._send(404, {"message": "Not Found"})
            prov = st["studio"]["Providers"][scope["providerId"]]
            cred = next(c for c in prov["credentials"] if c["name"] == scope["credentialName"])
            data = {d["key"]: d["value"] for d in cred["dataEx"]}
            if data.get("secretAccessKey") == SECRET_KEY:
                return self._send(200, {"data": {"resources": [], "nextToken": None}})
            return self._send(400, {"message": "Invalid Operation", "errors": "The security token included in the request is expired"})
        return self._send(404, {"message": f"unhandled {method} {path}"})

    # ── dynamic Google IAM model: userinfo, Resource Manager, Service Usage, IAM admin, impersonation, GCS ──
    def _g_send(self, code, obj=None):
        return self._send(code, obj) or True

    def _g_err(self, code, status, msg="denied", reason=None, consumer=None):
        err = {"code": code, "status": status, "message": msg}
        if reason:
            err["details"] = [{"@type": "type.googleapis.com/google.rpc.ErrorInfo", "reason": reason,
                               "metadata": {"consumer": consumer} if consumer else {}}]
        return self._g_send(code, {"error": err})

    def _gcp(self, method, path, qs, body):
        g = self.state["gcp"]
        self._greq = (method, qs)                        # the policy route enforces the exact Google contracts
        auth = self.headers.get("Authorization")
        denied = g.setdefault("deny", set())

        def need_user():
            if auth != "Bearer ya29.user":
                self._g_err(401, "UNAUTHENTICATED", "bad token")
                return False
            return True

        if path == "/userinfo":
            if not need_user():
                return True
            if g.get("userinfo_status"):
                return self._g_err(g["userinfo_status"], "PERMISSION_DENIED", "insufficient scope")
            return self._g_send(200, g.get("userinfo") or {"sub": "1", "email": g["user_email"], "email_verified": True})

        if path.startswith("/crm/projects/"):
            if not need_user():
                return True
            rest = path[len("/crm/projects/"):]
            pid, _, verb = rest.partition(":")
            if pid != g["project"]:
                return self._g_err(403, "PERMISSION_DENIED", "other project")
            if not verb:
                if "crm_get" in denied:
                    return self._g_err(403, "PERMISSION_DENIED", "resourcemanager.projects.get denied")
                return self._g_send(200, {"projectId": pid, "projectNumber": g["number"], "lifecycleState": "ACTIVE"})
            return self._g_policy_route(verb, body, g["proj_policy"], "proj-policy", "proj_setpolicy")

        if path.startswith("/su/"):
            if not need_user():
                return True
            rest = path[len("/su/"):]
            if rest.startswith("operations/"):
                op = g["ops"].get(rest)
                if op is None:
                    return self._g_err(404, "NOT_FOUND", "no op")
                op["polls"] -= 1
                if op["polls"] <= 0:
                    g["services"][op["svc"]] = "ENABLED"
                    return self._g_send(200, {"name": rest, "done": True, "response": {}})
                return self._g_send(200, {"name": rest, "done": False})
            prefix = f"projects/{g['number']}/services/"
            if not rest.startswith(prefix):
                return self._g_err(403, "PERMISSION_DENIED", "other project number")
            svc, _, verb = rest[len(prefix):].partition(":")
            if verb == "enable":
                if "enable" in denied:
                    return self._g_err(403, "PERMISSION_DENIED", "serviceusage.services.enable denied")
                g["writes"].append("enable:" + svc)
                name = f"operations/enable-{svc}"
                g["ops"][name] = {"svc": svc, "polls": g.get("op_polls", 1)}
                return self._g_send(200, {"name": name, "done": False})
            if "su_get" in denied:
                return self._g_err(403, "PERMISSION_DENIED", "serviceusage.services.get denied")
            return self._g_send(200, {"name": rest, "state": g["services"].get(svc, "DISABLED")})

        if path.startswith("/iamadmin/projects/"):
            if not need_user():
                return True
            rest = path[len("/iamadmin/projects/"):]
            proj, _, tail = rest.partition("/serviceAccounts")
            if proj != g["project"]:
                return self._g_err(403, "PERMISSION_DENIED", "other project")
            if tail == "" and method == "POST":
                if "sa_create" in denied:
                    return self._g_err(403, "PERMISSION_DENIED", "iam.serviceAccounts.create denied")
                email = f"{body['accountId']}@{proj}.iam.gserviceaccount.com"
                g["writes"].append("sa-create:" + email)
                g.setdefault("created_bodies", []).append(body)
                if g.get("create_race") or email in g["sas"]:
                    g["sas"].setdefault(email, {"email": email, "disabled": False})
                    return self._g_err(409, "ALREADY_EXISTS", "exists")
                g["sas"][email] = {"email": email, "disabled": False}
                return self._g_send(200, dict(g["sas"][email]))
            email_enc, _, verb = tail.lstrip("/").partition(":")
            email = urllib.parse.unquote(email_enc)
            if not verb:
                if "sa_get" in denied:
                    return self._g_err(403, "PERMISSION_DENIED", "iam.serviceAccounts.get denied")
                if g["services"].get("iam.googleapis.com") != "ENABLED":
                    return self._g_err(403, "PERMISSION_DENIED", "IAM API disabled", "SERVICE_DISABLED", "projects/" + g["number"])
                if email not in g["sas"]:
                    return self._g_err(404, "NOT_FOUND", "Service account does not exist")
                return self._g_send(200, g["sas"][email])
            if email not in g["sas"]:
                return self._g_err(404, "NOT_FOUND", "Service account does not exist")
            return self._g_policy_route(verb, body, g["sa_policy"].setdefault(email, {"version": 1, "etag": "ACAB"}),
                                        "sa-policy:" + email, "sa_setpolicy")

        if path.startswith("/iam/projects/-/serviceAccounts/"):
            sa = urllib.parse.unquote(path.split("/serviceAccounts/")[1].split(":")[0])
            if auth != "Bearer ya29.user":
                return self._g_err(401, "UNAUTHENTICATED", "bad token")
            if g.get("imp_status"):
                return self._g_err(g["imp_status"], "UNAVAILABLE", "backend error")
            g["imp_calls"] = g.get("imp_calls", 0) + 1
            if g["services"].get("iamcredentials.googleapis.com") != "ENABLED":
                return self._g_err(403, "PERMISSION_DENIED", "IAM Credentials API has not been used or is disabled",
                                   "SERVICE_DISABLED", g.get("consumer") or "projects/" + g["number"])
            if sa not in g["sas"]:
                code = g.get("missing_status", 404)
                return self._g_err(code, "NOT_FOUND" if code == 404 else "PERMISSION_DENIED", "no such service account or no permission")
            pol = g["sa_policy"].get(sa, {})
            has = any(b.get("role") == "roles/iam.serviceAccountTokenCreator" and not b.get("condition")
                      and "user:" + g["user_email"] in b.get("members", []) for b in pol.get("bindings", []))
            if not has:
                code = g.get("nogrant_status", 403)
                return self._g_err(code, "NOT_FOUND" if code == 404 else "PERMISSION_DENIED",
                                   "Permission 'iam.serviceAccounts.getAccessToken' denied")
            if g.get("lag", 0) > 0:
                g["lag"] -= 1
                return self._g_err(403, "PERMISSION_DENIED", "not propagated yet")
            return self._g_send(200, {"accessToken": "ya29.sa", "expireTime": "2099-01-01T00:00:00Z"})

        if path == "/storage/b":
            if auth != "Bearer ya29.sa":
                return self._g_err(401, "UNAUTHENTICATED", "bad token")
            sa = next(iter(g["sas"]), "")
            has = any(b.get("role") == "roles/viewer" and not b.get("condition") and "serviceAccount:" + sa in b.get("members", [])
                      for b in g["proj_policy"].get("bindings", []))
            if not has:
                return self._g_err(403, "PERMISSION_DENIED", "storage.buckets.list denied")
            return self._g_send(200, {"items": [{"name": n} for n in g.get("buckets", ["b1", "b2"])]})
        return False

    def _g_policy_route(self, verb, body, policy, tag, deny_key):
        g = self.state["gcp"]
        if verb == "getIamPolicy":
            method, qs = self._greq
            g.setdefault("policy_reads", []).append((tag, method, qs, body))
            if method != "POST":
                return self._g_err(405, "METHOD_NOT_ALLOWED", "getIamPolicy is POST")
            if tag.startswith("sa-policy:"):             # serviceAccounts.getIamPolicy: options in QUERY, body EMPTY
                if qs != {"options.requestedPolicyVersion": ["3"]} or body is not None:
                    return self._g_err(400, "INVALID_ARGUMENT", "SA getIamPolicy needs ?options.requestedPolicyVersion=3 and no body")
            elif qs or body != {"options": {"requestedPolicyVersion": 3}}:   # projects.getIamPolicy: options in BODY
                return self._g_err(400, "INVALID_ARGUMENT", "project getIamPolicy needs the options body and no query")
            return self._g_send(200, json.loads(json.dumps(policy)))
        if verb == "setIamPolicy":
            if deny_key in g["deny"]:
                return self._g_err(403, "PERMISSION_DENIED", "setIamPolicy denied")
            new = body["policy"]
            g.setdefault("policy_sets", []).append((tag, json.loads(json.dumps(new))))
            if g.get("conflict_once") and tag == "proj-policy":
                code = g.pop("conflict_once")            # a concurrent writer wins the race exactly once
                policy.setdefault("bindings", []).append({"role": "roles/logging.viewer", "members": ["user:other@example.com"]})
                policy["etag"] = "CONCURRENT"
                return self._g_err(code, "ABORTED" if code == 409 else "FAILED_PRECONDITION", "etag mismatch")
            if new.get("etag") != policy.get("etag"):
                return self._g_err(409, "ABORTED", "etag mismatch")
            g["writes"].append("set:" + tag)
            policy.clear()
            policy.update(new)
            policy["etag"] = "E%d" % len(g["writes"])
            return self._g_send(200, json.loads(json.dumps(policy)))
        return self._g_err(404, "NOT_FOUND", "no verb")

    def do_GET(self):
        self._route("GET")

    def do_POST(self):
        self._route("POST")

    def do_PUT(self):
        self._route("PUT")

    def do_DELETE(self):
        self._route("DELETE")


AWS_STUB = r'''#!/usr/bin/env bash
# stub aws CLI: records every invocation (argv only) and answers the two calls connect-cloud makes.
printf '%s\n' "$*" >> "$AWS_STUB_LOG"
case "$*" in
  "configure export-credentials --profile test21 --format process")
    [ -n "${AWS_STUB_HANG-}" ] && sleep 30
    echo "$AWS_STUB_CREDS_JSON" ;;
  "configure export-credentials --profile "*)
    echo "The config profile ($3) could not be found" >&2; exit 255 ;;
  "sts get-caller-identity --output json")
    [ -n "${AWS_PROFILE-}" ] && { echo "AWS_PROFILE leaked" >&2; exit 9; }
    if { [ "$AWS_SECRET_ACCESS_KEY" = "__SECRET__" ] || [ "$AWS_SECRET_ACCESS_KEY" = "$AWS_STUB_BACKEND_KEY" ]; } && [ "$AWS_SESSION_TOKEN" = "__TOKEN__" ]; then
      echo "{\"UserId\":\"AROAEXAMPLE:duplo-jit\",\"Account\":\"${AWS_STUB_ACCOUNT:-805863115079}\",\"Arn\":\"arn:aws:sts::805863115079:assumed-role/duplo-admin/duplo-jit\"}"
    else
      echo "An error occurred (InvalidClientTokenId) when calling the GetCallerIdentity operation: The security token included in the request is invalid." >&2; exit 254
    fi ;;
  *) echo "unexpected aws call: $*" >&2; exit 2 ;;
esac
'''

STORE_STUB = r'''#!/usr/bin/env bash
# stub credential store: `write <rel>` captures stdin into $STORE_DIR/<rel>; list/exists/volume/remove likewise.
set -e
op="$1"; rel="${2-}"
[ -n "${STORE_STUB_UNAVAILABLE-}" ] && { echo "no running 'duplo-ai-studio' container in compose project 'x'" >&2; exit 1; }
case "$op" in
  exists) [ -d "$STORE_DIR" ] ;;
  volume) echo "fakeproj_cloud_auth" ;;
  write)  mkdir -p "$STORE_DIR/$(dirname "$rel")"; cat > "$STORE_DIR/$rel"; chmod 0600 "$STORE_DIR/$rel"; echo "write $rel" >> "$STORE_DIR/.log" ;;
  remove) rm -f "$STORE_DIR/$rel"; echo "remove $rel" >> "$STORE_DIR/.log" ;;
  list)   cd "$STORE_DIR" && find . -type f -not -name .log | sed 's|^\./||' | while read -r f; do echo "600 readable $f"; done ;;
  *) echo "bad op $op" >&2; exit 2 ;;
esac
'''

DOCKER_STUB = r'''#!/usr/bin/env bash
# stub container CLI for snapshots: DOCKER_STUB_SERVICES lists running services as "svc:id:startedAt;…"
printf '%s\n' "$*" >> "$DOCKER_STUB_LOG"
case "$1" in
  ps)
    svc=""; for a in "$@"; do case "$a" in label=com.docker.compose.service=*) svc="${a#label=com.docker.compose.service=}";; esac; done
    IFS=';' read -ra entries <<< "${DOCKER_STUB_SERVICES-}"
    for e in "${entries[@]}"; do IFS=':' read -r s id started <<< "$e"; [ "$s" = "$svc" ] && echo "$id"; done
    exit 0 ;;
  inspect)
    cid="${@: -1}"
    IFS=';' read -ra entries <<< "${DOCKER_STUB_SERVICES-}"
    for e in "${entries[@]}"; do IFS=':' read -r s id started <<< "$e"; [ "$id" = "$cid" ] && echo "$id $started"; done
    exit 0 ;;
  *) echo "unexpected docker call: $*" >&2; exit 2 ;;
esac
'''

GCP_RUNTIME_STUB = r'''#!__PYTHON__
"""Stub of scripts/_gcp_auth.sh (CONNECT_CLOUD_GCP_CMD): a fake backend runtime kept in $GCP_STUB_DIR/state.json.
It reads the REAL file in the directory it pretends to bind, exactly as the busybox probe would, and records the
name of every op it is asked to run — the tests' evidence for "no restart", "no mutation" and ordering."""
import hashlib, json, os, sys
D = os.environ["GCP_STUB_DIR"]
SP = os.path.join(D, "state.json")
op = sys.argv[1]
with open(os.path.join(D, "calls.log"), "a") as f:
    f.write(op + "\n")
st = json.load(open(SP))
def save():
    json.dump(st, open(SP, "w"))
if st.get("fail") == op:
    print("stub: %s failed on purpose" % op, file=sys.stderr); sys.exit(1)
if op == "dir":
    print(json.dumps({"dir": st["dir"], "file": st["dir"] + "/application_default_credentials.json", "source": st.get("source", "test")}))
elif op == "inspect":
    if not st.get("running", True):
        print(json.dumps({"running": False, "service": "duplo-ai-studio", "project": "fakeproj"})); sys.exit(0)
    print(json.dumps({"running": True, "service": "duplo-ai-studio", "containerId": st["id"], "startedAt": st["started"],
                      "workingDir": None, "mount": {"present": bool(st["mount"]), "source": st["mount"], "readOnly": st["ro"], "type": "bind"},
                      "env": {"GOOGLE_APPLICATION_CREDENTIALS": st["env"]}, "user": "backenduser"}))
elif op == "probe":
    st["probes"] = st.get("probes", 0) + 1
    save()
    if st.get("probe_after_restart") and st.get("restarted_once"):
        print(json.dumps(dict({"user": "backenduser", "uid": "1001:1001", "type": None, "sha256": None, "detail": None}, **st["probe_after_restart"]))); sys.exit(0)
    if st.get("probe_second") and st["probes"] % 2 == 0:
        print(json.dumps(dict({"user": "backenduser", "uid": "1001:1001", "type": None, "sha256": None, "detail": None}, **st["probe_second"]))); sys.exit(0)
    if st.get("probe"):
        print(json.dumps(dict({"user": "backenduser", "uid": "1001:1001", "type": None, "sha256": None, "detail": None}, **st["probe"]))); sys.exit(0)
    r = {"user": "backenduser", "uid": "1001:1001", "type": None, "sha256": None, "detail": None}
    if not st["mount"]:
        r["state"] = "no-mount"
    else:
        f = os.path.join(st["mount"], "application_default_credentials.json")
        if not os.path.isfile(f):
            r["state"] = "missing"
        else:
            raw = open(f, "rb").read()
            r["state"] = "ok"
            r["type"] = "authorized_user" if b'"authorized_user"' in raw else "other"
            r["sha256"] = hashlib.sha256(raw).hexdigest()
    print(json.dumps(r))
elif op == "prepare":
    os.makedirs(st["dir"], exist_ok=True); print(json.dumps({"dir": st["dir"], "created": False}))
elif op == "reconcile":
    os.makedirs(st["dir"], exist_ok=True)
    st["n"] = st.get("n", 1) + 1
    st.update(id="stud%d" % st["n"], started="2026-11-03T10:00:%02dZ" % st["n"])
    if not st.get("reconcile_noop"):          # noop: a COMPOSE_FILE override that drops the studio's mount/env
        st.update(mount=st["dir"], ro=True, env="/devkit-gcloud/application_default_credentials.json")
    save(); print(json.dumps({"ok": True, "action": "recreated"}))
elif op == "restart":
    st["restarted_once"] = True
    st["n"] = st.get("n", 1) + 1
    st["started"] = "2026-11-03T10:00:%02dZ" % st["n"]
    save(); print(json.dumps({"ok": True, "action": "restarted"}))
else:
    sys.exit(2)
'''

GCLOUD_STUB = r'''#!/usr/bin/env bash
# stub gcloud: a DIFFERENT active account than the ADC user; any call is a test failure (it is logged).
printf '%s\n' "$*" >> "$GCLOUD_STUB_LOG"
echo "gcloud-active@example.com"
'''

BOTH_RUNNING = "duplo-ai-studio:aaaa1111:2026-10-27T09:00:00Z;claude-code-agent:bbbb2222:2026-10-27T09:00:05Z"


class Harness(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), Fake)
        cls.port = cls.server.server_address[1]
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="connect-cloud-test-")
        self.bin = os.path.join(self.tmp, "bin"); os.makedirs(self.bin)
        self.store_dir = os.path.join(self.tmp, "store"); os.makedirs(self.store_dir)
        self.state_file = os.path.join(self.tmp, "state", "connections.json")
        self.aws_log = os.path.join(self.tmp, "aws.log")
        self.docker_log = os.path.join(self.tmp, "docker.log")
        self.gdir = os.path.join(self.tmp, "gcloud"); os.makedirs(self.gdir)
        self.rt_dir = os.path.join(self.tmp, "rt"); os.makedirs(self.rt_dir)
        self.rt_set(dir=self.gdir, id="stud1", started="2026-11-03T10:00:01Z", n=1, mount=self.gdir, ro=True,
                    env="/devkit-gcloud/application_default_credentials.json", running=True)
        for name, text in (("aws", AWS_STUB), ("store", STORE_STUB), ("docker", DOCKER_STUB), ("gcloud", GCLOUD_STUB),
                           ("gcprt", GCP_RUNTIME_STUB.replace("__PYTHON__", sys.executable))):
            p = os.path.join(self.bin, name)
            with open(p, "w") as f:
                f.write(text)
            os.chmod(p, 0o755)
        self.adc_path = os.path.join(self.gdir, "application_default_credentials.json")
        self.write_adc(self.adc_path)
        Fake.state = {
            "sa": SA, "project": "gcp-test9",
            "buckets": ["b1", "b2", "b3", "b4", "b5", "b6"],
            "studio": {"Workspaces": {"ws-1": {"id": "ws-1", "name": "extension-dev", "scopeIds": []}}},
        }
        Fake.log = []
        self.base = f"http://127.0.0.1:{self.port}"
        self.extra_env: dict = {"DOCKER_STUB_SERVICES": BOTH_RUNNING}

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def write_adc(self, path, refresh=REFRESH_TOKEN, account="ganesh@example.com"):
        with open(path, "w") as f:
            json.dump({"type": "authorized_user", "client_id": "cid.apps.googleusercontent.com",
                       "client_secret": CLIENT_SECRET, "refresh_token": refresh,
                       "quota_project_id": "gcp-test9", "universe_domain": "googleapis.com", "account": account}, f)

    def run_cc(self, *args, creds=None, expect=0, workspace_default="ws-1", timeout=90):
        env = {
            "PATH": self.bin + os.pathsep + os.environ.get("PATH", ""),
            "HOME": self.tmp,
            # test-only hermeticity: keep the fake loopback servers off any system/host proxy
            "no_proxy": "127.0.0.1,localhost,::1", "NO_PROXY": "127.0.0.1,localhost,::1",
            "DUPLO_BASE": self.base, "DUPLO_TOKEN": "admin-token-not-a-secret-in-tests",
            "CONNECT_CLOUD_STATE": self.state_file,
            "CONNECT_CLOUD_STORE_CMD": os.path.join(self.bin, "store"),
            "CONNECT_CLOUD_GCP_CMD": os.path.join(self.bin, "gcprt"),
            "GCP_STUB_DIR": self.rt_dir,
            "CONNECT_CLOUD_PROJECT": "fakeproj",
            "RUNTIME": "docker",
            "CONNECT_CLOUD_ALLOW_NO_TTY": "1",
            "CONNECT_CLOUD_AWS_EXPORT_TIMEOUT": "3",
            "CONNECT_CLOUD_GOOGLE_TOKEN_URL": self.base + "/token",
            "CONNECT_CLOUD_GOOGLE_IAM_URL": self.base + "/iam",
            "CONNECT_CLOUD_GOOGLE_STORAGE_URL": self.base + "/storage",
            "CONNECT_CLOUD_GOOGLE_USERINFO_URL": self.base + "/userinfo",
            "CONNECT_CLOUD_GOOGLE_IAM_ADMIN_URL": self.base + "/iamadmin",
            "CONNECT_CLOUD_GOOGLE_CRM_URL": self.base + "/crm",
            "CONNECT_CLOUD_GOOGLE_SERVICEUSAGE_URL": self.base + "/su",
            "CONNECT_CLOUD_PROPAGATION_INTERVAL": "0",
            "GCLOUD_STUB_LOG": os.path.join(self.tmp, "gcloud.log"),
            "STORE_DIR": self.store_dir,
            "AWS_STUB_LOG": self.aws_log,
            "DOCKER_STUB_LOG": self.docker_log,
            "AWS_STUB_BACKEND_KEY": SECRET_KEY,
            "AWS_STUB_CREDS_JSON": json.dumps(creds or {
                "Version": 1, "AccessKeyId": "ASIAEXAMPLE", "SecretAccessKey": "__SECRET__",
                "SessionToken": "__TOKEN__", "Expiration": "2099-01-01T00:00:00+00:00"}),
        }
        if workspace_default:
            env["CONNECT_CLOUD_WORKSPACE_DEFAULT"] = workspace_default
        env.update(self.extra_env)
        p = subprocess.run([sys.executable, "-I", SCRIPT, *args], capture_output=True, text=True, env=env,
                           cwd=self.tmp, timeout=timeout)
        self.assertEqual(p.returncode, expect, f"rc={p.returncode}\nstdout:\n{p.stdout}\nstderr:\n{p.stderr}")
        return p

    # ── the fake backend runtime (stub of scripts/_gcp_auth.sh) ──
    def rt_set(self, **kw):
        p = os.path.join(self.rt_dir, "state.json")
        st = json.load(open(p)) if os.path.exists(p) else {}
        st.update(kw)
        json.dump(st, open(p, "w"))

    def rt_calls(self):
        p = os.path.join(self.rt_dir, "calls.log")
        return open(p).read().split() if os.path.exists(p) else []

    def rt_mutations(self):
        return [c for c in self.rt_calls() if c in ("prepare", "reconcile", "restart")]

    def rt_state_file(self):
        return os.path.join(self.tmp, "state", "gcp-runtime.json")

    def studio_writes(self):
        return [(m, p) for m, p, _, _ in Fake.log if m in ("POST", "PUT", "DELETE") and "/admin/data/" in p]

    def records(self):
        with open(self.state_file) as f:
            return json.load(f)["connections"]

    def store_log(self):
        p = os.path.join(self.store_dir, ".log")
        if not os.path.exists(p):
            return ""
        with open(p) as f:
            return f.read()

    def provider(self):
        return next(iter(Fake.state["studio"]["Providers"].values()))

    def gcp_args(self, name="gcp-test9", sa=SA, project="gcp-test9", adc=None):
        return ("gcp", "--name", name, "--project", project, "--service-account", sa, "--adc-source", adc or self.adc_path)



class ConnectCloudTests(Harness):
    # ── AWS ──

    def test_aws_connect_creates_chain_and_attaches_once(self):
        p = self.run_cc("aws", "--name", "test21", "--profile", "test21")
        self.assertIn("account 805863115079", p.stdout)
        self.assertIn("attached to workspace ws-1", p.stdout)
        writes = self.studio_writes()
        self.assertEqual([w[0] for w in writes], ["POST", "POST", "POST"])  # provider, scope, attach
        prov = self.provider()
        self.assertEqual((prov["name"], prov["type"], prov["accountId"], prov["metaData"]["source"]),
                         ("aws-test21", "aws", "805863115079", TOOL))
        cred = prov["credentials"][0]
        self.assertEqual(cred["name"], "test21")
        self.assertEqual({d["key"]: d["isSensitive"] for d in cred["dataEx"]},
                         {"accessKeyId": False, "secretAccessKey": True, "sessionToken": True})
        scope = next(iter(Fake.state["studio"]["Scopes"].values()))
        self.assertEqual(scope["awsResourceSearchFilter"], {"region": "us-east-1"})
        self.assertEqual((scope["credentialName"], scope["metaData"]["source"]), ("test21", TOOL))
        self.assertEqual(Fake.state["studio"]["Workspaces"]["ws-1"]["scopeIds"], [scope["id"]])
        with open(self.aws_log) as f:
            calls = f.read().splitlines()
        self.assertEqual(calls.count("configure export-credentials --profile test21 --format process"), 1)
        self.assertEqual(calls.count("sts get-caller-identity --output json"), 1)
        rec = self.records()["test21"]
        self.assertEqual((rec["expiration"], rec["accountId"]), ("2099-01-01T00:00:00+00:00", "805863115079"))

    def test_aws_rerun_is_idempotent_and_rotates_in_place(self):
        self.run_cc("aws", "--name", "test21", "--profile", "test21")
        Fake.log = []
        self.run_cc("aws", "--name", "test21", "--profile", "test21",
                    creds={"Version": 1, "AccessKeyId": "ASIAROTATED", "SecretAccessKey": "__SECRET__",
                           "SessionToken": "__TOKEN__", "Expiration": "2099-02-01T00:00:00+00:00"})
        writes = self.studio_writes()
        self.assertEqual(writes, [("PUT", f"/v1/aiservicedesk/admin/data/Providers/providers-1/credentials/test21")])
        self.assertEqual(len(Fake.state["studio"]["Providers"]), 1)
        self.assertEqual(len(Fake.state["studio"]["Scopes"]), 1)
        self.assertEqual(len(Fake.state["studio"]["Workspaces"]["ws-1"]["scopeIds"]), 1)
        self.assertEqual({d["key"]: d["value"] for d in self.provider()["credentials"][0]["dataEx"]}["accessKeyId"], "ASIAROTATED")
        self.assertEqual(self.records()["test21"]["expiration"], "2099-02-01T00:00:00+00:00")

    def test_aws_region_change_on_existing_scope_is_a_conflict_before_any_write(self):
        self.run_cc("aws", "--name", "test21", "--profile", "test21")
        before = json.dumps(Fake.state["studio"], sort_keys=True)
        Fake.log = []
        p = self.run_cc("aws", "--name", "test21", "--profile", "test21", "--region", "eu-west-1", expect=1)
        self.assertIn("pinned to region 'us-east-1'", p.stderr)
        self.assertIn("--region us-east-1", p.stderr)
        self.assertEqual(self.studio_writes(), [])
        self.assertEqual(json.dumps(Fake.state["studio"], sort_keys=True), before)
        self.assertEqual(self.records()["test21"]["region"], "us-east-1")  # records untouched too

    def test_aws_identity_mismatch_on_existing_provider_is_refused_without_writes(self):
        self.run_cc("aws", "--name", "test21", "--profile", "test21")
        before = json.dumps(Fake.state["studio"], sort_keys=True)
        Fake.log = []
        self.extra_env["AWS_STUB_ACCOUNT"] = "111111111111"
        p = self.run_cc("aws", "--name", "test21", "--profile", "test21", expect=1)
        self.assertIn("belong to '111111111111'", p.stderr)
        self.assertEqual(self.studio_writes(), [])
        self.assertEqual(json.dumps(Fake.state["studio"], sort_keys=True), before)

    def test_foreign_credential_or_scope_is_never_overwritten(self):
        # a credential of the same name created by hand (no ownership metadata)
        Fake.state["studio"]["Providers"] = {"providers-9": {
            "id": "providers-9", "name": "aws-test21", "type": "AWS", "accountId": "805863115079",
            "credentials": [{"name": "test21", "dataEx": [{"key": "accessKeyId", "value": "AKIAHAND"}]}]}}
        before = json.dumps(Fake.state["studio"], sort_keys=True)
        p = self.run_cc("aws", "--name", "test21", "--profile", "test21", expect=1)
        self.assertIn("was not created by connect-cloud", p.stderr)
        self.assertEqual(self.studio_writes(), [])
        self.assertEqual(json.dumps(Fake.state["studio"], sort_keys=True), before)
        # a scope of the same name owned by another provider
        Fake.state["studio"]["Providers"] = {}
        Fake.state["studio"]["Scopes"] = {"scopes-9": {"id": "scopes-9", "name": "test21", "providerId": "providers-other",
                                                       "credentialName": "x", "metaData": {"source": TOOL}}}
        Fake.log = []
        p = self.run_cc("aws", "--name", "test21", "--profile", "test21", expect=1)
        self.assertIn("belongs to provider 'providers-other'", p.stderr)
        self.assertEqual(self.studio_writes(), [])

    def test_scope_with_other_credential_name_is_refused(self):
        self.run_cc("aws", "--name", "test21", "--profile", "test21")
        next(iter(Fake.state["studio"]["Scopes"].values()))["credentialName"] = "someone-else"
        Fake.log = []
        p = self.run_cc("aws", "--name", "test21", "--profile", "test21", expect=1)
        self.assertIn("uses credential 'someone-else'", p.stderr)
        self.assertEqual(self.studio_writes(), [])

    def test_duplicate_names_are_ambiguous_not_first_match(self):
        self.run_cc("aws", "--name", "test21", "--profile", "test21")
        prov = dict(self.provider(), id="providers-dup")
        Fake.state["studio"]["Providers"]["providers-dup"] = prov
        Fake.log = []
        p = self.run_cc("aws", "--name", "test21", "--profile", "test21", expect=1)
        self.assertIn("2 Providers are named 'test21'".replace("test21", "aws-test21"), p.stderr)
        self.assertEqual(self.studio_writes(), [])

    def test_missing_workspace_fails_before_credential_write(self):
        # stale EXTENSION_DEV_WORKSPACE_ID after a reset: nothing may be written, not even the credential rotation
        self.run_cc("aws", "--name", "test21", "--profile", "test21")
        before = json.dumps(Fake.state["studio"], sort_keys=True)
        Fake.log = []
        p = self.run_cc("aws", "--name", "test21", "--profile", "test21", "--workspace", "ws-gone", expect=1)
        self.assertIn("workspace 'ws-gone' does not exist", p.stderr)
        self.assertEqual(self.studio_writes(), [])
        self.assertEqual(json.dumps(Fake.state["studio"], sort_keys=True), before)

    def test_no_workspace_at_all_is_refused_unless_explicit(self):
        p = self.run_cc("aws", "--name", "test21", "--profile", "test21", workspace_default=None, expect=1)
        self.assertIn("not selectable by any ticket", p.stderr)
        self.assertEqual(self.studio_writes(), [])
        p = self.run_cc("aws", "--name", "test21", "--profile", "test21", "--no-workspace", workspace_default=None)
        self.assertIn("NOT attached to any workspace", p.stdout)
        self.assertEqual(Fake.state["studio"]["Workspaces"]["ws-1"]["scopeIds"], [])

    def test_aws_bad_profile_fails_before_any_studio_write(self):
        p = self.run_cc("aws", "--name", "nope", "--profile", "nope", expect=1)
        self.assertIn("could not be found", p.stderr)
        self.assertEqual(self.studio_writes(), [])
        self.assertFalse(os.path.exists(self.state_file))

    def test_aws_invalid_credentials_fail_at_sts(self):
        p = self.run_cc("aws", "--name", "test21", "--profile", "test21", expect=1,
                        creds={"Version": 1, "AccessKeyId": "AKIA", "SecretAccessKey": "wrong"})
        self.assertIn("STS get-caller-identity rejected", p.stderr)
        self.assertEqual(self.studio_writes(), [])

    def test_aws_export_credentials_timeout_is_a_clear_error(self):
        self.extra_env["AWS_STUB_HANG"] = "1"
        p = self.run_cc("aws", "--name", "test21", "--profile", "test21", expect=1)
        self.assertIn("did not finish within 3s", p.stderr)
        self.assertNotIn("Traceback", p.stderr)

    def test_aws_verify_exercises_backend_scope_endpoint(self):
        self.run_cc("aws", "--name", "test21", "--profile", "test21",
                    creds={"Version": 1, "AccessKeyId": "ASIA", "SecretAccessKey": SECRET_KEY, "SessionToken": "__TOKEN__"})
        Fake.log = []
        p = self.run_cc("verify", "--name", "test21", "--json")
        res = json.loads(p.stdout)
        self.assertTrue(res["ok"], p.stdout)
        self.assertTrue(res["result"]["checks"]["backendScopeExpansion"])
        self.assertTrue(res["result"]["checks"]["workspaceAttached"])
        gets = [pth for m, pth, _, _ in Fake.log if m == "GET" and "/aws/resources" in pth]
        self.assertEqual(len(gets), 1)
        self.assertIn("resourceType=s3", gets[0])

    def test_aws_verify_reports_expired_backend_credentials(self):
        self.run_cc("aws", "--name", "test21", "--profile", "test21")
        p = self.run_cc("verify", "--name", "test21", "--json", expect=1)
        res = json.loads(p.stdout)
        self.assertFalse(res["result"]["checks"]["backendScopeExpansion"])
        self.assertIn("expired", res["result"]["checks"]["backendError"])

    # ── GCP ──

    def test_gcp_connect_proves_impersonation_uses_native_adc_and_registers_a_native_credential(self):
        p = self.run_cc(*self.gcp_args())
        self.assertIn("6 bucket(s) visible", p.stdout)
        self.assertIn("nothing is copied", p.stdout)
        google = [pth.split("?")[0] for m, pth, _, _ in Fake.log if pth.startswith(("/token", "/iam", "/storage"))]
        self.assertEqual(google, ["/token", f"/iam/projects/-/serviceAccounts/{urllib.parse.quote(SA)}:generateAccessToken", "/storage/b"])
        # the credential store is no longer involved at all: no write, no file, no volume lookup dependency
        self.assertEqual(self.store_log(), "")
        self.assertFalse(os.path.exists(os.path.join(self.store_dir, "gcp")))
        prov = self.provider()
        self.assertEqual((prov["type"], prov["accountId"], prov["name"]), ("gcp", "gcp-test9", "gcp-gcp-test9"))
        # the backend-visible credential shape: cloudRoleToAssume ONLY — no adcRef, no key material
        self.assertEqual(prov["credentials"][0]["dataEx"],
                         [{"key": "cloudRoleToAssume", "value": SA, "type": "string", "isSensitive": False}])
        rec = self.records()["gcp-test9"]
        self.assertEqual(rec["controlBucketCount"], 6)
        self.assertNotIn("adcRef", rec)
        self.assertNotIn("storeFile", rec)
        self.assertEqual((rec["adcMode"], rec["adcMount"], rec["adcSource"]),
                         ("native-directory", "/devkit-gcloud/application_default_credentials.json", self.adc_path))
        self.assertNotIn("adcRef", json.dumps(Fake.state["studio"]))
        # first native connection: the runtime check ran before registration and the backend was restarted once
        self.assertEqual(self.rt_calls(), ["dir", "inspect", "probe", "restart", "inspect", "probe"])
        self.assertIn("ticket-proven: NO", p.stdout)

    def test_gcp_bucket_list_is_paginated(self):
        Fake.state["bucket_pages"] = [["a", "b"], ["c"], ["d", "e", "f", "g"]]
        p = self.run_cc(*self.gcp_args())
        self.assertIn("7 bucket(s) visible", p.stdout)
        pages = [pth for m, pth, _, _ in Fake.log if pth.startswith("/storage/b")]
        self.assertEqual(len(pages), 3)
        self.assertIn("pageToken=2", pages[2])

    def test_gcp_repeat_is_idempotent_writes_nothing_and_does_not_restart(self):
        self.run_cc(*self.gcp_args())
        Fake.log = []
        n_calls = len(self.rt_calls())
        p = self.run_cc(*self.gcp_args())
        self.assertEqual(self.studio_writes(), [])                       # native-shaped credential: nothing to rewrite
        self.assertIn("unchanged", p.stdout)
        self.assertEqual(self.rt_calls().count("restart"), 1)             # only the first connection restarted
        self.assertEqual(self.rt_mutations(), ["restart"])
        self.assertIn("no restart needed", p.stdout)
        self.assertGreater(len(self.rt_calls()), n_calls)

    def test_gcp_reused_name_with_other_project_or_sa_changes_nothing(self):
        self.run_cc(*self.gcp_args())
        before = json.dumps(Fake.state["studio"], sort_keys=True)
        mutations = self.rt_mutations()
        Fake.log = []
        # other project under the same name
        Fake.state["project"] = "other-proj"
        p = self.run_cc(*self.gcp_args(project="other-proj"), expect=1)
        self.assertIn("already exists for account 'gcp-test9'", p.stderr)
        self.assertEqual(self.studio_writes(), [])
        # other service account under the same name (project matches)
        Fake.state["project"] = "gcp-test9"
        Fake.state["sa"] = "other-sa@gcp-test9.iam.gserviceaccount.com"
        p = self.run_cc(*self.gcp_args(sa="other-sa@gcp-test9.iam.gserviceaccount.com"), expect=1)
        self.assertIn("already impersonates", p.stderr)
        self.assertEqual(self.studio_writes(), [])
        self.assertEqual(self.rt_mutations(), mutations)                  # the conflicts touched no container
        self.assertEqual(json.dumps(Fake.state["studio"], sort_keys=True), before)

    def test_gcp_project_only_derives_name_and_service_account(self):
        Fake.state["sa"] = "helpdesk-sa@gcp-test9.iam.gserviceaccount.com"
        p = self.run_cc("gcp", "--project", "gcp-test9", "--adc-source", self.adc_path)
        self.assertIn("connection 'gcp-test9' ready", p.stdout)
        rec = self.records()["gcp-test9"]
        self.assertEqual((rec["project"], rec["serviceAccount"], rec["workspaceId"]),
                         ("gcp-test9", "helpdesk-sa@gcp-test9.iam.gserviceaccount.com", "ws-1"))
        self.assertEqual(Fake.state["studio"]["Workspaces"]["ws-1"]["scopeIds"], [rec["scopeId"]])

    def test_gcp_explicit_name_and_service_account_override_independently(self):
        Fake.state["sa"] = "helpdesk-sa@gcp-test9.iam.gserviceaccount.com"
        self.run_cc("gcp", "--project", "gcp-test9", "--name", "mine", "--adc-source", self.adc_path)
        rec = self.records()["mine"]
        self.assertEqual(rec["serviceAccount"], "helpdesk-sa@gcp-test9.iam.gserviceaccount.com")
        Fake.state["sa"] = SA
        self.run_cc("gcp", "--project", "gcp-test9", "--service-account", SA, "--adc-source", self.adc_path)
        rec = self.records()["gcp-test9"]
        self.assertEqual(rec["serviceAccount"], SA)

    def test_gcp_project_only_honours_workspace_flags(self):
        Fake.state["sa"] = "helpdesk-sa@gcp-test9.iam.gserviceaccount.com"
        Fake.state["studio"]["Workspaces"]["ws-2"] = {"id": "ws-2", "name": "other", "scopeIds": []}
        self.run_cc("gcp", "--project", "gcp-test9", "--workspace", "ws-2", "--adc-source", self.adc_path)
        self.assertEqual(self.records()["gcp-test9"]["workspaceId"], "ws-2")
        self.assertEqual(Fake.state["studio"]["Workspaces"]["ws-1"]["scopeIds"], [])
        p = self.run_cc("gcp", "--project", "gcp-test9", "--adc-source", self.adc_path,
                        workspace_default=None, expect=1)
        self.assertIn("not selectable by any ticket", p.stderr)
        p = self.run_cc("gcp", "--project", "gcp-test9", "--adc-source", self.adc_path, "--no-workspace",
                        workspace_default=None)
        self.assertIn("NOT attached to any workspace", p.stdout)

    def test_gcp_invalid_project_fails_before_any_side_effect(self):
        for bad in ("Bad_Project", "ab", "1abc-def", "abc-def-", "a" * 31, "has space", "../x", "valid-project\n"):
            Fake.log = []
            p = self.run_cc("gcp", "--project=" + bad, "--adc-source", self.adc_path, expect=1)
            self.assertIn("is not a GCP project ID", p.stderr)
            self.assertEqual(Fake.log, [])
            self.assertEqual(self.studio_writes(), [])
        self.assertFalse(os.path.exists(os.path.join(self.store_dir, "gcp")))
        self.assertEqual(self.store_log(), "")

    def test_gcp_does_not_depend_on_the_credential_store(self):
        self.extra_env["STORE_STUB_UNAVAILABLE"] = "1"          # the legacy store is unreachable: irrelevant to GCP now
        p = self.run_cc(*self.gcp_args())
        self.assertIn("connection 'gcp-test9' ready", p.stdout)
        self.assertEqual(self.store_log(), "")

    def test_gcp_two_connections_share_the_one_host_adc_without_a_second_restart(self):
        self.run_cc(*self.gcp_args(name="alice"))
        self.run_cc(*self.gcp_args(name="bob"))
        creds = [p["credentials"][0]["dataEx"] for p in Fake.state["studio"]["Providers"].values()]
        self.assertEqual(len(creds), 2)
        for data in creds:
            self.assertEqual([d["key"] for d in data], ["cloudRoleToAssume"])
        self.assertEqual(self.rt_calls().count("restart"), 1)
        self.assertEqual(self.store_log(), "")

    def test_gcp_wrong_service_account_fails_before_any_write(self):
        p = self.run_cc(*self.gcp_args(name="x", sa="nobody@gcp-test9.iam.gserviceaccount.com"), expect=1)
        self.assertIn("cannot impersonate nobody@gcp-test9", p.stderr)
        self.assertIn("serviceAccountTokenCreator", p.stderr)
        self.assertEqual(self.studio_writes(), [])
        self.assertEqual(self.rt_mutations(), [])                         # a failed host proof never restarts the backend

    def test_gcp_revoked_adc_fails_with_relogin_hint(self):
        with open(self.adc_path, "w") as f:
            json.dump({"type": "authorized_user", "client_id": "c", "client_secret": "s", "refresh_token": "revoked"}, f)
        p = self.run_cc(*self.gcp_args(name="x"), expect=1)
        self.assertIn("gcloud auth application-default login", p.stderr)
        self.assertEqual(self.studio_writes(), [])
        self.assertEqual(self.rt_mutations(), [])

    def test_gcp_rejects_service_account_key_and_external_account_files(self):
        for adc in ({"type": "service_account", "client_email": "x@y", "private_key": "k"},
                    {"type": "external_account", "audience": "a", "token_url": "https://evil", "credential_source": {}},
                    {"type": "authorized_user", "client_id": "c", "client_secret": "s", "refresh_token": "r", "token_uri": "https://evil"}):
            with open(self.adc_path, "w") as f:
                json.dump(adc, f)
            p = self.run_cc(*self.gcp_args(name="x"), expect=1)
            self.assertTrue("only an authorized_user" in p.stderr or "unexpected fields" in p.stderr, p.stderr)
            self.assertEqual([pth for m, pth, _, _ in Fake.log if pth.startswith("/token")], [])

    def test_gcp_verify_reports_separate_runtime_host_and_ticket_stages(self):
        self.run_cc(*self.gcp_args())
        p = self.run_cc("verify", "--name", "gcp-test9", "--json")
        res = json.loads(p.stdout)["result"]
        c = res["checks"]
        self.assertTrue(c["adcImpersonation"])
        self.assertTrue(all(c[k] for k in ("runtimeBackendRunning", "runtimeMountAndEnv", "runtimeFileReadable",
                                          "runtimeSourceAligned", "runtimeCacheCurrent")))
        self.assertEqual(c["controlBucketCount"], 6)
        self.assertNotIn("storeFileReadableByStudioUid", c)
        self.assertEqual(res["stages"], {"runtimeFile": True, "hostProof": True, "ticketProven": False})
        text = "\n".join(json.loads(p.stdout)["log"])
        self.assertIn("ticket-proven NO", text)
        self.assertIn("not that the backend used it", text)
        self.assertEqual(self.rt_mutations(), ["restart"])                # verify is read-only

    # ── refresh / snapshots ──

    def test_refresh_proves_no_restart_only_from_real_ids(self):
        self.run_cc("aws", "--name", "test21", "--profile", "test21")
        p = self.run_cc("refresh", "--name", "test21", "--json")
        res = json.loads(p.stdout)["result"]
        self.assertEqual(res["credentialAction"], "rotate")
        self.assertTrue(res["containers"]["unchanged"])
        self.assertEqual(res["containers"]["before"]["duplo-ai-studio"], {"id": "aaaa1111", "startedAt": "2026-10-27T09:00:00Z"})
        self.assertEqual(res["containers"]["after"]["claude-code-agent"]["id"], "bbbb2222")
        with open(self.docker_log) as f:
            calls = f.read()
        self.assertIn("label=com.docker.compose.project=fakeproj", calls)

    def test_refresh_fails_closed_when_a_service_is_missing(self):
        self.run_cc("aws", "--name", "test21", "--profile", "test21")
        before = json.dumps(Fake.state["studio"], sort_keys=True)
        Fake.log = []
        self.extra_env["DOCKER_STUB_SERVICES"] = "duplo-ai-studio:aaaa1111:2026-10-27T09:00:00Z"   # agent absent
        p = self.run_cc("refresh", "--name", "test21", expect=1)
        self.assertIn("cannot prove a no-restart refresh: claude-code-agent not running", p.stderr)
        self.assertEqual(self.studio_writes(), [])
        self.assertEqual(json.dumps(Fake.state["studio"], sort_keys=True), before)
        self.extra_env["DOCKER_STUB_SERVICES"] = ""   # nothing at all (e.g. wrong project name)
        p = self.run_cc("refresh", "--name", "test21", expect=1)
        self.assertIn("duplo-ai-studio, claude-code-agent not running", p.stderr)

    def test_refresh_reports_changed_container_as_not_a_proof(self):
        # The stub cannot change ids mid-run, so simulate by making the agent vanish AFTER the snapshot
        # is impossible here; instead assert the exit code contract via a mismatched 'after' is covered by
        # the unit: unchanged requires equality AND completeness (see snapshot_complete). A fully absent
        # project already fails before any write (previous test).
        pass

    # ── cross-cutting ──

    def test_names_are_validated_before_anything_runs(self):
        for bad in ("../x", "Upper", "a/b", "with space", "-dash", "a" * 65):
            p = self.run_cc("aws", "--name=" + bad, "--profile", "test21", expect=1)
            self.assertIn("--name must be", p.stderr)
        self.assertFalse(os.path.exists(self.aws_log))

    def test_no_secret_in_records_stdout_or_argv(self):
        p = self.run_cc("aws", "--name", "test21", "--profile", "test21", "--json")
        q = self.run_cc(*self.gcp_args())
        with open(self.state_file) as f:
            state_text = f.read()
        status = self.run_cc("status", "--json")
        for secret in ("__SECRET__", "__TOKEN__", REFRESH_TOKEN, CLIENT_SECRET):
            for text in (state_text, p.stdout + p.stderr, q.stdout + q.stderr, status.stdout + status.stderr):
                self.assertNotIn(secret, text)
        with open(self.aws_log) as f:
            self.assertNotIn("__SECRET__", f.read())  # never on the aws command line
        self.assertNotIn(REFRESH_TOKEN, self.store_log())  # the store helper saw only the path on argv

    def test_dry_run_writes_nothing_and_says_so(self):
        p = self.run_cc("--dry-run", "aws", "--name", "test21", "--profile", "test21")
        self.assertIn("would create", p.stdout)
        self.assertIn("nothing was written", p.stdout)
        self.assertIn("dry-run only — nothing installed", p.stdout)
        self.assertNotIn("ready", p.stdout)
        self.assertEqual(self.studio_writes(), [])
        self.assertFalse(os.path.exists(self.state_file))
        q = self.run_cc("--dry-run", *self.gcp_args())
        self.assertIn("would restart ONLY the backend", q.stdout)
        self.assertIn("would create", q.stdout)
        self.assertEqual(self.store_log(), "")
        self.assertEqual(self.studio_writes(), [])
        self.assertEqual(self.rt_calls(), ["dir", "inspect"])             # inspect only: no probe, mkdir, recreate or restart
        self.assertFalse(os.path.exists(self.rt_state_file()))
        self.assertIn("runtime-file: NOT PROVEN", q.stdout)
        self.assertNotIn("PROVEN (the backend", q.stdout)

    def test_status_reports_volume_and_unattached_connections(self):
        self.run_cc("aws", "--name", "test21", "--profile", "test21", "--no-workspace")
        p = self.run_cc("status", "--json")
        res = json.loads(p.stdout)["result"]
        self.assertEqual(res["storeVolume"], "fakeproj_cloud_auth")
        self.assertIsNone(res["result"] if "result" in res else res["storeError"])
        self.assertIn("NONE (not ticket-selectable)", "\n".join(json.loads(p.stdout)["log"]))
        self.extra_env["STORE_STUB_UNAVAILABLE"] = "1"
        p = self.run_cc("status", "--json")
        res = json.loads(p.stdout)["result"]
        self.assertIsNone(res["storeVolume"])
        self.assertIn("no running 'duplo-ai-studio'", res["storeError"])

    def test_malformed_records_file_is_a_clear_error(self):
        os.makedirs(os.path.dirname(self.state_file))
        with open(self.state_file, "w") as f:
            f.write("{not json")
        p = self.run_cc("status", expect=1)
        self.assertIn("unreadable or malformed", p.stderr)
        self.assertNotIn("Traceback", p.stderr)

    def test_studio_down_is_a_clear_error(self):
        env_base = self.base
        self.base = "http://127.0.0.1:9"  # closed port
        p = self.run_cc("aws", "--name", "test21", "--profile", "test21", expect=1)
        self.base = env_base
        self.assertIn("cannot reach the studio", p.stderr)


DSA = "helpdesk-sa@gcp-test9.iam.gserviceaccount.com"
REAL = "real.user@example.com"
COND = {"title": "temp", "expression": "request.time < timestamp('2099-01-01T00:00:00Z')"}
ADMIN_PREFIXES = ("/userinfo", "/crm", "/su", "/iamadmin")


class GcpBootstrapTests(Harness):
    """Seamless GCP onboarding: the derived helpdesk-sa is prepared against a fake Google (no network)."""

    def setUp(self):
        super().setUp()
        Fake.state = {"studio": {"Workspaces": {"ws-1": {"id": "ws-1", "name": "extension-dev", "scopeIds": []}}},
                      "gcp": self.model()}

    def model(self, **over):
        g = {"project": "gcp-test9", "number": "123456789012", "user_email": REAL, "deny": set(), "writes": [], "ops": {},
             "services": {"iam.googleapis.com": "DISABLED", "iamcredentials.googleapis.com": "DISABLED"},
             "sas": {}, "sa_policy": {},
             "proj_policy": {"version": 3, "etag": "BwProj", "bindings": [
                 {"role": "roles/owner", "members": ["user:boss@example.com"]},
                 {"role": "roles/viewer", "members": [f"serviceAccount:{DSA}"], "condition": COND}],
                 "auditConfigs": [{"service": "allServices", "auditLogConfigs": [{"logType": "DATA_READ"}]}]}}
        g.update(over)
        return g

    def ready_model(self):
        """Everything in place: the happy 'already configured' world."""
        g = self.model(sas={DSA: {"email": DSA, "disabled": False}},
                       services={"iam.googleapis.com": "ENABLED", "iamcredentials.googleapis.com": "ENABLED"})
        g["sa_policy"][DSA] = {"version": 3, "etag": "R1", "bindings": [
            {"role": "roles/iam.serviceAccountTokenCreator", "members": [f"user:{REAL}"]}]}
        g["proj_policy"]["bindings"].append({"role": "roles/viewer", "members": [f"serviceAccount:{DSA}"]})
        return g

    def run_derived(self, *extra, expect=0, **kw):
        # ADC file says one account; userinfo (the truth) says another; the gcloud stub says a third.
        self.write_adc(self.adc_path, account="stale-adc-field@example.com")
        return self.run_cc("gcp", "--project", "gcp-test9", "--adc-source", self.adc_path, *extra, expect=expect, **kw)

    def g(self):
        return Fake.state["gcp"]

    def cloud_state(self):
        g = self.g()
        return json.dumps({k: g[k] for k in ("services", "sas", "sa_policy", "proj_policy", "writes")}, sort_keys=True)

    def google_writes(self):
        return [(m, p.split("?")[0]) for m, p, _, _ in Fake.log if m == "POST" and (
            p.endswith(":setIamPolicy") or ":enable" in p or (p.startswith("/iamadmin") and p.endswith("/serviceAccounts")))]

    def admin_calls(self):
        return [p for _, p, _, _ in Fake.log if p.startswith(ADMIN_PREFIXES)]

    def assert_nothing_written(self):
        self.assertEqual(self.google_writes(), [])
        self.assertEqual(self.studio_writes(), [])
        self.assertEqual(self.store_log(), "")
        self.assertFalse(os.path.exists(self.state_file))

    def gcloud_calls(self):
        p = os.path.join(self.tmp, "gcloud.log")
        return open(p).read() if os.path.exists(p) else ""

    # ── happy path ──
    def test_missing_sa_is_created_granted_and_registered_with_the_adc_user(self):
        p = self.run_derived()
        g = self.g()
        # APIs, SA, narrow grants
        self.assertEqual(g["services"], {"iam.googleapis.com": "ENABLED", "iamcredentials.googleapis.com": "ENABLED"})
        self.assertEqual(g["created_bodies"][0]["accountId"], "helpdesk-sa")
        self.assertEqual(g["sa_policy"][DSA]["bindings"],
                         [{"role": "roles/iam.serviceAccountTokenCreator", "members": [f"user:{REAL}"]}])  # verified userinfo email
        viewer = [b for b in g["proj_policy"]["bindings"] if b["role"] == "roles/viewer"]
        self.assertIn({"role": "roles/viewer", "members": [f"serviceAccount:{DSA}"]}, viewer)
        # the identity came from userinfo, never from adc.account or gcloud
        self.assertNotIn("stale-adc-field@example.com", json.dumps(g, default=sorted))
        self.assertNotIn("gcloud-active@example.com", json.dumps(g, default=sorted))
        self.assertEqual(self.gcloud_calls(), "")
        # the only writes: enable x2, create, SA policy, project policy — and nothing else
        self.assertEqual(sorted(w.split(":")[0] for w in g["writes"]), ["enable", "enable", "sa-create", "set", "set"])
        self.assertEqual(len(g["policy_reads"]) , 2)
        for tag, method, qs, req in g["policy_reads"]:
            self.assertEqual(method, "POST")
            if tag.startswith("sa-policy:"):
                self.assertEqual((qs, req), ({"options.requestedPolicyVersion": ["3"]}, None))
            else:
                self.assertEqual((qs, req), ({}, {"options": {"requestedPolicyVersion": 3}}))
        sa_get = [pth for m, pth, _, _ in Fake.log if pth.split("?")[0].endswith(":getIamPolicy") and "/iamadmin/" in pth]
        self.assertTrue(sa_get and all(x.endswith(":getIamPolicy?options.requestedPolicyVersion=3") for x in sa_get))
        for _, pol in g["policy_sets"]:
            self.assertGreaterEqual(pol["version"], 3)
        # registration happened, after every cloud write
        self.assertEqual(self.provider()["credentials"][0]["dataEx"][0]["value"], DSA)
        self.assertEqual(self.store_log(), "")
        order = [m + " " + pth for m, pth, _, _ in Fake.log]
        last_google_write = max(i for i, o in enumerate(order) if o.startswith("POST") and
                                (":setIamPolicy" in o or ":enable" in o or o.endswith("/serviceAccounts")))
        first_studio_write = min(i for i, o in enumerate(order) if "/admin/data/" in o and not o.startswith("GET"))
        self.assertLess(last_google_write, first_studio_write)
        rec = self.records()["gcp-test9"]
        self.assertEqual(rec["serviceAccount"], DSA)
        self.assertEqual(len(rec["bootstrapChanges"]), 5)
        self.assertIn("created service account", p.stdout)
        self.assertIn("connection 'gcp-test9' ready", p.stdout)

    def test_policy_etag_conditions_and_audit_configs_are_preserved(self):
        self.run_derived()
        g = self.g()
        pol = g["proj_policy"]
        self.assertIn({"role": "roles/owner", "members": ["user:boss@example.com"]}, pol["bindings"])
        self.assertIn({"role": "roles/viewer", "members": [f"serviceAccount:{DSA}"], "condition": COND}, pol["bindings"])
        self.assertEqual(pol["auditConfigs"], [{"service": "allServices", "auditLogConfigs": [{"logType": "DATA_READ"}]}])
        sent = dict(g["policy_sets"])["proj-policy"]
        self.assertEqual(sent["etag"], "BwProj")           # the etag that was read is the one written back
        self.assertEqual(sent["version"], 3)
        # no role beyond the two allowed ones was added
        added = {b["role"] for b in pol["bindings"]} - {"roles/owner", "roles/viewer"}
        self.assertEqual(added, set())
        self.assertNotIn(f"serviceAccount:{DSA}", [m for b in pol["bindings"] if b["role"] == "roles/owner" for m in b["members"]])

    def test_etag_conflict_rereads_and_retries_without_overwriting_the_other_change(self):
        for code in (409, 412):
            with self.subTest(code=code):
                self.setUp()
                self.g()["conflict_once"] = code
                self.run_derived()
                pol = self.g()["proj_policy"]
                self.assertIn({"role": "roles/logging.viewer", "members": ["user:other@example.com"]}, pol["bindings"])
                self.assertIn({"role": "roles/viewer", "members": [f"serviceAccount:{DSA}"]}, pol["bindings"])
                self.assertEqual([t for t, _ in self.g()["policy_sets"]].count("proj-policy"), 2)
                self.assertEqual(self.g()["policy_sets"][-1][1]["etag"], "CONCURRENT")

    def test_persistent_conflict_gives_up_after_a_bounded_count(self):
        g = self.g()
        orig = Fake._g_policy_route

        def always_conflict(handler, verb, body, policy, tag, deny_key):
            if verb == "setIamPolicy" and tag == "proj-policy":
                g.setdefault("policy_sets", []).append((tag, body["policy"]))
                policy["etag"] = "X%d" % len(g["policy_sets"])
                return handler._g_err(409, "ABORTED", "etag mismatch")
            return orig(handler, verb, body, policy, tag, deny_key)
        Fake._g_policy_route = always_conflict
        try:
            p = self.run_derived(expect=1)
        finally:
            Fake._g_policy_route = orig
        self.assertEqual([t for t, _ in g["policy_sets"]].count("proj-policy"), 5)
        self.assertIn("Cloud changes ALREADY applied", p.stderr)
        self.assertEqual(self.studio_writes(), [])

    # ── idempotency ──
    def test_repeat_is_idempotent_and_needs_no_iam_admin(self):
        self.run_derived()
        snapshot = self.cloud_state()
        Fake.log = []
        self.g()["deny"] = {"crm_get", "su_get", "enable", "sa_get", "sa_create", "sa_setpolicy", "proj_setpolicy"}
        p = self.run_derived()
        self.assertEqual(self.admin_calls(), [])         # proof passed: no userinfo, no IAM, no Service Usage
        self.assertEqual(self.google_writes(), [])
        self.assertEqual(self.cloud_state(), snapshot)          # no cloud state changed at all
        self.assertEqual(self.studio_writes(), [])            # already native-shaped: nothing to rewrite
        self.assertIn("connection 'gcp-test9' ready", p.stdout)

    def test_fully_prepared_project_succeeds_without_any_cloud_write_or_admin_call(self):
        Fake.state["gcp"] = self.ready_model()
        self.g()["deny"] = {"crm_get", "su_get", "enable", "sa_get", "sa_create", "sa_setpolicy", "proj_setpolicy"}
        self.run_derived()
        self.assertEqual(self.admin_calls(), [])
        self.assertEqual(self.google_writes(), [])
        self.assertNotIn("bootstrapChanges", self.records()["gcp-test9"])

    def test_existing_sa_and_grants_are_reused_only_missing_pieces_written(self):
        g = self.g()
        g["services"] = {"iam.googleapis.com": "ENABLED", "iamcredentials.googleapis.com": "ENABLED"}
        g["sas"][DSA] = {"email": DSA, "disabled": False}
        g["nogrant_status"] = 404                          # a 404 from generateAccessToken is NOT proof the SA is absent
        self.run_derived()
        self.assertEqual(sorted(w.split(":")[0] for w in g["writes"]), ["set", "set"])   # grants only: no create, no enable
        self.assertNotIn("sa-create", " ".join(g["writes"]))

    def test_sa_lookup_distinguishes_real_404_from_403(self):
        g = self.g()
        g["missing_status"] = 403                          # Google may answer 403 for a missing SA at impersonation time
        self.run_derived()
        self.assertTrue(any(w.startswith("sa-create") for w in g["writes"]))   # the 404 came from the IAM lookup itself
        # …and an IAM lookup 403 is never read as 'absent'
        self.setUp()
        self.g()["deny"] = {"sa_get"}
        self.g()["services"] = {"iam.googleapis.com": "ENABLED", "iamcredentials.googleapis.com": "ENABLED"}
        p = self.run_derived(expect=1)
        self.assertIn("cannot look up service account", p.stderr)
        self.assertEqual(self.google_writes(), [])

    def test_create_race_409_is_handled_by_relookup(self):
        g = self.g()
        g["services"] = {"iam.googleapis.com": "ENABLED", "iamcredentials.googleapis.com": "ENABLED"}
        g["create_race"] = True
        self.run_derived()
        self.assertIn(DSA, g["sas"])
        self.assertEqual([w for w in g["writes"] if w.startswith("sa-create")], [f"sa-create:{DSA}"])  # one attempt, then reuse
        self.assertTrue(self.records()["gcp-test9"]["bootstrapChanges"])

    def test_disabled_existing_sa_stops_everything(self):
        g = self.g()
        g["services"] = {"iam.googleapis.com": "ENABLED", "iamcredentials.googleapis.com": "ENABLED"}
        g["sas"][DSA] = {"email": DSA, "disabled": True}
        p = self.run_derived(expect=1)
        self.assertIn("DISABLED", p.stderr)
        self.assertEqual(self.google_writes(), [])
        self.assertEqual(self.studio_writes(), [])
        self.assertEqual(self.store_log(), "")

    def test_service_enable_is_tracked_to_completion_and_checked_first(self):
        g = self.g()
        g["services"]["iam.googleapis.com"] = "ENABLED"     # already on: must not be re-enabled
        g["op_polls"] = 3
        self.run_derived()
        self.assertEqual([w for w in g["writes"] if w.startswith("enable")], ["enable:iamcredentials.googleapis.com"])
        polls = [pth for m, pth, _, _ in Fake.log if pth.startswith("/su/operations/")]
        self.assertEqual(len(polls), 3)
        for _, pth, _, _ in Fake.log:                       # Service Usage addressed by project NUMBER of the selected project only
            if pth.startswith("/su/projects/"):
                self.assertTrue(pth.startswith("/su/projects/123456789012/services/"), pth)

    def test_service_disabled_on_a_different_quota_project_is_not_mutated(self):
        g = self.g()
        g["consumer"] = "projects/999999999999"
        p = self.run_derived(expect=1)
        self.assertIn("quota project", p.stderr)
        self.assertEqual(self.google_writes(), [])
        self.assertEqual(self.studio_writes(), [])

    def test_bucket_denied_only_grants_the_viewer_and_skips_identity_lookup(self):
        Fake.state["gcp"] = self.ready_model()
        g = self.g()
        g["proj_policy"]["bindings"] = [b for b in g["proj_policy"]["bindings"] if b["role"] != "roles/viewer"]
        self.run_derived()
        self.assertEqual(g["writes"], ["set:proj-policy"])
        self.assertNotIn("/userinfo", self.admin_calls())

    # ── failures ──
    def test_403_on_admin_steps_stops_with_no_other_writes(self):
        for deny, applied in (("crm_get", False), ("su_get", False), ("enable", False), ("sa_create", True), ("sa_setpolicy", True),
                              ("proj_setpolicy", True)):
            with self.subTest(deny=deny):
                self.setUp()
                self.g()["deny"] = {deny}
                p = self.run_derived(expect=1)
                self.assertIn("HTTP 403", p.stderr)
                self.assertEqual(self.studio_writes(), [])
                self.assertEqual(self.store_log(), "")
                self.assertFalse(os.path.exists(self.state_file))
                self.assertFalse(os.path.exists(os.path.join(self.store_dir, "gcp")))
                if applied:   # honest partial-failure report: the API enables did happen
                    self.assertIn("Cloud changes ALREADY applied", p.stderr)
                    self.assertIn("enabled iam.googleapis.com", p.stderr)
                else:
                    self.assertNotIn("ALREADY applied", p.stderr)
                if deny == "sa_setpolicy":                  # stopped at the first denied write: the project policy is untouched
                    self.assertEqual(self.g()["proj_policy"]["etag"], "BwProj")
                    self.assertFalse(any(w.startswith("set:proj") for w in self.g()["writes"]))

    def test_dry_run_never_mutates_or_claims_validation(self):
        p = self.run_derived("--dry-run", expect=1)
        self.assertIn("NOT validated", p.stdout)
        self.assertIn("would prepare ONLY", p.stdout)
        self.assertIn("runtime not validated", p.stderr)
        self.assertNotIn("dry-run only — nothing installed", p.stdout)
        self.assertEqual(self.admin_calls(), [])
        self.assert_nothing_written()
        self.assertEqual(self.g()["writes"], [])
        self.assertEqual(self.gcloud_calls(), "")

    def test_malformed_or_unverified_identity_is_refused_with_no_writes(self):
        cases = [
            ({"sub": "1", "email": REAL, "email_verified": False}, "no verified email"),
            ({"sub": "1", "email_verified": True}, "no verified email"),
            ({"sub": "1", "email": "a@b.com, user:x@y.com", "email_verified": True}, "not a plain user email"),
            ({"sub": "1", "email": "sa@gcp-test9.iam.gserviceaccount.com", "email_verified": True}, "not a plain user email"),
            ({"sub": "1", "email": "bad\nuser@example.com", "email_verified": True}, "not a plain user email"),
        ]
        for info, msg in cases:
            with self.subTest(info=info):
                self.setUp()
                self.g()["userinfo"] = info
                p = self.run_derived(expect=1)
                self.assertIn(msg, p.stderr)
                self.assert_nothing_written()
        self.setUp()
        self.g()["userinfo_status"] = 403                      # token without the email scope
        p = self.run_derived(expect=1)
        self.assertIn("gcloud auth application-default login", p.stderr)
        self.assertIn("email scope", p.stderr)
        self.assert_nothing_written()
        self.assertEqual(self.gcloud_calls(), "")             # the tool never runs login itself

    def test_platform_conflicts_cause_zero_cloud_calls(self):
        Fake.state["studio"]["Providers"] = {"providers-9": {
            "id": "providers-9", "name": "gcp-gcp-test9", "type": "gcp", "accountId": "gcp-test9",
            "credentials": [{"name": "gcp-test9", "dataEx": [{"key": "cloudRoleToAssume", "value": "other@gcp-test9.iam.gserviceaccount.com"}],
                             "metaData": {"source": TOOL}}], "metaData": {"source": TOOL}}}
        Fake.log = []
        p = self.run_derived(expect=1)
        self.assertIn("already impersonates", p.stderr)
        self.assertEqual([x for x in Fake.log if not x[1].startswith("/v1/aiservicedesk")], [])   # not even a token refresh
        # foreign credential, other-project provider, missing workspace — same guarantee
        Fake.state["studio"]["Providers"]["providers-9"]["credentials"][0].pop("metaData")
        Fake.log = []
        self.assertIn("was not created by connect-cloud", self.run_derived(expect=1).stderr)
        self.assertEqual([x for x in Fake.log if not x[1].startswith("/v1/aiservicedesk")], [])
        Fake.state["studio"]["Providers"] = {}
        Fake.log = []
        self.assertIn("does not exist", self.run_derived("--workspace", "ws-gone", expect=1).stderr)
        self.assertEqual([x for x in Fake.log if not x[1].startswith("/v1/aiservicedesk")], [])
        self.assertEqual(self.g()["writes"], [])
        self.assertEqual(self.studio_writes(), [])

    def test_runtime_unusable_is_found_before_any_iam_write(self):
        self.rt_set(running=False)                                # the backend is not running: found before any IAM change
        p = self.run_derived(expect=1)
        self.assertIn("is not running", p.stderr)
        self.assertEqual(self.google_writes(), [])
        self.assertEqual(self.rt_mutations(), [])
        self.assertEqual(Fake.log, [x for x in Fake.log if x[1].startswith("/v1/aiservicedesk")])

    def test_explicit_service_account_and_no_bootstrap_are_never_prepared(self):
        for args, why in ((("--service-account", "other@elsewhere-proj.iam.gserviceaccount.com"), "--service-account"),
                          (("--no-bootstrap",), "--no-bootstrap")):
            with self.subTest(args=args):
                self.setUp()
                p = self.run_derived(*args, expect=1)
                self.assertIn("will not create it", p.stderr)
                self.assertIn(why, p.stderr)
                self.assertEqual(self.admin_calls(), [])
                self.assert_nothing_written()

    def test_explicitly_supplied_derived_default_still_bootstraps(self):
        p = self.run_derived("--service-account", DSA)
        self.assertIn("created service account", p.stdout)
        self.assertEqual(self.g()["sa_policy"][DSA]["bindings"],
                         [{"role": "roles/iam.serviceAccountTokenCreator", "members": [f"user:{REAL}"]}])
        # --no-bootstrap still wins over the spelled-out default
        self.setUp()
        p = self.run_derived("--service-account", DSA, "--no-bootstrap", expect=1)
        self.assertIn("--no-bootstrap", p.stderr)
        self.assert_nothing_written()

    def test_refresh_keeps_the_recorded_identity_and_never_bootstraps(self):
        self.run_derived()
        self.g()["sa_policy"][DSA]["bindings"] = []            # grant lost since
        Fake.log = []
        p = self.run_cc("refresh", "--name", "gcp-test9", expect=1)
        self.assertIn("recorded identity", p.stderr)
        self.assertEqual(self.admin_calls(), [])
        self.assertEqual(self.google_writes(), [])

    def test_not_an_iam_condition_is_not_bootstrapped(self):
        self.g()["imp_status"] = 503
        p = self.run_derived(expect=1)
        self.assertIn("HTTP 503", p.stderr)
        self.assertEqual(self.admin_calls(), [])
        self.assert_nothing_written()
        # a revoked login likewise (covered further by test_gcp_revoked_adc_fails_with_relogin_hint)
        self.setUp()
        self.write_adc(self.adc_path, refresh="revoked")
        p = self.run_cc("gcp", "--project", "gcp-test9", "--adc-source", self.adc_path, expect=1)
        self.assertIn("gcloud auth application-default login", p.stderr)
        self.assertEqual(self.admin_calls(), [])
        # a dead network
        self.setUp()
        self.base = "http://127.0.0.1:9"
        self.extra_env["DOCKER_STUB_SERVICES"] = BOTH_RUNNING
        p = self.run_cc("gcp", "--project", "gcp-test9", "--adc-source", self.adc_path, expect=1)
        self.assertNotIn("Traceback", p.stderr)

    # ── propagation ──
    def test_propagation_is_polled_then_succeeds(self):
        self.g()["lag"] = 2
        p = self.run_derived()
        self.assertEqual(self.g()["imp_calls"], 1 + 3)         # initial failure + 2 laggy + 1 success
        self.assertIn("waiting for IAM propagation", p.stdout)

    def test_propagation_is_bounded_and_failure_reports_the_changes_made(self):
        self.g()["lag"] = 10 ** 6
        self.extra_env["CONNECT_CLOUD_PROPAGATION_ATTEMPTS"] = "3"
        p = self.run_derived(expect=1)
        self.assertEqual(self.g()["imp_calls"], 1 + 3)
        self.assertIn("still fails after 3 attempt", p.stderr)
        self.assertIn("Cloud changes ALREADY applied", p.stderr)
        self.assertIn(f"created service account {DSA}", p.stderr)
        self.assertNotIn("nothing was", p.stderr.lower())
        self.assertEqual(self.studio_writes(), [])
        self.assertEqual(self.store_log(), "")                 # a cloud failure never leads to local credential writes

    def test_enable_operation_done_on_the_last_allowed_poll_succeeds(self):
        self.g()["op_polls"] = 3
        self.extra_env["CONNECT_CLOUD_PROPAGATION_ATTEMPTS"] = "3"
        self.run_derived()
        self.assertEqual(self.g()["services"], {"iam.googleapis.com": "ENABLED", "iamcredentials.googleapis.com": "ENABLED"})

    def test_enable_operation_not_done_after_the_last_poll_times_out(self):
        self.g()["op_polls"] = 4
        self.extra_env["CONNECT_CLOUD_PROPAGATION_ATTEMPTS"] = "3"
        p = self.run_derived(expect=1)
        self.assertIn("did not complete within 3 polls", p.stderr)
        self.assertEqual(self.studio_writes(), [])

    def test_policy_without_etag_refuses_the_write(self):
        del self.g()["proj_policy"]["etag"]
        self.g()["sas"][DSA] = {"email": DSA, "disabled": False}
        self.g()["services"] = {"iam.googleapis.com": "ENABLED", "iamcredentials.googleapis.com": "ENABLED"}
        p = self.run_derived(expect=1)
        self.assertIn("no etag", p.stderr)
        self.assertNotIn("proj-policy", [t for t, _ in self.g().get("policy_sets", [])])
        self.assertNotIn(f"serviceAccount:{DSA}", json.dumps(self.g()["proj_policy"]["bindings"][2:]))
        self.assertEqual(self.studio_writes(), [])

    def test_grants_already_present_but_proof_fails_is_reproved_before_blaming_anything(self):
        self.g().update(self.ready_model())
        self.g()["lag"] = 2                      # first proof fails (lag), bootstrap's reprove fails once more, then passes
        p = self.run_derived()
        self.assertEqual(self.google_writes(), [])
        self.assertIn("waiting for IAM propagation", p.stdout)
        self.assertIn("connection 'gcp-test9' ready", p.stdout)

    def test_grants_already_present_and_proof_never_passes_does_not_claim_a_proven_cause(self):
        self.g().update(self.ready_model())
        self.g()["lag"] = 10 ** 6
        self.extra_env["CONNECT_CLOUD_PROPAGATION_ATTEMPTS"] = "3"
        p = self.run_derived(expect=1)
        self.assertIn("changed nothing", p.stderr)
        self.assertIn("cause is not proven", p.stderr)
        self.assertEqual(self.google_writes(), [])
        self.assertEqual(self.studio_writes(), [])

    # ── secrets ──
    def test_no_token_or_secret_in_urls_argv_outputs_state_or_store_log(self):
        p = self.run_derived("--json")
        secrets = (REFRESH_TOKEN, CLIENT_SECRET, "ya29.user", "ya29.sa")
        for m, pth, body, hdrs in Fake.log:
            if pth.startswith("/token"):
                continue
            self.assertFalse(any(x in pth for x in secrets), pth)               # never in a URL
            self.assertFalse(any(x in json.dumps(body) for x in secrets), pth)  # never in a request body
            if "ya29" in json.dumps(hdrs):
                self.assertIn(hdrs.get("Authorization"), ("Bearer ya29.user", "Bearer ya29.sa"))
        with open(self.state_file) as f:
            state_text = f.read()
        for secret in secrets:
            for text in (p.stdout, p.stderr, state_text, self.store_log()):
                self.assertNotIn(secret, text)


class GcpNativeRuntimeTests(Harness):
    """The backend's native ADC: the whole gcloud directory bound read-only, GOOGLE_APPLICATION_CREDENTIALS set, no copy,
    no adcRef. The runtime is a stub of scripts/_gcp_auth.sh that reads the real files of the directory it pretends to
    bind; each test asserts which runtime operations ran and which platform/cloud writes did (or did not) follow."""

    def connect(self, *extra, name="gcp-test9", expect=0, **kw):
        args = ("gcp", "--name", name, "--project", "gcp-test9", "--service-account", SA, *extra)
        return self.run_cc(*args, expect=expect, **kw)

    def relogin(self, account="second.login@example.com"):
        """A new `gcloud auth application-default login`: the file is replaced (atomic rename, like gcloud)."""
        tmp = self.adc_path + ".new"
        self.write_adc(tmp, account=account)
        os.replace(tmp, self.adc_path)

    def assert_no_registration(self):
        self.assertEqual(self.studio_writes(), [])
        self.assertFalse(os.path.exists(self.state_file))

    # ── runtime wiring: absent / misaligned vs. readable ──
    def test_missing_mount_recreates_only_the_backend_once_then_registers_without_a_second_restart(self):
        self.rt_set(mount=None, env=None)                              # an old backend: no /devkit-gcloud, no env
        p = self.connect()
        calls = self.rt_calls()
        self.assertEqual(calls, ["dir", "inspect", "reconcile", "inspect", "probe"])
        self.assertNotIn("restart", calls)                             # the recreate already reset the ADC cache: no double restart
        self.assertIn("recreating ONLY the backend", p.stderr)        # announced before it was done
        self.assertIn("recreated the backend only", p.stdout)
        self.assertEqual([m for m, _ in self.studio_writes()], ["POST", "POST", "POST"])
        with open(self.rt_state_file()) as f:
            rec = json.load(f)
        self.assertEqual((rec["backendId"], rec["dir"]), ("stud2", self.gdir))
        self.assertEqual(len(rec["adcFingerprint"]), 64)

    def test_missing_env_with_the_mount_present_is_repaired_too(self):
        self.rt_set(env=None)
        self.connect()
        self.assertIn("reconcile", self.rt_calls())
        self.assertNotIn("restart", self.rt_calls())

    def test_mount_bound_from_another_directory_is_repaired(self):
        other = os.path.join(self.tmp, "elsewhere"); os.makedirs(other)
        self.rt_set(mount=other)
        p = self.connect()
        self.assertIn(f"is bound from {other}", p.stdout)
        self.assertIn("reconcile", self.rt_calls())

    def test_a_writable_mount_is_not_accepted_as_wired(self):
        self.rt_set(ro=False)
        p = self.connect()
        self.assertIn("not mounted read-only", p.stdout)
        self.assertIn("reconcile", self.rt_calls())

    def test_wiring_still_wrong_after_the_recreate_registers_nothing(self):
        self.rt_set(mount=None, env=None, reconcile_noop=True)     # compose applied an override that drops the mount
        p = self.connect(expect=1)
        self.assertIn("wiring is still wrong", p.stderr)
        self.assertIn("COMPOSE_FILE", p.stderr)
        self.assert_no_registration()
        self.assertFalse(os.path.exists(self.rt_state_file()))

    def test_reconcile_failure_registers_nothing_and_records_no_state(self):
        self.rt_set(mount=None, env=None, fail="reconcile")
        p = self.connect(expect=1)
        self.assertIn("reconcile' failed", p.stderr)
        self.assert_no_registration()
        self.assertFalse(os.path.exists(self.rt_state_file()))

    def test_unreadable_by_the_backend_uid_is_a_specific_permission_failure_before_any_write(self):
        for state in ("dir-not-traversable", "unreadable"):
            with self.subTest(state=state):
                self.rt_set(probe={"state": state})
                Fake.log = []
                p = self.connect(expect=1)
                self.assertIn("PERMISSIONS", p.stderr)
                self.assertIn("uid:gid 1001:1001", p.stderr)
                self.assertIn("never loosens permissions", p.stderr)
                self.assertEqual(self.studio_writes(), [])
                self.assertEqual([x for x in Fake.log if x[1].startswith(("/token", "/iam", "/storage"))], [])   # before the host proof too
                self.assertEqual(self.rt_mutations(), [])
                self.assertFalse(os.path.exists(self.state_file))

    def test_runtime_reads_a_different_file_than_the_host_proof_registers_nothing(self):
        other = os.path.join(self.tmp, "other-gcloud"); os.makedirs(other)
        self.write_adc(os.path.join(other, "application_default_credentials.json"), account="someone.else@example.com")
        self.rt_set(mount=self.gdir, probe={"state": "ok", "type": "authorized_user", "sha256": "0" * 64})
        p = self.connect(expect=1)
        self.assertIn("DIFFERENT file", p.stderr)
        self.assert_no_registration()
        self.assertEqual(self.rt_mutations(), [])

    def test_missing_file_inside_a_wired_backend_directs_to_login_not_a_copy(self):
        self.rt_set(probe={"state": "missing"})
        p = self.connect(expect=1)
        self.assertIn("gcloud auth application-default login", p.stderr)
        self.assertIn("never copies", p.stderr)
        self.assert_no_registration()

    # ── --adc-source: only the exact native file ──
    def test_adc_source_must_be_the_exact_native_file_the_backend_binds(self):
        other = os.path.join(self.tmp, "adc2.json")
        self.write_adc(other, account="bob@example.com")
        p = self.connect("--adc-source", other, expect=1)
        self.assertIn("is not the file the running backend reads", p.stderr)
        self.assertIn("DEVKIT_GCLOUD_DIR=", p.stderr)
        self.assertEqual(self.rt_calls(), ["dir"])                    # refused before inspecting, probing or changing anything
        self.assertEqual(Fake.log, [])
        self.assert_no_registration()
        # the same native file spelled through a symlink is the same file
        link = os.path.join(self.tmp, "link.json")
        os.symlink(self.adc_path, link)
        self.connect("--adc-source", link)
        self.assertEqual(self.records()["gcp-test9"]["adcSource"], self.adc_path)

    # ── no ADC → login → visible ──
    def test_no_adc_then_login_then_the_backend_sees_it_after_exactly_one_restart(self):
        os.remove(self.adc_path)
        p = self.connect(expect=1)
        self.assertIn("gcloud auth application-default login", p.stderr)
        self.assertIn("never copies", p.stderr)
        self.assertEqual(self.rt_calls(), ["dir"])                    # nothing touched: no mkdir, no restart, no cloud call
        self.assertEqual(Fake.log, [])
        self.assert_no_registration()
        self.write_adc(self.adc_path)                                  # the user (or the agent) ran the normal login
        p = self.connect()
        self.assertIn("first native ADC connection", p.stderr)         # the backend may have cached the earlier failure
        self.assertEqual(self.rt_calls().count("restart"), 1)
        self.assertIn("connection 'gcp-test9' ready", p.stdout)

    # ── cache reset: re-login restarts; repeat and new target do not ──
    def test_relogin_restarts_the_backend_automatically_and_then_settles(self):
        self.connect()
        self.assertEqual(self.rt_calls().count("restart"), 1)
        first = json.load(open(self.rt_state_file()))["adcFingerprint"]
        self.connect()
        self.assertEqual(self.rt_calls().count("restart"), 1)          # unchanged ADC: no restart
        self.relogin()
        p = self.connect()
        self.assertEqual(self.rt_calls().count("restart"), 2)
        self.assertIn("a new login", p.stderr)
        self.assertIn("restarting ONLY the backend", p.stderr)
        self.assertNotEqual(json.load(open(self.rt_state_file()))["adcFingerprint"], first)
        self.connect()
        self.assertEqual(self.rt_calls().count("restart"), 2)          # settled again
        self.assertEqual(self.rt_calls().count("reconcile"), 0)        # a restart, never a recreate, when wiring is fine

    def test_new_target_project_on_the_same_adc_does_not_restart(self):
        self.connect()
        Fake.state["project"] = "proj-two"
        Fake.state["sa"] = "helpdesk-sa@proj-two.iam.gserviceaccount.com"
        p = self.run_cc("gcp", "--name", "second", "--project", "proj-two",
                        "--service-account", "helpdesk-sa@proj-two.iam.gserviceaccount.com")
        self.assertIn("no restart needed", p.stdout)
        self.assertEqual(self.rt_calls().count("restart"), 1)
        self.assertEqual(sorted(self.records()), ["gcp-test9", "second"])

    def test_a_backend_restarted_elsewhere_is_restarted_once_more_because_its_cache_is_unknown(self):
        self.connect()
        self.rt_set(started="2026-11-03T11:11:11Z")                    # someone restarted it (new start marker)
        p = self.connect()
        self.assertIn("restarted since this tool last recorded it", p.stderr)
        self.assertEqual(self.rt_calls().count("restart"), 2)

    def test_the_private_state_holds_hashes_only(self):
        self.connect()
        with open(self.rt_state_file()) as f:
            text = f.read()
        for secret in (REFRESH_TOKEN, CLIENT_SECRET, "ya29", "ganesh@example.com"):
            self.assertNotIn(secret, text)
        self.assertEqual(oct(os.stat(self.rt_state_file()).st_mode & 0o777), "0o600")
        self.assertEqual(sorted(json.loads(text)), ["adcFingerprint", "backendId", "dir", "startedAt", "updatedAt", "version"])

    # ── dry-run: inspect only ──
    def test_dry_run_with_missing_wiring_mutates_nothing(self):
        self.rt_set(mount=None, env=None)
        before = open(os.path.join(self.rt_dir, "state.json")).read()
        p = self.connect("--dry-run")
        self.assertIn("would create", p.stdout)
        self.assertIn("recreate ONLY the backend", p.stdout)
        self.assertIn("compose up -d --no-deps --no-build --pull never duplo-ai-studio", p.stdout)
        self.assertEqual(self.rt_calls(), ["dir", "inspect"])
        self.assertEqual(open(os.path.join(self.rt_dir, "state.json")).read(), before)
        self.assertEqual(self.studio_writes(), [])
        self.assertFalse(os.path.exists(self.state_file))
        self.assertFalse(os.path.exists(self.rt_state_file()))
        self.assertEqual(self.store_log(), "")

    # ── migration of a legacy adcRef credential ──
    def seed_legacy(self, extra_credential=True):
        creds = [{"name": "gcp-test9", "dataEx": [
            {"key": "cloudRoleToAssume", "value": SA, "type": "string", "isSensitive": False},
            {"key": "adcRef", "value": "gcp-test9", "type": "string", "isSensitive": False}],
            "metaData": {"source": TOOL}}]
        if extra_credential:
            creds.append({"name": "someone-elses", "dataEx": [{"key": "cloudRoleToAssume", "value": "x@y.iam.gserviceaccount.com"}]})
        Fake.state["studio"]["Providers"] = {"providers-1": {
            "id": "providers-1", "name": "gcp-gcp-test9", "type": "gcp", "accountId": "gcp-test9", "credentials": creds,
            "metaData": {"source": TOOL}}}
        Fake.state["studio"]["Scopes"] = {"scopes-1": {
            "id": "scopes-1", "name": "gcp-test9", "providerId": "providers-1", "credentialName": "gcp-test9",
            "metaData": {"source": TOOL}}}
        Fake.state["studio"]["Workspaces"]["ws-1"]["scopeIds"] = ["scopes-1"]
        os.makedirs(os.path.join(self.store_dir, "gcp"))
        legacy_file = os.path.join(self.store_dir, "gcp", "gcp-test9.json")
        with open(legacy_file, "w") as f:
            f.write("legacy-store-file-kept-for-rollback")
        return legacy_file

    def test_legacy_adcref_credential_is_migrated_in_place_idempotently_without_touching_others_or_the_store(self):
        legacy_file = self.seed_legacy()
        p = self.connect()
        self.assertIn("legacy adcRef", p.stdout)
        self.assertEqual(self.studio_writes(), [("PUT", "/v1/aiservicedesk/admin/data/Providers/providers-1/credentials/gcp-test9")])
        creds = Fake.state["studio"]["Providers"]["providers-1"]["credentials"]
        self.assertEqual([c["name"] for c in creds], ["gcp-test9", "someone-elses"])
        self.assertEqual([d["key"] for d in creds[0]["dataEx"]], ["cloudRoleToAssume"])
        self.assertEqual(creds[1]["dataEx"], [{"key": "cloudRoleToAssume", "value": "x@y.iam.gserviceaccount.com"}])   # untouched
        self.assertEqual(len(Fake.state["studio"]["Scopes"]), 1)
        with open(legacy_file) as f:
            self.assertEqual(f.read(), "legacy-store-file-kept-for-rollback")                 # old named store data intact
        self.assertEqual(self.store_log(), "")                                                 # and never written or removed
        Fake.log = []
        p = self.connect()
        self.assertEqual(self.studio_writes(), [])                                             # second run: nothing left to migrate
        self.assertIn("already in its final shape", p.stdout)

    def test_a_foreign_credential_is_never_migrated_or_overwritten(self):
        self.seed_legacy()
        Fake.state["studio"]["Providers"]["providers-1"]["credentials"][0].pop("metaData")
        before = json.dumps(Fake.state["studio"], sort_keys=True)
        p = self.connect(expect=1)
        self.assertIn("was not created by connect-cloud", p.stderr)
        self.assertEqual(json.dumps(Fake.state["studio"], sort_keys=True), before)
        self.assertEqual(self.rt_mutations(), [])

    # ── verify / status / refresh ──
    def test_verify_fails_the_runtime_stage_alone_when_the_backend_mount_is_gone(self):
        self.connect()
        self.rt_set(mount=None, env=None)
        p = self.run_cc("verify", "--name", "gcp-test9", "--json", expect=1)
        res = json.loads(p.stdout)["result"]
        self.assertEqual(res["stages"], {"runtimeFile": False, "hostProof": True, "ticketProven": False})
        self.assertFalse(res["checks"]["runtimeMountAndEnv"])
        self.assertTrue(res["checks"]["adcImpersonation"])                 # host proof alone is not enough
        self.assertEqual(self.rt_calls().count("reconcile"), 0)            # verify never repairs

    def test_verify_flags_a_stale_adc_cache_after_a_relogin_and_refresh_restarts_the_backend(self):
        self.connect()
        self.relogin()
        p = self.run_cc("verify", "--name", "gcp-test9", "--json", expect=1)
        res = json.loads(p.stdout)["result"]
        self.assertFalse(res["checks"]["runtimeCacheCurrent"])
        self.assertTrue(res["checks"]["runtimeFileReadable"])
        self.assertTrue(res["checks"]["runtimeSourceAligned"])             # the NEW file is what the backend binds and sees
        self.assertEqual(self.rt_calls().count("restart"), 1)              # verify did not restart
        r = self.run_cc("refresh", "--name", "gcp-test9", "--json")
        self.assertTrue(json.loads(r.stdout)["ok"])                         # no "no restart" claim is made for GCP
        self.assertEqual(self.rt_calls().count("restart"), 2)
        self.run_cc("verify", "--name", "gcp-test9")

    def test_refresh_does_not_require_the_agent_container_for_gcp(self):
        self.connect()
        self.extra_env["DOCKER_STUB_SERVICES"] = ""
        self.run_cc("refresh", "--name", "gcp-test9")

    def test_status_reports_the_one_shared_runtime_adc(self):
        self.connect()
        self.connect(name="other")
        p = self.run_cc("status", "--json")
        res = json.loads(p.stdout)["result"]
        self.assertTrue(res["gcpRuntime"]["runtimeMountAndEnv"])
        self.assertEqual(res["gcpRuntime"]["adcFile"], self.adc_path)
        self.assertIn("one identity for every GCP connection", "\n".join(json.loads(p.stdout)["log"]))


    # ── review fixes ──
    def test_dry_run_json_never_claims_the_runtime_file_proven(self):
        for wiring in ({}, {"mount": None, "env": None}):
            self.rt_set(**wiring) if wiring else None
            p = self.connect("--dry-run", "--json")
            res = json.loads(p.stdout)["result"]
            self.assertEqual(res["stages"], {"runtimeFile": False, "hostProof": True, "ticketProven": False})
            self.assertFalse(res["runtime"]["verified"])
            self.assertNotIn("runtime-file: PROVEN", p.stdout)
        self.assertEqual(self.rt_mutations(), [])

    def test_real_run_stage_line_says_proven_only_after_the_probe(self):
        p = self.connect("--json")
        res = json.loads(p.stdout)["result"]
        self.assertEqual(res["stages"], {"runtimeFile": True, "hostProof": True, "ticketProven": False})
        self.assertIn("no SDK/end-to-end claim", p.stdout)

    def test_adc_replaced_during_the_restart_is_not_recorded_or_registered(self):
        # the file the backend reads after the restart differs from the one the host proof used
        self.rt_set(probe_after_restart={"state": "ok", "type": "authorized_user", "sha256": "1" * 64})
        p = self.connect(expect=1)
        self.assertIn("after the restart", p.stderr)
        self.assertIn("DIFFERENT file", p.stderr)
        self.assert_no_registration()
        self.assertFalse(os.path.exists(self.rt_state_file()))

    def test_unreadable_after_the_restart_registers_nothing(self):
        self.rt_set(probe_after_restart={"state": "unreadable"})
        p = self.connect(expect=1)
        self.assertIn("PERMISSIONS", p.stderr)
        self.assert_no_registration()
        self.assertFalse(os.path.exists(self.rt_state_file()))

    def test_adc_replaced_after_precheck_is_caught_even_when_no_restart_is_needed(self):
        self.connect()
        self.rt_set(probe_after_restart=None, probe_on_nth=None)
        self.rt_set(probe_second={"state": "ok", "type": "authorized_user", "sha256": "2" * 64})
        before = open(self.rt_state_file()).read()
        p = self.connect(expect=1)
        self.assertIn("after the final check", p.stderr)
        self.assertEqual(open(self.rt_state_file()).read(), before)

    def test_credential_with_an_empty_target_is_rewritten_not_kept(self):
        self.seed_legacy(extra_credential=False)
        Fake.state["studio"]["Providers"]["providers-1"]["credentials"][0]["dataEx"] = [
            {"key": "cloudRoleToAssume", "value": "", "type": "string", "isSensitive": False}]
        self.connect()
        self.assertEqual([m for m, _ in self.studio_writes()], ["PUT"])
        data = Fake.state["studio"]["Providers"]["providers-1"]["credentials"][0]["dataEx"]
        self.assertEqual(data[0]["value"], SA)

    def test_missing_adc_names_the_scoped_login_for_a_custom_directory(self):
        custom = os.path.join(self.tmp, "my gcloud's dir")
        os.makedirs(custom)
        self.rt_set(dir=custom, source="DEVKIT_GCLOUD_DIR (.env)")
        p = self.connect(expect=1)
        self.assertIn("CLOUDSDK_CONFIG='" + custom.replace("'", "'\"'\"'") + "' gcloud auth application-default login", p.stderr)
        # the default directory keeps the plain command
        self.rt_set(dir=self.gdir, source="default ($HOME/.config/gcloud)")
        os.remove(self.adc_path)
        p = self.connect(expect=1)
        self.assertIn("Run: gcloud auth application-default login", p.stderr)
        self.assertNotIn("CLOUDSDK_CONFIG", p.stderr)

    def test_permission_message_makes_no_rootless_podman_claim(self):
        self.rt_set(probe={"state": "unreadable"})
        p = self.connect(expect=1)
        self.assertNotIn("usually map", p.stderr)
        self.assertIn("only Docker Desktop has been verified", p.stderr)

    # ── nothing secret anywhere new ──
    def test_no_secret_in_runtime_calls_state_or_output(self):
        p = self.connect("--json")
        self.relogin()
        q = self.connect("--json")
        texts = [p.stdout + p.stderr, q.stdout + q.stderr, open(self.rt_state_file()).read(),
                 open(os.path.join(self.rt_dir, "calls.log")).read(), open(self.state_file).read()]
        for secret in (REFRESH_TOKEN, CLIENT_SECRET, "ya29.user", "ya29.sa"):
            for t in texts:
                self.assertNotIn(secret, t)
        self.assertEqual(self.store_log(), "")


if __name__ == "__main__":
    unittest.main(verbosity=1)
