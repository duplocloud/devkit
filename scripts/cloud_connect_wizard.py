#!/usr/bin/env python3
"""cloud_connect_wizard.py — the interactive, deterministic cloud-onboarding wizard.

Run through scripts/cloud-connect-wizard.sh (run.sh offers it as its last step; run it yourself any time
to connect another account or reconnect one). It asks, in this order and never out of it:

    cloud (AWS / GCP / Azure)  →  sign-in method  →  the one or two details that method needs

and then runs the existing connector, scripts/connect-cloud.sh, followed by `verify --name <same name>`.
No LLM and no agent runtime is involved; the /duplo-cloud-connect agent skill remains the conversational
alternative and drives the same connector.

Rules this file keeps (they are what the tests pin):
  * Nothing cloud-specific is looked at until the user has chosen BOTH the cloud and the method. Profiles are
    listed by NAME only (`aws configure list-profiles`), and a profile is never chosen for the user — not even
    when there is exactly one. AWS_PROFILE, CLOUDSDK_* project settings and the like are never used as defaults.
  * No secret is asked for, read into a variable that is printed, put on a command line, or stored. Access
    keys must already live in a named AWS profile; a GCP service-account key is not supported and no key path
    is requested. The ADC file is only checked for shape (type / presence of a refresh token).
  * Every external program is started with an argv list (never a shell string). Browser logins and the
    connector inherit the terminal; helper lookups are captured with a timeout.
  * `aws sso login` is run only for the profile the user selected and only when that profile really is an IAM
    Identity Center profile without a working session. A credential_process profile (duplo-jit, …) is never
    sent to `aws sso login`: the connector runs its credential_process itself, in this terminal.
  * `gcloud auth application-default login` is offered only when the ADC file the backend binds is absent or
    not a usable authorized_user file, or when the connector reported one of its known ADC-login errors —
    never on an arbitrary failure. It writes into the directory the stack binds (CLOUDSDK_CONFIG is set for a
    non-default one); nothing is copied.
  * Azure has no connector: the wizard says so and returns to the cloud menu. Nothing Azure is inspected.
  * Success is claimed only when connect AND verify both exit 0. This file never starts, stops or restarts
    anything itself, but the steps it runs can: a login writes local CLI state, and the connector may have
    restarted the backend or made IAM/API/platform writes before a failure, a cancel or a failed verify. So
    "nothing was changed" is said only when no step was run; afterwards the wizard says the dev kit remains
    available, that setup is incomplete, and points at the output of the steps above for what changed.

Exit status: 0 connected and verified · 1 failed (the reason is printed) · 2 usage · 130 cancelled / end of
input / declined.
"""

from __future__ import annotations

import json
import os
import re
import shlex
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CONNECTOR = os.path.join(HERE, "connect-cloud.sh")

# The connector's own rules, mirrored so a bad value is re-asked here instead of failing later.
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")
GCP_PROJECT_RE = re.compile(r"^[a-z][a-z0-9-]{4,28}[a-z0-9]$")
# AWS profile names: no whitespace, no leading '-', nothing a config-section header cannot hold.
PROFILE_RE = re.compile(r"^[A-Za-z0-9_.@+:/=][A-Za-z0-9_.@+:/=-]{0,127}$")
REGION_RE = re.compile(r"^[a-z]{2,3}(-[a-z]+)+-\d{1,2}$")
DEFAULT_REGION = "us-east-1"

LOOKUP_TIMEOUT = 30        # names / config lookups
IDENTITY_TIMEOUT = 60      # the one STS call that tells whether an SSO session is live
MAX_LISTED_PROFILES = 30
STDERR_TAIL_CHARS = 8000

# The connector's known "you need a (new) ADC login" failures (scripts/connect_cloud.py). Only these make the
# wizard offer a login and one retry; anything else is reported as the failure it is.
ADC_LOGIN_MARKERS = (
    "ADC file not found",
    "ADC refresh token was rejected",
    "has no email scope",
    "no verified email for the ADC token",
)

OK, FAILED, USAGE, CANCELLED = 0, 1, 2, 130


class Cancel(Exception):
    """The user cancelled, or input ended."""


class Back(Exception):
    """The user asked to go back one menu."""


