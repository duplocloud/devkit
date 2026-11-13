#!/usr/bin/env python3
"""Mocked tests for scripts/cloud_connect_wizard.py — no cloud, no container, no network, no real .env.

Three layers, all executed:
  * Wizard driven in-process with scripted answers and a recording fake runner (dependency injection): the
    exact argv/env of every subprocess the wizard WOULD start is asserted.
  * The real script as a subprocess, answers on stdin, with a fake connector next to it and fake `aws` /
    `gcloud` executables as the ONLY things on PATH — pins the real Runner, argv passing and exit codes.
  * run.sh's final onboarding block under a pseudo-terminal with a fake wizard: yes runs it, a failing wizard
    does not fail run.sh, no/empty skips it.

    python3 tests/test_cloud_connect_wizard.py
"""

from __future__ import annotations

import json
import os
import select
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))
import cloud_connect_wizard as w  # noqa: E402

CONNECTOR = "/kit/scripts/connect-cloud.sh"
REFRESH = "1//0gExampleRefreshTokenNeverPrinted"
GOOD_ADC = {"type": "authorized_user", "client_id": "id", "client_secret": "s3cr3t-client", "refresh_token": REFRESH}


class FakeIO:
    """Scripted answers; running out of them is end of input (EOF)."""

    def __init__(self, answers):
        self.answers = list(answers)
        self.out: list[str] = []

    def say(self, text: str = "") -> None:
        self.out.append(text)

    def ask(self, prompt: str) -> str:
        self.out.append(prompt)
        if not self.answers:
            raise w.Cancel()
        return self.answers.pop(0).strip()

    @property
    def text(self) -> str:
        return "\n".join(self.out)


class FakeRunner:
    """Records every call. `on` maps an argv prefix (tuple) to a result or a callable(argv, env) → result.
    capture → (rc, out, err) · interactive → rc · relay → (rc, stderr tail)."""

    def __init__(self, on=None, have=("aws", "gcloud")):
        self.on = dict(on or {})
        self.have = set(have)
        self.calls: list[tuple[str, list[str], dict | None]] = []

    def which(self, name):
        return f"/fake/{name}" if name in self.have else None

    def _find(self, kind, argv, env, default):
        self.calls.append((kind, list(argv), None if env is None else dict(env)))
        best = None
        for k in self.on:
            if tuple(argv[:len(k)]) == k and (best is None or len(k) > len(best)):
                best = k
        if best is None:
            return default
        r = self.on[best]
        if isinstance(r, list):                      # a sequence: one result per call
            r = r.pop(0)
        return r(argv, env) if callable(r) else r

    def capture(self, argv, *, env=None, timeout=30):
        return self._find("capture", argv, env, (1, "", ""))

    def interactive(self, argv, *, env=None):
        return self._find("interactive", argv, env, 0)

    def relay(self, argv, *, env=None):
        return self._find("relay", argv, env, (0, ""))

    def argvs(self, kind=None):
        return [a for k, a, _ in self.calls if kind in (None, k)]


def aws_runner(profiles, cfg=None, **kw):
    """A fake AWS CLI: `cfg` is {profile: {key: value}} for `aws configure get`."""
    cfg = {} if cfg is None else cfg          # keep the caller's dict: a test may fill it later

    def get(argv, env):
        v = cfg.get(argv[5], {}).get(argv[3], "")
        return (0, v + "\n", "") if v else (1, "", "")

    on = {("aws", "configure", "list-profiles"): (0, "\n".join(profiles) + "\n", ""),
          ("aws", "configure", "get"): get}
    on.update(kw.pop("on", {}))
    return FakeRunner(on, **kw)


def run_wizard(answers, runner, env=None, confirm=False):
    fio = FakeIO(answers)
    rc = w.Wizard(fio, runner, env=env if env is not None else {"PATH": "/fake", "HOME": "/nonexistent"},
                  connector=CONNECTOR).start(confirm=confirm)
    return rc, fio


class WizardCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="wizard-test-")
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

    def gdir(self, adc=None, source="DEVKIT_GCLOUD_DIR (.env)"):
        d = os.path.join(self.tmp, "gcloud dir")          # a space: the shown command must quote it
        os.makedirs(d, exist_ok=True)
        f = os.path.join(d, "application_default_credentials.json")
        if adc is not None:
            with open(f, "w") as fh:
                fh.write(adc if isinstance(adc, str) else json.dumps(adc))
        return d, f, (0, json.dumps({"dir": d, "file": f, "source": source}), "")

    def connects(self, runner):
        return [a for a in runner.argvs() if a[0] == CONNECTOR and a[1] in ("aws", "gcp")]

    def verifies(self, runner):
        return [a for a in runner.argvs() if a[0] == CONNECTOR and a[1] == "verify"]


