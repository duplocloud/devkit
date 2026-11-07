# Admin Settings — an admin-scoped extension and a workspace resource that consumes it

The worked reference for **admin extension scope**, in its most common shape: two resources.

- **`AdminSetting` (admin-scoped)** — platform-wide configuration administrators manage in AI Admin. It is the
  `helloworld` resource with one change of extension scope.
- **`AdminSettingConsumer` (workspace-scoped)** — what each workspace creates to *use* an admin setting: it picks
  one, and its agent is provisioned with that setting's details.

Read `../helloworld/README.md` first; this file only covers what differs. The full rules are in
`.claude/skills/duplo-extension-dev/reference/21-admin-resources.md`.

```
backend/    AdminSetting (+ AdminSettingsController : AdminResourcesController, AdminSettingsReadController)
            AdminSettingConsumer (+ AdminSettingConsumersController : ResourcesController)
frontend/   Angular 22 Native-Federation remote: admin-setting pages (admin route; read-only on the workspace
            side) + consumer pages (workspace route); resource-page.component picks the page per mount
skills/     provision-adminsetting — reads settingKey+settingValue, writes summary back via the ADMIN route
            provision-adminsettingconsumer — reads the embedded admin setting, writes back via the WORKSPACE route
manifest.json  both typed resources + skills + an admin menu tree and a workspace one, with their routes
```

## What differs from a workspace-scoped resource (`AdminSetting`)

| Piece | Workspace resource (`helloworld`) | Admin resource (this sample) |
|---|---|---|
| Controller base | `ResourcesController<…>` | `AdminResourcesController<…>` |
| Controller `[Route]` | `v1/aiservicedesk/user/data/workspaces/{workspaceId}/environment/extensions/helloworlds` | `v1/aiservicedesk/admin/data/environment/extensions/admin-settings` |
| Access-node declaration | `[AccessControl(Parent = typeof(Workspace), …)]` | the same — mandatory; the host rejects the load without it |
| Who can call it | members of the workspace (per their grants) | administrators, plus any user granted the Admin Workspace (per verb) |
| Row owner (`ownerWorkspaceId`) | the workspace in the route | always the system Admin Workspace, assigned by the platform |
| FE service base URL | `…/user/data/workspaces/${tenant}/environment/${REST_SEGMENT}` | `…/admin/data/environment/${REST_SEGMENT}` |
| FE list refresh | `session.getTenantRefreshTimer` (re-fetch on workspace switch) | `session.getRefreshTimer` (no workspace to switch) |
| Ticket link | `/ai/service-desk/<workspace>/tickets/chat/<name>` | `/ai/suite/admin/tickets/chat/<name>` |
| Manifest menu tree / route | no `scope` (workspace) | `"scope": "admin"` on the top-level menu node and on the route |
| Where it renders | AI DevOps, `/ai/suite/{tenant}/extensions/…` | AI Admin, `/ai/suite/admin/extensions/…` |
| Skill write-back `RES` | `…/user/data/workspaces/<ownerWorkspaceId>/environment/extensions/helloworlds/<id>` | `…/admin/data/environment/extensions/admin-settings/<id>` |
| Provider-scope credentials | the workspace's provider scopes | only scopes attached to the Admin Workspace and listed in `spec.scopeIds` |

**Read-only workspace view (optional).** Workspace members can also see the settings — read-only, without the value —
under **AI DevOps → Platform Settings → Admin Settings**. `AdminSettingsReadController` (a plain
`ControllerBase` with `[Authorize]`) serves `GET`/`GET {id}` on
`…/user/data/workspaces/{workspaceId}/environment/extensions/admin-settings` and returns `AdminSettingView`
(name, key, status, timestamps). The same frontend pages read `scope` from the route and hide every action and
the value there. It is a deliberate platform-wide disclosure: every member of every workspace sees every row.
See `reference/21-admin-resources.md` → "Read-only workspace view".

Entity, spec, result, hooks and service are identical in shape. The provisioning lifecycle (tickets, status,
results, deprovision) is the same pipeline; the platform grants the agent's token on the admin callback routes.

## The consumer (`AdminSettingConsumer`)

An ordinary workspace resource — workspace route, workspace access node, ticket in its own workspace — plus the
four things that make the cross-scope link work:

| Concern | Where |
|---|---|
| Spec references the admin row: `adminSettingId` | `AdminSettingConsumerSpec` |
| Create/change is rejected unless that row exists, belongs to the Admin Workspace and is `Complete` | `AdminSettingConsumerService.ValidateSpecAsync` |
| The add form's picker lists `Complete` settings from the read-only workspace view (members cannot call the admin route) | `consumer/add-admin-setting-consumer.component.ts` |
| The admin row is embedded as `adminSetting` in `shared/admin-setting-consumer.json` — the platform writes only the consumer's own spec, and its token cannot read the admin route | `AdminSettingConsumerService.GetExpandedSpecForAgentAsync` |
| An admin setting cannot be deprovisioned or deleted while any workspace's consumer references it | `AdminSettingService.GuardNotInUseAsync` |

The consumer's skill keeps the setting's value out of its Result: workspace members can read the Result, and the
read-only view hides the value from them on purpose.

## Requirements

- **A host SDK that ships `AdminResourcesController`** (duplo-ai-helpdesk#685). `build-extension.sh` probes the
  host's SDK bundle for it and stops with a clear error when it is missing.
- **A portal with admin extension routes, menus and the AI Admin ticket page** (`scope: "admin"` support). On
  an older portal the backend still works but the pages and menu do not appear.

## Build + load

```bash
./scripts/build-extension.sh  samples/admin-settings
./scripts/deploy-extension.sh samples/admin-settings/dist/extension.zip
```

## Verify

```bash
A=$DUPLO_BASE/v1/aiservicedesk/admin/data/environment/extensions/admin-settings
curl -fsS -H "Authorization: Bearer $ADMIN_TOKEN" "$A"                       # 200 for an administrator
curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $USER_TOKEN" "$A"   # 403 without an Admin Workspace grant
curl -fsS -X POST "$A" -H "Authorization: Bearer $ADMIN_TOKEN" -H "Content-Type: application/json" \
  -d '{"name":"maintenance-banner","spec":{"settingKey":"maintenance-banner","settingValue":"Back at 18:00 UTC"}}'
# then poll GET $A/<id> until status is Complete; ownerWorkspaceId is the Admin Workspace, not yours

W=$DUPLO_BASE/v1/aiservicedesk/user/data/workspaces/$WS/environment/extensions/admin-setting-consumers
curl -s -w '\n%{http_code}\n' -X POST "$W" -H "Authorization: Bearer $USER_TOKEN" -H "Content-Type: application/json" \
  -d '{"name":"bad","spec":{"adminSettingId":"no-such-id"}}'           # 400 "Admin setting 'no-such-id' does not exist."
curl -fsS -X POST "$W" -H "Authorization: Bearer $USER_TOKEN" -H "Content-Type: application/json" \
  -d '{"name":"banner-for-team-a","spec":{"adminSettingId":"<id>"}}'   # then poll GET $W/<consumerId> until Complete
curl -fsS -H "Authorization: Bearer $ADMIN_TOKEN" "$A/<id>/can-deprovision"   # canDeprovision false while in use
```

In the UI, **AI Admin → Platform Settings → Admin Settings** is the full editor; **AI DevOps → Platform Settings →
Admin Settings** is the read-only view (no value, no actions), and **AI DevOps → Platform Settings → Setting
Consumers** is where a workspace picks one.