class WizardFail(Exception):
    """A step failed; the message is honest, actionable and free of secrets."""


# ── terminal I/O ─────────────────────────────────────────────────────────────────

class TermIO:
    """Line-based terminal I/O. EOF and Ctrl-C both mean cancel; nothing is ever read without echo because
    nothing secret is ever asked."""

    def __init__(self, stdin=None, stdout=None):
        self.stdin = stdin or sys.stdin
        self.stdout = stdout or sys.stdout

    def say(self, text: str = "") -> None:
        self.stdout.write(text + "\n")
        self.stdout.flush()

    def ask(self, prompt: str) -> str:
        self.stdout.write(prompt)
        self.stdout.flush()
        try:
            line = self.stdin.readline()
        except KeyboardInterrupt:
            self.stdout.write("\n")
            raise Cancel()
        if line == "":                       # EOF
            self.stdout.write("\n")
            raise Cancel()
        return line.strip()


# ── subprocesses ─────────────────────────────────────────────────────────────────

class Runner:
    """All process execution. argv lists only; `env` (when given) is the COMPLETE environment."""

    def which(self, name: str) -> str | None:
        return shutil.which(name)

    def capture(self, argv: list[str], *, env: dict | None = None, timeout: int = LOOKUP_TIMEOUT) -> tuple[int, str, str]:
        """Run a non-interactive lookup. → (rc, stdout, stderr); rc 127 = not installed, 124 = timed out."""
        try:
            p = subprocess.run(argv, stdin=subprocess.DEVNULL, capture_output=True, text=True, env=env, timeout=timeout)
        except FileNotFoundError:
            return 127, "", f"{argv[0]}: not found"
        except subprocess.TimeoutExpired:
            return 124, "", f"{argv[0]}: no answer within {timeout}s"
        except OSError as e:
            return 126, "", f"{argv[0]}: {e.strerror or e}"
        return p.returncode, p.stdout, p.stderr

    def interactive(self, argv: list[str], *, env: dict | None = None) -> int:
        """Run with the terminal inherited (browser logins, the connector). No timeout: a person is typing."""
        try:
            return subprocess.run(argv, env=env).returncode
        except FileNotFoundError:
            return 127
        except OSError:
            return 126
        except KeyboardInterrupt:
            return 130

    def relay(self, argv: list[str], *, env: dict | None = None) -> tuple[int, str]:
        """Like interactive(), but stderr is passed through line by line AND its tail kept, so a known error
        can be recognised. stdin/stdout stay on the terminal. → (rc, stderr tail)."""
        try:
            p = subprocess.Popen(argv, env=env, stderr=subprocess.PIPE, text=True, errors="replace")
        except FileNotFoundError:
            return 127, ""
        except OSError:
            return 126, ""
        tail = ""
        try:
            assert p.stderr is not None
            for line in p.stderr:
                sys.stderr.write(line)
                sys.stderr.flush()
                tail = (tail + line)[-STDERR_TAIL_CHARS:]
            return p.wait(), tail
        except KeyboardInterrupt:
            try:
                p.wait(timeout=10)
            except subprocess.TimeoutExpired:
                p.terminate()
            return 130, tail


# ── the wizard ───────────────────────────────────────────────────────────────────

