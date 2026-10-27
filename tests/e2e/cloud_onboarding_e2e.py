#!/usr/bin/env python3
"""End-to-end proof that a connected cloud scope works through a REAL ticket — isolated from onboarding.

This is deliberately NOT part of `connect-cloud.sh`: it invokes the LLM, creates a ticket, and costs
money, so it runs only when an operator asks for it. It PASSES only when all of the following hold:

  1. both the studio and the agent containers are found before and after, with identical ids and
     start times (a missing service is a failure, never a vacuous pass);
  2. the workspace has an assigned agent; the ticket is created with that agent and the scope, and the
     studio reads the scope id back from the persisted ticket;
  3. every approval request the agent raises is for one of the exact generated read-only commands
     (whitespace-normalized equality); anything else is rejected and fails the run. There is no regex,
     no wildcard, no "remember for this ticket", and token-printing commands are not in the set;
  4. at least one allowed command was actually executed (approval_status "approved") and its RAW tool
     output parses as a bucket listing whose name set equals the operator's independent control list
     (an empty listing is a legitimate parsed result — a missing or unparsable output is not);
  5. the SSE stream closed without an error event and inside the timeout, and no background
     exception occurred.

A correct final answer in prose with no matching raw tool output FAILS. Standard library only.

  --base URL --token-env VAR     studio URL; the admin token is read from the named env var
  --workspace ID --scope-id ID   the scope connect-cloud registered (see .devkit-cloud/connections.json)
  --cloud aws|gcp --name NAME    the connection name (= AWS profile / gcloud configuration the agent sees)
  --control-file PATH            JSON list of bucket names obtained independently (operator-run control)
  --runtime docker --project P   container CLI + compose project for the snapshots (both required)
  --evidence DIR                 where the JSON evidence file is written (keep it OUTSIDE the source clone)
  --agent-name NAME              workspace agent to assign (default local-agent)
  --timeout SECONDS              overall wait for the agent turn (default 600)
"""

from __future__ import annotations

import argparse
import datetime as _dt
import json
import os
import re
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

TICKETS = "/v1/aiservicedesk/tickets"
USER_WS = "/v1/aiservicedesk/user/data/workspaces"
SERVICES = ("duplo-ai-studio", "claude-code-agent")


def allowed_commands(cloud: str, name: str) -> list[str]:
    """The ONLY commands the harness will ever approve. Identity + bucket listing, JSON output, nothing
    that prints a token or touches state."""
    if cloud == "aws":
        return [
            f"aws sts get-caller-identity --profile {name} --output json",
            f"aws s3api list-buckets --profile {name} --output json",
        ]
    return [
        f"gcloud storage buckets list --configuration {name} --format json",
        f"gcloud storage buckets list --configuration {name} --format=json",
    ]


def prompt(cloud: str, name: str, project: str | None) -> str:
    cmds = allowed_commands(cloud, name)
    if cloud == "aws":
        return ("Using ONLY the AWS profile '%s', run exactly these two commands and nothing else: "
                "`%s` then `%s`. Do not pipe, chain, substitute, or add flags. Then reply with the account id and "
                "a plain list of every bucket name, one per line, under the heading BUCKETS:" % (name, cmds[0], cmds[1]))
    return ("Using ONLY the gcloud configuration '%s' (project %s), run exactly this one command and nothing else: "
            "`%s`. Do not pipe, chain, substitute, or add flags. Then reply with a plain list of every bucket name, "
            "one per line, under the heading BUCKETS:" % (name, project or "?", cmds[0]))


def norm(cmd: str) -> str:
    return re.sub(r"\s+", " ", (cmd or "").strip())


class HarnessError(Exception):
    pass