class TopLevel(WizardCase):
    def test_decline_runs_nothing(self):
        r = FakeRunner()
        rc, fio = run_wizard(["n"], r, confirm=True)
        self.assertEqual(rc, w.CANCELLED)
        self.assertEqual(r.calls, [])
        self.assertIn("Nothing was changed", fio.text)

    def test_yes_then_full_gcp_flow(self):
        _, _, loc = self.gdir(GOOD_ADC)
        r = FakeRunner({(CONNECTOR, "_gcp", "dir"): loc})
        rc, fio = run_wizard(["y", "2", "1", "my-project-1"], r, confirm=True)
        self.assertEqual(rc, w.OK)
        self.assertEqual(r.argvs(), [[CONNECTOR, "_gcp", "dir"],
                                     [CONNECTOR, "gcp", "--project", "my-project-1"],
                                     [CONNECTOR, "verify", "--name", "my-project-1"]])
        self.assertIn("✔ Cloud connection 'my-project-1'", fio.text)
        self.assertIn("attached to the configured workspace", fio.text)
        self.assertIn("Ticket execution has not been tested by this wizard", fio.text)
        self.assertNotIn("tests/e2e", fio.text)                  # no developer-harness / LLM detail in product copy
        self.assertNotIn("LLM", fio.text)
        self.assertNotIn("default workspace", fio.text)
        self.assertNotIn(REFRESH, fio.text)
        self.assertNotIn("s3cr3t-client", fio.text)

    def test_eof_at_every_stage_cancels_without_connecting(self):
        _, _, loc = self.gdir(GOOD_ADC)
        for answers in ([], ["y"], ["y", "1"], ["y", "1", "2"], ["y", "2"], ["y", "2", "1"], ["y", "1", "1"], ["y", "1", "1", "1"]):
            r = aws_runner(["p1", "p2"], on={(CONNECTOR, "_gcp", "dir"): loc})
            rc, fio = run_wizard(answers, r, confirm=True)
            self.assertEqual(rc, w.CANCELLED, answers)
            self.assertEqual(self.connects(r) + self.verifies(r), [], answers)
            self.assertNotIn("✔", fio.text)

    def test_q_cancels_from_any_menu(self):
        for answers in (["q"], ["1", "q"], ["2", "q"], ["2", "1", "q"], ["1", "2", "q"]):
            r = aws_runner(["p1"])
            rc, _ = run_wizard(answers, r)
            self.assertEqual(rc, w.CANCELLED, answers)
            self.assertEqual(self.connects(r), [], answers)

    def test_invalid_menu_input_is_reasked(self):
        _, _, loc = self.gdir(GOOD_ADC)
        r = FakeRunner({(CONNECTOR, "_gcp", "dir"): loc})
        rc, fio = run_wizard(["", "9", "aws?", "0", "b", "2", "7", "1", "My Project", "123", "good-project"], r)
        self.assertEqual(rc, w.OK)
        self.assertEqual(self.connects(r), [[CONNECTOR, "gcp", "--project", "good-project"]])
        self.assertIn("is not one of the choices", fio.text)
        self.assertIn("There is no previous step here", fio.text)
        self.assertIn("not a GCP project ID", fio.text)

    def test_nothing_is_looked_up_before_cloud_and_method(self):
        r = aws_runner(["only"])
        run_wizard(["1"], r)                 # cloud chosen, method not: EOF
        self.assertEqual(r.calls, [])
        r = FakeRunner()
        run_wizard(["2"], r)
        self.assertEqual(r.calls, [])

    def test_back_from_aws_method_returns_to_cloud_menu(self):
        _, _, loc = self.gdir(GOOD_ADC)
        r = aws_runner(["p1"], on={(CONNECTOR, "_gcp", "dir"): loc})
        rc, _ = run_wizard(["1", "2", "b", "b", "2", "1", "b", "1", "proj-abc"], r)
        self.assertEqual(rc, w.OK)
        self.assertEqual(self.connects(r), [[CONNECTOR, "gcp", "--project", "proj-abc"]])


class Azure(WizardCase):
    def test_azure_is_unsupported_and_returns_to_the_menu(self):
        r = FakeRunner()
        rc, fio = run_wizard(["3", "3"], r)                  # twice, then EOF
        self.assertEqual(rc, w.CANCELLED)
        self.assertEqual(r.calls, [])                        # nothing Azure (or anything) was run or probed
        self.assertEqual(fio.text.count("Azure is not supported yet"), 2)
        self.assertEqual(fio.text.count("Which cloud do you want to connect?"), 3)
        self.assertNotIn("az login", fio.text)

    def test_azure_then_aws_still_works(self):
        r = aws_runner(["dev"])
        rc, _ = run_wizard(["3", "1", "2", "1"], r)
        self.assertEqual(rc, w.OK)
        self.assertEqual(self.connects(r), [[CONNECTOR, "aws", "--name", "dev", "--profile", "dev", "--region", "us-east-1"]])


