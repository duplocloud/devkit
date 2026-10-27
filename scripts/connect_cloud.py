#!/usr/bin/env python3
"""connect-cloud: register an AWS account or a GCP project with the local dev kit.

Invoked by scripts/connect-cloud.sh, which supplies every input through the environment:

  DUPLO_BASE / DUPLO_TOKEN            studio URL and admin bearer token (never on a command line)
  CONNECT_CLOUD_WORKSPACE_DEFAULT     workspace to attach scopes to when --workspace is not given
  CONNECT_CLOUD_STATE                 path of the non-secret connection records (JSON)
  CONNECT_CLOUD_STORE_CMD             command prefix for the credential store (write|remove|list|exists|volume)
  CONNECT_CLOUD_PROJECT / RUNTIME     compose project + container CLI, for container snapshots only
  CONNECT_CLOUD_GOOGLE_TOKEN_URL, CONNECT_CLOUD_GOOGLE_IAM_URL, CONNECT_CLOUD_GOOGLE_STORAGE_URL
                                      Google endpoints (tests point them at a local fake)

Rules this file enforces, in order of importance:
  * secrets travel on stdin / in HTTPS request bodies only; the records file and all output carry
    names, ids and expiry — never key material;
  * every conflict is found BEFORE any write (preflight), then writes are applied in order; a
    re-run never duplicates and a rotation is an in-place update of the same credential;
  * the identity a connection is registered with is proven before it is stored (STS for AWS, an
    actual IAM generateAccessToken + bucket list for GCP), with the very credentials being stored;
  * a "no restart" claim is only ever made from real container ids and start times of BOTH the
    studio and the agent; a missing service fails the claim instead of passing vacuously.
"""

from __future__ import annotations

import argparse
import datetime as _dt
import json
import os
import re
import shlex
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

ADMIN = "/v1/aiservicedesk/admin/data"
TOOL_SOURCE = "devkit connect-cloud"
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")
ADC_WELL_KNOWN = os.path.join(
    os.environ.get("CLOUDSDK_CONFIG") or os.path.expanduser("~/.config/gcloud"),
    "application_default_credentials.json",
)
GOOGLE_TOKEN_URL = os.environ.get("CONNECT_CLOUD_GOOGLE_TOKEN_URL", "https://oauth2.googleapis.com/token")
GOOGLE_IAM_URL = os.environ.get("CONNECT_CLOUD_GOOGLE_IAM_URL", "https://iamcredentials.googleapis.com/v1")
GOOGLE_STORAGE_URL = os.environ.get("CONNECT_CLOUD_GOOGLE_STORAGE_URL", "https://storage.googleapis.com/storage/v1")
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
        if plan["credential_action"] == "rotate":
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