class Api:
    def __init__(self, base: str, token: str):
        self.base = base.rstrip("/")
        self.token = token

    def _req(self, method: str, path: str, body=None, accept="application/json"):
        req = urllib.request.Request(self.base + path, method=method,
                                     data=None if body is None else json.dumps(body).encode())
        req.add_header("Authorization", "Bearer " + self.token)
        req.add_header("Accept", accept)
        if body is not None:
            req.add_header("Content-Type", "application/json")
        return req

    def call(self, method: str, path: str, body=None, ok=(200, 201, 204), timeout=60):
        try:
            with urllib.request.urlopen(self._req(method, path, body), timeout=timeout) as r:
                raw = r.read().decode()
                status = r.status
        except urllib.error.HTTPError as e:
            raw, status = e.read().decode(errors="replace"), e.code
        except (urllib.error.URLError, TimeoutError, OSError) as e:
            raise HarnessError(f"{method} {path}: {getattr(e, 'reason', e)}")
        if status not in ok:
            raise HarnessError(f"{method} {path} → HTTP {status}: {raw[:400]}")
        try:
            return status, (json.loads(raw) if raw else None)
        except ValueError:
            return status, raw

    def stream_sse(self, path: str, body: dict, deadline: float) -> list[dict]:
        """POST and read `event:`/`data:` frames until the server closes or the deadline passes.

        Returns the parsed events as [{"event": name, "data": <json or str>}]. Raises HarnessError on a
        non-200, an `error` event, or the deadline.
        """
        events: list[dict] = []
        req = self._req("POST", path, body, accept="text/event-stream")
        # The socket timeout IS the deadline: a blocked readline past it raises instead of hanging.
        try:
            resp = urllib.request.urlopen(req, timeout=max(1.0, deadline - time.time()))
        except urllib.error.HTTPError as e:
            raise HarnessError(f"sendMessageStreaming → HTTP {e.code}: {e.read().decode(errors='replace')[:400]}")
        except (urllib.error.URLError, TimeoutError, OSError) as e:
            raise HarnessError(f"sendMessageStreaming: {getattr(e, 'reason', e)}")
        if resp.status != 200:
            raise HarnessError(f"sendMessageStreaming → HTTP {resp.status}")
        if "text/event-stream" not in (resp.headers.get("Content-Type") or ""):
            raise HarnessError(f"sendMessageStreaming did not answer text/event-stream (got {resp.headers.get('Content-Type')})")
        name, data_lines = "message", []
        with resp:
            while True:
                if time.time() > deadline:
                    raise HarnessError("stream deadline exceeded while the agent turn was still open")
                try:
                    line = resp.readline()
                except (TimeoutError, OSError) as e:
                    raise HarnessError(f"stream deadline exceeded while the agent turn was still open ({type(e).__name__})")
                if not line:
                    break
                line = line.decode(errors="replace").rstrip("\r\n")
                if line == "":
                    if data_lines:
                        raw = "\n".join(data_lines)
                        try:
                            data = json.loads(raw)
                        except ValueError:
                            data = raw
                        events.append({"event": name, "data": data})
                        if name == "error" or (isinstance(data, dict) and data.get("type") == "error"):
                            raise HarnessError(f"stream error event: {str(data)[:300]}")
                    name, data_lines = "message", []
                elif line.startswith("event:"):
                    name = line[6:].strip()
                elif line.startswith("data:"):
                    data_lines.append(line[5:].lstrip())
        return events


def snapshot(runtime: str, project: str) -> dict:
    out: dict = {}
    for svc in SERVICES:
        out[svc] = None
        try:
            p = subprocess.run([runtime, "ps", "-q", "--filter", f"label=com.docker.compose.project={project}",
                                "--filter", f"label=com.docker.compose.service={svc}"], capture_output=True, text=True, timeout=30)
            cid = p.stdout.strip().splitlines()[0] if p.returncode == 0 and p.stdout.strip() else ""
            if not cid:
                continue
            q = subprocess.run([runtime, "inspect", "--format", "{{.Id}} {{.State.StartedAt}}", cid],
                               capture_output=True, text=True, timeout=30)
            parts = q.stdout.strip().split(" ", 1) if q.returncode == 0 else []
            if len(parts) == 2 and all(parts):
                out[svc] = {"id": parts[0], "startedAt": parts[1]}
        except (subprocess.TimeoutExpired, OSError):
            continue
    return out