class Aws(WizardCase):
    def test_existing_profile_connects_with_its_region_and_verifies(self):
        r = aws_runner(["dev", "prod"], {"prod": {"region": "eu-west-2"}})
        rc, fio = run_wizard(["1", "2", "2"], r)
        self.assertEqual(rc, w.OK)
        self.assertEqual(self.connects(r), [[CONNECTOR, "aws", "--name", "prod", "--profile", "prod", "--region", "eu-west-2"]])
        self.assertEqual(self.verifies(r), [[CONNECTOR, "verify", "--name", "prod"]])
        self.assertFalse(any(a[:3] == ["aws", "sso", "login"] for a in r.argvs()))
        self.assertIn("backend populated credentials", fio.text)
        self.assertIn("Ticket execution has not been tested by this wizard", fio.text)

    def test_sole_profile_is_never_chosen_automatically(self):
        r = aws_runner(["only"])
        rc, fio = run_wizard(["1", "2"], r)                  # EOF at the profile question
        self.assertEqual(rc, w.CANCELLED)
        self.assertIn("1) only", fio.text)
        self.assertEqual(self.connects(r), [])
        self.assertEqual([a for a in r.argvs() if a[:3] == ["aws", "configure", "get"]], [])

    def test_env_profile_and_keys_are_not_defaults_and_keys_do_not_leak(self):
        env = {"PATH": "/fake", "AWS_PROFILE": "ambient", "AWS_DEFAULT_PROFILE": "ambient2",
               "AWS_ACCESS_KEY_ID": "AKIAEXAMPLE", "AWS_SECRET_ACCESS_KEY": "shh", "AWS_SESSION_TOKEN": "tok",
               "AWS_REGION": "ap-south-1"}
        r = aws_runner(["chosen", "ambient"])
        rc, fio = run_wizard(["1", "2", "1"], r, env=env)
        self.assertEqual(rc, w.OK)
        self.assertEqual(self.connects(r), [[CONNECTOR, "aws", "--name", "chosen", "--profile", "chosen", "--region", "us-east-1"]])
        for kind, argv, cenv in r.calls:
            self.assertNotIn("ambient", argv)
            self.assertNotIn("shh", " ".join(argv))
            if argv[0] == "aws":                             # lookups never answer from static keys in the shell
                self.assertNotIn("AWS_SECRET_ACCESS_KEY", cenv)
                self.assertNotIn("AWS_ACCESS_KEY_ID", cenv)
        self.assertNotIn("shh", fio.text)

    def test_typed_profile_name_and_unknown_name_reasked(self):
        r = aws_runner(["a", "b"])
        rc, fio = run_wizard(["1", "2", "nope", "has space", "b"], r)   # "b" here is "back", not profile b
        self.assertEqual(rc, w.CANCELLED)
        self.assertIn("There is no AWS profile named 'nope'", fio.text)
        self.assertIn("not a valid AWS profile name", fio.text)
        r = aws_runner(["a", "typed-one"])
        rc, _ = run_wizard(["1", "2", "typed-one"], r)
        self.assertEqual(rc, w.OK)
        self.assertEqual(self.connects(r)[0][2:6], ["--name", "typed-one", "--profile", "typed-one"])

    def test_credential_process_profile_never_gets_sso_login(self):
        r = aws_runner(["jit"], {"jit": {"credential_process": "duplo-jit aws --admin --host https://x --interactive",
                                         "sso_start_url": "https://should-be-ignored"}})
        rc, fio = run_wizard(["1", "2", "1"], r)
        self.assertEqual(rc, w.OK)
        self.assertFalse(any(a[:2] == ["aws", "sso"] or a[:2] == ["aws", "sts"] for a in r.argvs()))
        kinds = {tuple(a[:2]): k for k, a, _ in r.calls}
        self.assertEqual(kinds[(CONNECTOR, "aws")], "interactive")       # the connector inherits the terminal
        self.assertIn("credential_process", fio.text)
        self.assertNotIn("duplo-jit aws --admin", fio.text)              # its command line is not echoed

    def test_existing_sso_profile_with_live_session_is_not_logged_in_again(self):
        r = aws_runner(["sso1"], {"sso1": {"sso_session": "corp", "region": "us-west-2"}},
                       on={("aws", "sts", "get-caller-identity"): (0, '{"Account":"1"}', "")})
        rc, _ = run_wizard(["1", "1", "2", "1"], r)
        self.assertEqual(rc, w.OK)
        self.assertFalse(any(a[:3] == ["aws", "sso", "login"] for a in r.argvs()))
        self.assertEqual(self.connects(r), [[CONNECTOR, "aws", "--name", "sso1", "--profile", "sso1", "--region", "us-west-2"]])

    def test_existing_sso_profile_expired_logs_in_only_that_profile_then_connects(self):
        r = aws_runner(["other", "sso1"], {"sso1": {"sso_start_url": "https://d-1.awsapps.com/start"}, "other": {"sso_session": "x"}},
                       on={("aws", "sts", "get-caller-identity"): (255, "", "Token has expired")})
        rc, _ = run_wizard(["1", "1", "2", "2"], r)
        self.assertEqual(rc, w.OK)
        logins = [a for a in r.argvs("interactive") if a[:2] == ["aws", "sso"]]
        self.assertEqual(logins, [["aws", "sso", "login", "--profile", "sso1"]])
        order = [tuple(a[:3]) for a in r.argvs("interactive")]
        self.assertLess(order.index(("aws", "sso", "login")), order.index((CONNECTOR, "aws", "--name")))

    def test_sso_login_failure_is_a_failure_without_connect(self):
        r = aws_runner(["sso1"], {"sso1": {"sso_session": "corp"}},
                       on={("aws", "sts", "get-caller-identity"): (255, "", ""), ("aws", "sso", "login"): 1})
        rc, fio = run_wizard(["1", "1", "2", "1"], r)
        self.assertEqual(rc, w.FAILED)
        self.assertEqual(self.connects(r), [])
        self.assertIn("aws sso login --profile sso1 did not complete", fio.text)
        self.assertIn("remains available", fio.text)

    def test_non_sso_profile_under_the_sso_choice_is_refused_then_reasked(self):
        r = aws_runner(["plain"])
        rc, fio = run_wizard(["1", "1", "2", "1"], r)
        self.assertEqual(rc, w.CANCELLED)
        self.assertIn("'plain' is not an IAM Identity Center profile", fio.text)
        self.assertEqual(self.connects(r), [])
        self.assertFalse(any(a[:2] == ["aws", "sso"] for a in r.argvs()))

    def test_new_sso_profile_runs_configure_sso_with_the_named_profile(self):
        cfg: dict = {}
        profiles = ["old"]

        def configure(argv, env):
            profiles.append(argv[-1]); cfg[argv[-1]] = {"sso_session": "new", "region": "us-east-2"}
            return 0

        r = aws_runner(profiles, cfg, on={("aws", "configure", "sso"): configure,
                                           ("aws", "configure", "list-profiles"): lambda a, e: (0, "\n".join(profiles), ""),
                                           ("aws", "sts", "get-caller-identity"): (0, "{}", "")})
        rc, fio = run_wizard(["1", "1", "1", "old", "1", "acct-a"], r)   # refused name → back at the SSO menu
        self.assertEqual(rc, w.OK)
        self.assertIn("A profile named 'old' already exists", fio.text)
        self.assertEqual([a for a in r.argvs("interactive") if a[0] == "aws"], [["aws", "configure", "sso", "--profile", "acct-a"]])
        self.assertEqual(self.connects(r), [[CONNECTOR, "aws", "--name", "acct-a", "--profile", "acct-a", "--region", "us-east-2"]])

    def test_new_sso_configure_failure_fails_honestly(self):
        r = aws_runner([], on={("aws", "configure", "sso"): 130})
        rc, fio = run_wizard(["1", "1", "1", "acct-a"], r)
        self.assertEqual(rc, w.FAILED)
        self.assertEqual(self.connects(r), [])
        self.assertIn("AWS was not connected", fio.text)

    def test_access_keys_method_asks_for_no_secret(self):
        r = aws_runner(["keys"])
        rc, fio = run_wizard(["1", "3", "1"], r)
        self.assertEqual(rc, w.OK)
        prompts = [ln for ln in fio.out if ln.rstrip().endswith(": ")]
        self.assertFalse(any("secret" in p.lower() or "access key id" in p.lower() for p in prompts))
        r = aws_runner([])
        rc, fio = run_wizard(["1", "3"], r)
        self.assertIn("aws configure --profile <name>", fio.text)
        self.assertFalse(any(a[:2] == ["aws", "configure"] and "list-profiles" not in a for a in r.argvs()))

    def test_profile_name_that_is_not_a_connection_name_asks_for_one(self):
        r = aws_runner(["Corp.Admin"])
        rc, fio = run_wizard(["1", "2", "1", "Bad Name", "corp-admin"], r)
        self.assertEqual(rc, w.OK)
        self.assertEqual(self.connects(r), [[CONNECTOR, "aws", "--name", "corp-admin", "--profile", "Corp.Admin", "--region", "us-east-1"]])
        self.assertEqual(self.verifies(r), [[CONNECTOR, "verify", "--name", "corp-admin"]])

    def test_missing_aws_cli(self):
        r = FakeRunner(have=())
        rc, fio = run_wizard(["1", "2"], r)
        self.assertEqual(rc, w.FAILED)
        self.assertEqual(r.calls, [])
        self.assertIn("'aws' command is not installed", fio.text)

    def test_connect_failure_is_not_success_and_skips_verify(self):
        r = aws_runner(["dev"], on={(CONNECTOR, "aws"): 1})
        rc, fio = run_wizard(["1", "2", "1"], r)
        self.assertEqual(rc, w.FAILED)
        self.assertEqual(self.verifies(r), [])
        self.assertNotIn("✔", fio.text)
        self.assertIn("NOT completed", fio.text)

    def test_verify_failure_is_not_success(self):
        r = aws_runner(["dev"], on={(CONNECTOR, "verify"): 1})
        rc, fio = run_wizard(["1", "2", "1"], r)
        self.assertEqual(rc, w.FAILED)
        self.assertNotIn("✔", fio.text)
        self.assertIn("verification FAILED", fio.text)
        self.assertIn("./scripts/connect-cloud.sh verify --name dev", fio.text)


