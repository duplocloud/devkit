---
name: provision-network-stack
description: Provisions and operates a Network Stack (AWS VPC + subnets + security group) with a LONG-RUNNING background terraform the agent launches detached and watches with a sleep loop. Dispatches on spec.lastRequestedAction for on-demand plan/apply runs after provisioning, writes per-run logs the Logs tab reads, and handles deprovision as terraform destroy.
---

# provision-network-stack — long-running terraform + on-demand actions

You are the provisioning agent for a **NetworkStack** resource (origin `NetworkStack`, subType
`network-stack`). This skill is the dev-kit's reference for three patterns beyond hello-world:

1. **Long-running provisioning** — terraform runs for minutes: launch it DETACHED in the background and
   watch it with a sleep loop, posting progressive `Result.modules[]` + `subStatus` heartbeats.
2. **On-demand actions** — after provisioning, the user presses Plan/Apply on the detail view; the
   backend stamps `spec.lastRequestedAction` and the platform messages THIS SAME ticket. You dispatch on
   the verb. There is never a second ticket.
3. **Run logs** — every run writes `canvas-documents/{plans,applies}/<runId>.{log,meta.json}` in the
   ticket workdir; the agent's backend serves them to the Logs tab via `ITicketService`
   (see reference/05 §7).

## Inputs the platform gives you

- `$DUPLO_HOST` + `$DUPLO_TOKEN` — resource-scoped write-back credentials (never overwrite either;
  `$DUPLO_BASE` exists only when a developer exports it locally — scripts read `${DUPLO_BASE:-$DUPLO_HOST}`).
- `shared/network-stack.json` — the expanded spec: `spec.region`, `spec.vpcCidr`, `spec.subnets[]`,
  `spec.tags`, `spec.lastRequestedAction`, plus `id` / `ownerWorkspaceId` / `name`.
- An **AWS scope** — its credentials land at `.aws/credentials` (+ `AWS_SHARED_CREDENTIALS_FILE` /
  `AWS_CONFIG_FILE` env), which the terraform AWS provider picks up automatically
  (reference/07-scope-credentials.md).

Write-back base:
`RES=${DUPLO_BASE:-$DUPLO_HOST}/v1/aiservicedesk/user/data/workspaces/<ownerWorkspaceId>/environment/extensions/network-stacks/<id>`

## Dispatch — what run is this?

`spec.lastRequestedAction` PERSISTS on the spec forever, but every "spec updated" reconcile message
re-delivers the whole spec — so a request must be acted on **once**. `tf-run.sh` stamps the
`requestedAt` it consumed to `shared/.last-action-processed` after every run; **compare before acting**:

```bash
REQ_AT=$(jq -r '.spec.lastRequestedAction.requestedAt // empty' shared/network-stack.json)
DONE_AT=$(cat shared/.last-action-processed 2>/dev/null || true)
```

| Situation | Meaning | Run |
|---|---|---|
| `lastRequestedAction` absent AND no prior provision run | initial provisioning (first message) | `bash .claude/skills/provision-network-stack/scripts/tf-run.sh apply provision` |
| `$REQ_AT` non-empty and `≠ $DONE_AT` | a NEW user request (Plan or Apply button) | `tf-run.sh plan` or `tf-run.sh apply` per `.action` |
| `$REQ_AT` empty or `== $DONE_AT` (and already provisioned) | a plain reconcile — e.g. the user edited the spec | **do NOT re-run the stale action.** First check the run-lock: `shared/.run-lock` is a HEARTBEAT file — a run is in flight iff it exists AND its mtime is younger than 90 s (`[ -f shared/.run-lock ] && [ $(( $(date +%s) - $(stat -c %Y shared/.run-lock) )) -lt 90 ]`; PID probes are meaningless across bash calls). In flight → post `{"status":"Processing","subStatus":"a run is in flight — the edit is recorded"}` (never flip a mid-run resource to Complete). Otherwise post `{"status":"Complete","subStatus":"Spec updated — run a Plan to preview the change"}`. Then stop. |

The message the platform sends for an on-demand action re-states the requested verb — but the spec file +
stamp are the source of truth. **Never** run `destroy` in response to these messages (see Deprovision
below). A duplicate plan/apply while the lock is live **exits 3 without posting any status** (report "a run
is already in progress" in chat and stop; do not re-run); a deprovision **waits** for the lock (up to
20 min) instead of being dropped.

## Runtime facts worth knowing

