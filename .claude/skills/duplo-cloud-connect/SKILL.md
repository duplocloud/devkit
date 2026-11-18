---
name: duplo-cloud-connect
description: Connect an AWS account or GCP project to the running DuploCloud dev kit (invoke as /duplo-cloud-connect — provider, credential, scope, workspace attach) with scripts/connect-cloud.sh, reconnect expired credentials, or check connection status; Azure has no connector, so say so and stop. Not for the LLM provider the agent runs on (that is run.sh --model / switch-llm.sh).
---

# duplo-cloud-connect — cloud connections for the local dev kit

`./scripts/connect-cloud.sh` is the one deterministic way to register a cloud account with the local
stack. It is idempotent (same `--name` → same objects, updated in place), checks every
conflict before it writes anything, and never puts a secret on a command line, in its output, or in
`.devkit-cloud/connections.json`. AWS never restarts anything; GCP may restart ONLY the backend (see below). Its only subcommands are `aws`, `gcp`, `refresh`, `verify` and
`status`; there is no `azure` subcommand.

**Without an agent:** `./scripts/cloud-connect-wizard.sh` is the same onboarding as a terminal wizard — it
asks the cloud, the sign-in method and the profile or project (numbered menus; Azure is listed as not
supported), runs the scoped browser login when one is needed, then runs `connect-cloud.sh` and
`verify --name <name>` itself. `./run.sh` offers it as its last, opt-in step on a terminal. It needs a
terminal and no LLM; when a user wants to do the connection themselves, point them to it. This skill is the
conversational path over the same connector and follows the same rules.

## Conversation protocol — before any tool call

The user chooses the cloud, the credential method and the target. Never infer any of them from what
is installed or configured, the CLI's current default profile/project, environment variables
(`AWS_PROFILE`, `CLOUDSDK_*`, `AZURE_*`), the examples in this file, or an earlier unrelated task. A
single available profile is not consent; the choice is still the user's.