class Wizard:
    def __init__(self, io: TermIO, runner: Runner, env: dict | None = None, connector: str = CONNECTOR):
        self.io, self.run, self.connector = io, runner, connector
        self.env = dict(os.environ if env is None else env)
        self.acted = False          # True once any login or connector step was started (it may have changed things)

    def step(self, argv: list[str], *, env: dict | None = None) -> int:
        self.acted = True
        return self.run.interactive(argv, env=env)

    def step_relay(self, argv: list[str], *, env: dict | None = None) -> tuple[int, str]:
        self.acted = True
        return self.run.relay(argv, env=env)

    # -- generic prompts ----------------------------------------------------------

    def menu(self, title: str, options: list[str], *, back: bool = True, free: str | None = None,
             validate=None) -> int | str:
        """Numbered choice. Returns the 0-based index, or (when `free` is set) a typed value as a str.
        Invalid input re-asks; b = back, q = cancel, EOF = cancel."""
        while True:
            self.io.say()
            self.io.say(title)
            for i, o in enumerate(options, 1):
                self.io.say(f"  {i}) {o}")
            hints = []
            if options:
                hints.append(f"1-{len(options)}" if len(options) > 1 else "1")
            if free:
                hints.append(free)
            if back:
                hints.append("b = back")
            hints.append("q = cancel")
            ans = self.io.ask(f"Choose [{', '.join(hints)}]: ")
            low = ans.lower()
            if low in ("q", "quit", "cancel", "exit"):
                raise Cancel()
            if low in ("b", "back"):
                if back:
                    raise Back()
                self.io.say("There is no previous step here.")
                continue
            if ans.isdigit() and options:
                n = int(ans)
                if 1 <= n <= len(options):
                    return n - 1
                self.io.say(f"'{ans}' is not one of the choices.")
                continue
            if free and ans:
                err = validate(ans) if validate else None
                if err is None:
                    return ans
                self.io.say(err)
                continue
            self.io.say("Please pick one of the listed choices." if ans else "Nothing entered.")

    def text(self, prompt: str, validate) -> str:
        """Free text with validation. b = back, q = cancel, EOF = cancel."""
        while True:
            ans = self.io.ask(f"{prompt} [b = back, q = cancel]: ")
            low = ans.lower()
            if low in ("q", "quit", "cancel", "exit"):
                raise Cancel()
            if low in ("b", "back"):
                raise Back()
            if not ans:
                self.io.say("Nothing entered.")
                continue
            err = validate(ans)
            if err is None:
                return ans
            self.io.say(err)

    def yes_no(self, prompt: str) -> bool:
        while True:
            ans = self.io.ask(f"{prompt} [y/n, q = cancel]: ").lower()
            if ans in ("y", "yes"):
                return True
            if ans in ("n", "no"):
                return False
            if ans in ("q", "quit", "cancel", "exit"):
                raise Cancel()
            self.io.say("Please answer y or n.")

    # -- top level ----------------------------------------------------------------

    def start(self, *, confirm: bool) -> int:
        try:
            if confirm and not self.yes_no("Connect a cloud account (AWS or GCP) to this dev kit now?"):
                self.io.say("Nothing was changed. Run ./scripts/cloud-connect-wizard.sh whenever you want to connect one.")
                return CANCELLED
            return self.cloud_menu()
        except Cancel:
            if self.acted:
                self.io.say("Cancelled — cloud setup is incomplete. The dev kit remains available.")
                self.io.say("Any changes already made are shown in the output of the steps above.")
            else:
                self.io.say("Cancelled before any step was run — nothing was changed.")
            self.io.say("Run ./scripts/cloud-connect-wizard.sh whenever you want to connect a cloud account.")
            return CANCELLED
        except WizardFail as e:
            self.io.say()
            self.io.say(f"✗ {e}")
            self.io.say("Cloud setup is incomplete. The dev kit remains available.")
            if self.acted:
                self.io.say("Any changes already made are shown in the output of the steps above.")
            else:
                self.io.say("No step was run, so nothing was changed.")
            self.io.say("Fix the cause above, then run ./scripts/cloud-connect-wizard.sh again.")
            return FAILED

    def cloud_menu(self) -> int:
        while True:
            try:
                c = self.menu("Which cloud do you want to connect?",
                              ["AWS", "GCP", "Azure — not supported yet (no connector)"], back=False)
            except Back:
                continue
            try:
                if c == 0:
                    return self.aws()
                if c == 1:
                    return self.gcp()
                self.io.say()
                self.io.say("Azure is not supported yet: this dev kit has no Azure connector and no Azure sign-in.")
                self.io.say("Nothing was looked up or changed. Choose AWS or GCP, or q to cancel.")
            except Back:
                continue

    # -- AWS ----------------------------------------------------------------------

    def aws_env(self) -> dict:
        """The environment for AWS lookups: static keys in the shell must not answer for a named profile."""
        env = dict(self.env)
        for k in ("AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN"):
            env.pop(k, None)
        return env

    def aws(self) -> int:
        while True:
            m = self.menu("How do you sign in to AWS?", [
                "IAM Identity Center (SSO) in the browser — recommended",
                "An existing named profile (it may use a credential_process such as duplo-jit)",
                "Access keys already stored in a named profile (keys are never asked for here)",
            ])
            # Cloud + method are chosen: only now is anything AWS looked at.
            self.need_cli("aws", "Install the AWS CLI v2 (https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)")
            try:
                if m == 0:
                    profile = self.aws_sso_profile()
                elif m == 1:
                    profile = self.aws_pick_profile(
                        "Which profile? (names only — nothing is resolved until you choose)",
                        none_hint="No named profiles exist yet. Go back and choose SSO to create one.")
                else:
                    profile = self.aws_pick_profile(
                        "Which profile holds the access keys? (names only)",
                        none_hint="No named profiles exist yet. Store the keys first with: aws configure --profile <name>   "
                                  "(run it yourself; this wizard never takes keys), then run this wizard again.")
                return self.aws_connect(profile)
            except Back:
                continue

    def need_cli(self, name: str, how: str) -> None:
        if not self.run.which(name):
            raise WizardFail(f"the '{name}' command is not installed or not on PATH. {how}, then run this wizard again.")

    def aws_profiles(self) -> list[str]:
        rc, out, err = self.run.capture(["aws", "configure", "list-profiles"], env=self.aws_env())
        if rc != 0:
            raise WizardFail(f"could not list AWS profile names (aws configure list-profiles exited {rc}): {_brief(err)}")
        seen, names = set(), []
        for ln in out.splitlines():
            n = ln.strip()
            if n and n not in seen and PROFILE_RE.fullmatch(n):
                seen.add(n)
                names.append(n)
        return names

    def aws_get(self, profile: str, key: str) -> str:
        """`aws configure get <key> --profile <p>` — '' when unset. The value is used, never printed."""
        rc, out, _ = self.run.capture(["aws", "configure", "get", key, "--profile", profile], env=self.aws_env())
        return out.strip() if rc == 0 else ""

    def aws_pick_profile(self, title: str, *, none_hint: str) -> str:
        names = self.aws_profiles()
        shown = names[:MAX_LISTED_PROFILES]
        while True:
            if not names:
                self.io.say()
                self.io.say(none_hint)
            elif len(names) > len(shown):
                self.io.say()
                self.io.say(f"({len(names) - len(shown)} more profiles are not listed; type the name.)")
            pick = self.menu(title, shown, free="or type a profile name", validate=_profile_error)
            profile = shown[pick] if isinstance(pick, int) else pick
            if profile in names:
                return profile
            self.io.say(f"There is no AWS profile named '{profile}' on this machine (aws configure list-profiles does not list it).")

    def aws_sso_profile(self) -> str:
        while True:
            how = self.menu("IAM Identity Center:", [
                "Set up a new SSO profile now (aws configure sso asks for the start URL, region, account and role)",
                "Use an SSO profile that already exists",
            ])
            try:
                if how == 1:
                    profile = self.aws_pick_profile(
                        "Which SSO profile? (names only)",
                        none_hint="No named profiles exist yet. Go back and set up a new SSO profile.")
                    if not self.aws_is_sso(profile):
                        self.io.say(f"'{profile}' is not an IAM Identity Center profile (it has no sso_session / sso_start_url).")
                        self.io.say("Pick an SSO profile, or go back and choose 'an existing named profile' to use it as it is.")
                        continue
                    return profile
                profile = self.text("Name for the new profile (it becomes the connection name, e.g. the account alias)",
                                    _profile_error)
                if profile in self.aws_profiles():
                    self.io.say(f"A profile named '{profile}' already exists; it is not reconfigured here.")
                    self.io.say("Choose another name, or go back and pick 'Use an SSO profile that already exists'.")
                    continue
                self.io.say()
                self.io.say(f"Running: aws configure sso --profile {shlex.quote(profile)}")
                self.io.say("(the AWS CLI asks its own questions and opens the browser sign-in)")
                rc = self.step(["aws", "configure", "sso", "--profile", profile], env=self.aws_env())
                if rc != 0:
                    raise WizardFail(f"aws configure sso --profile {profile} did not complete (exit {rc}). "
                                     "AWS was not connected. Run this wizard again to retry.")
                if not self.aws_is_sso(profile):
                    raise WizardFail(f"aws configure sso finished but profile '{profile}' has no SSO settings; "
                                     "AWS was not connected. Run this wizard again to retry.")
                return profile
            except Back:
                continue

    def aws_is_sso(self, profile: str) -> bool:
        return bool(self.aws_get(profile, "sso_session") or self.aws_get(profile, "sso_start_url"))

    def aws_connect(self, profile: str) -> int:
        uses_process = bool(self.aws_get(profile, "credential_process"))
        if uses_process:
            self.io.say()
            self.io.say(f"Profile '{profile}' uses a credential_process: the connector runs it once in this terminal and it")
            self.io.say("may open its own browser sign-in. (aws sso login is not used for such a profile.)")
        elif self.aws_is_sso(profile):
            self.aws_sso_session(profile)

        region = self.aws_get(profile, "region")
        if not REGION_RE.fullmatch(region):
            region = DEFAULT_REGION
        name = profile
        if not NAME_RE.fullmatch(name):
            self.io.say()
            self.io.say(f"The profile name '{profile}' cannot be used as the connection name as it is.")
            name = self.text("Connection name (lowercase letters, digits, '-' or '_'; starts with a letter or digit)", _name_error)

        self.io.say()
        self.io.say("Connecting AWS:")
        self.io.say(f"  connection name  {name}")
        self.io.say(f"  profile          {profile}")
        self.io.say(f"  region           {region}" + ("" if region != DEFAULT_REGION else "   (the profile's own region, else us-east-1)"))
        self.io.say("  workspace        the configured workspace (EXTENSION_DEV_WORKSPACE_ID in .env unless overridden)")
        self.io.say("The profile is resolved once and only that credential snapshot is handed to the local studio.")
        self.io.say("Temporary credentials expire and are not renewed automatically — run this wizard again to reconnect.")
        argv = [self.connector, "aws", "--name", name, "--profile", profile, "--region", region]
        self.io.say(f"Running: {_show(argv)}")
        rc = self.step(argv, env=self.env)
        if rc != 0:
            hint = ("If the failure above is a sign-in problem, the profile's credential_process must be able to log in "
                    "from this terminal." if uses_process else
                    "If the failure above is a sign-in problem, fix the profile's login and run this wizard again.")
            raise WizardFail(f"the AWS connection was NOT completed (connect-cloud.sh aws exited {rc}; its message is above). {hint}")
        return self.verify(name, "aws")

    def aws_sso_session(self, profile: str) -> None:
        """Log in to the SELECTED Identity Center profile only when its session does not work right now."""
        rc, _, _ = self.run.capture(["aws", "sts", "get-caller-identity", "--profile", profile, "--output", "json"],
                                    env=self.aws_env(), timeout=IDENTITY_TIMEOUT)
        if rc == 0:
            self.io.say(f"The SSO session for profile '{profile}' is active; no new login is needed.")
            return
        self.io.say()
        self.io.say(f"Profile '{profile}' has no usable SSO session. Running: aws sso login --profile {shlex.quote(profile)}")
        rc = self.step(["aws", "sso", "login", "--profile", profile], env=self.aws_env())
        if rc != 0:
            raise WizardFail(f"aws sso login --profile {profile} did not complete (exit {rc}). AWS was not connected. "
                             "Finish the browser sign-in, then run this wizard again.")

    # -- GCP ----------------------------------------------------------------------

    def gcp(self) -> int:
        while True:
            m = self.menu("How do you sign in to GCP?", [
                "Local Application Default Credentials (gcloud browser login, keyless) — recommended",
                "Service-account key file — not supported (keys are refused by design)",
            ])
            if m == 1:
                self.io.say()
                self.io.say("A service-account key is not supported: the connector is keyless and refuses key files,")
                self.io.say("so no key path is asked for. Choose Application Default Credentials instead.")
                continue
            try:
                project = self.text("GCP project ID to connect", _project_error)
            except Back:
                continue
            return self.gcp_connect(project)

    def gcp_adc_location(self) -> dict:
        """The directory the stack binds for ADC, from the connector's own resolver (never a second guess)."""
        rc, out, err = self.run.capture([self.connector, "_gcp", "dir"], env=self.env)
        if rc != 0:
            raise WizardFail("could not resolve the gcloud directory the dev kit uses "
                             f"(connect-cloud.sh exited {rc}): {_brief(err)}")
        try:
            loc = json.loads(out)
            d, f, src = loc["dir"], loc["file"], str(loc.get("source") or "")
        except (ValueError, KeyError, TypeError):
            raise WizardFail("connect-cloud.sh returned an unexpected answer for the gcloud directory; nothing was changed.")
        if not (isinstance(d, str) and isinstance(f, str) and os.path.isabs(d) and os.path.isabs(f)):
            raise WizardFail("connect-cloud.sh returned a gcloud directory that is not an absolute path; nothing was changed.")
        return {"dir": d, "file": f, "source": src}

    @staticmethod
    def adc_problem(path: str) -> str | None:
        """None when the file LOOKS like a usable login; else why not. Shape only — values are never shown."""
        if not os.path.isfile(path):
            return "there is no Application Default Credentials file yet"
        try:
            with open(path, "rb") as fh:
                adc = json.loads(fh.read())
        except (OSError, ValueError):
            return "the Application Default Credentials file cannot be read as JSON"
        if not isinstance(adc, dict) or adc.get("type") != "authorized_user":
            return "the Application Default Credentials file is not a user login (authorized_user)"
        for k in ("client_id", "client_secret", "refresh_token"):   # the connector requires all three
            if not adc.get(k):
                return f"the Application Default Credentials file is incomplete (no {k})"
        return None

    def gcp_login(self, loc: dict, why: str) -> None:
        default = loc["source"].startswith("default")
        shown = "gcloud auth application-default login"
        env = dict(self.env)
        if not default:
            # A bare login would write ~/.config/gcloud; the stack binds this directory instead.
            shown = f"CLOUDSDK_CONFIG={shlex.quote(loc['dir'])} {shown}"
            env["CLOUDSDK_CONFIG"] = loc["dir"]
        self.io.say()
        self.io.say(f"A Google login is needed: {why}.")
        self.io.say(f"The dev kit reads it in place from {loc['dir']} (nothing is copied).")
        if not self.yes_no(f"Run `{shown}` now (opens the browser)?"):
            raise WizardFail(f"the Google login was declined, so GCP was not connected. Run it yourself:\n    {shown}\n"
                             "  then run this wizard again.")
        self.need_cli("gcloud", "Install the Google Cloud CLI (https://cloud.google.com/sdk/docs/install)")
        rc = self.step(["gcloud", "auth", "application-default", "login"], env=env)
        if rc != 0:
            raise WizardFail(f"`{shown}` did not complete (exit {rc}). GCP was not connected. "
                             "Finish the browser sign-in, then run this wizard again.")
        still = self.adc_problem(loc["file"])
        if still:
            raise WizardFail(f"the login finished but {still} at {loc['file']}. GCP was not connected.")

    def gcp_connect(self, project: str) -> int:
        loc = self.gcp_adc_location()
        logged_in_now = False
        problem = self.adc_problem(loc["file"])
        if problem:
            self.gcp_login(loc, problem)
            logged_in_now = True

        self.io.say()
        self.io.say("Connecting GCP:")
        self.io.say(f"  project          {project}")
        self.io.say(f"  connection name  {project}")
        self.io.say(f"  service account  helpdesk-sa@{project}.iam.gserviceaccount.com   (keyless impersonation)")
        self.io.say("  workspace        the configured workspace (EXTENSION_DEV_WORKSPACE_ID in .env unless overridden)")
        self.io.say(f"If helpdesk-sa or its access is missing, the connector prepares it in '{project}' only (enables iam +")
        self.io.say("iamcredentials, creates/reuses the account, lets your login impersonate it, grants it read-only")
        self.io.say("roles/viewer). It may restart ONLY the dev kit backend so it picks up the login.")
        argv = [self.connector, "gcp", "--project", project]
        self.io.say(f"Running: {_show(argv)}")
        rc, tail = self.step_relay(argv, env=self.env)
        if rc != 0 and not logged_in_now and any(m in tail for m in ADC_LOGIN_MARKERS):
            # A known "the login is missing / expired / revoked" failure, raised before any platform write.
            self.gcp_login(loc, "the connector reported that the current login is missing, expired or revoked")
            self.io.say(f"Retrying: {_show(argv)}")
            rc, tail = self.step_relay(argv, env=self.env)
        if rc != 0:
            raise WizardFail(f"the GCP connection was NOT completed (connect-cloud.sh gcp exited {rc}; its message is above, "
                             "including any cloud changes it had already made).")
        return self.verify(project, "gcp")

    # -- verify + report ----------------------------------------------------------

    def verify(self, name: str, cloud: str) -> int:
        argv = [self.connector, "verify", "--name", name]
        self.io.say()
        self.io.say(f"Verifying: {_show(argv)}")
        rc = self.step(argv, env=self.env)
        if rc != 0:
            raise WizardFail(f"connection '{name}' was registered, but verification FAILED (verify exited {rc}; see above), "
                             f"so it is not reported as working. Re-check with: ./scripts/connect-cloud.sh verify --name {name}")
        self.io.say()
        self.io.say(f"✔ Cloud connection '{name}' is registered, attached to the configured workspace, and verified.")
        if cloud == "aws":
            self.io.say("  Verified: the backend populated credentials for the scope (the studio's own AWS scope endpoint).")
        else:
            self.io.say("  Verified: runtime-file (the backend reads your login) and host-proof (impersonation + bucket list).")
        self.io.say("  You can now select this scope in a ticket. Ticket execution has not been tested by this wizard.")
        self.io.say(f"  Later: ./scripts/connect-cloud.sh status   ·   reconnect: ./scripts/cloud-connect-wizard.sh")
        return OK