def snapshot_complete(s: dict) -> bool:
    return all(isinstance(s.get(k), dict) and s[k].get("id") and s[k].get("startedAt") for k in SERVICES)


def parse_bucket_output(cloud: str, command: str, output: str) -> list[str] | None:
    """Bucket names from the RAW output of an allowed listing command; None when it is not a parsable
    listing. An empty listing parses to []."""
    if output is None:
        return None
    text = output.strip()
    try:
        d = json.loads(text) if text else None
    except ValueError:
        return None
    if cloud == "aws":
        if "list-buckets" not in command:
            return None
        if not isinstance(d, dict) or not isinstance(d.get("Buckets"), list):
            return None
        names = [b.get("Name") for b in d["Buckets"] if isinstance(b, dict)]
        return sorted(n for n in names if isinstance(n, str))
    if "buckets list" not in command:
        return None
    if d is None:
        return []  # gcloud prints nothing / [] for no buckets
    if not isinstance(d, list):
        return None
    names = [b.get("name") for b in d if isinstance(b, dict)]
    return sorted(n for n in names if isinstance(n, str))


def executed_from_messages(messages: list[dict]) -> list[dict]:
    """ExecutedCommand records persisted on the ticket (chunksFromAgent[].executed_cmds[])."""
    found: list[dict] = []
    for m in messages or []:
        for ev in m.get("chunksFromAgent") or []:
            for ec in ev.get("executed_cmds") or []:
                if isinstance(ec, dict):
                    found.append({"command": ec.get("command"), "approval_status": ec.get("approval_status"),
                                  "output": ec.get("output")})
    return found