def http_json(url: str, *, data: dict | None = None, headers: dict | None = None, form: bool = False) -> tuple[int, dict | None]:
    body = None
    hdrs = dict(headers or {})
    if data is not None:
        if form:
            body = urllib.parse.urlencode(data).encode()
            hdrs["Content-Type"] = "application/x-www-form-urlencoded"
        else:
            body = json.dumps(data).encode()
            hdrs["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=body, headers=hdrs, method="POST" if body else "GET")
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


def gcp_load_adc(path: str) -> dict:
    if not os.path.isfile(path):
        raise Fail(f"ADC file not found: {path}\n    Run: gcloud auth application-default login   (or pass --adc-source)")
    with open(path) as f:
        try:
            adc = json.load(f)
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
    return adc


def gcp_prove_impersonation(adc: dict, sa: str, project: str) -> dict:
    """The exact chain the studio performs with this file: refresh → generateAccessToken(sa) → GCS list.

    Returns the principal label and the full (paginated) bucket name list; never the tokens.
    """
    status, tok = http_json(GOOGLE_TOKEN_URL, form=True, data={
        "grant_type": "refresh_token", "client_id": adc["client_id"],
        "client_secret": adc["client_secret"], "refresh_token": adc["refresh_token"]})
    if status != 200 or not isinstance(tok, dict) or not tok.get("access_token"):
        raise Fail(f"the ADC refresh token was rejected by Google (HTTP {status}: {describe_error(tok, '')}). "
                   "Re-run: gcloud auth application-default login")
    user_token = tok["access_token"]
    status, imp = http_json(
        f"{GOOGLE_IAM_URL}/projects/-/serviceAccounts/{urllib.parse.quote(sa)}:generateAccessToken",
        headers={"Authorization": "Bearer " + user_token},
        data={"scope": [CLOUD_PLATFORM_SCOPE], "lifetime": "600s"})
    if status != 200 or not isinstance(imp, dict) or not imp.get("accessToken"):
        raise Fail(f"this ADC identity cannot impersonate {sa} (HTTP {status}: {describe_error(imp, '')}).\n"
                   f"    It needs roles/iam.serviceAccountTokenCreator ON that service account, and "
                   f"iamcredentials.googleapis.com must be enabled on the ADC quota project. "
                   f"scripts/setup-google-auth.sh --sa {sa} --grant can apply the grant if you are an IAM admin.")
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
            raise Fail(f"{sa} could mint a token but cannot list buckets in '{project}' (HTTP {status}: "
                       f"{describe_error(buckets, '')}). Grant it roles/storage.viewer (or the project's read-only role).")
        names.extend(i.get("name", "") for i in buckets.get("items") or [])
        page_token = buckets.get("nextPageToken")
        if not page_token:
            break
    else:
        raise Fail("bucket listing did not terminate after 100 pages; refusing to trust the count")
    return {"principal": adc.get("account") or "(ADC user)", "buckets": len(names), "bucketNames": sorted(names)}


def cmd_gcp(args, studio: Studio, records: Records, out: list[str]) -> dict:
    check_name(args.name)
    workspace = resolve_workspace(args)
    sa = args.service_account
    if not re.match(r"^[a-z0-9-]+@[a-z0-9-]+\.iam\.gserviceaccount\.com$", sa):
        raise Fail(f"--service-account '{sa}' is not a service-account email")
    adc_path = os.path.abspath(args.adc_source or ADC_WELL_KNOWN)
    adc = gcp_load_adc(adc_path)
    proof = gcp_prove_impersonation(adc, sa, args.project)
    out.append(f"identity   ADC {proof['principal']} → impersonates {sa}: OK ({proof['buckets']} bucket(s) visible in {args.project})")

    # Everything that can conflict is checked here, before the store file or any platform object changes.
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

    rel = f"gcp/{args.name}.json"
    minimal = {k: adc[k] for k in ADC_ALLOWED_KEYS if k in adc}   # only the fields the backend accepts
    if studio.dry_run:
        out.append(f"store      {rel}: would write (uid 1001, mode 0600) — dry-run, nothing written")
    else:
        volume = store_volume()
        store_write(rel, (json.dumps(minimal) + "\n").encode())
        out.append(f"store      {rel}: written to volume {volume} (uid 1001, mode 0600) — the studio reads it per ticket message")

    credential = {"name": args.name, "dataEx": [
        {"key": "cloudRoleToAssume", "value": sa, "type": "string", "isSensitive": False},
        {"key": "adcRef", "value": args.name, "type": "string", "isSensitive": False},
    ], "metaData": {"source": TOOL_SOURCE, "updatedAt": now_iso()}}
    chain = apply_chain(
        studio, plan, provider_name=provider_name, provider_type="gcp", account_id=args.project,
        description=f"Dev-kit GCP connection '{args.name}' (project {args.project}, keyless via ADC '{args.name}')",
        credential=credential,
        scope_body={"name": args.name, "description": f"GCP project {args.project} as {sa}"},
        out=out)
    record = {"cloud": "gcp", "name": args.name, "project": args.project, "serviceAccount": sa,
              "adcSource": adc_path, "adcRef": args.name, "storeFile": rel,
              "controlBucketCount": proof["buckets"], "updatedAt": now_iso(), **chain}
    if not studio.dry_run:
        records.put(args.name, record)
    return record


# ── refresh / verify / status ──────────────────────────────────────────────────

def cmd_refresh(args, studio: Studio, records: Records, out: list[str]) -> dict:
    rec = records.get(args.name) or raise_unknown(args.name)
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
    elif rec.get("cloud") == "gcp":
        ns.project, ns.service_account, ns.adc_source = rec["project"], rec["serviceAccount"], rec.get("adcSource")
        result = cmd_gcp(ns, studio, records, out)
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
        adc = gcp_load_adc(rec["adcSource"])
        proof = gcp_prove_impersonation(adc, rec["serviceAccount"], rec["project"])
        result["checks"]["adcImpersonation"] = True
        result["checks"]["controlBucketCount"] = proof["buckets"]
        result["checks"]["storeFileReadableByStudioUid"] = any(
            ln.split()[-1] == rec["storeFile"] and "UNREADABLE" not in ln for ln in store_list())
        out.append(f"bootstrap  ADC → {rec['serviceAccount']} OK ({proof['buckets']} bucket(s)); "
                   "backend expansion of a GCP scope is only exercised by a ticket: tests/e2e/cloud_onboarding_e2e.py")
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
    out.append(f"store      {volume or 'UNAVAILABLE: ' + str(store_err)}")
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

    def common(sp):
        globals_(sp)
        sp.add_argument("--name", required=True, help="connection name (scope name, agent profile/config name)")
        sp.add_argument("--workspace", default=None, help="workspace id (default: EXTENSION_DEV_WORKSPACE_ID)")
        sp.add_argument("--no-workspace", action="store_true", help="register without attaching (not ticket-selectable)")

    globals_(p)
    a = sub.add_parser("aws", help="connect an AWS account from a local profile")
    common(a)
    a.add_argument("--profile", required=True)
    a.add_argument("--region", default="us-east-1")

    g = sub.add_parser("gcp", help="connect a GCP project keylessly via your ADC + SA impersonation")
    common(g)
    g.add_argument("--project", required=True)
    g.add_argument("--service-account", required=True)
    g.add_argument("--adc-source", default=None, help=f"authorized_user ADC JSON (default {ADC_WELL_KNOWN})")

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
        elif args.dry_run:
            print(f"✔ {args.cmd}: dry-run only — nothing installed, nothing tested in the backend")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
