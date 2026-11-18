#!/usr/bin/env python3
"""connect-cloud: register an AWS account or a GCP project with the local dev kit.

Invoked by scripts/connect-cloud.sh, which supplies every input through the environment:

  DUPLO_BASE / DUPLO_TOKEN            studio URL and admin bearer token (never on a command line)
  CONNECT_CLOUD_WORKSPACE_DEFAULT     workspace to attach scopes to when --workspace is not given
  CONNECT_CLOUD_STATE                 path of the non-secret connection records (JSON)
  CONNECT_CLOUD_STORE_CMD             command prefix for the (AWS-era, now legacy) credential store (write|remove|list|exists|volume)
  CONNECT_CLOUD_GCP_CMD               command prefix for the GCP runtime helper (dir|inspect|probe|prepare|reconcile|restart);
                                      the ONLY way GCP touches the container runtime — tests stub it
  CONNECT_CLOUD_GCP_STATE             private record of the runtime ADC fingerprint + backend start marker
                                      (default: gcp-runtime.json beside the connection records; hashes only)
  CONNECT_CLOUD_PROJECT / RUNTIME     compose project + container CLI, for container snapshots only
  CONNECT_CLOUD_GOOGLE_TOKEN_URL, CONNECT_CLOUD_GOOGLE_IAM_URL, CONNECT_CLOUD_GOOGLE_STORAGE_URL,
  CONNECT_CLOUD_GOOGLE_USERINFO_URL, CONNECT_CLOUD_GOOGLE_IAM_ADMIN_URL, CONNECT_CLOUD_GOOGLE_CRM_URL,
  CONNECT_CLOUD_GOOGLE_SERVICEUSAGE_URL
                                      Google endpoints (tests point them at a local fake)
  CONNECT_CLOUD_PROPAGATION_ATTEMPTS / _INTERVAL
                                      bounded IAM-propagation polling after a bootstrap (default 12 x 5s)

Rules this file enforces, in order of importance:
  * secrets travel on stdin / in HTTPS request bodies only; the records file and all output carry
    names, ids and expiry — never key material;
  * every conflict is found BEFORE any write (preflight), then writes are applied in order; a
    re-run never duplicates and a rotation is an in-place update of the same credential;
  * the identity a connection is registered with is proven before it is stored (STS for AWS, an
    actual IAM generateAccessToken + bucket list for GCP), with the very credentials being stored;
  * selecting a GCP project authorizes preparing ONLY the derived helpdesk-sa in that project, and only
    when the impersonation/bucket proof fails with a typed missing-SA/permission/API condition (see
    GcpBootstrap); every local conflict is refused BEFORE the first cloud IAM write;
  * a "no restart" claim is only ever made from real container ids and start times of BOTH the
    studio and the agent; a missing service fails the claim instead of passing vacuously;
  * GCP uses the published backend's stock Application Default Credentials lookup: the whole host gcloud
    directory is bound read-only into the backend (docker-compose.yml) and nothing is copied. A connection
    registers only cloudRoleToAssume. The runtime (mount, env, the backend uid's read access, source identity) is
    proven BEFORE any platform write; the backend is recreated/restarted, only that service, only when its
    process-lifetime ADC cache has to be reset (first native connection, or ADC replaced by a new login).
"""

from __future__ import annotations

import argparse
import datetime as _dt
import hashlib
import json
import os
import re
import shlex
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

ADMIN = "/v1/aiservicedesk/admin/data"
TOOL_SOURCE = "devkit connect-cloud"
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")
RUNTIME_MOUNT = "/devkit-gcloud"                      # where the backend sees the host gcloud directory (docker-compose.yml)
RUNTIME_ADC_FILE = "application_default_credentials.json"
RUNTIME_ENV = "GOOGLE_APPLICATION_CREDENTIALS"
RUNTIME_ENV_VALUE = f"{RUNTIME_MOUNT}/{RUNTIME_ADC_FILE}"
GCP_OP_TIMEOUT = int(os.environ.get("CONNECT_CLOUD_GCP_OP_TIMEOUT", "600"))   # reconcile/restart include a bounded health wait
GOOGLE_TOKEN_URL = os.environ.get("CONNECT_CLOUD_GOOGLE_TOKEN_URL", "https://oauth2.googleapis.com/token")
GOOGLE_IAM_URL = os.environ.get("CONNECT_CLOUD_GOOGLE_IAM_URL", "https://iamcredentials.googleapis.com/v1")
GOOGLE_STORAGE_URL = os.environ.get("CONNECT_CLOUD_GOOGLE_STORAGE_URL", "https://storage.googleapis.com/storage/v1")
GOOGLE_USERINFO_URL = os.environ.get("CONNECT_CLOUD_GOOGLE_USERINFO_URL", "https://openidconnect.googleapis.com/v1/userinfo")
GOOGLE_IAM_ADMIN_URL = os.environ.get("CONNECT_CLOUD_GOOGLE_IAM_ADMIN_URL", "https://iam.googleapis.com/v1")
GOOGLE_CRM_URL = os.environ.get("CONNECT_CLOUD_GOOGLE_CRM_URL", "https://cloudresourcemanager.googleapis.com/v1")
GOOGLE_SERVICEUSAGE_URL = os.environ.get("CONNECT_CLOUD_GOOGLE_SERVICEUSAGE_URL", "https://serviceusage.googleapis.com/v1")
PROPAGATION_ATTEMPTS = max(1, int(os.environ.get("CONNECT_CLOUD_PROPAGATION_ATTEMPTS", "12")))
PROPAGATION_INTERVAL = max(0.0, float(os.environ.get("CONNECT_CLOUD_PROPAGATION_INTERVAL", "5")))
IAM_WRITE_ATTEMPTS = 5            # etag conflicts (409/412) on a policy write: re-read and retry this many times
BOOTSTRAP_APIS = ("iam.googleapis.com", "iamcredentials.googleapis.com")
SA_ACCOUNT_ID = "helpdesk-sa"
ROLE_TOKEN_CREATOR = "roles/iam.serviceAccountTokenCreator"
ROLE_VIEWER = "roles/viewer"
CLOUD_PLATFORM_SCOPE = "https://www.googleapis.com/auth/cloud-platform"
ADC_ALLOWED_KEYS = {"type", "client_id", "client_secret", "refresh_token", "quota_project_id", "universe_domain", "account"}
AWS_EXPORT_TIMEOUT = int(os.environ.get("CONNECT_CLOUD_AWS_EXPORT_TIMEOUT", "300"))   # interactive logins take a while
AWS_STS_TIMEOUT = int(os.environ.get("CONNECT_CLOUD_AWS_STS_TIMEOUT", "60"))
SERVICES = ("duplo-ai-studio", "claude-code-agent")


class Fail(Exception):
    """A user-facing failure: message printed, exit 1, no traceback."""


def now_iso() -> str:
    return _dt.datetime.now(_dt.timezone.utc).replace(microsecond=0).isoformat()


# ── studio API ─────────────────────────────────────────────────────────────────

class Studio:
    def __init__(self, base: str, token: str, dry_run: bool = False):
        self.base = base.rstrip("/")
        self.token = token
        self.dry_run = dry_run
        self.writes: list[str] = []

    def call(self, method: str, path: str, body=None, *, ok=(200, 201, 204), timeout=20):
        url = self.base + path
        data = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("Authorization", "Bearer " + self.token)
        if data is not None:
            req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                raw = resp.read().decode() if resp.length != 0 else ""
                status = resp.status
        except urllib.error.HTTPError as e:
            raw = e.read().decode(errors="replace")
            status = e.code
        except (urllib.error.URLError, TimeoutError, OSError) as e:
            raise Fail(f"{method} {url}: cannot reach the studio ({getattr(e, 'reason', e)}). Is the stack up? (./run.sh)")
        parsed = None
        if raw:
            try:
                parsed = json.loads(raw)
            except ValueError:
                parsed = None
        if status not in ok:
            raise Fail(f"{method} {path} → HTTP {status}: {describe_error(parsed, raw)}")
        return status, parsed

    def write(self, method: str, path: str, body=None, **kw):
        """A mutating call. In --dry-run it is recorded and NOT sent."""
        self.writes.append(f"{method} {path}")
        if self.dry_run:
            return 200, {"data": {"id": "(dry-run)"}}
        return self.call(method, path, body, **kw)

    # -- lookups (list + filter in python, like scripts/register-qdrant.sh) --
    def list_all(self, collection: str) -> list[dict]:
        items: list[dict] = []
        page = 1
        while True:
            _, d = self.call("GET", f"{ADMIN}/{collection}?page={page}&pageSize=100")
            data = (d or {}).get("data", d)
            batch = data.get("items", data) if isinstance(data, dict) else data
            if not isinstance(batch, list):
                raise Fail(f"unexpected response listing {collection}: {str(d)[:200]}")
            items.extend(batch)
            total_pages = data.get("totalPages") if isinstance(data, dict) else None
            if not batch or not total_pages or page >= int(total_pages):
                break
            page += 1
        return items

    def find_unique(self, collection: str, name: str) -> dict | None:
        """Exact-name match; more than one is a conflict the user must resolve, never 'the first'."""
        matches = [x for x in self.list_all(collection) if x.get("name") == name]
        if len(matches) > 1:
            raise Fail(f"{len(matches)} {collection} are named '{name}' ({', '.join(m.get('id', '?') for m in matches)}); "
                       "ambiguous — rename or delete the duplicates in the UI, or use another --name")
        return matches[0] if matches else None

    def get(self, collection: str, id_: str) -> dict | None:
        status, d = self.call("GET", f"{ADMIN}/{collection}/{id_}", ok=(200, 404))
        if status == 404:
            return None
        return (d or {}).get("data", d)


def describe_error(parsed, raw: str) -> str:
    if isinstance(parsed, dict):
        if isinstance(parsed.get("error"), dict) and parsed["error"].get("message"):   # Google's {"error": {...}}
            return str(parsed["error"]["message"])[:300]
        parts = [str(parsed.get(k)) for k in ("message", "errors", "title", "detail") if parsed.get(k)]
        if parsed.get("code"):
            parts.append(f"({parsed['code']})")
        if parts:
            return " ".join(parts)
    return (raw or "<empty body>").strip()[:500]


# ── connection records (non-secret) ────────────────────────────────────────────