Every question below is asked with the **`AskUserQuestion`** tool as a multiple-choice question (the
recommended option first, marked "(Recommended)"; the tool's built-in "Other" takes free text). Use plain chat
only for a value with no sensible options, such as a GCP project ID.

1. **Ask the cloud only when it is missing.** If the request does not name a cloud (for example a bare
   `/duplo-cloud-connect`), the first action is `AskUserQuestion` with the options **AWS**, **GCP**,
   **Azure** — no discovery, no `status`, no reading `~/.aws`, `~/.config/gcloud` or `.env` until the
   user answers. If the user already said AWS, GCP or Azure
   but left details out, do not re-ask the cloud: ask only for the missing method and details
   (steps 2–3). A complete explicit request (cloud, `--name`, and the profile; or for GCP just the
   project ID), or `status` / `refresh` / `verify` of a named connection, is not re-asked: run it.
2. **Then ask the credential method** for the chosen cloud, again as an `AskUserQuestion` MCQ:
   - **AWS** — (a) browser SSO through IAM Identity Center (**recommended**), (b) an existing named
     profile (it may use a `credential_process` such as `duplo-jit`), or (c) access-key credentials,
     which this command accepts only when they already live in a named profile. Never present long-lived
     keys as the default. For a new SSO profile, and only after the user picks (a): collect only the
     inputs `aws configure sso` needs (SSO start URL, SSO region, and the account and role they choose),
     then `aws sso login --profile <profile>`; the command consumes that profile via `--profile`.
     Credentials copied into the studio are a snapshot — never promise automatic renewal.
   - **GCP** — (a) local Application Default Credentials login (**recommended**) or (b) an existing
     service-account JSON key file, which the MCQ must label **"(b) unavailable — not implemented, keys are
     refused by design"** (never as a working choice). Never ask for a key path, key contents or any secret in
     chat; if the user picks (b) anyway, say it is unavailable and ask whether to switch to (a) — do not
     silently fall back. For (a), once GCP + ADC is selected
     **ask only for the project ID** — never infer it from gcloud config, environment or examples.
     Derive the rest: connection name = project ID, service account =
     `helpdesk-sa@<project-id>.iam.gserviceaccount.com`, workspace = the configured default
     (`EXTENSION_DEV_WORKSPACE_ID`), used automatically. Ask about name, service account or workspace
     only when the user volunteers an override, or when an exception actually occurs: missing
     workspace config, a name/object conflict, ADC login needed, or a denied/failed cloud step. Selecting
     GCP + ADC + the project **is** the authorization for the default-identity preparation described
     under *GCP seamless bootstrap* below — do not ask "may I create the service account / grant IAM?"
     and do not invent a `--grant` step or hand the user manual `gcloud` commands. A missing ADC login is
     handled by *Expired or missing login* below.
   - **Azure** — **unsupported.** `connect-cloud.sh` has **no `azure` subcommand**; the dev kit has no
     Azure connector and no Azure SSO. If the user picks Azure, say exactly that in the same reply, do not
     present any Azure login method as working, and **stop**: no method question, no credential
     discovery, `az login`, app registration or subscription lookup. A host `az login` does not
     authenticate the Docker backend. Offer only to connect AWS or GCP instead.
3. **Collect only what is still missing**, and derive the rest:
   - **AWS, existing profile (b/c):** once the user chose AWS + an existing profile, list the profile
     **names** (`aws configure list-profiles` — names only) to build the MCQ. The listing is part of that
     selection: do not ask a separate "may I list profiles?" question (normal tool approval still
     applies). Do not read `~/.aws/config` or credential files, and never resolve or export credentials
     for a profile the user did not select — the script resolves the one chosen profile itself. If there
     are more profiles than an MCQ holds, show a few and let "Other" take a typed name; with none, say so
     and offer the SSO path (a).
   - **AWS, new SSO (a):** only the `aws configure sso` inputs above.
   - **AWS derived values:** `--name` = the selected profile name; region = the selected profile's own
     region (`aws configure get region --profile <profile>`), falling back to `us-east-1` when it has
     none; workspace = the configured `EXTENSION_DEV_WORKSPACE_ID`, used automatically. Ask about name,
     region or workspace only when the user volunteers an override or an exception occurs (unset or
     ambiguous workspace, name/object conflict, denied step).
   - **GCP (a):** the project ID only, see above.
4. **Echo the selection** (cloud, `--name`, profile or project + service account, region, workspace —
   including the derived values) before running the registration; `--dry-run` previews it. A target must
   be selected before any run. Skip the echo when the user already supplied the complete command.

## Expired or missing login — log in, then retry

If registration fails because the selected credential needs a browser login, do not stop at a manual
handoff: offer and run the matching **scoped** login through the normal tool-approval mechanism, then retry
the same registration and finish with `verify`.

- **AWS IAM Identity Center profile** — only when the selected profile actually has `sso_session` /
  `sso_start_url` (check with `aws configure get sso_session --profile <p>` / `sso_start_url`, never by
  reading credential files) and its SSO token is missing/expired: `aws sso login --profile <selected-profile>`.
- **AWS `credential_process` profile** (for example `duplo-jit`): this is **not** IAM Identity Center — never
  run `aws sso login` for it. Re-run the selected `connect-cloud.sh aws …` command in an interactive terminal
  (the normal tool call, with approval) so the profile's own configured `credential_process` opens its
  browser login; then retry/verify. If the runtime cannot provide an interactive terminal, say so.
- **GCP ADC** (plain `gcloud auth login` does not write ADC): the **exact** login the failing command
  printed — `gcloud auth application-default login` for the default directory, or
  `CLOUDSDK_CONFIG=<selected dir> gcloud auth application-default login` (shell-quoted path) when
  `DEVKIT_GCLOUD_DIR` selects another one, since a bare login would write elsewhere. Run only that
  approved command yourself; never copy the ADC file.
- Only if the runtime cannot run a browser login (no interactive terminal) say so and give the user that
  single exact command as `! <command>` (for `credential_process`, the selected `connect-cloud.sh aws …`
  command); then retry yourself.
- If the login is denied, follow *If a real tool or approval reviewer denies it* below.

## Permission and completion — running the registration

This section applies only after the user has selected the cloud, the credential method **and** the
actual target (the profile, or the GCP project ID with its derived or explicit name, service account
and workspace); a
cloud and method alone authorize nothing. That selection authorizes exactly that one connection: not
other profiles, other ADC files, other projects, or any credential the user did not name. Once the
selection is echoed, the job is to **run the registration and verify it end to end**, obtaining
approval through the agent runtime's normal permission mechanism whenever it asks for one.

- **Say what the run will do before asking for approval.** For a user-selected GCP connection: nothing is copied.
  The published backend reads the user's normal `authorized_user` ADC file (it contains a refresh token) **in
  place** — compose binds the whole gcloud directory (`DEVKIT_GCLOUD_DIR`, else an explicit `CLOUDSDK_CONFIG`,
  else `~/.config/gcloud`) read-only at `/devkit-gcloud`. The run proves the impersonation with that file, checks
  the running backend's own uid can read it, **recreates or restarts only the backend** when needed (first
  native connection or after a new ADC login — local restarts of the dev-kit backend are authorized by selecting
  the GCP connection; announce it, do not ask again), then registers the provider, a credential carrying only
  `cloudRoleToAssume`, and the scope, attached to the workspace (unless `--no-workspace`). Every GCP connection
  shares that one host ADC identity. For AWS: the selected profile is resolved once via
  `aws configure export-credentials` and only that snapshot is handed to the studio under the connection's name.
  Cloud APIs are read-only unless the user explicitly authorizes writes — except the narrow GCP bootstrap below,
  which selecting the GCP project already authorizes.
