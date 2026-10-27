# Connect GCP (keyless, from the command line)

**What you'll do:** give the agent read-only access to a GCP project through a service account you
already have, without creating or downloading any key, then prove the connection with a real ticket.

**What you need first:** the platform running ([1. Install and sign in](install.md)), the `gcloud` CLI,
and a service account in the project that your Google user may impersonate.

## 1. Log in for Application Default Credentials

```bash
./scripts/setup-google-auth.sh --sa helpdesk-test@gcp-test9.iam.gserviceaccount.com
```

This runs `gcloud auth application-default login` if needed (plain `gcloud auth login` is not enough)
and checks that your user can impersonate the service account. If it cannot and you are an IAM admin on
the project, add `--grant` to give yourself `roles/iam.serviceAccountTokenCreator` on that account.

## 2. Connect

```bash
./scripts/connect-cloud.sh gcp --name gcp-test9 --project gcp-test9 \
    --service-account helpdesk-test@gcp-test9.iam.gserviceaccount.com
```

What happens, in order, and nothing else:

1. Your ADC file is read and checked to be an `authorized_user` file.
2. With exactly that file, the script mints an impersonated token for the service account and lists the
   project's buckets with it. A failure here stops everything — nothing has been written yet.
3. Every existing object named `gcp-test9` is checked for conflicts (another project or service account
   under the same name, a credential or scope not created by this tool, a missing workspace). A conflict
   stops everything — still nothing written.
4. The file is copied into the stack's credential store under the connection name, as the studio's own
   user, readable by nobody else. The store is the compose volume the running studio mounts read-only at
   `/devkit-auth`; no container is restarted.
5. A provider `gcp-gcp-test9` (type GCP, account = the project), a credential `gcp-test9` carrying only
   `cloudRoleToAssume` and `adcRef` (no keys), and a scope `gcp-test9` are created — or reused — and the
   scope is attached to the `extension-dev` workspace.

Re-running the same command is safe: it rewrites the stored file and updates the credential in place.
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