class Records:
    FORBIDDEN = ("secretAccessKey", "sessionToken", "accessKeyId", "refresh_token", "client_secret", "access_token")

    def __init__(self, path: str):
        self.path = path
        self.data: dict = {"version": 1, "connections": {}}
        if os.path.exists(path):
            try:
                with open(path) as f:
                    self.data = json.load(f)
                if not isinstance(self.data, dict) or not isinstance(self.data.get("connections", {}), dict):
                    raise ValueError("not an object with a 'connections' object")
            except (ValueError, OSError) as e:
                raise Fail(f"connection records file {path} is unreadable or malformed ({e}); fix or delete it")
            self.data.setdefault("connections", {})

    def get(self, name: str) -> dict | None:
        rec = self.data["connections"].get(name)
        if rec is not None and not isinstance(rec, dict):
            raise Fail(f"connection record '{name}' in {self.path} is malformed; delete it and re-run")
        return rec

    def put(self, name: str, record: dict) -> None:
        text = json.dumps(record)
        for forbidden in self.FORBIDDEN:
            if forbidden in text:
                raise AssertionError(f"refusing to record a secret field ({forbidden})")
        self.data["connections"][name] = record
        self.save()

    def save(self) -> None:
        d = os.path.dirname(self.path)
        if d:
            os.makedirs(d, mode=0o700, exist_ok=True)
        tmp = self.path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(self.data, f, indent=2, sort_keys=True)
            f.write("\n")
        os.chmod(tmp, 0o600)
        os.replace(tmp, self.path)


# ── credential store (the studio's /devkit-auth volume, via scripts/_cloud_auth.sh) ──

def store_cmd() -> list[str]:
    cmd = os.environ.get("CONNECT_CLOUD_STORE_CMD")
    if not cmd:
        raise Fail("CONNECT_CLOUD_STORE_CMD is not set — run this through scripts/connect-cloud.sh")
    return shlex.split(cmd)


def _store(op: str, *args: str, input_bytes: bytes | None = None) -> subprocess.CompletedProcess:
    try:
        return subprocess.run(store_cmd() + [op, *args], input=input_bytes, capture_output=True, timeout=120)
    except subprocess.TimeoutExpired:
        raise Fail(f"credential store '{op}' timed out — is the container runtime responsive?")


def store_volume() -> str:
    """The volume the running studio has mounted at /devkit-auth; a hard error when unknown."""
    p = _store("volume")
    if p.returncode != 0 or not p.stdout.strip():
        raise Fail("credential store unavailable: " + (p.stderr.decode(errors="replace").strip() or "unknown volume"))
    return p.stdout.decode().strip()


def store_write(rel: str, secret_bytes: bytes) -> None:
    p = _store("write", rel, input_bytes=secret_bytes)
    if p.returncode != 0:
        raise Fail(f"credential store write failed: {p.stderr.decode(errors='replace').strip() or p.returncode}")


def store_list() -> list[str]:
    p = _store("list")
    if p.returncode != 0:
        return []
    return [ln for ln in p.stdout.decode(errors="replace").splitlines() if ln.strip()]


# ── container snapshot (evidence that nothing restarted) ───────────────────────

def container_snapshot() -> dict:
    """{service: {"id":…, "startedAt":…}} for the studio and the agent, from the real containers.

    Services that are not running are reported as None so callers can refuse to make claims about them.
    """
    runtime = os.environ.get("RUNTIME")
    project = os.environ.get("CONNECT_CLOUD_PROJECT")
    out: dict = {svc: None for svc in SERVICES}
    if not runtime or not project:
        return out
    for svc in SERVICES:
        try:
            p = subprocess.run(
                [runtime, "ps", "-q", "--filter", f"label=com.docker.compose.project={project}",
                 "--filter", f"label=com.docker.compose.service={svc}"],
                capture_output=True, text=True, timeout=30)
            cid = p.stdout.strip().splitlines()[0] if p.returncode == 0 and p.stdout.strip() else ""
            if not cid:
                continue
            q = subprocess.run([runtime, "inspect", "--format", "{{.Id}} {{.State.StartedAt}}", cid],
                               capture_output=True, text=True, timeout=30)
            parts = q.stdout.strip().split(" ", 1) if q.returncode == 0 else []
            if len(parts) == 2 and parts[0] and parts[1]:
                out[svc] = {"id": parts[0], "startedAt": parts[1]}
        except (subprocess.TimeoutExpired, OSError):
            continue
    return out


def snapshot_complete(snap: dict) -> bool:
    return all(isinstance(snap.get(s), dict) and snap[s].get("id") and snap[s].get("startedAt") for s in SERVICES)


# ── preflight + apply: the shared platform-object chain ────────────────────────

def _cred_data(cred: dict) -> dict:
    return {d.get("key"): d.get("value") for d in cred.get("dataEx") or []}


def _owned_by_tool(obj: dict) -> bool:
    return ((obj.get("metaData") or {}).get("source")) == TOOL_SOURCE


def preflight_chain(studio: Studio, *, provider_name: str, provider_type: str, account_id: str,
                    credential_name: str, scope_name: str, region: str | None,
                    workspace: str | None, out: list[str]) -> dict:
    """Resolve every existing object and refuse every conflict. Reads only; returns the plan."""
    plan: dict = {"provider": None, "credential_action": None, "scope": None, "attach": False, "workspace": workspace}

    provider = studio.find_unique("Providers", provider_name)
    if provider is not None:
        existing_account = provider.get("accountId") or ""
        if (provider.get("type") or "").lower() != provider_type:
            raise Fail(f"provider '{provider_name}' exists with type '{provider.get('type')}', not '{provider_type}'. Use another --name.")
        if existing_account and existing_account != account_id:
            raise Fail(f"provider '{provider_name}' already exists for account '{existing_account}', but the credentials you "
                       f"supplied belong to '{account_id}'. Use a different --name (nothing was changed).")
        existing_cred = next((c for c in provider.get("credentials") or []
                              if (c.get("name") or "").lower() == credential_name.lower()), None)
        if existing_cred is not None:
            if not _owned_by_tool(existing_cred):
                raise Fail(f"credential '{credential_name}' on provider '{provider_name}' exists but was not created by "
                           f"connect-cloud (no metaData.source='{TOOL_SOURCE}'); refusing to overwrite it. Use another --name.")
            plan["credential_action"] = "rotate"
        else:
            plan["credential_action"] = "add"
        plan["provider"] = provider
    else:
        plan["credential_action"] = "create-with-provider"

    scope = studio.find_unique("Scopes", scope_name)
    if scope is not None:
        if provider is None or scope.get("providerId") != provider["id"]:
            raise Fail(f"scope '{scope_name}' already exists but belongs to provider '{scope.get('providerId')}', "
                       f"not to '{provider_name}'. Use another --name.")
        if not _owned_by_tool(scope):
            raise Fail(f"scope '{scope_name}' exists but was not created by connect-cloud; refusing to reuse it. Use another --name.")
        if (scope.get("credentialName") or "").lower() != credential_name.lower():
            raise Fail(f"scope '{scope_name}' uses credential '{scope.get('credentialName')}', not '{credential_name}'; "
                       "refusing to silently repoint it. Use another --name.")
        if region is not None:
            have = (scope.get("awsResourceSearchFilter") or {}).get("region") or ""
            if have != region:
                raise Fail(f"scope '{scope_name}' is pinned to region '{have}' but you asked for '{region}'. "
                           f"Re-run with --region {have}, or choose another --name for a {region} connection.")
        plan["scope"] = scope

    if workspace:
        ws = studio.get("Workspaces", workspace)
        if ws is None:
            raise Fail(f"workspace '{workspace}' does not exist (EXTENSION_DEV_WORKSPACE_ID stale? re-run ./run.sh, or pass --workspace)")
        plan["attach"] = scope is None or scope["id"] not in (ws.get("scopeIds") or [])
    return plan


def apply_chain(studio: Studio, plan: dict, *, provider_name: str, provider_type: str, account_id: str,
                description: str, credential: dict, scope_body: dict, out: list[str]) -> dict:
    """Perform the writes the preflight approved, in order. Each line says what happened — or, in
    --dry-run, what would have."""
    would = "would " if studio.dry_run else ""
    cred_name = credential["name"]
    if plan["credential_action"] == "create-with-provider":
        out.append(f"provider   {provider_name}: {would}create (type {provider_type}, account {account_id}) with credential {cred_name}")
        _, d = studio.write("POST", f"{ADMIN}/Providers", {
            "name": provider_name, "description": description, "type": provider_type, "category": "cloud",
            "accountId": account_id, "credentials": [credential], "metaData": {"source": TOOL_SOURCE}})
        provider_id = d["data"]["id"]
    else:
        provider_id = plan["provider"]["id"]
        out.append(f"provider   {provider_name}: reuse ({provider_id})")
        if plan["credential_action"] == "keep":
            out.append(f"credential {cred_name}: already in its final shape — unchanged")
        elif plan["credential_action"] == "rotate":
            out.append(f"credential {cred_name}: {would}update in place (rotation)")
            studio.write("PUT", f"{ADMIN}/Providers/{provider_id}/credentials/{urllib.parse.quote(cred_name)}", credential)
        else:
            out.append(f"credential {cred_name}: {would}add to the existing provider")
            studio.write("POST", f"{ADMIN}/Providers/{provider_id}/credentials", credential)

    if plan["scope"] is None:
        out.append(f"scope      {scope_body['name']}: {would}create")
        _, d = studio.write("POST", f"{ADMIN}/Scopes", dict(scope_body, providerId=provider_id, credentialName=cred_name,
                                                             metaData={"source": TOOL_SOURCE}))
        scope_id = d["data"]["id"]
    else:
        scope_id = plan["scope"]["id"]
        out.append(f"scope      {scope_body['name']}: reuse ({scope_id})")

    workspace = plan["workspace"]
    if workspace:
        if plan["attach"]:
            out.append(f"workspace  {workspace}: {would}attach scope")
            studio.write("POST", f"{ADMIN}/Workspaces/{workspace}/scopes/{scope_id}")
        else:
            out.append(f"workspace  {workspace}: scope already attached")
    else:
        out.append("workspace  (none) — the scope is NOT selectable by tickets until you attach it: "
                   f"POST {ADMIN}/Workspaces/<id>/scopes/{scope_id}")
    return {"providerId": provider_id, "scopeId": scope_id, "credentialName": cred_name,
            "credentialAction": plan["credential_action"], "workspaceId": workspace}


# ── AWS ────────────────────────────────────────────────────────────────────────

def _run(cmd: list[str], *, env: dict, timeout: int, what: str) -> subprocess.CompletedProcess:
    try:
        return subprocess.run(cmd, capture_output=True, text=True, env=env, timeout=timeout)
    except FileNotFoundError:
        raise Fail(f"'{cmd[0]}' is not installed or not on PATH (needed for: {what})")
    except subprocess.TimeoutExpired:
        raise Fail(f"{what} did not finish within {timeout}s (a credential_process waiting for a browser login? run it once by hand)")