- **GCP seamless bootstrap (authorized by selecting the project).** Add one concise line to the
  announcement and then just run the command: "If `helpdesk-sa@<project>` or its access is missing,
  connect-cloud will, in `<project>` only: enable `iam` + `iamcredentials` if disabled, create/reuse
  `helpdesk-sa`, let your verified ADC user impersonate it (`roles/iam.serviceAccountTokenCreator` on
  that account only), and give it read-only `roles/viewer` on the project; then validate and register."
  It runs only when the impersonation or bucket proof fails with a typed missing-account / permission /
  disabled-API condition (never for a revoked login, a network error or a 5xx), uses no keys, never
  Owner/Editor, deletes nothing, and never touches another project, the ADC quota project or any
  different/custom account you passed with `--service-account` (passing the derived
  `helpdesk-sa@<project>` itself still bootstraps). Local conflicts are refused before any cloud write.
  Do not claim TokenCreator grants resource access (the viewer grant is what the listing relies on) and
  do not read a bare 404 from `generateAccessToken` as proof the account is absent — the script looks
  the account up itself. `--no-bootstrap` is the advanced opt-out; `--dry-run` never mutates and, when
  repair would be needed, reports that it is *not validated*.
- **Ask once, scoped, through the normal mechanism.** If the runtime requires approval, request it for
  that exact `connect-cloud.sh` invocation and wait. Do not assume credential handling is forbidden
  because the session runs in an auto mode, do not invent a policy refusal, do not downgrade a run
  the user asked for to `--dry-run` and call it done, and do not hand the user a manual
  `! ./scripts/connect-cloud.sh …` command as the default path. An approval already given for that
  exact connection is not re-asked for its `verify`, `status` or an immediate `refresh`.
- **If a real tool or approval reviewer denies it, obey.** State exactly what was denied and why,
  what was and was not changed, and ask for the allowed scoped approval through the available normal
  mechanism. Never bypass the denial, use a dangerous skip/approval flag, change global permission
  settings, or promise that approval can always be granted. Hand the task back to the user only when
  a genuine, unresolvable boundary remains.
