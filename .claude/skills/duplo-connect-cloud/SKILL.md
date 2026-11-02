---
name: duplo-connect-cloud
description: Connect an AWS account or GCP project to the running DuploCloud dev kit (provider, credential, scope, workspace attach) with scripts/connect-cloud.sh, reconnect expired credentials, or check connection status; for Azure, explain what exists and stop. Not for the LLM provider the agent runs on (that is run.sh --model / switch-llm.sh).
---

# duplo-connect-cloud — cloud connections for the local dev kit

`./scripts/connect-cloud.sh` is the one deterministic way to register a cloud account with the local
stack. It is idempotent (same `--name` → same objects, updated in place), restarts nothing, checks every
conflict before it writes anything, and never puts a secret on a command line, in its output, or in
`.devkit-cloud/connections.json`. Its only subcommands are `aws`, `gcp`, `refresh`, `verify` and
`status`; there is no `azure` subcommand.

## Conversation protocol — before any tool call

The user chooses the cloud, the credential method and the target. Never infer any of them from what
is installed or configured, the CLI's current default profile/project, environment variables
(`AWS_PROFILE`, `CLOUDSDK_*`, `AZURE_*`), the examples in this file, or an earlier unrelated task. A
single available profile is not consent; the choice is still the user's.

1. **Ask the cloud only when it is missing.** If the request does not name a cloud, the first reply
   is only the question "AWS, GCP, or Azure?" — no discovery, no `status`, no reading `~/.aws`,
   `~/.config/gcloud` or `.env` until the user answers. If the user already said AWS, GCP or Azure
   but left details out, do not re-ask the cloud: ask only for the missing method and details
   (steps 2–3). A complete explicit request (cloud, `--name`, and the profile or project + service
   account), or `status` / `refresh` / `verify` of a named connection, is not re-asked: run it.
2. **Then ask the credential method** for the chosen cloud:
   - **AWS** — (a) browser SSO through IAM Identity Center, (b) an existing named profile (it may use
     a `credential_process` such as `duplo-jit`), or (c) access-key credentials, which this command
     accepts only when they already live in a named profile. Never present long-lived keys as the
     default. For a new SSO profile, and only after the user picks (a): walk them through
     `aws configure sso` (they choose the account and role) and `aws sso login --profile <profile>`;
     the command then consumes that profile via `--profile`. Credentials copied into the studio are a
     snapshot — never promise automatic renewal.
   - **GCP** — (a) local Application Default Credentials login (recommended) or (b) an existing
     service-account JSON key file. State before asking for any path that (b) is **not implemented by
     this command** (keys are refused by design); never ask for key contents or any secret in chat;
     do not silently fall back to (a) — ask whether to switch. For (a): ask for the project and the
     existing service account to impersonate (never pick one for the user, never create a service
     account or IAM grant unless asked) and point to `gcloud auth application-default login`
     (plain `gcloud auth login` does not write ADC).
   - **Azure** — (a) Entra browser login with `az login` (recommended for developer use) or (b)
     existing service-principal credentials (workload use); managed identity only when the runtime
     actually runs on Azure infrastructure. In the same reply state that `connect-cloud.sh` has **no
     `azure` subcommand** and vendor SSO is not implemented in dev-kit onboarding, then stop: no
     credential discovery, `az login`, app registration or subscription lookup. A host `az login`
     does not authenticate the Docker backend.
3. **Collect only what is still missing** for a supported method: `--name`, the workspace, and the
   target (AWS: profile + region, script default `us-east-1`; GCP: project + service account).
   Propose `EXTENSION_DEV_WORKSPACE_ID` from `.env` as the workspace, but do not use it silently when
   it is unset or ambiguous. List profile names (`aws configure list-profiles`) only after the user
   chose AWS + existing profile **and** authorized listing; never resolve or export credentials for
   discovered profiles — the script resolves the one chosen profile itself.
4. **Echo the selection** (cloud, `--name`, profile or project + service account, region, workspace)
   before running the registration; `--dry-run` previews it. A target must be selected before any
   run. Skip the echo when the user already supplied the complete command.

## Permission and completion — running the registration

This section applies only after the user has selected the cloud, the credential method **and** the
actual target (the profile, or the project + service account, plus `--name` and the workspace); a
cloud and method alone authorize nothing. That selection authorizes exactly that one connection: not
other profiles, other ADC files, other projects, or any credential the user did not name. Once the
selection is echoed, the job is to **run the registration and verify it end to end**, obtaining
approval through the agent runtime's normal permission mechanism whenever it asks for one.