def aws_resolve_profile(profile: str) -> dict:
    """Run the profile's credential chain ONCE (credential_process included) and keep the result in memory."""
    if not sys.stdin.isatty() and os.environ.get("CONNECT_CLOUD_ALLOW_NO_TTY") != "1":
        # duplo-jit's --interactive login needs a terminal; failing early beats a hung browser prompt.
        raise Fail("stdin is not a terminal: a credential_process such as duplo-jit may need to prompt. "
                   "Run from an interactive shell (or set CONNECT_CLOUD_ALLOW_NO_TTY=1 if the profile is cached).")
    env = dict(os.environ)
    for k in ("AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN"):
        env.pop(k, None)
    p = _run(["aws", "configure", "export-credentials", "--profile", profile, "--format", "process"],
             env=env, timeout=AWS_EXPORT_TIMEOUT, what=f"aws configure export-credentials --profile {profile}")
    if p.returncode != 0:
        raise Fail(f"aws configure export-credentials --profile {profile} failed: {p.stderr.strip()[:400]}")
    try:
        creds = json.loads(p.stdout)
    except ValueError:
        raise Fail("export-credentials did not return JSON")
    if not isinstance(creds, dict):
        raise Fail("export-credentials returned an unexpected JSON shape")
    for k in ("AccessKeyId", "SecretAccessKey"):
        if not creds.get(k):
            raise Fail(f"export-credentials returned no {k} for profile '{profile}'")
    return creds


def aws_identity(creds: dict, region: str) -> dict:
    env = dict(os.environ)
    env.pop("AWS_PROFILE", None)
    env.update({"AWS_ACCESS_KEY_ID": creds["AccessKeyId"], "AWS_SECRET_ACCESS_KEY": creds["SecretAccessKey"],
                "AWS_DEFAULT_REGION": region})
    if creds.get("SessionToken"):
        env["AWS_SESSION_TOKEN"] = creds["SessionToken"]
    else:
        env.pop("AWS_SESSION_TOKEN", None)
    p = _run(["aws", "sts", "get-caller-identity", "--output", "json"], env=env, timeout=AWS_STS_TIMEOUT,
             what="aws sts get-caller-identity")
    if p.returncode != 0:
        raise Fail(f"STS get-caller-identity rejected the resolved credentials: {p.stderr.strip()[:400]}")
    try:
        ident = json.loads(p.stdout)
    except ValueError:
        raise Fail("STS returned non-JSON output")
    if not isinstance(ident, dict) or not ident.get("Account"):
        raise Fail("STS returned no Account")
    return ident


def aws_credential_body(name: str, creds: dict) -> dict:
    data = [
        {"key": "accessKeyId", "value": creds["AccessKeyId"], "type": "string", "isSensitive": False},
        {"key": "secretAccessKey", "value": creds["SecretAccessKey"], "type": "secret", "isSensitive": True},
    ]
    if creds.get("SessionToken"):
        data.append({"key": "sessionToken", "value": creds["SessionToken"], "type": "secret", "isSensitive": True})
    return {"name": name, "dataEx": data, "metaData": {"source": TOOL_SOURCE, "updatedAt": now_iso()}}


def resolve_workspace(args) -> str | None:
    if getattr(args, "no_workspace", False):
        return None
    ws = args.workspace or os.environ.get("CONNECT_CLOUD_WORKSPACE_DEFAULT") or None
    if not ws:
        raise Fail("no workspace to attach the scope to: pass --workspace <id> (or set EXTENSION_DEV_WORKSPACE_ID in .env "
                   "by running ./run.sh). A scope not attached to a workspace is not selectable by any ticket; "
                   "use --no-workspace only if that is what you want.")
    return ws


def cmd_aws(args, studio: Studio, records: Records, out: list[str]) -> dict:
    check_name(args.name)
    workspace = resolve_workspace(args)
    creds = aws_resolve_profile(args.profile)
    ident = aws_identity(creds, args.region)
    out.append(f"identity   {ident.get('Arn')} (account {ident['Account']})")
    expiration = creds.get("Expiration")
    if expiration:
        out.append(f"expires    {expiration} (temporary credentials — re-run to reconnect; nothing renews them)")
    provider_name = f"aws-{args.name}"
    plan = preflight_chain(studio, provider_name=provider_name, provider_type="aws", account_id=ident["Account"],
                           credential_name=args.name, scope_name=args.name, region=args.region,
                           workspace=workspace, out=out)
    chain = apply_chain(
        studio, plan, provider_name=provider_name, provider_type="aws", account_id=ident["Account"],
        description=f"Dev-kit AWS connection '{args.name}' (profile {args.profile})",
        credential=aws_credential_body(args.name, creds),
        scope_body={"name": args.name, "description": f"AWS account {ident['Account']} via profile {args.profile}",
                    "awsResourceSearchFilter": {"region": args.region}},
        out=out)
    record = {"cloud": "aws", "name": args.name, "profile": args.profile, "region": args.region,
              "accountId": ident["Account"], "principalArn": ident.get("Arn"),
              "expiration": expiration, "updatedAt": now_iso(), **chain}
    if not studio.dry_run:
        records.put(args.name, record)
    return record


# ── GCP ────────────────────────────────────────────────────────────────────────