- **Then verify.** After a successful `aws` or `gcp` run, run `verify --name <name>` (and `status`)
  and report the result as described under *Reporting completion*.

## Commands (placeholders — illustrations, not defaults)

```bash
./scripts/connect-cloud.sh aws --name <name> --profile <profile> [--region <region>] [--workspace <workspace-id>]
./scripts/connect-cloud.sh gcp --project <project-id> \
    [--name <name>] [--service-account <sa>@<project>.iam.gserviceaccount.com] \
    [--adc-source <the native ADC file>] [--workspace <workspace-id>] [--no-workspace] [--no-bootstrap]
# defaults: --name = project ID; --service-account = helpdesk-sa@<project-id>.iam.gserviceaccount.com;
# the project ID is validated before any storage or cloud API call
./scripts/connect-cloud.sh refresh --name <name> [--workspace <workspace-id>]   # re-resolve + rotate in place; prints container ids/start times before and after
./scripts/connect-cloud.sh verify  --name <name>      # backend/bootstrap checks, no ticket, no LLM cost
./scripts/connect-cloud.sh status [--json]
```

Every `<placeholder>` is filled only from the user's own selection (GCP name and service account fall
back to the derived defaults above); no project, profile or connection
name in this file is a default. `--json` on any subcommand gives a machine-readable result; `--dry-run`
resolves, validates and prints what *would* be written, and writes nothing. The scope the agent sees
is named exactly `--name`: AWS → `aws … --profile <name>`, GCP → `gcloud … --configuration <name>`.

## What to know before running it

- **The stack must be up** (`./run.sh` once). The script finds the backend through this checkout's compose
  project (`COMPOSE_PROJECT_NAME` in `.env` works unchanged) and refuses a backend started from another
  checkout. No running backend is a hard error.
- **A workspace is required** so the scope is selectable by tickets; the default is
  `EXTENSION_DEV_WORKSPACE_ID` from `.env`. When the user explicitly selected a workspace, always pass
  `--workspace <selected-id>` on the `aws`/`gcp` connect and on `refresh` — never let the `.env`
  default override the selection — and confirm the attachment before claiming it; never report it
  from intent alone. Pass `--no-workspace` only to register without attaching.
- **Conflicts stop the command before any write**: a reused `--name` whose provider belongs to another
  account/project, whose credential was not created by this tool, whose scope points elsewhere or has
  a different region, or an ambiguous (duplicate) name. Pick another `--name` or fix the object in the UI.
- **AWS** resolves the profile once via `aws configure export-credentials`. A `credential_process`
  such as `duplo-jit … --interactive` may open a browser and needs a terminal — run it from an
  interactive shell, not a background job. Credentials from JIT are temporary: `status` shows the
  expiry and there is **no automatic renewal** — run `refresh` (or the same `aws` command) to reconnect.
  Platform-side assume-role is not used: the studio has no AWS identity of its own in the dev kit.
