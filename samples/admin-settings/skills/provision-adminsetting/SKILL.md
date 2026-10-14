---
name: provision-adminsetting
description: Provisions an Admin Setting — the agent-based provisioning loop for an ADMIN-scoped resource. Reads the spec the platform wrote to the ticket, applies the setting (here: records `key = "value"` as the summary), and writes the result back via the resource's own admin status/results routes.
---

# provision-adminsetting — agent-based provisioning for an admin-scoped resource

You are the **provisioning agent** for an **Admin Setting** (origin `AdminSetting`, subType `admin-setting`).
When an administrator creates one, the platform opens a ticket in the system **Admin Workspace** and runs this
skill. The loop is the same as for any agent-provisioned resource; only the write-back URL differs, because
admin-scoped resources are served under `/v1/aiservicedesk/admin/data/environment/…` with no `{workspaceId}`.

```
read spec  ->  POST status Processing (+ progressive subStatus)  ->  do the work
           ->  POST results (the outputs)  ->  POST status Complete
           (on error at any point: POST status Failed + faults, then stop)
```

## Inputs the platform gives you

- `$DUPLO_BASE` (fall back to `$DUPLO_HOST`) + `$DUPLO_TOKEN` — base URL + a **resource-scoped** token. For an
  admin-scoped resource the platform grants it on THIS resource's admin routes
  (`…/admin/data/environment/*/{id}/status` and `…/{id}/results`) and nothing else.
- `shared/admin-setting.json` — the resource's expanded spec. Read `spec.settingKey`, `spec.settingValue`, and
  `id` for the write-back URL. `ownerWorkspaceId` is always the Admin Workspace;
  you do not need it.
- **No scope credentials by default.** The Admin Workspace has no scopes; a skill only gets credentials for
  scopes listed in the resource's own `spec.scopeIds`.

Write-back base: `RES=${DUPLO_BASE:-$DUPLO_HOST}/v1/aiservicedesk/admin/data/environment/extensions/admin-settings/<id>`
(the resource's OWN admin route — it must equal the `AdminSettingController` `[Route]`). Never post to the
`…/user/data/workspaces/…` form: the token does not cover it and no such controller exists.

## Steps

1. **Report progress.** `POST $RES/status {"status":"Processing","subStatus":"Applying setting"}`.
2. **Do the work.** Here: `summary = <settingKey> = "<settingValue>"`. A real skill applies the setting to the
   system it configures.
3. **Write the result** (a SEPARATE api from status): `POST $RES/results {"summary":"<...>"}`.
4. **Complete.** `POST $RES/status {"status":"Complete","subStatus":"Setting applied"}`.
   On any failure: `POST $RES/status {"status":"Failed","faults":["<message>"]}` and stop.

### Deterministic helper
`provision.sh` (next to this SKILL.md) runs steps 1–4 verbatim. This skill is mounted under `.claude/skills/`,
so invoke it by its full path from the ticket workdir:
```bash
bash .claude/skills/provision-adminsetting/provision.sh
```

## Deprovision
On delete the platform reuses the same ticket and sends *"Deprovision this resource. Tear down all infrastructure
managed by this resource."* This sample creates nothing outside its own row, so reply by posting
`POST $RES/status {"status":"DeProvisioned"}`; the platform then deletes the row.

## Notes

- **Status and results are two separate APIs** — never fold the result into a status payload.
- See the dev-kit's `.claude/skills/duplo-extension-dev/reference/21-admin-resources.md` for admin scope end to end.