def http_json(url: str, *, data: dict | None = None, headers: dict | None = None, form: bool = False,
              method: str | None = None) -> tuple[int, dict | None]:
    body = None
    hdrs = dict(headers or {})
    if data is not None:
        if form:
            body = urllib.parse.urlencode(data).encode()
            hdrs["Content-Type"] = "application/x-www-form-urlencoded"
        else:
            body = json.dumps(data).encode()
            hdrs["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=body, headers=hdrs, method=method or ("POST" if body else "GET"))
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read().decode()
            status = resp.status
    except urllib.error.HTTPError as e:
        raw = e.read().decode(errors="replace")
        status = e.code
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        raise Fail(f"{url.split('?')[0]}: {getattr(e, 'reason', e)}")
    try:
        return status, json.loads(raw) if raw else None
    except ValueError:
        return status, {"raw": raw[:300]}


def login_command(exp: dict) -> str:
    """The login that writes the file the backend binds. Scoped with CLOUDSDK_CONFIG whenever the directory was
    not the plain default, because a bare login would write ~/.config/gcloud instead."""
    if str(exp.get("source") or "").startswith("default"):
        return "gcloud auth application-default login"
    return f"CLOUDSDK_CONFIG={shlex.quote(exp['dir'])} gcloud auth application-default login"


def gcp_read_adc(path: str, hint_dir: str | None = None, login: str = "gcloud auth application-default login") -> tuple[dict, str]:
    """Validate the host ADC file and return (fields, sha256 of its bytes). The hash is the file's fingerprint:
    it is compared with what the backend's own uid reads and recorded (hash only) to know when a new login has
    replaced the file. File bytes are never logged."""
    if not os.path.isfile(path):
        where = f" The backend reads it in place from {hint_dir} (bound read-only at {RUNTIME_MOUNT})." if hint_dir else ""
        raise Fail(f"ADC file not found: {path}\n    Run: {login}   — then re-run this command."
                   f"{where} connect-cloud never copies or moves ADC files. Nothing was changed.")
    with open(path, "rb") as f:
        raw = f.read()
    try:
        adc = json.loads(raw)
    except ValueError:
        raise Fail(f"{path} is not valid JSON")
    if not isinstance(adc, dict) or adc.get("type") != "authorized_user":
        raise Fail(f"{path} has type '{adc.get('type') if isinstance(adc, dict) else '?'}'; only an authorized_user "
                   "ADC file (gcloud auth application-default login) is supported on this keyless path. "
                   "Service-account keys and external_account files are deliberately not accepted.")
    extra = sorted(set(adc) - ADC_ALLOWED_KEYS)
    if extra:
        raise Fail(f"{path} carries unexpected fields {extra}; refusing to use it.")
    for k in ("client_id", "client_secret", "refresh_token"):
        if not adc.get(k):
            raise Fail(f"{path} is missing '{k}'")
    return adc, hashlib.sha256(raw).hexdigest()


def google_error(body) -> dict:
    """The typed parts of a Google API error body: canonical status, ErrorInfo reasons, consumer project."""
    out = {"status": "", "message": "", "reasons": [], "consumer": ""}
    err = body.get("error") if isinstance(body, dict) else None
    if not isinstance(err, dict):
        return out
    out["status"] = str(err.get("status") or "")
    out["message"] = str(err.get("message") or "")
    for d in err.get("details") or []:
        if not isinstance(d, dict):
            continue
        if d.get("reason"):
            out["reasons"].append(str(d["reason"]))
        meta = d.get("metadata")
        if isinstance(meta, dict) and meta.get("consumer"):
            out["consumer"] = str(meta["consumer"])
    return out


class ProofFailure(Fail):
    """The impersonation/bucket proof failed. `repairable` is True only for a typed missing-SA / missing-
    permission / disabled-API condition on the selected project — never for a revoked login, a network
    error or a 5xx, which no IAM change could fix."""

    NOT_IAM = {"ACCESS_TOKEN_SCOPE_INSUFFICIENT", "USER_PROJECT_DENIED", "CONSUMER_INVALID", "BILLING_DISABLED",
               "RATE_LIMIT_EXCEEDED", "RESOURCE_EXHAUSTED"}

    def __init__(self, msg: str, stage: str, status: int, body):
        super().__init__(msg)
        self.stage, self.status, self.info = stage, status, google_error(body)

    @property
    def repairable(self) -> bool:
        if self.stage not in ("impersonate", "buckets") or self.status not in (403, 404):
            return False
        if self.stage == "buckets" and self.status != 403:
            return False
        reasons = set(self.info["reasons"])
        if reasons & self.NOT_IAM:
            return False
        if "SERVICE_DISABLED" in reasons:
            return self.stage == "impersonate"        # a disabled Storage API is not ours to enable
        if self.status == 404:
            return True                               # not-found is only a hint; the bootstrap looks the account up
        return self.info["status"] in ("", "PERMISSION_DENIED")


def gcp_user_token(adc: dict) -> str:
    """Refresh the ADC refresh token into a short-lived access token (kept in memory, sent only in Authorization)."""
    status, tok = http_json(GOOGLE_TOKEN_URL, form=True, data={
        "grant_type": "refresh_token", "client_id": adc["client_id"],
        "client_secret": adc["client_secret"], "refresh_token": adc["refresh_token"]})
    if status != 200 or not isinstance(tok, dict) or not tok.get("access_token"):
        raise ProofFailure(f"the ADC refresh token was rejected by Google (HTTP {status}: {describe_error(tok, '')}). "
                           "Re-run: gcloud auth application-default login", "adc", status, tok)
    return tok["access_token"]


def gcp_prove_impersonation(adc: dict, sa: str, project: str) -> dict:
    """The exact chain the studio performs with this file: refresh → generateAccessToken(sa) → GCS list.

    Returns the principal label and the full (paginated) bucket name list; never the tokens.
    """
    user_token = gcp_user_token(adc)
    status, imp = http_json(
        f"{GOOGLE_IAM_URL}/projects/-/serviceAccounts/{urllib.parse.quote(sa)}:generateAccessToken",
        headers={"Authorization": "Bearer " + user_token},
        data={"scope": [CLOUD_PLATFORM_SCOPE], "lifetime": "600s"})
    if status != 200 or not isinstance(imp, dict) or not imp.get("accessToken"):
        raise ProofFailure(
            f"this ADC identity cannot impersonate {sa} (HTTP {status}: {describe_error(imp, '')}).\n"
            f"    It needs roles/iam.serviceAccountTokenCreator ON that service account, the account must exist, and "
            f"iamcredentials.googleapis.com must be enabled. A 403/404 alone does not say which.",
            "impersonate", status, imp)
    sa_token = imp["accessToken"]
    names: list[str] = []
    page_token = None
    for _ in range(100):  # 100 pages × 1000 = plenty; never loop forever on a misbehaving server
        q = {"project": project, "maxResults": "1000", "fields": "items/name,nextPageToken"}
        if page_token:
            q["pageToken"] = page_token
        status, buckets = http_json(f"{GOOGLE_STORAGE_URL}/b?{urllib.parse.urlencode(q)}",
                                    headers={"Authorization": "Bearer " + sa_token})
        if status != 200 or not isinstance(buckets, dict):
            raise ProofFailure(f"{sa} could mint a token but cannot list buckets in '{project}' (HTTP {status}: "
                               f"{describe_error(buckets, '')}). It needs a read-only role on the project "
                               "(roles/viewer or roles/storage.objectViewer + a bucket-list permission).",
                               "buckets", status, buckets)
        names.extend(i.get("name", "") for i in buckets.get("items") or [])
        page_token = buckets.get("nextPageToken")
        if not page_token:
            break
    else:
        raise Fail("bucket listing did not terminate after 100 pages; refusing to trust the count")
    return {"principal": adc.get("account") or "(ADC user)", "buckets": len(names), "bucketNames": sorted(names)}


EMAIL_RE = re.compile(r"^[A-Za-z0-9._%+'-]{1,64}@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$")


def gcp_verified_email(user_token: str) -> str:
    """The real caller behind the refreshed ADC token, from Google's authenticated userinfo endpoint.

    adc.account and gcloud's active account are never consulted: neither proves who the token belongs to."""
    relogin = ("Re-run: gcloud auth application-default login (the login must include the email scope; "
               "gcloud's default ADC login does). No IAM change was made.")
    status, info = http_json(GOOGLE_USERINFO_URL, headers={"Authorization": "Bearer " + user_token})
    if status in (401, 403):
        raise Fail(f"Google would not tell this tool who the ADC token belongs to (userinfo HTTP {status}): the token "
                   f"has no email scope. {relogin}")
    if status != 200 or not isinstance(info, dict):
        raise Fail(f"could not resolve the ADC identity (userinfo HTTP {status}); refusing to guess who to grant. "
                   "No IAM change was made.")
    email = info.get("email")
    if info.get("email_verified") not in (True, "true") or not isinstance(email, str) or not email:
        raise Fail(f"Google returned no verified email for the ADC token. {relogin}")
    if not EMAIL_RE.fullmatch(email) or email.lower().endswith(".gserviceaccount.com"):
        raise Fail("the ADC identity is not a plain user email (it is malformed or a service account); refusing to "
                   "bind IAM to it. This path supports authorized_user ADC only. No IAM change was made.")
    return email


class GcpBootstrap:
    """Prepare the derived helpdesk-sa in the SELECTED project — nothing else — after the proof failed with a
    typed, repairable condition. Everything is read first and written only when needed:

      * enable iam + iamcredentials on the selected project if disabled (Service Usage, tracked operation);
      * create/reuse helpdesk-sa (a disabled one stops the run);
      * grant the verified ADC user roles/iam.serviceAccountTokenCreator ON that service account only;
      * grant that service account roles/viewer ON the selected project only (read-only diagnostics).

    No Owner/Editor, no keys, no deletes, no other project, no other principal. Policies are read at
    version 3 and written back whole (etag, conditional bindings and auditConfigs preserved) with at most
    one unconditional membership appended. TokenCreator lets the user mint the SA's token; it does not by
    itself give the SA access to anything — the viewer grant is what the read-only listing relies on.
    """

    def __init__(self, adc: dict, project: str, sa: str, out: list[str], changes: list[str]):
        self.adc, self.project, self.sa, self.out, self.changes = adc, project, sa, out, changes
        self.sa_url = f"{GOOGLE_IAM_ADMIN_URL}/projects/{project}/serviceAccounts/{urllib.parse.quote(sa, safe='')}"
        self.fresh_apis = False

    def say(self, line: str) -> None:
        self.out.append("bootstrap  " + line)

    def done(self, line: str) -> None:
        self.changes.append(line)
        self.say(line)

    @staticmethod
    def _auth(token: str) -> dict:
        return {"Authorization": "Bearer " + token}

    @staticmethod
    def _sleep() -> None:
        if PROPAGATION_INTERVAL:
            time.sleep(PROPAGATION_INTERVAL)

    def _denied(self, what: str, status: int, body) -> Fail:
        gerr = google_error(body)
        hint = ("this is a permission problem for the ADC user, not something to retry or work around; an IAM/project "
                "admin has to make the change" if status == 403 else "unexpected response")
        return Fail(f"cannot {what} (HTTP {status}: {describe_error(body, '')}); {hint}.")

    def run(self, failure: ProofFailure) -> dict:
        token = gcp_user_token(self.adc)
        if failure.stage == "impersonate":
            email = gcp_verified_email(token)          # BEFORE any write: a bad identity changes nothing
            self.say(f"ADC identity (Google userinfo, verified): {email}")
            number = self.project_number(token)
            consumer = failure.info["consumer"]
            if consumer and consumer != f"projects/{number}":
                raise Fail(f"the API is disabled on {consumer}, which is not the selected project '{self.project}' "
                           f"(projects/{number}). That is the ADC quota project; connect-cloud does not change other "
                           "projects. Fix the quota project (gcloud auth application-default set-quota-project) or enable "
                           "the API there yourself. No IAM change was made.")
            for api in BOOTSTRAP_APIS:
                self.ensure_api(token, number, api)
            self.ensure_service_account(token)
            # serviceAccounts.getIamPolicy: POST, options in the QUERY, EMPTY body (IAM v1 reference)
            self.grant(token, f"{self.sa_url}:getIamPolicy?options.requestedPolicyVersion=3", f"{self.sa_url}:setIamPolicy",
                       ROLE_TOKEN_CREATOR, "user:" + email, f"{ROLE_TOKEN_CREATOR} to {email} on {self.sa}", get_body=None)
        self.grant(token, f"{GOOGLE_CRM_URL}/projects/{self.project}:getIamPolicy",
                   f"{GOOGLE_CRM_URL}/projects/{self.project}:setIamPolicy", ROLE_VIEWER,
                   "serviceAccount:" + self.sa, f"{ROLE_VIEWER} to {self.sa} on project {self.project}",
                   get_body={"options": {"requestedPolicyVersion": 3}})     # projects.getIamPolicy: POST, options in body
        return self.reprove(failure, applied=bool(self.changes))

    # -- project / APIs --
    def project_number(self, token: str) -> str:
        status, d = http_json(f"{GOOGLE_CRM_URL}/projects/{self.project}", headers=self._auth(token))
        if status != 200 or not isinstance(d, dict):
            raise self._denied(f"read the metadata of project '{self.project}'", status, d)
        if d.get("projectId") != self.project or not str(d.get("projectNumber") or "").isdigit():
            raise Fail(f"project metadata for '{self.project}' is malformed or names another project; refusing to continue.")
        return str(d["projectNumber"])

    def ensure_api(self, token: str, number: str, api: str) -> None:
        base = f"{GOOGLE_SERVICEUSAGE_URL}/projects/{number}/services/{api}"
        status, d = http_json(base, headers=self._auth(token))
        if status != 200 or not isinstance(d, dict):
            raise self._denied(f"read the state of {api} on project '{self.project}'", status, d)
        if d.get("state") == "ENABLED":
            self.say(f"{api}: already enabled")
            return
        status, op = http_json(base + ":enable", headers=self._auth(token), data={})
        if status != 200 or not isinstance(op, dict):
            raise self._denied(f"enable {api} on project '{self.project}'", status, op)
        name = str(op.get("name") or "")
        polls = 0
        while not op.get("done"):                      # a result seen on the LAST allowed poll still counts
            if not name.startswith("operations/"):
                raise Fail(f"enabling {api} returned no trackable operation; state unknown.")
            if polls >= PROPAGATION_ATTEMPTS:
                raise Fail(f"enabling {api} did not complete within {PROPAGATION_ATTEMPTS} polls (operation {name}); "
                           "it may still finish — re-run later.")
            self._sleep()
            polls += 1
            status, op = http_json(f"{GOOGLE_SERVICEUSAGE_URL}/{name}", headers=self._auth(token))
            if status != 200 or not isinstance(op, dict):
                raise self._denied(f"track the operation enabling {api}", status, op)
        if op.get("error"):
            raise Fail(f"enabling {api} failed: {str(op['error'])[:300]}")
        self.fresh_apis = True
        self.done(f"enabled {api} on project {self.project}")

    # -- service account --
    def lookup_sa(self, token: str) -> dict | None:
        for attempt in range(PROPAGATION_ATTEMPTS):
            status, d = http_json(self.sa_url, headers=self._auth(token))
            if status == 200 and isinstance(d, dict):
                return d
            if status == 404:
                return None                            # an actual 404 from the IAM API, not from generateAccessToken
            if self.fresh_apis and "SERVICE_DISABLED" in google_error(d)["reasons"] and attempt + 1 < PROPAGATION_ATTEMPTS:
                self._sleep()                          # the API we just enabled is still propagating
                continue
            raise self._denied(f"look up service account {self.sa}", status, d)
        raise Fail(f"service account lookup for {self.sa} kept failing while the API propagated.")

    def _check_enabled(self, sa_obj: dict) -> None:
        if sa_obj.get("disabled"):
            raise Fail(f"service account {self.sa} exists but is DISABLED; refusing to enable or use it. Enable it "
                       "yourself or choose another --service-account.")
        if sa_obj.get("email") and sa_obj["email"] != self.sa:
            raise Fail(f"IAM returned service account '{sa_obj['email']}' for {self.sa}; refusing to continue.")

    def ensure_service_account(self, token: str) -> None:
        existing = self.lookup_sa(token)
        if existing is None:
            status, d = http_json(
                f"{GOOGLE_IAM_ADMIN_URL}/projects/{self.project}/serviceAccounts", headers=self._auth(token),
                data={"accountId": SA_ACCOUNT_ID, "serviceAccount": {
                    "displayName": "DuploCloud dev kit helpdesk (read-only)",
                    "description": "Impersonated by the dev kit connect-cloud ADC connection; read-only (roles/viewer)."}})
            if status in (200, 201) and isinstance(d, dict):
                self._check_enabled(d)
                self.done(f"created service account {self.sa}")
                return
            if status != 409:
                raise self._denied(f"create service account {self.sa}", status, d)
            existing = self.lookup_sa(token)           # lost a create race (or it exists after all): re-look-up
            if existing is None:
                raise Fail(f"creating {self.sa} reported a conflict but it cannot be found (a recently deleted account "
                           "keeps its ID reserved for a while). Choose another --service-account or retry later.")
        self._check_enabled(existing)
        self.say(f"service account {self.sa}: exists, reused")

    # -- IAM policy merge --
    def grant(self, token: str, get_url: str, set_url: str, role: str, member: str, label: str, *, get_body: dict | None) -> None:
        for attempt in range(IAM_WRITE_ATTEMPTS):
            status, pol = self._retry_not_found(lambda: http_json(
                get_url, headers=self._auth(token), data=get_body, method="POST"))
            if status != 200 or not isinstance(pol, dict):
                raise self._denied(f"read the IAM policy to grant {label}", status, pol)
            bindings = pol.get("bindings") or []
            if any(b.get("role") == role and not b.get("condition")
                   and member.lower() in [str(m).lower() for m in b.get("members") or []] for b in bindings):
                self.say(f"{label}: already granted")
                return
            if not pol.get("etag"):                    # Google always returns one; without it a write would overwrite blindly
                raise Fail(f"the IAM policy read to grant {label} carried no etag; refusing to write it back because that "
                           "could overwrite a concurrent change. Nothing was written for this grant; re-run.")
            new = json.loads(json.dumps(pol))          # everything else (etag, auditConfigs, conditions) is kept verbatim
            new["version"] = max(3, int(pol.get("version") or 0))
            target = next((b for b in new.setdefault("bindings", []) if b.get("role") == role and not b.get("condition")), None)
            if target is None:
                new["bindings"].append({"role": role, "members": [member]})
            else:
                target.setdefault("members", []).append(member)
            status, d = self._retry_not_found(lambda: http_json(set_url, headers=self._auth(token), data={"policy": new}))
            if status == 200:
                self.done(f"granted {label}")
                return
            if status in (409, 412):
                self.say(f"{label}: policy changed concurrently (HTTP {status}); re-reading ({attempt + 1}/{IAM_WRITE_ATTEMPTS})")
                continue
            raise self._denied(f"grant {label}", status, d)
        raise Fail(f"could not grant {label}: the policy kept changing under us ({IAM_WRITE_ATTEMPTS} attempts). Nothing "
                   "was overwritten; re-run when the policy is stable.")

    def _retry_not_found(self, call):
        """A just-created service account may not be visible to the IAM policy API yet: bounded retry on not-found only."""
        for attempt in range(PROPAGATION_ATTEMPTS):
            status, d = call()
            missing = status == 404 or (status == 400 and "does not exist" in describe_error(d, "").lower())
            if not (missing and any(c.startswith("created service account") for c in self.changes)) \
                    or attempt + 1 == PROPAGATION_ATTEMPTS:
                return status, d
            self._sleep()
        return status, d

    # -- validate again, with bounded propagation polling --
    def reprove(self, failure: ProofFailure, applied: bool) -> dict:
        for attempt in range(PROPAGATION_ATTEMPTS):
            try:
                return gcp_prove_impersonation(self.adc, self.sa, self.project)
            except ProofFailure as e:
                if e.stage in ("impersonate", "buckets") and e.status in (403, 404) and attempt + 1 < PROPAGATION_ATTEMPTS:
                    self.say(f"waiting for IAM propagation ({attempt + 1}/{PROPAGATION_ATTEMPTS}): HTTP {e.status}")
                    self._sleep()
                    continue
                if applied:
                    raise Fail(f"the bootstrap changes were applied but the proof still fails after {attempt + 1} "
                               f"attempt(s): {e}")
                raise Fail(f"{failure}\n    The bootstrap found the APIs, the service account and both grants already in "
                           f"place and changed nothing, yet the proof still fails after {attempt + 1} attempt(s): {e}\n"
                           "    The cause is not proven: it may be slow IAM propagation, an organization policy, a deny "
                           "policy, or a condition on a binding.")
        raise AssertionError("unreachable")


# ── GCP runtime: the backend's native ADC (mount + env + the backend uid's read access + cache lifetime) ──

def gcp_cmd() -> list[str]:
    cmd = os.environ.get("CONNECT_CLOUD_GCP_CMD")
    if not cmd:
        raise Fail("CONNECT_CLOUD_GCP_CMD is not set — run this through scripts/connect-cloud.sh")
    return shlex.split(cmd)


def say_now(line: str) -> None:
    """An announcement made BEFORE the action it describes (the final report is printed at the end)."""
    print("    " + line, file=sys.stderr, flush=True)


class GcpRuntime:
    """The GCP runtime helper (scripts/_gcp_auth.sh), one JSON object per call. Nothing else in this file touches
    the container runtime for GCP. A non-zero exit is a failure to answer, never an answer."""

    def call(self, op: str) -> dict:
        timeout = GCP_OP_TIMEOUT if op in ("reconcile", "restart") else 180
        try:
            p = subprocess.run(gcp_cmd() + [op], capture_output=True, text=True, timeout=timeout)
        except subprocess.TimeoutExpired:
            raise Fail(f"the GCP runtime helper '{op}' did not finish within {timeout}s — is the container runtime responsive?")
        except OSError as e:
            raise Fail(f"the GCP runtime helper could not run: {e}")
        if p.returncode != 0:
            raise Fail(f"GCP runtime '{op}' failed: " + (p.stderr.strip()[-600:] or f"exit {p.returncode}"))
        try:
            d = json.loads(p.stdout)
        except ValueError:
            raise Fail(f"the GCP runtime helper '{op}' returned no JSON")
        if not isinstance(d, dict):
            raise Fail(f"the GCP runtime helper '{op}' returned an unexpected shape")
        return d

    def expected(self) -> dict:
        d = self.call("dir")
        if not d.get("dir") or not str(d["dir"]).startswith("/"):
            raise Fail("the GCP runtime helper returned no absolute gcloud directory")
        d["file"] = d.get("file") or os.path.join(d["dir"], RUNTIME_ADC_FILE)
        return d


def _norm_path(path) -> str:
    p = str(path or "")
    if p.startswith("/host_mnt/"):                      # Docker Desktop's view of a host path
        p = p[len("/host_mnt"):]
    return os.path.realpath(p) if p else ""


def wiring_problems(info: dict, expected_dir: str) -> list[str]:
    """What is wrong with the RUNNING backend's native-ADC wiring (empty list = wired as docker-compose.yml says).
    Only the mount and the one environment variable are consulted."""
    probs: list[str] = []
    m = info.get("mount") or {}
    if not m.get("present"):
        probs.append(f"the running backend has no {RUNTIME_MOUNT} mount (it predates this design or was started by another compose file)")
    else:
        if _norm_path(m.get("source")) != _norm_path(expected_dir):
            probs.append(f"{RUNTIME_MOUNT} is bound from {m.get('source')}, not from {expected_dir}")
        if m.get("readOnly") is not True:
            probs.append(f"{RUNTIME_MOUNT} is not mounted read-only")
    have = (info.get("env") or {}).get(RUNTIME_ENV)
    if have != RUNTIME_ENV_VALUE:
        probs.append(f"{RUNTIME_ENV} is {'unset' if not have else 'set to ' + str(have)} in the backend, not {RUNTIME_ENV_VALUE}")
    return probs


def probe_failure(probe: dict, host_hash: str | None, exp: dict) -> str | None:
    """None when the backend's exact uid can read the exact file the host proof used; else the specific reason."""
    state = probe.get("state")
    who = f"{probe.get('user') or 'root (no user set)'} (uid:gid {probe.get('uid')})"
    if state == "ok":
        if probe.get("type") != "authorized_user":
            return (f"the file the backend reads at {RUNTIME_ENV_VALUE} is not an authorized_user ADC file; "
                    "run `gcloud auth application-default login` and re-run")
        if host_hash is not None and probe.get("sha256") != host_hash:
            return (f"the backend reads a DIFFERENT file than the host proof used (sha256 differs: backend "
                    f"{str(probe.get('sha256'))[:12]}…, host {host_hash[:12]}…). The runtime is bound from another "
                    f"directory, or a login is replacing the file right now; re-run once it finishes. No registration was written.")
        return None
    if state in ("dir-not-traversable", "unreadable"):
        what = ("the directory itself (no search permission)" if state == "dir-not-traversable"
                else f"{RUNTIME_ADC_FILE}")
        return (f"PERMISSIONS: the backend's user {who} cannot read {what} inside {RUNTIME_MOUNT} (host {exp['dir']}). "
                "A native gcloud directory is typically mode 0700 / the ADC file 0600 owned by you, which another uid "
                "cannot read on native Linux. connect-cloud never loosens permissions, changes ownership or runs the "
"backend as root, and does not claim this is solved on every host (only Docker Desktop has been verified; native "
                "Linux and rootless podman may need uid mapping or an ACL). Treat it as a real exception and decide yourself: "
                "point DEVKIT_GCLOUD_DIR at a directory that uid can read, or grant that one uid read access on the directory "
                "and the file (e.g. a POSIX ACL), then re-run. No registration was written.")
    if state == "missing":
        return (f"the backend does not see {RUNTIME_ADC_FILE} in {RUNTIME_MOUNT} (host {exp['dir']}). If you have not "
                "logged in, run `" + login_command(exp) + "`, then re-run — this tool never copies the "
                "file. Otherwise the running backend is bound from a different directory than the one selected.")
    if state == "no-mount":
        return f"{RUNTIME_MOUNT} does not exist in the backend container (the mount is missing)"
    if state == "not-regular":
        return f"{RUNTIME_ENV_VALUE} is not a regular file in the backend (a dangling or special link?)"
    if state == "user-unresolved":
        return (f"cannot determine the backend's exact uid:gid (user '{probe.get('user')}' has no readable /etc/passwd entry "
                "in its image), so readability by that user cannot be proven; refusing to guess or to probe as root")
    return f"the readability probe could not run ({probe.get('detail') or state}); the runtime file is unproven"


class GcpRuntimeState:
    """PRIVATE, hash-only record of what the running backend's process-lifetime ADC cache could have seen:
    the sha256 of the ADC file, the backend's container id + start marker, the directory. No file bytes, no
    tokens, no identity. It is how a repeat or a new-target connection avoids a restart and a re-login
    does not."""

    def __init__(self, path: str):
        self.path = path

    def load(self) -> dict:
        try:
            with open(self.path) as f:
                d = json.load(f)
            return d if isinstance(d, dict) else {}
        except (OSError, ValueError):
            return {}

    def save(self, *, fingerprint: str, info: dict, directory: str) -> None:
        d = os.path.dirname(self.path)
        if d:
            os.makedirs(d, mode=0o700, exist_ok=True)
        tmp = self.path + ".tmp"
        with open(tmp, "w") as f:
            json.dump({"version": 1, "adcFingerprint": fingerprint, "backendId": info.get("containerId"),
                       "startedAt": info.get("startedAt"), "dir": directory, "updatedAt": now_iso()}, f, indent=2, sort_keys=True)
            f.write("\n")
        os.chmod(tmp, 0o600)
        os.replace(tmp, self.path)

    def cache_reason(self, fingerprint: str, info: dict) -> str | None:
        """Why the backend's cached Google credential lookup can no longer be trusted — None when it can."""
        rec = self.load()
        if not rec:
            return "first native ADC connection: the backend may already have cached a failed (missing-ADC) or older lookup"
        if rec.get("adcFingerprint") != fingerprint:
            return "the ADC file changed since the backend last started (a new login): its process-lifetime cache holds the old credential"
        if rec.get("backendId") != info.get("containerId") or rec.get("startedAt") != info.get("startedAt"):
            return "the backend was restarted since this tool last recorded it, so what it cached is unknown"
        return None


def gcp_state(records: "Records") -> GcpRuntimeState:
    return GcpRuntimeState(os.environ.get("CONNECT_CLOUD_GCP_STATE")
                           or os.path.join(os.path.dirname(records.path) or ".", "gcp-runtime.json"))


def resolve_adc_source(adc_source: str | None, exp: dict) -> str:
    """The ADC file used for the proof is the one the backend binds. --adc-source may only NAME that file."""
    native = exp["file"]
    if not adc_source:
        return native
    given = os.path.abspath(adc_source)
    if os.path.realpath(given) != os.path.realpath(native):
        raise Fail(f"--adc-source {given} is not the file the running backend reads. The backend binds the whole directory "
                   f"{exp['dir']} (from {exp.get('source')}) and uses {native}; there are no per-connection ADC files, "
                   "so a different identity would be proven here and never used by the backend. Nothing was changed.\n"
                   f"    To use that file anyway, make its directory the one the backend binds: set DEVKIT_GCLOUD_DIR="
                   f"{os.path.dirname(given)} in .env (the file must be named {RUNTIME_ADC_FILE}); the next run recreates "
                   "only the backend with that mount. Or omit --adc-source.")
    return native


def gcp_runtime_precheck(rt: GcpRuntime, exp: dict, host_hash: str, out: list[str], dry_run: bool) -> dict:
    """READ-ONLY runtime checks that must pass before any local write or cloud bootstrap: the backend is running,
    and when it is already wired, its exact uid can read the exact file the host proof will use."""
    info = rt.call("inspect")
    if not info.get("running"):
        raise Fail(f"the backend ({info.get('service', 'duplo-ai-studio')}) is not running in compose project "
                   f"'{info.get('project') or os.environ.get('CONNECT_CLOUD_PROJECT')}'. Start the stack (./run.sh) and re-run; "
                   "nothing was changed.")
    problems = wiring_problems(info, exp["dir"])
    ctx = {"info": info, "problems": problems, "probe": None}
    if problems:
        out.append("runtime    backend wiring: " + "; ".join(problems))
    else:
        out.append(f"runtime    backend mounts {exp['dir']} read-only at {RUNTIME_MOUNT} and sets {RUNTIME_ENV}")
        if dry_run:
            out.append("runtime    readability by the backend uid: not probed in --dry-run")
        else:
            ctx["probe"] = rt.call("probe")
            msg = probe_failure(ctx["probe"], host_hash, exp)
            if msg:
                raise Fail(msg)
            out.append(f"runtime    the backend's uid ({ctx['probe'].get('uid')}) reads {RUNTIME_ADC_FILE}: same file as the host proof")
    return ctx


def _verify_runtime(rt: GcpRuntime, exp: dict, host_hash: str, after: str) -> tuple[dict, dict]:
    """Re-inspect and re-probe the RUNNING backend: still wired, and its exact uid reads the exact file (same sha256)
    the host proof used. Run after every recreate/restart and before the state is written, so an ADC replaced
    mid-run (or unreadable after a restart) fails instead of being recorded as ready."""
    info = rt.call("inspect")
    if not info.get("running"):
        raise Fail(f"the backend is not running after {after}; nothing was registered")
    problems = wiring_problems(info, exp["dir"])
    if problems:
        raise Fail(f"the backend's wiring is still wrong after {after}: " + "; ".join(problems) +
                   ". A COMPOSE_FILE / override in .env may replace the studio's volumes or environment. No registration was written.")
    probe = rt.call("probe")
    msg = probe_failure(probe, host_hash, exp)
    if msg:
        raise Fail(f"after {after}: {msg}")
    return info, probe


def gcp_runtime_apply(rt: GcpRuntime, ctx: dict, state: GcpRuntimeState, exp: dict, host_hash: str,
                      out: list[str], dry_run: bool) -> dict:
    """Make the running backend able to use the selected ADC: recreate it (backend only) if the wiring is absent or
    misaligned, reset the process-lifetime ADC cache (one backend-only restart) only when the record says it can be
    stale, and ALWAYS finish by re-verifying wiring + the backend uid's read of the host-proven file before the state
    is recorded. Returns what it did; "verified" is True only when the runtime was actually probed this run."""
    res = {"recreated": False, "restarted": False, "reason": None, "verified": False}
    info = ctx["info"]
    if ctx["problems"]:
        res["reason"] = "wiring"
        if dry_run:
            out.append(f"runtime    would create {exp['dir']} if missing and recreate ONLY the backend "
                       "(compose up -d --no-deps --no-build --pull never duplo-ai-studio); that fresh process also resets its ADC cache")
            return res
        say_now(f"backend wiring is not in place ({'; '.join(ctx['problems'])}) — recreating ONLY the backend now")
        rt.call("reconcile")
        res["recreated"] = True
        info, probe = _verify_runtime(rt, exp, host_hash, "the recreate")
        out.append(f"runtime    recreated the backend only; its uid ({probe.get('uid')}) reads {RUNTIME_ADC_FILE}: same file as the host proof")
    else:
        reason = state.cache_reason(host_hash, info)
        if dry_run:
            out.append(("runtime    would restart ONLY the backend: " + reason) if reason else
                       "runtime    the backend's ADC cache matches this ADC file (recorded): no restart needed")
            res["reason"] = reason
            return res
        if reason:
            res["reason"] = reason
            say_now("restarting ONLY the backend: " + reason)
            rt.call("restart")
            res["restarted"] = True
            out.append("runtime    restarted the backend only (its Google client caches the first credential lookup for the life of the process)")
            info, probe = _verify_runtime(rt, exp, host_hash, "the restart")
            out.append(f"runtime    after the restart its uid ({probe.get('uid')}) reads the same file as the host proof")
        else:
            out.append("runtime    the backend's ADC cache matches this ADC file (recorded): no restart needed")
            info, probe = _verify_runtime(rt, exp, host_hash, "the final check")
    res["verified"] = True
    state.save(fingerprint=host_hash, info=info, directory=exp["dir"])
    return res


def gcp_runtime_checks(rt: GcpRuntime, state: GcpRuntimeState, exp: dict, host_hash: str | None) -> tuple[dict, list[str]]:
    """READ-ONLY runtime proof for verify/status: separate facts, no ticket claim."""
    checks: dict = {}
    info = rt.call("inspect")
    running = bool(info.get("running"))
    problems = wiring_problems(info, exp["dir"]) if running else ["the backend is not running"]
    checks["runtimeBackendRunning"] = running
    checks["runtimeMountAndEnv"] = running and not problems
    checks["runtimeFileReadable"] = False
    checks["runtimeSourceAligned"] = False
    checks["runtimeCacheCurrent"] = False
    messages = list(problems)
    if running and not problems:
        probe = rt.call("probe")
        checks["runtimeFileReadable"] = probe.get("state") == "ok" and probe.get("type") == "authorized_user"
        if not checks["runtimeFileReadable"]:
            messages.append(probe_failure(probe, host_hash, exp) or "unreadable")
        else:
            checks["runtimeSourceAligned"] = host_hash is not None and probe.get("sha256") == host_hash
            if not checks["runtimeSourceAligned"]:
                messages.append(probe_failure(probe, host_hash, exp) or "the host ADC file is unreadable or differs from the backend's")
        checks["runtimeCacheCurrent"] = host_hash is not None and state.cache_reason(host_hash, info) is None
        if host_hash is not None and not checks["runtimeCacheCurrent"]:
            messages.append("the backend's ADC cache is not known to match this ADC file ("
                            + str(state.cache_reason(host_hash, info)) + "): run `connect-cloud.sh refresh --name <name>` "
                            "(or the gcp command again) — it restarts only the backend")
    return checks, messages


GCP_PROJECT_RE = re.compile(r"^[a-z][a-z0-9-]{4,28}[a-z0-9]$")


def check_gcp_project(project: str) -> None:
    if not GCP_PROJECT_RE.fullmatch(project or ""):
        raise Fail(f"--project '{project}' is not a GCP project ID (6-30 chars of [a-z0-9-], starting with a "
                   "letter, not ending with a hyphen). Nothing was changed.")


def cmd_gcp(args, studio: Studio, records: Records, out: list[str]) -> dict:
    check_gcp_project(args.project)
    # Project-only form: name defaults to the project ID, service account to helpdesk-sa@<project>.
    # Each default applies independently, so an explicit --name or --service-account is always kept.
    derived_sa = f"helpdesk-sa@{args.project}.iam.gserviceaccount.com"
    from_record = getattr(args, "from_record", False)          # refresh: the recorded identity is kept as-is
    explicit_other = bool(args.service_account) and args.service_account != derived_sa    # the derived default spelled out still bootstraps
    keep_reason = ("it was given with --service-account" if explicit_other and not from_record else
                   "--no-bootstrap was given" if getattr(args, "no_bootstrap", False) else
                   f"refresh keeps the recorded identity; re-run `connect-cloud.sh gcp --project {args.project}` to prepare it"
                   if from_record else None)
    args.name = args.name or args.project
    args.service_account = args.service_account or derived_sa
    check_name(args.name)
    workspace = resolve_workspace(args)
    sa = args.service_account
    if not re.match(r"^[a-z0-9-]+@[a-z0-9-]+\.iam\.gserviceaccount\.com$", sa):
        raise Fail(f"--service-account '{sa}' is not a service-account email")
    bootstrap_ok = keep_reason is None and sa == derived_sa

    # The ADC file is the NATIVE one: the file inside the directory the backend binds (scripts/_runtime.sh is the
    # single resolver). --adc-source may only name that exact file.
    rt = GcpRuntime()
    exp = rt.expected()
    adc_path = resolve_adc_source(args.adc_source, exp)
    adc, host_hash = gcp_read_adc(adc_path, hint_dir=exp["dir"], login=login_command(exp))
    out.append(f"adc        {adc_path} (source: {exp.get('source')}) — the backend reads this file in place; nothing is copied")

    # Everything LOCAL that can conflict is checked here — before any Google call that could write IAM,
    # any container change, or any platform object. Reads only.
    provider_name = f"gcp-{args.name}"
    plan = preflight_chain(studio, provider_name=provider_name, provider_type="gcp", account_id=args.project,
                           credential_name=args.name, scope_name=args.name, region=None,
                           workspace=workspace, out=out)
    existing_cred = next((c for c in (plan["provider"] or {}).get("credentials") or []
                          if (c.get("name") or "").lower() == args.name.lower()), None)
    if existing_cred is not None:
        have_sa = _cred_data(existing_cred).get("cloudRoleToAssume") or ""
        if have_sa and have_sa != sa:
            raise Fail(f"connection '{args.name}' already impersonates '{have_sa}', not '{sa}'. "
                       "Use another --name for a different service account (nothing was changed).")
        keys = {d.get("key") for d in existing_cred.get("dataEx") or []}
        if plan["credential_action"] == "rotate":
            if keys == {"cloudRoleToAssume"} and _cred_data(existing_cred).get("cloudRoleToAssume") == sa:
                plan["credential_action"] = "keep"          # already native-shaped: a re-run writes nothing
            elif "adcRef" in keys:
                out.append("migrate    this credential carries a legacy adcRef (ignored by the published backend); it is rewritten "
                           "in place to cloudRoleToAssume only. The old named store data is left untouched for rollback.")

    # Runtime checks (read-only) before any write; the backend must be up and, if already wired, able to read the file.
    state = gcp_state(records)
    ctx = gcp_runtime_precheck(rt, exp, host_hash, out, studio.dry_run)

    changes: list[str] = []      # cloud IAM changes actually completed by THIS run
    try:
        try:
            proof = gcp_prove_impersonation(adc, sa, args.project)
        except ProofFailure as failure:
            if not failure.repairable:
                raise
            if not bootstrap_ok:
                why = keep_reason or "it is not the derived default"
                raise Fail(f"{failure}\n    connect-cloud uses {sa} as-is ({why}) and will not create it, enable APIs "
                           "or change grants for it; an admin must fix the condition above.")
            if studio.dry_run:
                needs = ("enable iam + iamcredentials on the project if disabled; create/reuse the service account; grant "
                         f"the verified ADC user {ROLE_TOKEN_CREATOR} on it; grant it {ROLE_VIEWER} on {args.project}"
                         if failure.stage == "impersonate" else f"grant {sa} {ROLE_VIEWER} on {args.project}")
                out.append(f"dry-run    NOT validated: {failure}")
                out.append(f"dry-run    a real run would prepare ONLY {sa} in {args.project}: {needs}. Nothing was changed.")
                return {"ok": False, "dryRun": True, "runtimeValidated": False, "bootstrapNeeded": True,
                        "name": args.name, "project": args.project, "serviceAccount": sa}
            proof = GcpBootstrap(adc, args.project, sa, out, changes).run(failure)
        out.append(f"identity   ADC {proof['principal']} → impersonates {sa}: OK ({proof['buckets']} bucket(s) visible in {args.project}) "
                   "— host-side proof only")

        # Host proof passed: now make the backend able to use this ADC (bounded, backend-only), BEFORE registering.
        runtime = gcp_runtime_apply(rt, ctx, state, exp, host_hash, out, studio.dry_run)

        credential = {"name": args.name, "dataEx": [
            {"key": "cloudRoleToAssume", "value": sa, "type": "string", "isSensitive": False},
        ], "metaData": {"source": TOOL_SOURCE, "updatedAt": now_iso()}}
        chain = apply_chain(
            studio, plan, provider_name=provider_name, provider_type="gcp", account_id=args.project,
            description=f"Dev-kit GCP connection '{args.name}' (project {args.project}, keyless: native ADC + impersonation)",
            credential=credential,
            scope_body={"name": args.name, "description": f"GCP project {args.project} as {sa}"},
            out=out)
    except Fail as e:
        if changes:
            raise Fail(f"{e}\n    Cloud changes ALREADY applied by this run (not rolled back): " + "; ".join(changes) + ".")
        raise
    if runtime["verified"]:
        out.append("stages     runtime-file: PROVEN (the backend's own uid read the host-proven file) · host-proof: OK · "
                   "ticket-proven: NO — not exercised (tests/e2e/cloud_onboarding_e2e.py); no SDK/end-to-end claim")
    else:
        out.append("stages     runtime-file: NOT PROVEN (dry-run planned only; no probe, recreate or restart ran) · "
                   "host-proof: OK · ticket-proven: NO")
    record = {"cloud": "gcp", "name": args.name, "project": args.project, "serviceAccount": sa,
              "adcSource": adc_path, "adcMode": "native-directory", "adcMount": RUNTIME_ENV_VALUE,
              "controlBucketCount": proof["buckets"], "updatedAt": now_iso(), **chain}
    if changes:
        record["bootstrapChanges"] = changes
    if not studio.dry_run:
        records.put(args.name, record)
    return dict(record, runtime=runtime, stages={"runtimeFile": runtime["verified"], "hostProof": True, "ticketProven": False})


# ── refresh / verify / status ──────────────────────────────────────────────────

def cmd_refresh(args, studio: Studio, records: Records, out: list[str]) -> dict:
    rec = records.get(args.name) or raise_unknown(args.name)
    if rec.get("cloud") == "gcp":
        # No "no restart" claim for GCP: re-checking the native ADC may legitimately restart the backend (and only the
        # backend) when a new login replaced the file. cmd_gcp announces and reports exactly that.
        ns = argparse.Namespace(name=args.name, workspace=args.workspace or rec.get("workspaceId"), no_workspace=not (
            args.workspace or rec.get("workspaceId")), project=rec["project"], service_account=rec["serviceAccount"],
            adc_source=None, from_record=True)      # always the native file; a legacy recorded adcSource is not trusted
        return cmd_gcp(ns, studio, records, out)
    before = container_snapshot()
    if not snapshot_complete(before):
        missing = [s for s in SERVICES if not before.get(s)]
        raise Fail(f"cannot prove a no-restart refresh: {', '.join(missing)} not running in compose project "
                   f"'{os.environ.get('CONNECT_CLOUD_PROJECT')}'. Start the stack (./run.sh) and re-run; "
                   "nothing was changed.")
    ns = argparse.Namespace(name=args.name, workspace=args.workspace or rec.get("workspaceId"), no_workspace=False)
    if not ns.workspace:
        ns.no_workspace = True
    if rec.get("cloud") == "aws":
        ns.profile, ns.region = rec["profile"], rec["region"]
        result = cmd_aws(ns, studio, records, out)
    else:
        raise Fail(f"connection record '{args.name}' has unknown cloud '{rec.get('cloud')}'")
    after = container_snapshot()
    unchanged = snapshot_complete(after) and before == after
    result["containers"] = {"before": before, "after": after, "unchanged": unchanged}
    for svc in SERVICES:
        b, a = before[svc], after.get(svc)
        out.append(f"container  {svc}: {b['id'][:12]} started {b['startedAt']}" +
                   ("" if a == b else f" → NOW {a['id'][:12] if a else 'absent'} started {a['startedAt'] if a else '-'}"))
    out.append("containers " + ("unchanged — no restart" if unchanged else "CHANGED or missing — this refresh is NOT a no-restart proof"))
    if not unchanged:
        result["ok"] = False
    return result


def cmd_verify(args, studio: Studio, records: Records, out: list[str]) -> dict:
    rec = records.get(args.name) or raise_unknown(args.name)
    result = {"name": args.name, "cloud": rec.get("cloud"), "checks": {}}
    scope = studio.get("Scopes", rec["scopeId"])
    result["checks"]["scopeExists"] = scope is not None
    provider = studio.get("Providers", rec["providerId"]) if scope else None
    result["checks"]["providerExists"] = provider is not None
    result["checks"]["credentialPresent"] = bool(provider and any(
        (c.get("name") or "").lower() == rec["credentialName"].lower() for c in provider.get("credentials") or []))
    if rec.get("workspaceId"):
        ws = studio.get("Workspaces", rec["workspaceId"])
        result["checks"]["workspaceAttached"] = bool(ws and rec["scopeId"] in (ws.get("scopeIds") or []))
    else:
        result["checks"]["workspaceAttached"] = False
        out.append("workspace  none attached — the scope is not selectable by tickets")
    if rec.get("cloud") == "aws":
        exp = rec.get("expiration")
        if exp:
            try:
                expires = _dt.datetime.fromisoformat(exp.replace("Z", "+00:00"))
                result["checks"]["notExpired"] = expires > _dt.datetime.now(_dt.timezone.utc)
            except ValueError:
                result["checks"]["notExpired"] = None
        # The studio's own scope endpoint: ScopesController.ListAwsResources → ScopeService →
        # ScopeHelper.ListAwsResourcesByFilterAsync → AwsStsHelper.PopulateCredentialsFromScopeAsync →
        # ResourceGroupsTaggingAPI with the scope's stored credentials. A 200 proves the backend
        # resolved and used this scope's credentials; the listed count is tag-API based and may be 0.
        path = f"{ADMIN}/Scopes/{rec['scopeId']}/aws/resources?resourceType=s3&resourcesPerPage=5"
        status, d = studio.call("GET", path, ok=(200, 400, 403, 404, 500), timeout=60)
        result["checks"]["backendScopeExpansion"] = status == 200
        if status != 200:
            result["checks"]["backendError"] = describe_error(d, "")
            out.append(f"backend    scope expansion FAILED (HTTP {status}): {describe_error(d, '')}")
        else:
            out.append("backend    scope expansion OK — the studio populated and used this scope's AWS credentials")
    else:
        # Three SEPARATE stages, never merged: the runtime file (what the running backend's own uid can read, and
        # that it is the host-proven file), the host-side proof (impersonation + bucket list with that ADC), and
        # a ticket (never exercised here).
        rt = GcpRuntime()
        exp = rt.expected()
        host_hash = None
        host_err = None
        try:
            adc, host_hash = gcp_read_adc(exp["file"], hint_dir=exp["dir"], login=login_command(exp))
            proof = gcp_prove_impersonation(adc, rec["serviceAccount"], rec["project"])
            result["checks"]["adcImpersonation"] = True
            result["checks"]["controlBucketCount"] = proof["buckets"]
        except Fail as e:
            result["checks"]["adcImpersonation"] = False
            host_err = str(e)
            out.append(f"host-proof  FAILED: {e}")
        rchecks, rmsgs = gcp_runtime_checks(rt, gcp_state(records), exp, host_hash)
        result["checks"].update(rchecks)
        runtime_ok = all(rchecks[k] for k in rchecks)
        for m in rmsgs:
            out.append(f"runtime-file  {m}")
        out.append(f"runtime-file  {'OK' if runtime_ok else 'FAILED'} — the running backend's mount, {RUNTIME_ENV}, its own uid's read of "
                   "the file, source identity with the host file, and a recorded ADC cache that matches")
        if result["checks"]["adcImpersonation"]:
            out.append(f"host-proof    OK — ADC → {rec['serviceAccount']} ({result['checks']['controlBucketCount']} bucket(s)); "
                       "this proves the host-side chain, not that the backend used it")
        result["stages"] = {"runtimeFile": runtime_ok, "hostProof": result["checks"]["adcImpersonation"], "ticketProven": False}
        out.append("ticket-proven NO — verify never runs a ticket; only tests/e2e/cloud_onboarding_e2e.py (run when asked) can show a ticket "
                   "using the scope, and nothing here proves the backend SDK path end to end")
        if host_err is None and "adcRef" in {d.get("key") for c in (provider or {}).get("credentials") or []
                                              if (c.get("name") or "").lower() == rec["credentialName"].lower() for d in c.get("dataEx") or []}:
            out.append("note        the credential still carries a legacy adcRef; the published backend ignores it "
                       "(re-run `connect-cloud.sh gcp --project …` to migrate it in place)")
    result["ok"] = all(v is not False for k, v in result["checks"].items() if not k.endswith("Error") and not k.startswith("control"))
    out.append("verify     " + ("OK" if result["ok"] else "FAILED") + " " + json.dumps(result["checks"]))
    return result


def cmd_status(args, studio: Studio, records: Records, out: list[str]) -> dict:
    conns = records.data["connections"]
    try:
        volume = store_volume()
        store_err = None
    except Fail as e:
        volume, store_err = None, str(e)
    store = store_list() if volume else []
    result = {"connections": conns, "storeVolume": volume, "storeError": store_err, "store": store}
    out.append(f"store      legacy credential store (no longer used by GCP; kept intact for rollback): "
               f"{volume or 'UNAVAILABLE: ' + str(store_err)}")
    if any(r.get("cloud") == "gcp" for r in conns.values() if isinstance(r, dict)):
        # One global fact for every GCP connection: they all share the ONE host ADC the backend binds.
        try:
            rt = GcpRuntime()
            exp = rt.expected()
            try:
                host_hash = gcp_read_adc(exp["file"], hint_dir=exp["dir"], login=login_command(exp))[1]
            except Fail as e:
                host_hash = None
                out.append(f"gcp        host ADC: {str(e).splitlines()[0]}")
            rchecks, rmsgs = gcp_runtime_checks(rt, gcp_state(records), exp, host_hash)
            result["gcpRuntime"] = dict(rchecks, adcFile=exp["file"], adcDir=exp["dir"], messages=rmsgs)
            out.append(f"gcp        shared host ADC {exp['file']}: runtime-file " + ("OK" if all(rchecks.values()) else "NOT OK")
                       + " (one identity for every GCP connection; ticket-proven: not shown by status)")
            for m in rmsgs:
                out.append(f"gcp        {m}")
        except Fail as e:
            result["gcpRuntime"] = {"error": str(e)}
            out.append(f"gcp        runtime unavailable: {e}")
    if not conns:
        out.append("no connections recorded in " + records.path)
    for name, rec in sorted(conns.items()):
        live = studio.get("Scopes", rec["scopeId"]) is not None
        extra = f"expires {rec.get('expiration')}" if rec.get("expiration") else ""
        out.append(f"{name:<16} {rec.get('cloud', '?'):<4} account={rec.get('accountId') or rec.get('project')} "
                   f"scope={'live' if live else 'MISSING'} ws={rec.get('workspaceId') or 'NONE (not ticket-selectable)'} {extra}")
    for ln in store:
        out.append(f"store      {ln}")
    return result


# ── plumbing ───────────────────────────────────────────────────────────────────

def raise_unknown(name: str):
    raise Fail(f"no connection named '{name}' — see `connect-cloud.sh status`")


def check_name(name: str) -> None:
    if not NAME_RE.match(name or ""):
        raise Fail("--name must be 1-64 chars of [a-z0-9_-], starting with a letter or digit (it names the "
                   "scope, the AWS profile the agent sees, and the stored ADC file)")


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="connect-cloud.sh", description=__doc__.split("\n\n")[0])
    sub = p.add_subparsers(dest="cmd", required=True)

    def globals_(sp):  # accepted before or after the subcommand
        sp.add_argument("--json", action="store_true", default=argparse.SUPPRESS, help="machine-readable result on stdout")
        sp.add_argument("--dry-run", action="store_true", default=argparse.SUPPRESS, help="resolve and validate, but write nothing")

    def common(sp, name_required=True):
        globals_(sp)
        sp.add_argument("--name", required=name_required, default=None,
                        help="connection name (scope name, agent profile/config name)"
                        + ("" if name_required else "; default: the project ID"))
        sp.add_argument("--workspace", default=None, help="workspace id (default: EXTENSION_DEV_WORKSPACE_ID)")
        sp.add_argument("--no-workspace", action="store_true", help="register without attaching (not ticket-selectable)")

    globals_(p)
    a = sub.add_parser("aws", help="connect an AWS account from a local profile")
    common(a)
    a.add_argument("--profile", required=True)
    a.add_argument("--region", default="us-east-1")

    g = sub.add_parser("gcp", help="connect a GCP project keylessly via the backend's native ADC + SA impersonation")
    common(g, name_required=False)
    g.add_argument("--project", required=True)
    g.add_argument("--service-account", default=None,
                   help="service account to impersonate (default: helpdesk-sa@<project>.iam.gserviceaccount.com)")
    g.add_argument("--no-bootstrap", action="store_true",
                   help="advanced: never prepare the derived service account (no API enable / SA create / IAM grants); "
                        "a missing account or permission then fails instead of being repaired")
    g.add_argument("--adc-source", default=None, help="advanced: must name the exact native file the backend binds "
                        f"(<gcloud dir>/{RUNTIME_ADC_FILE}; default: that file) — any other file is refused")

    for name in ("refresh", "verify"):
        sp = sub.add_parser(name)
        globals_(sp)
        sp.add_argument("--name", required=True)
        if name == "refresh":
            sp.add_argument("--workspace", default=None)
    globals_(sub.add_parser("status"))
    return p


