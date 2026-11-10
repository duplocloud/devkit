# Connect GCP (keyless, from the command line)

**What you'll do:** give the agent read-only access to a GCP project through a service account,
without creating or downloading any key, then prove the connection with a real ticket.

**What you need first:** the platform running ([1. Install and sign in](install.md)), the `gcloud` CLI,
and a Google user that can administer IAM in the project (only needed the first time, when
`helpdesk-sa` does not exist yet).

> **From Claude Code:** run `/duplo-cloud-connect`, choose GCP and ADC, and give the project ID. The agent runs
> the ADC login (with your approval) if it is missing, connects, and verifies. The manual steps follow.

## 1. Log in for Application Default Credentials

```bash
gcloud auth application-default login
```

The backend reads this file **in place**: the stack binds your whole gcloud directory read-only (default
`~/.config/gcloud`; an exported `CLOUDSDK_CONFIG` or `DEVKIT_GCLOUD_DIR` in `.env` selects another). If you use
a custom directory, log in with `CLOUDSDK_CONFIG=<that directory> gcloud auth application-default login` so the
file lands where the backend looks. Nothing is copied, and every GCP connection shares this one identity.

If there is no local ADC file when the stack first starts, `GOOGLE_APPLICATION_CREDENTIALS` is left empty so the
standard Google metadata fallback remains. After this login, `connect-cloud.sh` automatically applies the native
environment variable and mount and resets the backend's credential cache.

Plain `gcloud auth login` is not enough. The login must include the email scope (gcloud's default does):
connect-cloud asks Google who the ADC token belongs to and never trusts the `account` field or
gcloud's active account.

## 2. Connect

```bash
./scripts/connect-cloud.sh gcp --project gcp-test9
```

The connection name defaults to the project ID (`gcp-test9`) and the service account to
`helpdesk-sa@<project-id>.iam.gserviceaccount.com`; the scope is attached to the workspace configured in
`.env` (`EXTENSION_DEV_WORKSPACE_ID`). To use something else, add `--name <name>` and/or
`--service-account <email>`, or `--workspace <id>` / `--no-workspace`.

What happens, in order, and nothing else:

1. The native ADC file (the one the backend binds) is read and checked to be an `authorized_user` file. `--adc-source` may only name that exact file.
2. Every existing object named `gcp-test9` is checked for conflicts (another project or service account
   under the same name, a credential or scope not created by this tool, a missing workspace) and the
   running backend is inspected (read-only). A conflict stops everything — before any cloud write.
3. With exactly the ADC file, the script mints an impersonated token for the service account and lists
   the project's buckets with it. If that works, nothing in Google is touched (no IAM admin rights needed).
   If it fails with a *missing account / missing permission / disabled API* condition (not a revoked
   login, a network error or a 5xx) and the service account is the derived default, the script prepares
   **only that account, in only that project** — choosing the project is the authorization:
   - enables `iam.googleapis.com` and `iamcredentials.googleapis.com` if disabled;
   - creates (or reuses) `helpdesk-sa@<project>`; a disabled one stops the run;
   - grants your verified ADC user `roles/iam.serviceAccountTokenCreator` **on that service account
     only** (this lets you mint its token; it gives the account no access by itself);
   - grants `helpdesk-sa` read-only `roles/viewer` **on that project only**.

   IAM policies are read and written whole (etag, conditions and audit configs preserved, one
   unconditional membership appended, bounded retry on concurrent edits). No Owner/Editor, no keys, no
   deletes, no other project or quota project is touched. It then waits (bounded) for IAM propagation and
   re-runs the proof. A 403 here means an IAM admin must act; the output lists exactly which changes
   were already applied. `--dry-run` never changes anything and says "not validated" if repair is needed;
   `--no-bootstrap` skips all of this; a different/custom `--service-account` (including a cross-project one) is used as-is
   (never created, no grants added); spelling out the derived default `helpdesk-sa@<project>` still bootstraps.
4. With the host proof passed, the kit makes the backend able to use the file — only the backend, only
   when needed: if the running backend lacks the `/devkit-gcloud` mount or the environment variable it is
   recreated (`compose up -d --no-deps --no-build --pull never duplo-ai-studio`); and because Google's client
   caches the first credential lookup for the life of the process, it is restarted on the first native
   connection and after a new login (never on a repeat or a new target project with the same ADC). It then
   waits for health and probes, as the backend's exact uid, that it reads the same file the host proof used.
   Nothing is registered if that fails. On native Linux a `0700`/`0600` directory owned by you can be
   unreadable to the backend's uid; the kit reports it and never loosens permissions (only Docker Desktop has
   been verified).
5. A provider `gcp-gcp-test9` (type GCP, account = the project), a credential `gcp-test9` carrying only
   `cloudRoleToAssume` (no keys, no copied file) and a scope `gcp-test9` are created — or reused — and the
   scope is attached to the `extension-dev` workspace. A credential from the earlier design that still carries
   `adcRef` is rewritten in place (the published backend ignores `adcRef`).

Re-running the same command is safe: when the proof already passes it makes no IAM or API change and writes nothing new. After a new
`gcloud auth application-default login`, run it again (or `connect-cloud.sh refresh --name gcp-test9`): it
restarts only the backend so it picks up the new login.

## 3. Prove it works

Open **HelpDesk → Add Ticket**, select the scope **gcp-test9**, and ask:

```
List the buckets in this project.
```

Approve the `gcloud storage buckets list --configuration gcp-test9` command when the agent asks. The
names it returns are the names `gcloud storage buckets list --project gcp-test9` shows you locally. The
backend impersonates the service account with the one shared host ADC, so every GCP connection is that same
Google user acting as its own service account.

`connect-cloud.sh verify` reports **runtime-file** (the backend's mount, variable, uid read and source
identity), **host-proof** (impersonation + bucket list) and **ticket-proven** separately; only a real ticket
like this one — or the harness below — proves the last.

An automated version of this check, which approves only the exact read-only command and compares the
output against a list you supply, is `tests/e2e/cloud_onboarding_e2e.py --cloud gcp`.

**Next:** [3. Connect Kubernetes](connect-kubernetes.md)