- **Say what the run will do before asking for approval.** For a user-selected GCP connection: the
  exact selected `authorized_user` ADC file (it contains a refresh token) is copied from the selected
  host path into this Compose project's private connection store — the `cloud_auth` named volume
  mounted read-only into the backend at `/devkit-auth` (owned by uid 1001, mode 0700) — as
  `gcp/<name>.json` with mode 0600, written through the script's stdin helper, never a command-line
  argument; then the local provider, credential and scope are registered and the scope attached to
  the workspace (unless `--no-workspace`). For AWS: the selected profile is resolved once via
  `aws configure export-credentials` and only that snapshot is handed to the studio under the
  connection's name. The copy plus the read-only mount is delegated access to that one identity, in
  either store design. Cloud APIs are read-only unless the user explicitly authorizes writes.
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
./scripts/connect-cloud.sh gcp --name <name> --project <project> \
    --service-account <sa>@<project>.iam.gserviceaccount.com [--adc-source <authorized_user json>] \
    [--workspace <workspace-id>]
./scripts/connect-cloud.sh refresh --name <name> [--workspace <workspace-id>]   # re-resolve + rotate in place; prints container ids/start times before and after
./scripts/connect-cloud.sh verify  --name <name>      # backend/bootstrap checks, no ticket, no LLM cost
./scripts/connect-cloud.sh status [--json]
```

Every `<placeholder>` is filled only from the user's own selection; no project, profile or connection
name in this file is a default. `--json` on any subcommand gives a machine-readable result; `--dry-run`
resolves, validates and prints what *would* be written, and writes nothing. The scope the agent sees
is named exactly `--name`: AWS → `aws … --profile <name>`, GCP → `gcloud … --configuration <name>`.

## What to know before running it

- **The stack must be up** (`./run.sh` once). The credential store is the volume the running studio
  has mounted at `/devkit-auth`; the script reads it from the container, so an isolated checkout with
  `COMPOSE_PROJECT_NAME` in `.env` works unchanged. No running studio is a hard error.
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
- **GCP** is keyless: it copies your `authorized_user` ADC file (from `gcloud auth application-default
  login`; plain `gcloud auth login` is not enough) into the store under the connection's name, after
  proving with that exact file that it can mint an impersonated token for the service account and list
  the project's buckets. Service-account keys and `external_account` files are refused by design. The
  user behind the ADC needs `roles/iam.serviceAccountTokenCreator` on the service account. The studio
  honours this only when its image carries the `adcRef` credential path (`AIStudio__GcpAdcRoot`).
- **GCP compatibility is not proven by the mount.** The Compose mount of the store and the
  `AIStudio__GcpAdcRoot` setting show only that the stack is configured for `adcRef`; they do not
  prove the running studio image supports it. A legacy error mentioning *no private key*,
  `SystemCredential` or *default ADC* means the image lacks `adcRef` support or the credential was
  registered without a reference. Check those non-secret markers — the error text, the running
  image's build, and whether the credential carries a reference — never the credential contents. The
  fix is a one-time update of the backend using the companion backend PR 796 and its build
  instructions. Do not suggest a service-account private key, a global ADC mount or an extra Google
  login as a workaround, and do not call a bootstrap `verify` pass a ticket success.
- **This check changes no rules.** It links no new files and adds no new paths; the question-first
  protocol and the scoped-permission rules above apply unchanged. Diagnosing compatibility is not a
  reason to read `~/.config/gcloud` or the store, pick a target for the user, or run anything beyond
  `status` / `verify` of the already-approved connection without the usual approval.
- **Verification scope.** `verify` for AWS calls the studio's own scope endpoint, which runs the
  backend's credential population for that scope. For GCP, nothing outside a ticket expands a scope,
  so `verify` proves the bootstrap and the store file only; the ticket proof is
  `tests/e2e/cloud_onboarding_e2e.py` (invokes the LLM, approves only exact read-only commands, passes
  only on raw tool output equal to an operator-supplied control list, and requires unchanged container
  ids). Run it only when asked; it costs tokens.
- **Failures are final, not retried.** A wrong profile, revoked ADC, or un-granted service account
  fails before any platform write; read the `✗` line, fix the cause, re-run.

## Reporting completion — name the stage actually reached

Each stage is a separate claim. Report the furthest stage that succeeded and name the ones that did not
run; never present an earlier stage as a later one.

1. **Validated** — `--dry-run` or the pre-write checks passed (profile or ADC resolved; for GCP the
   impersonated token and bucket listing proved). Nothing was written.
2. **Stored** — the credential snapshot or ADC copy exists in the `cloud_auth` volume under the
   connection's name.
3. **Registered** — the provider, credential and scope objects exist in the studio.
4. **Workspace-attached** — the scope is confirmed attached to the selected workspace, not assumed
   from the flag (not when `--no-workspace` was used).
5. **Verification passed** — `verify --name <name>` passed. For AWS this exercises the backend's
   credential population for the scope; for GCP it proves only the bootstrap and the store file.
   **GCP `verify` is not the ticket E2E** — only `tests/e2e/cloud_onboarding_e2e.py`, run when asked,
   proves a ticket can use the scope.

A dry run is never reported as a connection. A denied approval or a failed step is reported as exactly
that, with the `✗` line and what remains to be done.