def main(argv: list[str]) -> int:
    args = build_parser().parse_args(argv)
    for flag in ("json", "dry_run"):
        if not hasattr(args, flag):
            setattr(args, flag, False)
    base, token = os.environ.get("DUPLO_BASE"), os.environ.get("DUPLO_TOKEN")
    if not base or not token:
        print("DUPLO_BASE / DUPLO_TOKEN missing — run through scripts/connect-cloud.sh", file=sys.stderr)
        return 2
    studio = Studio(base, token, dry_run=args.dry_run)
    out: list[str] = []
    handlers = {"aws": cmd_aws, "gcp": cmd_gcp, "refresh": cmd_refresh, "verify": cmd_verify, "status": cmd_status}
    try:
        records = Records(os.environ.get("CONNECT_CLOUD_STATE", ".devkit-cloud/connections.json"))
        result = handlers[args.cmd](args, studio, records, out)
    except Fail as e:
        for ln in out:
            print("    " + ln)
        print(f"✗ {e}", file=sys.stderr)
        return 1
    ok = result.get("ok", True)
    if args.dry_run:
        out.append("dry-run    nothing was written; the studio writes that would have happened: " + (", ".join(studio.writes) or "none"))
    if args.json:
        print(json.dumps({"ok": ok, "dryRun": args.dry_run, "result": result, "log": out}, indent=2, sort_keys=True))
    else:
        for ln in out:
            print("    " + ln)
        if args.cmd in ("aws", "gcp", "refresh") and ok and not args.dry_run:
            ws = result.get("workspaceId")
            print(f"✔ {args.cmd}: connection '{args.name}' ready — scope '{args.name}' ({result.get('scopeId')}) "
                  + (f"attached to workspace {ws}" if ws else "NOT attached to any workspace (not ticket-selectable)"))
        elif args.dry_run and ok:
            print(f"✔ {args.cmd}: dry-run only — nothing installed, nothing tested in the backend")
        elif args.dry_run:
            print(f"✗ {args.cmd}: dry-run found the connection would NOT validate today (see above) — nothing was changed, "
                  "runtime not validated", file=sys.stderr)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