# ── helpers ──────────────────────────────────────────────────────────────────────

def _profile_error(v: str) -> str | None:
    return None if PROFILE_RE.fullmatch(v) else "That is not a valid AWS profile name (no spaces; letters, digits and . _ - @ + : / = only)."


def _name_error(v: str) -> str | None:
    return None if NAME_RE.fullmatch(v) else "Use 1-64 lowercase letters, digits, '-' or '_', starting with a letter or digit."


def _project_error(v: str) -> str | None:
    return None if GCP_PROJECT_RE.fullmatch(v) else ("That is not a GCP project ID (6-30 characters: lowercase letters, digits and "
                                                      "hyphens, starting with a letter). Use the ID, not the project name or number.")


def _brief(text: str) -> str:
    """The last few lines of a helper's stderr, bounded."""
    lines = [ln.strip() for ln in (text or "").splitlines() if ln.strip()]
    return (" | ".join(lines[-3:]) or "no message")[:400]


def _show(argv: list[str]) -> str:
    """A copy-pasteable rendering of an argv: the connector as its repo-relative path, every argument quoted."""
    head = "./scripts/connect-cloud.sh" if os.path.basename(argv[0]) == "connect-cloud.sh" else shlex.quote(argv[0])
    return " ".join([head] + [shlex.quote(a) for a in argv[1:]])