class Gcp(WizardCase):
    def test_service_account_key_choice_is_unsupported_and_asks_for_no_path(self):
        r = FakeRunner()
        rc, fio = run_wizard(["2", "2"], r)
        self.assertEqual(rc, w.CANCELLED)
        self.assertEqual(r.calls, [])
        self.assertIn("A service-account key is not supported", fio.text)
        self.assertEqual(fio.text.count("How do you sign in to GCP?"), 2)
        self.assertFalse(any("path" in ln.lower() and ln.rstrip().endswith(": ") for ln in fio.out))

    def test_valid_adc_means_no_login_and_only_the_project_is_asked(self):
        _, _, loc = self.gdir(GOOD_ADC)
        r = FakeRunner({(CONNECTOR, "_gcp", "dir"): loc})
        rc, fio = run_wizard(["2", "1", "proj-one"], r)
        self.assertEqual(rc, w.OK)
        self.assertFalse(any(a[0] == "gcloud" for a in r.argvs()))
        self.assertEqual(fio.answers, [])
        self.assertEqual(self.connects(r), [[CONNECTOR, "gcp", "--project", "proj-one"]])   # no --name/--service-account
        self.assertIn("runtime-file", fio.text)

    def test_missing_adc_logs_in_to_the_bound_directory(self):
        d, f, loc = self.gdir(None)

        def login(argv, env):
            with open(f, "w") as fh:
                json.dump(GOOD_ADC, fh)
            return 0

        r = FakeRunner({(CONNECTOR, "_gcp", "dir"): loc, ("gcloud",): login})
        rc, fio = run_wizard(["2", "1", "proj-one", "y"], r, env={"PATH": "/fake", "CLOUDSDK_CONFIG": "/somewhere/else"})
        self.assertEqual(rc, w.OK)
        g = [(a, e) for k, a, e in r.calls if a[0] == "gcloud"]
        self.assertEqual([a for a, _ in g], [["gcloud", "auth", "application-default", "login"]])
        self.assertEqual(g[0][1]["CLOUDSDK_CONFIG"], d)
        self.assertIn(f"CLOUDSDK_CONFIG='{d}' gcloud auth application-default login", fio.text)
        order = [a[:2] for a in r.argvs()]
        self.assertLess(order.index(["gcloud", "auth"]), order.index([CONNECTOR, "gcp"]))

    def test_default_directory_login_does_not_set_cloudsdk_config(self):
        d, f, loc = self.gdir("{not json", source="default ($HOME/.config/gcloud)")

        def login(argv, env):
            with open(f, "w") as fh:
                json.dump(GOOD_ADC, fh)
            return 0

        r = FakeRunner({(CONNECTOR, "_gcp", "dir"): loc, ("gcloud",): login})
        rc, fio = run_wizard(["2", "1", "proj-one", "y"], r, env={"PATH": "/fake"})
        self.assertEqual(rc, w.OK)
        env = [e for k, a, e in r.calls if a[0] == "gcloud"][0]
        self.assertNotIn("CLOUDSDK_CONFIG", env)
        self.assertIn("Run `gcloud auth application-default login` now", fio.text)

    def test_wrong_type_adc_offers_login_and_decline_fails_with_the_exact_command(self):
        d, _, loc = self.gdir({"type": "service_account", "private_key": "-----BEGIN PRIVATE KEY-----abc"})
        r = FakeRunner({(CONNECTOR, "_gcp", "dir"): loc})
        rc, fio = run_wizard(["2", "1", "proj-one", "maybe", "n"], r)
        self.assertEqual(rc, w.FAILED)
        self.assertEqual(self.connects(r), [])
        self.assertFalse(any(a[0] == "gcloud" for a in r.argvs()))
        self.assertIn("not a user login", fio.text)
        self.assertIn(f"CLOUDSDK_CONFIG='{d}' gcloud auth application-default login", fio.text)
        self.assertNotIn("BEGIN PRIVATE KEY", fio.text)

    def test_missing_gcloud_cli(self):
        _, _, loc = self.gdir(None)
        r = FakeRunner({(CONNECTOR, "_gcp", "dir"): loc}, have=("aws",))
        rc, fio = run_wizard(["2", "1", "proj-one", "y"], r)
        self.assertEqual(rc, w.FAILED)
        self.assertIn("'gcloud' command is not installed", fio.text)
        self.assertEqual(self.connects(r), [])

    def test_login_failure_and_login_that_leaves_no_file(self):
        _, _, loc = self.gdir(None)
        r = FakeRunner({(CONNECTOR, "_gcp", "dir"): loc, ("gcloud",): 1})
        rc, fio = run_wizard(["2", "1", "proj-one", "y"], r)
        self.assertEqual(rc, w.FAILED)
        self.assertIn("did not complete (exit 1)", fio.text)
        r = FakeRunner({(CONNECTOR, "_gcp", "dir"): loc, ("gcloud",): 0})
        rc, fio = run_wizard(["2", "1", "proj-one", "y"], r)
        self.assertEqual(rc, w.FAILED)
        self.assertIn("the login finished but there is no Application Default Credentials file", fio.text)
        self.assertEqual(self.connects(r), [])

    def test_expired_login_reported_by_the_connector_offers_one_login_and_one_retry(self):
        _, _, loc = self.gdir(GOOD_ADC)
        r = FakeRunner({(CONNECTOR, "_gcp", "dir"): loc,
                        (CONNECTOR, "gcp"): [(1, "✗ the ADC refresh token was rejected by Google (HTTP 400: invalid_grant). Re-run: …\n"),
                                             (0, "")]})
        rc, fio = run_wizard(["2", "1", "proj-one", "y"], r)
        self.assertEqual(rc, w.OK)
        self.assertEqual([a[:2] for a in r.argvs() if a[0] in ("gcloud", CONNECTOR)],
                         [[CONNECTOR, "_gcp"], [CONNECTOR, "gcp"], ["gcloud", "auth"], [CONNECTOR, "gcp"], [CONNECTOR, "verify"]])

    def test_expired_login_retry_that_fails_again_does_not_loop(self):
        _, _, loc = self.gdir(GOOD_ADC)
        bad = (1, "✗ the ADC refresh token was rejected by Google\n")
        r = FakeRunner({(CONNECTOR, "_gcp", "dir"): loc, (CONNECTOR, "gcp"): [bad, bad, bad]})
        rc, fio = run_wizard(["2", "1", "proj-one", "y", "y"], r)
        self.assertEqual(rc, w.FAILED)
        self.assertEqual(len(self.connects(r)), 2)
        self.assertEqual(len([a for a in r.argvs() if a[0] == "gcloud"]), 1)
        self.assertEqual(self.verifies(r), [])

    def test_arbitrary_connector_failure_never_triggers_a_login(self):
        _, _, loc = self.gdir(GOOD_ADC)
        for tail in ("✗ this ADC identity cannot impersonate helpdesk-sa@p (HTTP 403: denied)\n",
                     "✗ https://oauth2.googleapis.com/token: timed out\n", "✗ workspace not found\n", ""):
            r = FakeRunner({(CONNECTOR, "_gcp", "dir"): loc, (CONNECTOR, "gcp"): (1, tail)})
            rc, fio = run_wizard(["2", "1", "proj-one", "y"], r)
            self.assertEqual(rc, w.FAILED, tail)
            self.assertFalse(any(a[0] == "gcloud" for a in r.argvs()), tail)
            self.assertEqual(len(self.connects(r)), 1)
            self.assertEqual(self.verifies(r), [])
            self.assertNotIn("✔", fio.text)

    def test_incomplete_adc_triggers_the_login_flow_for_each_required_field(self):
        for missing in ("client_id", "client_secret", "refresh_token"):
            for broken in ({k: v for k, v in GOOD_ADC.items() if k != missing}, dict(GOOD_ADC, **{missing: ""})):
                d, f, loc = self.gdir(broken)

                def login(argv, env, f=f):
                    with open(f, "w") as fh:
                        json.dump(GOOD_ADC, fh)
                    return 0

                r = FakeRunner({(CONNECTOR, "_gcp", "dir"): loc, ("gcloud",): login})
                rc, fio = run_wizard(["2", "1", "proj-one", "y"], r)
                self.assertEqual(rc, w.OK, missing)
                self.assertEqual([a[:2] for a in r.argvs()],
                                 [[CONNECTOR, "_gcp"], ["gcloud", "auth"], [CONNECTOR, "gcp"], [CONNECTOR, "verify"]], missing)
                self.assertIn(f"incomplete (no {missing})", fio.text)
                for secret in (REFRESH, "s3cr3t-client"):
                    self.assertNotIn(secret, fio.text)
                    self.assertFalse(any(secret in " ".join(a) for a in r.argvs()))

    def test_no_blanket_no_change_claim_after_a_step_ran(self):
        _, _, loc = self.gdir(GOOD_ADC)
        # connect fails · verify fails · cancel (EOF) at the re-login question after the connector already ran
        cases = (({(CONNECTOR, "gcp"): (1, "✗ backend restarted, then scope conflict\n")}, w.FAILED),
                 ({(CONNECTOR, "verify"): 1}, w.FAILED),
                 ({(CONNECTOR, "gcp"): (1, "✗ the ADC refresh token was rejected by Google\n")}, w.CANCELLED))
        for on, want in cases:
            r = FakeRunner({(CONNECTOR, "_gcp", "dir"): loc, **on})
            rc, fio = run_wizard(["2", "1", "proj-one"], r)
            self.assertEqual(rc, want)
            low = fio.text.lower()
            for claim in ("untouched", "nothing was changed", "stopped or restarted nothing", "no connection was made"):
                self.assertNotIn(claim, low)
            self.assertIn("remains available", fio.text)
            self.assertIn("setup is incomplete", fio.text)
            self.assertIn("shown in the output of the steps above", fio.text)

    def test_no_change_wording_is_kept_when_no_step_ran(self):
        r = FakeRunner()
        rc, fio = run_wizard(["2", "q"], r)
        self.assertEqual(rc, w.CANCELLED)
        self.assertIn("Cancelled before any step was run — nothing was changed", fio.text)
        r = FakeRunner(have=())
        rc, fio = run_wizard(["1", "2"], r)
        self.assertEqual(rc, w.FAILED)
        self.assertIn("No step was run, so nothing was changed", fio.text)
        self.assertIn("remains available", fio.text)

    def test_stack_not_ready_is_reported_from_the_connector(self):
        r = FakeRunner({(CONNECTOR, "_gcp", "dir"): (1, "", "No token resolved — run ./run.sh first (it writes DUPLO_ADMIN_TOKEN to .env).\n")})
        rc, fio = run_wizard(["2", "1", "proj-one"], r)
        self.assertEqual(rc, w.FAILED)
        self.assertIn("run ./run.sh first", fio.text)
        self.assertEqual(self.connects(r), [])

    def test_verify_failure_is_not_success(self):
        _, _, loc = self.gdir(GOOD_ADC)
        r = FakeRunner({(CONNECTOR, "_gcp", "dir"): loc, (CONNECTOR, "verify"): 1})
        rc, fio = run_wizard(["2", "1", "proj-one"], r)
        self.assertEqual(rc, w.FAILED)
        self.assertNotIn("✔", fio.text)
        self.assertIn("verification FAILED", fio.text)

    def test_ambient_project_settings_are_never_used(self):
        _, _, loc = self.gdir(GOOD_ADC)
        env = {"PATH": "/fake", "CLOUDSDK_CORE_PROJECT": "ambient-project", "GOOGLE_CLOUD_PROJECT": "ambient-project",
               "GCLOUD_PROJECT": "ambient-project"}
        r = FakeRunner({(CONNECTOR, "_gcp", "dir"): loc})
        rc, fio = run_wizard(["2", "1"], r, env=env)          # EOF at the project question: nothing is defaulted
        self.assertEqual(rc, w.CANCELLED)
        self.assertEqual(r.calls, [])
        self.assertNotIn("ambient-project", fio.text)


