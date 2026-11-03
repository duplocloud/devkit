# Connect GCP (keyless, from the command line)

**What you'll do:** give the agent read-only access to a GCP project through a service account,
without creating or downloading any key, then prove the connection with a real ticket.

**What you need first:** the platform running ([1. Install and sign in](install.md)), the `gcloud` CLI,
and a Google user that can administer IAM in the project (only needed the first time, when
`helpdesk-sa` does not exist yet).

## 1. Log in for Application Default Credentials

```bash
gcloud auth application-default login
```

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

1. Your ADC file is read and checked to be an `authorized_user` file.
2. Every existing object named `gcp-test9` is checked for conflicts (another project or service account
   under the same name, a credential or scope not created by this tool, a missing workspace) and the
   credential store is checked to be reachable. A conflict stops everything — before any cloud write.
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
4. The file is copied into the stack's credential store under the connection name, as the studio's own
   user, readable by nobody else. The store is the compose volume the running studio mounts read-only at
   `/devkit-auth`; no container is restarted.
5. A provider `gcp-gcp-test9` (type GCP, account = the project), a credential `gcp-test9` carrying only
   `cloudRoleToAssume` and `adcRef` (no keys), and a scope `gcp-test9` are created — or reused — and the
   scope is attached to the `extension-dev` workspace.

Re-running the same command is safe: when the proof already passes it makes no IAM or API change; it rewrites the stored file and updates the credential in place.
After a new `gcloud auth application-default login`, run it again (or `connect-cloud.sh refresh --name
gcp-test9`).

## 3. Prove it works

Open **HelpDesk → Add Ticket**, select the scope **gcp-test9**, and ask:

```
List the buckets in this project.
```

Approve the `gcloud storage buckets list --configuration gcp-test9` command when the agent asks. The
names it returns are the names `gcloud storage buckets list --project gcp-test9` shows you locally. Each
ticket message makes the studio load the stored ADC file afresh and impersonate the service account, so
a second connection with a different Google user (`--name other --adc-source <other file>`) carries its
own identity.

An automated version of this check, which approves only the exact read-only command and compares the
output against a list you supply, is `tests/e2e/cloud_onboarding_e2e.py --cloud gcp`.

**Next:** [3. Connect Kubernetes](connect-kubernetes.md)