def run(argv: list[str]) -> tuple[int, dict]:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--base", required=True)
    ap.add_argument("--token-env", default="DUPLO_ADMIN_TOKEN")
    ap.add_argument("--workspace", required=True)
    ap.add_argument("--scope-id", required=True)
    ap.add_argument("--cloud", choices=("aws", "gcp"), required=True)
    ap.add_argument("--name", required=True)
    ap.add_argument("--project", default=None, help="GCP project (for the prompt only)")
    ap.add_argument("--control-file", required=True)
    ap.add_argument("--runtime", required=True)
    ap.add_argument("--project-name", required=True, help="compose project name the stack runs under")
    ap.add_argument("--evidence", required=True)
    ap.add_argument("--agent-name", default="local-agent")
    ap.add_argument("--timeout", type=int, default=600)
    ap.add_argument("--poll-interval", type=float, default=2.0)
    a = ap.parse_args(argv)

    ev: dict = {"cloud": a.cloud, "name": a.name, "scopeId": a.scope_id, "workspace": a.workspace,
                "startedAt": _dt.datetime.now(_dt.timezone.utc).isoformat(),
                "allowedCommands": allowed_commands(a.cloud, a.name), "approvals": [], "rejections": [],
                "checks": {}, "failures": []}
    checks = ev["checks"]

    def fail(reason: str):
        ev["failures"].append(reason)

    token = os.environ.get(a.token_env)
    if not token:
        fail(f"env {a.token_env} is empty")
        return finish(a, ev)
    try:
        with open(a.control_file) as f:
            control = json.load(f)
        if not isinstance(control, list) or not all(isinstance(x, str) for x in control):
            raise ValueError("control file must be a JSON list of bucket names")
    except (OSError, ValueError) as e:
        fail(f"control file: {e}")
        return finish(a, ev)
    control = sorted(set(control))
    ev["control"] = control
    allowed = {norm(c) for c in allowed_commands(a.cloud, a.name)}
    api = Api(a.base, token)

    # 1. container snapshot — complete or nothing
    before = snapshot(a.runtime, a.project_name)
    ev["containersBefore"] = before
    if not snapshot_complete(before):
        fail(f"container snapshot incomplete for project '{a.project_name}': {before}")
        return finish(a, ev)

    try:
        # 2. workspace agent + ticket with scope, read back
        _, agents = api.call("GET", f"{USER_WS}/{a.workspace}/agents")
        agents = (agents or {}).get("data") or []
        agent = next((x for x in agents if x.get("name") == a.agent_name), None)
        if agent is None and len(agents) == 1:
            agent = agents[0]
        if agent is None:
            raise HarnessError(f"workspace {a.workspace} has no assigned agent named '{a.agent_name}' "
                               f"(found: {[x.get('name') for x in agents]}); run ./scripts/register-agent.sh <workspace>")
        ev["agentId"] = agent["id"]
        _, ticket = api.call("POST", f"{TICKETS}/{a.workspace}", {
            "title": f"devkit e2e {a.cloud} {a.name}",
            "aiAgentId": agent["id"],
            "ticketContextForAgent": {"scopeIds": [a.scope_id]},
        })
        tname = ticket.get("name") if isinstance(ticket, dict) else None
        if not tname:
            raise HarnessError(f"ticket create returned no name: {str(ticket)[:200]}")
        ev["ticket"] = tname
        _, readback = api.call("GET", f"{TICKETS}/{a.workspace}/{tname}")
        rb_scopes = ((readback or {}).get("ticketContextForAgent") or {}).get("scopeIds") or []
        checks["scopeReadBack"] = a.scope_id in rb_scopes
        checks["agentAssigned"] = (readback or {}).get("aiAgentId") == agent["id"]
        if not checks["scopeReadBack"]:
            raise HarnessError(f"the persisted ticket does not carry scope {a.scope_id} (has {rb_scopes})")
        if not checks["agentAssigned"]:
            raise HarnessError(f"the persisted ticket is not assigned to agent {agent['id']}")

        # 3. stream the turn in a bounded worker; answer approvals concurrently
        msg = prompt(a.cloud, a.name, a.project)
        ev["prompt"] = msg
        deadline = time.time() + a.timeout
        box: dict = {}

        def worker():
            try:
                box["events"] = api.stream_sse(f"{TICKETS}/{a.workspace}/{tname}/sendMessageStreaming",
                                               {"role": "user", "content": msg}, deadline)
            except Exception as e:  # noqa: BLE001 — recorded, judged below
                box["error"] = f"{type(e).__name__}: {e}"

        th = threading.Thread(target=worker, daemon=True)
        th.start()
        while th.is_alive() and time.time() < deadline:
            status, pending = api.call("GET", f"{TICKETS}/{a.workspace}/{tname}/agentCallback/pending", ok=(200, 204))
            if status == 200 and isinstance(pending, dict):
                data = pending.get("data") or {}
                cmds = [c for c in (data.get("cmds") or []) if isinstance(c, dict)]
                tool_calls = [t for t in (data.get("tool_calls") or []) if isinstance(t, dict)]
                decisions = []
                for c in cmds:
                    cmd = c.get("command", "")
                    execute = norm(cmd) in allowed
                    decisions.append({"command": cmd, "execute": execute,
                                      **({} if execute else {"rejection_reason": "not one of the harness's exact read-only commands"})})
                    (ev["approvals"] if execute else ev["rejections"]).append(cmd)
                if tool_calls:
                    decisions_tools = [dict(t, execute=False, rejection_reason="harness allows bash only") for t in tool_calls]
                    ev["rejections"].extend("tool:" + str(t.get("name")) for t in tool_calls)
                    api.call("POST", f"{TICKETS}/{a.workspace}/{tname}/agentCallback/respond",
                             {"tool_calls": decisions_tools}, ok=(200, 409))
                if decisions:
                    api.call("POST", f"{TICKETS}/{a.workspace}/{tname}/agentCallback/respond",
                             {"cmds": decisions}, ok=(200, 409))
            time.sleep(a.poll_interval)
        th.join(timeout=max(0.0, deadline - time.time()) + 2)
        checks["turnFinishedInTime"] = (not th.is_alive()) and time.time() <= deadline + 2
        if not checks["turnFinishedInTime"]:
            raise HarnessError(f"agent turn did not finish within {a.timeout}s")
        if "error" in box:
            raise HarnessError(f"stream worker failed: {box['error']}")
        ev["streamEventCount"] = len(box.get("events") or [])
        checks["streamClosedCleanly"] = True

        # 4. persisted raw events are the source of truth
        _, messages = api.call("GET", f"{TICKETS}/{a.workspace}/{tname}/getMessages")
        if not isinstance(messages, list):
            raise HarnessError("getMessages did not return a list")
        executed = executed_from_messages(messages)
        ev["executedCommands"] = [{"command": e["command"], "approval_status": e["approval_status"]} for e in executed]
        final_text = next((m.get("content") for m in reversed(messages)
                           if m.get("role") == "assistant" and m.get("content")), "") or ""
        ev["finalReplyExcerpt"] = final_text[:2000]

        allowed_executed = [e for e in executed
                            if norm(e.get("command") or "") in allowed and e.get("approval_status") == "approved"]
        # Strict: every record that actually ran — approved, or executed with no callback at all (a
        # status other than "rejected"), must be one of the exact allowed commands. A correct listing
        # plus correct prose never excuses an unexpected execution.
        unexpected = [e.get("command") for e in executed
                      if e.get("approval_status") != "rejected" and norm(e.get("command") or "") not in allowed]
        ev["unexpectedExecutions"] = unexpected
        checks["noUnexpectedExecutions"] = not unexpected
        if unexpected:
            fail(f"commands were executed that the harness never allowed: {unexpected}")
        checks["noRejectedCommands"] = not ev["rejections"]
        checks["allowedCommandExecuted"] = bool(allowed_executed)
        parsed_sets = []
        for e in allowed_executed:
            names = parse_bucket_output(a.cloud, e["command"], e.get("output"))
            if names is not None:
                parsed_sets.append(names)
        ev["bucketsFromRawToolOutput"] = parsed_sets[-1] if parsed_sets else None
        checks["rawToolOutputParsed"] = bool(parsed_sets)
        checks["rawToolOutputMatchesControl"] = bool(parsed_sets) and parsed_sets[-1] == control
        if not checks["noRejectedCommands"]:
            fail(f"the agent asked for commands outside the allow-list: {ev['rejections']}")
        if not checks["allowedCommandExecuted"]:
            fail("no allowed command was executed with approval_status=approved (prose is not evidence)")
        elif not checks["rawToolOutputParsed"]:
            fail("the executed listing command's raw output is missing or not a parsable bucket listing")
        elif not checks["rawToolOutputMatchesControl"]:
            fail(f"raw tool output {parsed_sets[-1]} != control {control}")
    except HarnessError as e:
        fail(str(e))

    # 5. containers again — complete and identical, or no claim
    after = snapshot(a.runtime, a.project_name)
    ev["containersAfter"] = after
    checks["containersUnchanged"] = snapshot_complete(after) and after == before
    if not checks["containersUnchanged"]:
        fail(f"studio/agent containers changed or went missing during the run: before={before} after={after}")
    return finish(a, ev)


def finish(a, ev: dict) -> tuple[int, dict]:
    ev["ok"] = not ev["failures"]
    ev["finishedAt"] = _dt.datetime.now(_dt.timezone.utc).isoformat()
    os.makedirs(a.evidence, exist_ok=True)
    path = os.path.join(a.evidence, f"e2e-{a.cloud}-{a.name}-{ev.get('ticket') or 'noticket'}-{int(time.time())}.json")
    with open(path, "w") as f:
        json.dump(ev, f, indent=2, sort_keys=True)
    ev["evidencePath"] = path
    return (0 if ev["ok"] else 1), ev


def main() -> int:
    rc, ev = run(sys.argv[1:])
    print(json.dumps({"ok": ev["ok"], "checks": ev["checks"], "failures": ev["failures"],
                      "ticket": ev.get("ticket"), "evidence": ev.get("evidencePath")}, indent=2))
    return rc


if __name__ == "__main__":
    sys.exit(main())
