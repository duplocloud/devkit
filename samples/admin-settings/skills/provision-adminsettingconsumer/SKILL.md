---
name: provision-adminsettingconsumer
description: Provisions an Admin Setting Consumer — a WORKSPACE resource that uses an admin-scoped Admin Setting. Reads the admin setting the platform embedded in the ticket's spec file, applies it to the workspace (here: records which setting is in use), and writes the result back via the resource's own workspace status/results routes.
---

# provision-adminsettingconsumer — a workspace resource that consumes an admin one

You are the **provisioning agent** for an **Admin Setting Consumer** (origin `AdminSettingConsumer`, subType
`admin-setting-consumer`). A workspace member created it and picked an **Admin Setting** — a platform-wide row an
administrator provisioned in the system Admin Workspace. The ticket runs in the consumer's **own workspace**, so
this is the ordinary workspace loop; the only extra is reading the admin setting.

```
read spec + adminSetting  ->  POST status Processing  ->  apply the setting to this workspace
                          ->  POST results (the outputs)  ->  POST status Complete
                          (on error at any point: POST status Failed + faults, then stop)
```

## Inputs the platform gives you

- `$DUPLO_BASE` (fall back to `$DUPLO_HOST`) + `$DUPLO_TOKEN` — base URL + a **resource-scoped** token for THIS
  resource's workspace `status`/`results` routes.
- `shared/admin-setting-consumer.json` — this resource's expanded spec:
  - `id`, `ownerWorkspaceId` — for the write-back URL.
  - `spec.adminSettingId` — the admin row it references.
  - `adminSetting` — **the admin row's details** (`id`, `name`, `status`, `settingKey`, `settingValue`). The
    platform writes only this resource's own spec to the file; the extension's
    `GetExpandedSpecForAgentAsync` embeds `adminSetting`. **You cannot GET the admin route** — the token does not
    cover it — so this is your only source. `null` means the row is gone: fail with a clear fault.
- **Provider-scope credentials:** the usual ones for this workspace and `spec.scopeIds`. This sample needs none.

Write-back base:
`RES=${DUPLO_BASE:-$DUPLO_HOST}/v1/aiservicedesk/user/data/workspaces/<ownerWorkspaceId>/environment/extensions/admin-setting-consumers/<id>`
(it must equal the `AdminSettingConsumersController` `[Route]`). Never post to the admin route: that belongs to
the admin setting, not to this resource.

## Steps

1. **Check the reference.** If `adminSetting` is null or has no `settingKey`:
   `POST $RES/status {"status":"Failed","faults":["<why>"]}` and stop.
2. **Report progress.** `POST $RES/status {"status":"Processing","subStatus":"Applying admin setting"}`.
3. **Do the work.** A real skill applies `adminSetting.settingValue` to this workspace's systems. Keep the value
   **out of the result**: every workspace member can read the result, and the platform hides the value from
   them on purpose. Here: `summary = Using <settingKey> (admin setting '<name>')`.
4. **Write the result** (a SEPARATE api from status): `POST $RES/results {"summary":"<...>"}`.
5. **Complete.** `POST $RES/status {"status":"Complete","subStatus":"Admin setting applied"}`.
   On any failure: `POST $RES/status {"status":"Failed","faults":["<message>"]}` and stop.

### Deterministic helper
`provision.sh` (next to this SKILL.md) runs steps 1–5 verbatim:
```bash
bash .claude/skills/provision-adminsettingconsumer/provision.sh
```

## Deprovision
On delete the platform reuses the same ticket and sends *"Deprovision this resource. Tear down all infrastructure
managed by this resource."* Undo what step 3 applied (this sample applied nothing outside its row), then
`POST $RES/status {"status":"DeProvisioned"}`; the platform deletes the row. Until every consumer of an admin
setting is gone, the admin side cannot deprovision that setting.

## Notes

- **Status and results are two separate APIs** — never fold the result into a status payload.
- See the dev-kit's `.claude/skills/duplo-extension-dev/reference/21-admin-resources.md` →
  "Workspace resources that consume an admin resource".