- This skill lands in the ticket at `.claude/skills/<sanitized skill Name>/` (lowercased,
  `[^a-zA-Z0-9_-]` → `-`) — the `bash .claude/skills/provision-network-stack/…` paths hold because the
  registered skill name is exactly `provision-network-stack`. Skills are **frozen after the ticket's first
  message** — editing the bundle mid-ticket does not update the copy on disk.
- Files this script writes under `canvas-documents/` do **not** auto-open the chat canvas panel (only
  Write/Edit-tool writes do) — that's fine: the agent's Logs tab reads them through the backend API.
- Cross-call scratch belongs in `$TMPDIR` (the ticket's `tmp/`), never `/tmp` — `/tmp` is a private tmpfs
  per bash invocation.

## Turn lifetime — the rules this design lives under (verified against the agent runtime)

- **The whole run happens inside ONE bash invocation.** Launch `tf-run.sh` and stay attached until it
  exits. Nothing resumes a run later: there are no cross-turn wakeups, and the ticket's credential files
  (`.aws/…`) are **wiped at the end of every agent turn** — a terraform that outlives its invocation loses
  its credentials mid-run and nobody finalizes it. The next dispatch heals such orphaned runs to `Failed`.
- **Always pass an explicit Bash timeout** when invoking `tf-run.sh` for provision/apply/destroy — e.g.
  `timeout: 3600000` (60 min; ceiling 90 min). The DEFAULT bash budget is 30 minutes, which is exactly the
  manifest's `timeout.provision` — a slow apply on the default budget is killed mid-watch.
- The run-lock exists because **force-sent messages (deprovision, forced spec updates) kill the in-flight
  turn**: the next invocation must not race a half-finished terraform over the same state. It is a
  heartbeat file, stale after 90 s.

## What tf-run.sh does (the long-running pattern — read it, it is the lesson)

```
take shared/.run-lock — duplicate plan/apply: exit 3, NO status post; deprovision: wait for the lock
  (heartbeat file — the watch loop re-touches it every tick; stale after 90 s)
heal orphaned runs: any meta still running:true with a stale lock -> running:false, success:false
write canvas-documents/<plans|applies>/<runId>.meta.json  (running:true)
copy _terraform -> .tf-work/   (skill mount is read-only; local tfstate persists here across runs)
spec -> stack.tfvars.json
POST status Processing "terraform <verb> started"
terraform init && terraform <verb> ... in the background # the long-running part — watched below,
                                                         # finished INSIDE this same invocation
while the rc file has not appeared:                     # the watch loop
    sleep 10; touch the run-lock (heartbeat)
    grep the log for aws_vpc/aws_subnet/aws_security_group transitions
      -> POST results { modules:[ {key,label,status} … ] }   # progressive, only on change
    POST status Processing "terraform <verb>: <last log line>"
classify rc (plan: 0 clean / 2 has-diff / else failed) -> finalize <runId>.meta.json
apply: terraform output -json -> POST results { vpcId, subnetIds, securityGroupId } + modules Created
append the run to results.actions[] (copying spec.lastRequestedAction.requestedBy — the run's only
  notion of WHO) and POST the merged result store
stamp spec.lastRequestedAction.requestedAt -> shared/.last-action-processed  # consumed, even on failure
POST terminal status:  apply -> Complete|Failed;  plan -> ALWAYS Complete (a failed plan mutates
  nothing — it reports "Plan FAILED — see the Logs tab" in subStatus instead of failing the resource)
```

Stay attached until the script exits and report its terminal status in your reply. If the script itself
cannot start (missing spec, no AWS scope), `POST $RES/status {"status":"Failed","faults":["<why>"]}`.

## Deprovision

When the platform sends the generic teardown message (*"Deprovision this resource. Tear down all
infrastructure managed by this resource."*) — and ONLY then:

```bash
DEPROVISION=1 bash .claude/skills/provision-network-stack/scripts/tf-run.sh destroy deprovision
```

`DEPROVISION=1` makes the script post `DeProvisioning` heartbeats and a terminal `DeProvisioned`
(success) or `Failed` (see reference/11-deprovisioning.md). Terraform destroy is idempotent — a re-run
after a partial teardown destroys the remainder.

## Notes

- **Status and results are separate APIs** — never fold one into the other.
- The result accumulator `shared/.result.json` is merged and re-POSTed whole after every run so earlier
  outputs and the `actions[]` history survive later runs.
- Terraform state is LOCAL to the ticket workdir (`.tf-work/terraform.tfstate`) — fine for a sample whose
  ticket owns the stack's whole life. A production agent uses a remote backend (S3 + locking).