USAGE_TEXT = """usage: cloud-connect-wizard.sh [--yes]

Interactive cloud onboarding for the running dev kit: asks the cloud (AWS or GCP; Azure is not supported
yet), the sign-in method and the profile or project, then runs scripts/connect-cloud.sh and verifies the
connection. Needs a terminal. For scripted use call scripts/connect-cloud.sh directly.

  --yes    skip the first "connect now?" question (run.sh passes it after asking that itself)
"""


def main(argv: list[str]) -> int:
    confirm = True
    for a in argv:
        if a in ("-h", "--help"):
            print(USAGE_TEXT, end="")
            return OK
        if a == "--yes":
            confirm = False
        else:
            print(f"unknown argument '{a}'\n\n{USAGE_TEXT}", end="", file=sys.stderr)
            return USAGE
    # Never prompt (or hang) off a terminal. The override exists for the tests, which feed answers on a pipe.
    if os.environ.get("CLOUD_CONNECT_WIZARD_ALLOW_NO_TTY") != "1" and not (sys.stdin.isatty() and sys.stdout.isatty()):
        print("cloud-connect-wizard.sh is interactive and needs a terminal; nothing was changed.\n"
              "For scripted use run ./scripts/connect-cloud.sh aws|gcp … directly.", file=sys.stderr)
        return USAGE
    if not os.path.isfile(CONNECTOR):
        print(f"✗ {CONNECTOR} is missing; run this from a complete dev-kit checkout.", file=sys.stderr)
        return FAILED
    return Wizard(TermIO(), Runner()).start(confirm=confirm)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
