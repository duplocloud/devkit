---
name: provision-helloworld
description: Provisions a Hello World resource — the canonical AGENT-BASED provisioning loop. Reads the spec the platform wrote to the ticket, does the work (here: combine firstName + lastName into fullName), and writes the result back via the resource's own status/results APIs.
---

# provision-helloworld — the agent-based provisioning pattern

You are the **provisioning agent** for a **Hello World** resource (origin `HelloWorld`, subType
`hello-world`). When a user creates one, the platform opens a ticket and runs this skill. This is the
reference for **agent-based provisioning** (`ProvisioningMode.HelpdeskAgent`): the platform owns the
resource lifecycle; your job is to realize the spec and report back. Substitute the trivial "combine
names" step with real automation (call a cloud/SaaS API, run a job, apply a manifest) for a real resource.

The pattern (independent of what the work actually is):

```
read spec  ->  POST status Processing (+ progressive subStatus)  ->  do the work
           ->  POST results (the outputs)  ->  POST status Complete
           (on error at any point: POST status Failed + faults, then stop)
```

## Inputs the platform gives you

- `$DUPLO_BASE` (fall back to `$DUPLO_HOST`) + `$DUPLO_TOKEN` — base URL + a **resource-scoped** token
  valid only for THIS resource's `…/{id}/status` and `…/{id}/results`.
- `shared/hello-world.json` — the resource's expanded spec (`GetExpandedSpecForAgentAsync` output).
  Read `spec.firstName`, `spec.lastName`; it also carries `id` and `ownerWorkspaceId` for the write-back URL.
- `platform_context.scopes` (or `other_scopes/*.json`) — **if the resource selected scopes**, their cloud
  credentials are here (and written to `./.aws/credentials`, `./.kube/config`, etc.). A real provisioning
  skill uses these to talk to the cloud. Hello World needs none.

Write-back base: `RES=${DUPLO_BASE:-$DUPLO_HOST}/v1/aiservicedesk/user/data/workspaces/<ownerWorkspaceId>/environment/extensions/helloworlds/<id>`
(the resource's OWN typed route — not a generic one). Spec fields are typed properties directly under
`spec`; the result body IS the typed `HelloWorldResult` object.

## Steps

1. **Report progress.** `POST $RES/status {"status":"Processing","subStatus":"Generating full name"}`.
   Post `subStatus` updates as you go — the UI shows them live.
2. **Do the work.** Here: `fullName = trim("<firstName> <lastName>")`. (A real skill calls its API/SDK here,
   using scope credentials from step above.)
3. **Write the result** (a SEPARATE api from status): `POST $RES/results {"fullName":"<...>"}`.
4. **Complete.** `POST $RES/status {"status":"Complete","subStatus":"Full name generated"}`.
   On any failure: `POST $RES/status {"status":"Failed","faults":["<message>"]}` and stop.

### Deterministic helper
`provision.sh` (next to this SKILL.md) runs steps 1–4 verbatim (parses the spec with `jq`, curls the
three endpoints). This skill is mounted under `.claude/skills/`, so invoke it by its full path from the
ticket workdir (NOT `skills/…`, which does not exist there):
```bash
bash .claude/skills/provision-helloworld/provision.sh
```
Or follow the steps yourself if you need to branch on the spec.

## Notes

- **Status and results are two separate APIs** — never fold the result into a status payload
  (see [reference/04-hooks.md](../../../../reference/04-hooks.md)).
- The result body IS the typed result object (`{ "fullName": … }`); the agent's FE remote renders
  `result.fullName`.
- The backend C# (`backend/HelloWorld.cs`) defines the typed `spec`/`result` shape and provides the
  `…/status` + `…/results` endpoints via `ResourcesController`; this skill only fills them. See
  [reference/01-architecture.md](../../../../reference/01-architecture.md) for the full loop.