- **GCP** is keyless and native: the backend reads the user's `authorized_user` ADC file (from `gcloud auth
  application-default login`; plain `gcloud auth login` is not enough) in place; the connection proves with that
  exact file that it can mint an impersonated token for the service account and list the project's buckets.
  `--adc-source` may only name that exact native file (another file is refused — the backend would never use
  it). Missing ADC → run the login command the failure prints (scoped with `CLOUDSDK_CONFIG=<dir>` for a custom
  `DEVKIT_GCLOUD_DIR`), then retry; never copy a file. Service-account keys and `external_account` files are
  refused. The user behind the ADC needs `roles/iam.serviceAccountTokenCreator` on the service account; for the
  default `helpdesk-sa@<project>` the script arranges that (and the rest of the bootstrap) itself. If an
  IAM/project admin step is **denied (HTTP 403)** it stops and reports exactly which cloud changes were and were
  not made. A different/custom `--service-account` is used as-is: never created, no grants added.
- **Why the backend restarts (honestly).** Google's .NET client caches the first credential lookup for the life of
  the process — a "no ADC" failure included — so changing the file cannot clear it. The tool restarts only the
  backend on the first native connection and after a new login, waits (bounded) for health, and records a
  hash-only fingerprint so a repeat or a new target project on the same ADC does not restart. Never promise it
  never restarts, and never restart other services.
- **Startup without local ADC.** If no ADC file exists when the stack starts, `GOOGLE_APPLICATION_CREDENTIALS` is
  left empty so the standard metadata fallback remains. After login, `connect-cloud.sh` automatically applies the
  native environment variable and mount and resets the credential cache.
- **Permissions on native Linux.** If the backend's uid cannot read a `0700`/`0600` gcloud directory the run
  fails with a specific PERMISSIONS message before registering. Do not chmod/chown it, run anything as root, or
  copy the file; report it as an exception the user decides (a readable `DEVKIT_GCLOUD_DIR`, or a uid-scoped
  ACL they grant). Only Docker Desktop has been verified.
- **An older stack** (backend without the mount) is repaired automatically by the same run. A legacy `adcRef`
  on an existing tool-created credential is ignored by the published backend and rewritten in place; the old
  `cloud_auth` store data is left untouched. Do not suggest a service-account private key, a backend patch or
  an extra Google login as a workaround, and do not call a `verify` pass a ticket success.
- **This check changes no rules.** It links no new files and adds no new paths; the question-first
  protocol and the scoped-permission rules above apply unchanged. Diagnosing compatibility is not a
  reason to read `~/.config/gcloud` pick a target for the user, or run anything beyond
  `status` / `verify` of the already-approved connection without the usual approval.
- **Verification scope.** `verify` for AWS calls the studio's own scope endpoint, which runs the
  backend's credential population for that scope. For GCP, nothing outside a ticket expands a scope,
  so `verify` reports three separate stages — runtime-file, host-proof and ticket-proven (always NO) — and the ticket proof is
  `tests/e2e/cloud_onboarding_e2e.py` (invokes the LLM, approves only exact read-only commands, passes
  only on raw tool output equal to an operator-supplied control list, and requires unchanged container
  ids). Run it only when asked; it costs tokens.
- **Failures are final, not retried.** A wrong profile, a revoked ADC, or a custom/opted-out service
  account that is not granted fails before any platform write; read the `✗` line, fix the cause,
  re-run. A bootstrap that stops part-way (403, IAM still propagating after the bounded wait, a
  disabled service account) prints the cloud changes it already completed — report those; never say
  "nothing was changed" if any were applied. Cloud failures never lead to platform
  writes.

## Reporting completion — name the stage actually reached

Each stage is a separate claim. Report the furthest stage that succeeded and name the ones that did not
run; never present an earlier stage as a later one.

1. **Validated** — `--dry-run` or the pre-write checks passed (profile or ADC resolved; for GCP the
   impersonated token and bucket listing proved). Nothing was written. A GCP dry run that finds the
   account/permissions missing is *not validated*: report the repair a real run would make.
   (If a real run's bootstrap made cloud changes, report those as their own line.)
2. **Runtime-ready** (GCP) / **Stored** (AWS) — GCP: the running backend's own uid was probed reading the
   host-proven ADC file (`runtime-file: PROVEN`; a `--dry-run` prints NOT PROVEN); AWS: the credential snapshot
   is handed to the studio.
3. **Registered** — the provider, credential and scope objects exist in the studio.
4. **Workspace-attached** — the scope is confirmed attached to the selected workspace, not assumed
   from the flag (not when `--no-workspace` was used).
5. **Verification passed** — `verify --name <name>` passed. For AWS this exercises the backend's
   credential population for the scope; for GCP it reports runtime-file and host-proof only.
   **GCP `verify` is not the ticket E2E** — only `tests/e2e/cloud_onboarding_e2e.py`, run when asked,
   proves a ticket can use the scope.

A dry run is never reported as a connection. A denied approval or a failed step is reported as exactly
that, with the `✗` line and what remains to be done.
