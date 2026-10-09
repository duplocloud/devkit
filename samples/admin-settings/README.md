# Admin Settings — an admin-scoped typed extension

The worked reference for an **admin-scoped** resource. It is the `helloworld` sample with one change of
scope: the resource is platform-wide configuration that only administrators see and manage, instead of a
per-workspace resource. Read `../helloworld/README.md` first; this file only covers what differs. The full
rules are in `.claude/skills/duplo-extension-dev/reference/21-admin-resources.md`.

```
backend/    Spec/Result/Resource/Hooks/Service (unchanged shape) + AdminSettingsController : AdminResourcesController
frontend/   Angular 22 Native-Federation remote (list/add/view) calling the ADMIN route; the service never reads the tenant
skills/     provision-adminsetting — reads settingKey+settingValue, writes summary back via the admin route
manifest.json  typed resource + skill + an admin-scoped menu tree and route ("scope": "admin")
```

## What differs from a workspace-scoped resource

| Piece | Workspace resource (`helloworld`) | Admin resource (this sample) |
|---|---|---|
| Controller base | `ResourcesController<…>` | `AdminResourcesController<…>` |
| Controller `[Route]` | `v1/aiservicedesk/user/data/workspaces/{workspaceId}/environment/extensions/helloworlds` | `v1/aiservicedesk/admin/data/environment/extensions/admin-settings` |
| Access-node declaration | `[AccessControl(Parent = typeof(Workspace), …)]` | none — administrators bypass hierarchical access |
| Who can call it | members of the workspace | administrators only (the platform's tenant policy guards every `/aiservicedesk/admin` route) |
| Row owner (`ownerWorkspaceId`) | the workspace in the route | always the system Admin Workspace `000000000000000000000ad1` |
| FE service base URL | `…/user/data/workspaces/${tenant}/environment/${REST_SEGMENT}` | `…/admin/data/environment/${REST_SEGMENT}` |
| FE list refresh | `session.getTenantRefreshTimer` (re-fetch on workspace switch) | `session.getRefreshTimer` (no workspace to switch) |
| Ticket link | `/ai/service-desk/<workspace>/tickets/chat/<name>` | `/ai/suite/admin/tickets/chat/<name>` |
| Manifest menu tree / route | no `scope` (workspace) | `"scope": "admin"` on the top-level menu node and on the route |
| Where it renders | AI DevOps, `/ai/suite/{tenant}/extensions/…` | AI Admin, `/ai/suite/admin/extensions/…` |
| Skill write-back `RES` | `…/user/data/workspaces/<ownerWorkspaceId>/environment/extensions/helloworlds/<id>` | `…/admin/data/environment/extensions/admin-settings/<id>` |
| Scope credentials | the workspace's scopes | none unless the spec lists `scopeIds` (the Admin Workspace has none) |

Entity, spec, result, hooks and service are identical in shape. The provisioning lifecycle (tickets, status,
results, deprovision) is the same pipeline; the platform grants the agent's token on the admin callback routes.

## Requirements

- **SDK 1.0.7 or later** — the first SDK that ships `AdminResourcesController`. Against 1.0.6 the backend does
  not compile.
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
curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $USER_TOKEN" "$A"   # 403 for anyone else
curl -fsS -X POST "$A" -H "Authorization: Bearer $ADMIN_TOKEN" -H "Content-Type: application/json" \
  -d '{"name":"maintenance-banner","spec":{"settingKey":"maintenance-banner","settingValue":"Back at 18:00 UTC"}}'
# then poll GET $A/<id> until status is Complete; ownerWorkspaceId is 000000000000000000000ad1
```

In the UI the menu appears only in **AI Admin → Platform Settings → Admin Settings**, never in AI DevOps.