# ── the real script, as a subprocess, with fake executables ─────────────────────

BASH = shutil.which("bash") or "/bin/bash"


def _exe(path: str, body: str) -> None:
    with open(path, "w") as fh:
        fh.write(f"#!{BASH}\n{body}")
    os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


class Subprocess(unittest.TestCase):
    """scripts/cloud_connect_wizard.py copied into a throw-away tree whose connect-cloud.sh is a recorder. PATH
    holds ONLY the fakes, HOME is the temp dir, and nothing from the caller's environment is passed on."""

    def setUp(self):
        self.tmp = os.path.realpath(tempfile.mkdtemp(prefix="wizard-e2e-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.scripts = os.path.join(self.tmp, "kit", "scripts")
        self.bin = os.path.join(self.tmp, "bin")
        self.gcloud_dir = os.path.join(self.tmp, "gc")
        for d in (self.scripts, self.bin, self.gcloud_dir):
            os.makedirs(d)
        self.log = os.path.join(self.tmp, "calls.log")
        self.adc = os.path.join(self.gcloud_dir, "application_default_credentials.json")
        shutil.copy(os.path.join(ROOT, "scripts", "cloud_connect_wizard.py"), self.scripts)
        # Each fake appends "<tool>|<arg>|<arg>…" (+ the CLOUDSDK_CONFIG it saw) and obeys FAKE_* switches.
        _exe(os.path.join(self.scripts, "connect-cloud.sh"), r'''
{ printf 'connector'; printf '|%s' "$@"; printf '\n'; } >> "$FAKE_LOG"
case "$1" in
  _gcp) printf '{"dir":"%s","file":"%s/application_default_credentials.json","source":"DEVKIT_GCLOUD_DIR (environment)"}\n' "$FAKE_GDIR" "$FAKE_GDIR" ;;
  gcp)  if [ -n "${FAKE_GCP_FAIL_ONCE-}" ] && [ ! -e "$FAKE_GDIR/.failed" ]; then : > "$FAKE_GDIR/.failed"
          echo "✗ the ADC refresh token was rejected by Google (HTTP 400: invalid_grant)." >&2; exit 1; fi
        [ -z "${FAKE_CONNECT_FAIL-}" ] || { echo "✗ scope conflict: name already used" >&2; exit 1; }
        echo "✔ gcp: connection ready" ;;
  aws)  [ -z "${FAKE_CONNECT_FAIL-}" ] || { echo "✗ export-credentials failed" >&2; exit 1; }
        echo "✔ aws: connection ready" ;;
  verify) [ -z "${FAKE_VERIFY_FAIL-}" ] || { echo "✗ verify: scope expansion failed" >&2; exit 1; }
        echo "verify ok" ;;
esac
''')
        _exe(os.path.join(self.bin, "aws"), r'''
{ printf 'aws'; printf '|%s' "$@"; printf '\n'; } >> "$FAKE_LOG"
case "$1 $2" in
  "configure list-profiles") printf 'jit\nsso-a\nplain\n' ;;
  "configure get")
     case "$3:$5" in
       credential_process:jit) echo "duplo-jit aws --interactive" ;;
       sso_session:sso-a) echo corp ;;
       region:sso-a) echo eu-central-1 ;;
       *) exit 1 ;;
     esac ;;
  "sts get-caller-identity") exit 255 ;;
  "sso login") exit "${FAKE_SSO_LOGIN_RC:-0}" ;;
esac
''')
        _exe(os.path.join(self.bin, "gcloud"), r'''
{ printf 'gcloud'; printf '|%s' "$@"; printf '|CLOUDSDK_CONFIG=%s\n' "${CLOUDSDK_CONFIG-}"; } >> "$FAKE_LOG"
printf '{"type":"authorized_user","client_id":"i","client_secret":"s","refresh_token":"r"}' > "$CLOUDSDK_CONFIG/application_default_credentials.json"
''')

    def wizard(self, answers: str, args=("--yes",), path=None, allow_no_tty=True, **extra):
        env = {"PATH": self.bin if path is None else path, "HOME": self.tmp, "FAKE_LOG": self.log, "FAKE_GDIR": self.gcloud_dir}
        if allow_no_tty:
            env["CLOUD_CONNECT_WIZARD_ALLOW_NO_TTY"] = "1"
        env.update(extra)
        p = subprocess.run([sys.executable, "-I", os.path.join(self.scripts, "cloud_connect_wizard.py"), *args],
                           input=answers, capture_output=True, text=True, env=env, timeout=60, cwd=self.tmp)
        calls = []
        if os.path.exists(self.log):
            with open(self.log) as fh:
                calls = fh.read().splitlines()
        return p, calls

    def test_gcp_login_connect_verify_end_to_end(self):
        p, calls = self.wizard("y\n2\n1\nacme-prod-1\ny\n", args=())
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertEqual(calls, ["connector|_gcp|dir",
                                 f"gcloud|auth|application-default|login|CLOUDSDK_CONFIG={self.gcloud_dir}",
                                 "connector|gcp|--project|acme-prod-1",
                                 "connector|verify|--name|acme-prod-1"])
        self.assertIn("✔ Cloud connection 'acme-prod-1'", p.stdout)
        self.assertIn("Ticket execution has not been tested by this wizard", p.stdout)

    def test_gcp_with_existing_login_does_not_log_in_again(self):
        with open(self.adc, "w") as fh:
            json.dump(GOOD_ADC, fh)
        p, calls = self.wizard("2\n1\nacme-prod-1\n")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertFalse([c for c in calls if c.startswith("gcloud")])
        self.assertNotIn(REFRESH, p.stdout + p.stderr)

    def test_gcp_expired_login_is_recognised_from_relayed_stderr(self):
        with open(self.adc, "w") as fh:
            json.dump(GOOD_ADC, fh)
        p, calls = self.wizard("2\n1\nacme-prod-1\ny\n", FAKE_GCP_FAIL_ONCE="1")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertEqual([c.split("|")[0] + "|" + c.split("|")[1] for c in calls],
                         ["connector|_gcp", "connector|gcp", "gcloud|auth", "connector|gcp", "connector|verify"])
        self.assertIn("refresh token was rejected", p.stderr)            # the connector's own message was shown

    def test_gcp_other_failure_exits_1_without_login_or_verify(self):
        with open(self.adc, "w") as fh:
            json.dump(GOOD_ADC, fh)
        p, calls = self.wizard("2\n1\nacme-prod-1\n", FAKE_CONNECT_FAIL="1")
        self.assertEqual(p.returncode, 1)
        self.assertEqual(calls, ["connector|_gcp|dir", "connector|gcp|--project|acme-prod-1"])
        self.assertIn("scope conflict", p.stderr)
        self.assertNotIn("✔ Cloud connection", p.stdout)
        self.assertIn("remains available", p.stdout)
        self.assertIn("shown in the output of the steps above", p.stdout)
        self.assertNotIn("nothing was changed", p.stdout.lower())

    def test_aws_credential_process_profile_no_sso(self):
        p, calls = self.wizard("1\n2\n1\n")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertFalse([c for c in calls if c.startswith("aws|sso") or c.startswith("aws|sts")])
        self.assertEqual(calls[-2:], ["connector|aws|--name|jit|--profile|jit|--region|us-east-1", "connector|verify|--name|jit"])

    def test_aws_sso_profile_expired_scoped_login_then_connect(self):
        p, calls = self.wizard("1\n1\n2\n2\n")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertEqual([c for c in calls if c.startswith("aws|sso")], ["aws|sso|login|--profile|sso-a"])
        self.assertEqual(calls[-2:], ["connector|aws|--name|sso-a|--profile|sso-a|--region|eu-central-1", "connector|verify|--name|sso-a"])

    def test_aws_sso_login_failure_exits_1(self):
        p, calls = self.wizard("1\n1\n2\n2\n", FAKE_SSO_LOGIN_RC="1")
        self.assertEqual(p.returncode, 1)
        self.assertFalse([c for c in calls if c.startswith("connector")])

    def test_verify_failure_exits_1(self):
        p, calls = self.wizard("1\n2\n3\n", FAKE_VERIFY_FAIL="1")
        self.assertEqual(p.returncode, 1)
        self.assertEqual(calls[-1], "connector|verify|--name|plain")
        self.assertNotIn("✔ Cloud connection", p.stdout)
        self.assertIn("verification FAILED", p.stdout)

    def test_missing_cli_exits_1_with_install_hint(self):
        empty = os.path.join(self.tmp, "empty"); os.makedirs(empty)
        p, calls = self.wizard("1\n2\n", path=empty)
        self.assertEqual(p.returncode, 1)
        self.assertEqual(calls, [])
        self.assertIn("'aws' command is not installed", p.stdout)

    def test_no_decline_eof_and_cancel_exit_130_and_run_nothing(self):
        for answers, args in (("n\n", ()), ("", ()), ("", ("--yes",)), ("q\n", ("--yes",)), ("3\n", ("--yes",)), ("2\n1\n", ("--yes",))):
            p, calls = self.wizard(answers, args=args)
            self.assertEqual(p.returncode, 130, (answers, p.stdout, p.stderr))
            self.assertEqual(calls, [], answers)

    def test_without_a_terminal_it_refuses_instead_of_prompting(self):
        p, calls = self.wizard("y\n1\n", args=(), allow_no_tty=False)
        self.assertEqual(p.returncode, 2)
        self.assertEqual(calls, [])
        self.assertEqual(p.stdout, "")
        self.assertIn("needs a terminal", p.stderr)

    def test_unknown_argument_is_usage(self):
        p, calls = self.wizard("", args=("--profile", "x"))
        self.assertEqual(p.returncode, 2)
        self.assertEqual(calls, [])


# ── run.sh's final block under a pseudo-terminal ────────────────────────────────

def _run_sh_block() -> str:
    with open(os.path.join(ROOT, "run.sh")) as fh:
        lines = fh.read().split("\n")
    start = next(i for i, ln in enumerate(lines) if ln.startswith("# ── optional cloud onboarding"))
    return "\n".join(lines[start:])


@unittest.skipUnless(hasattr(os, "fork") and sys.platform != "win32", "needs a pty")
class RunShBlock(unittest.TestCase):
    def setUp(self):
        self.tmp = os.path.realpath(tempfile.mkdtemp(prefix="wizard-runsh-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        os.makedirs(os.path.join(self.tmp, "scripts"))
        self.marker = os.path.join(self.tmp, "wizard-called")
        _exe(os.path.join(self.tmp, "scripts", "cloud-connect-wizard.sh"),
             'printf "%s\\n" "$*" > "$FAKE_MARKER"\necho "FAKE WIZARD RAN"\nexit "${FAKE_WIZARD_RC:-0}"\n')

    def block(self, typed: bytes, **extra):
        """Run the block exactly as run.sh ends (set -euo pipefail), on a pty. → (exit status, output)."""
        import pty
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": self.tmp, "NONINTERACTIVE": "0", "FAKE_MARKER": self.marker}
        env.update(extra)
        pid, fd = pty.fork()
        if pid == 0:                                             # child: stdin/stdout/stderr are the pty
            try:
                os.chdir(self.tmp)
                os.execve(BASH, [BASH, "-c", "set -euo pipefail\n" + _run_sh_block() + "\necho BLOCK-DONE\n"], env)
            finally:
                os._exit(127)
        out, sent, deadline = b"", False, time.time() + 20
        while time.time() < deadline:
            r, _, _ = select.select([fd], [], [], 0.2)
            if r:
                try:
                    chunk = os.read(fd, 4096)
                except OSError:
                    break
                if not chunk:
                    break
                out += chunk
            if not sent and b"[y/N]" in out:
                os.write(fd, typed)
                sent = True
        else:
            os.kill(pid, 9)
            os.waitpid(pid, 0)
            self.fail(f"run.sh block hung; output so far: {out!r}")
        _, status = os.waitpid(pid, 0)
        os.close(fd)
        return os.waitstatus_to_exitcode(status), out.decode(errors="replace")

    def test_yes_runs_the_wizard_with_yes(self):
        rc, out = self.block(b"y\n")
        self.assertEqual(rc, 0, out)
        with open(self.marker) as fh:
            self.assertEqual(fh.read().strip(), "--yes")
        self.assertIn("FAKE WIZARD RAN", out)
        self.assertIn("BLOCK-DONE", out)
        self.assertNotIn("No verified cloud connection", out)
        self.assertNotIn("start Claude Code", out)               # the old manual hand-off is gone

    def test_failed_or_cancelled_wizard_does_not_fail_run_sh(self):
        for wrc in ("1", "130"):
            rc, out = self.block(b"yes\n", FAKE_WIZARD_RC=wrc)
            self.assertEqual(rc, 0, out)
            self.assertIn("BLOCK-DONE", out)
            self.assertIn("No verified cloud connection was made", out)
            self.assertIn("The dev kit is up and usable", out)

    def test_no_and_empty_answer_skip_the_wizard(self):
        for typed in (b"n\n", b"\n", b"maybe\n"):
            rc, out = self.block(typed)
            self.assertEqual(rc, 0, out)
            self.assertFalse(os.path.exists(self.marker), typed)
            self.assertIn("BLOCK-DONE", out)

    def test_ci_and_non_interactive_never_prompt_even_on_a_terminal(self):
        for extra in ({"CI": "true"}, {"NONINTERACTIVE": "1"}):
            rc, out = self.block(b"y\n", **extra)
            self.assertEqual(rc, 0, out)
            self.assertNotIn("[y/N]", out)
            self.assertFalse(os.path.exists(self.marker))


if __name__ == "__main__":
    unittest.main(verbosity=1)
