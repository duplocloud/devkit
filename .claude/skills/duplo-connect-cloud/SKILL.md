---
name: duplo-connect-cloud
description: Connect an AWS account or GCP project to the running DuploCloud dev kit (provider, credential, scope, workspace attach) with scripts/connect-cloud.sh, reconnect expired credentials, or check connection status. Not for the LLM provider the agent runs on (that is run.sh --model / switch-llm.sh).
---

# duplo-connect-cloud — cloud connections for the local dev kit

`./scripts/connect-cloud.sh` is the one deterministic way to register a cloud account with the local
stack. It is idempotent (same `--name` → same objects, updated in place), restarts nothing, checks every
conflict before it writes anything, and never puts a secret on a command line, in its output, or in
`.devkit-cloud/connections.json`.

## Commands

```bash
./scripts/connect-cloud.sh aws --name test21 --profile test21 [--region us-east-1]
./scripts/connect-cloud.sh gcp --name gcp-test9 --project gcp-test9 \
    --service-account helpdesk-test@gcp-test9.iam.gserviceaccount.com [--adc-source <authorized_user json>]
./scripts/connect-cloud.sh refresh --name <name>      # re-resolve + rotate in place; prints container ids/start times before and after
./scripts/connect-cloud.sh verify  --name <name>      # backend/bootstrap checks, no ticket, no LLM cost
./scripts/connect-cloud.sh status [--json]
```

`--json` on any subcommand gives a machine-readable result; `--dry-run` resolves, validates and prints
what *would* be written, and writes nothing. The scope the agent sees is named exactly `--name`:
AWS → `aws … --profile <name>`, GCP → `gcloud … --configuration <name>`.

## What to know before running it

- **The stack must be up** (`./run.sh` once). The credential store is the volume the running studio
  has mounted at `/devkit-auth`; the script reads it from the container, so an isolated checkout with
  `COMPOSE_PROJECT_NAME` in `.env` works unchanged. No running studio is a hard error.
- **A workspace is required** so the scope is selectable by tickets; the default is
  `EXTENSION_DEV_WORKSPACE_ID` from `.env`. Pass `--no-workspace` only to register without attaching.
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
- **Verification scope.** `verify` for AWS calls the studio's own scope endpoint, which runs the
  backend's credential population for that scope. For GCP, nothing outside a ticket expands a scope,
  so `verify` proves the bootstrap and the store file only; the ticket proof is
  `tests/e2e/cloud_onboarding_e2e.py` (invokes the LLM, approves only exact read-only commands, passes
  only on raw tool output equal to an operator-supplied control list, and requires unchanged container
  ids). Run it only when asked; it costs tokens.
- **Failures are final, not retried.** A wrong profile, revoked ADC, or un-granted service account
  fails before any platform write; read the `✗` line, fix the cause, re-run.
