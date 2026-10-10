# 08 — Parent/child resources + nested left-hand menus

An extension can ship **more than one resource type** in a single bundle (sharing one backend DLL + one FE remote),
either **flat** (independent resources — e.g. `GCP` → `network`, `cluster`, `database`) or linked as
**parent → child** (e.g. import a parent "Job" once, then submit many "Build" children under it). Each resource is
a separate entry in `manifest.resources[]`; add a `parent` block only for the child case, omit it for flat. It can
also surface **multiple top-level menu groups** at once (see `frontend.menus[]` below). This doc covers the backend
wiring, the manifest, and — the part that's easy to miss — **how resources surface in the frontend** (nested
left-hand-side menus, or a tab inside a parent's detail view).

> **Worked sample: [`samples/parent-child`](../../../../samples/parent-child/)** — `HelloParent` → `HelloChild`,
> end to end (two-resource backend, nested child controller, manifest `parent` link, and a parent view with a
> children tab built on the platform UI library). Copy and adapt it the way `helloworld` is copied for single
> resources.

## Backend: parent + child resource

A child resource's spec extends `ParentRefSpec<TParent>` instead of `BaseSpec`. That base adds one field,
`ParentId`, which the platform stamps from the nested route — the child always knows its parent.

```csharp
// Duplo.Ai.Model/.../DataContracts/Resource/ParentRefSpec.cs  (the base)
public abstract class ParentRefSpec<TParent> : BaseSpec where TParent : Entity {
    public string? ParentId { get; set; }   // stamped by the controller from the URL
}

// your child spec
public class HelloChildSpec : ParentRefSpec<HelloParent> {
    public string? Note { get; set; }
}
```

The child's controller extends `ChildResourceController<TChild, TParent, TSpec, TResult>` (instead of
`ResourcesController<>`). Its constructor takes `IEntityService<TParent> parentService`. **Override the base
`Create`** (don't add a second `[HttpPost]` — that collides with the inherited one and throws
`AmbiguousMatchException`). Stamp `Spec.ParentId` from the route, validate the parent, then create via
`Service.CreateAsync` and return 201 yourself — do **not** fall back to the base `Create`, because its
`CreatedAtAction(nameof(GetById), …)` can't build a Location for a NESTED route (`GetById` needs `{parentId}`
too) and would turn a successful create into a 400. (`CreateUnderParentAsync` exists on the base, but it calls
`Create` internally — so calling it from your `Create` override would recurse; do the create inline as below.)

```csharp
// Reference: Duplo.Ai.DataManagement/.../Controllers/User/Resource/ChildResourceController.cs
[ApiController]
[Route("v1/aiservicedesk/user/data/workspaces/{workspaceId}/environment/extensions/hello-parents/{parentId}/hello-children")]
// Access node under the parent — see 18-access-control.md. The parent controller carries
// Parent = typeof(Workspace), ParentIdProperty = "OwnerWorkspaceId". ParentIdProperty must be
// explicit here: Spec.ParentId is not a convention path, and omitting it would bind this node to
// the workspace via the OwnerWorkspaceId every entity carries.
[AccessControl(Parent = typeof(HelloParent), ParentIdProperty = "Spec.ParentId")]
public class HelloChildrenController : ChildResourceController<HelloChild, HelloParent, HelloChildSpec, HelloChildResult> {
    private readonly IEntityService<HelloParent> _parent;
    public HelloChildrenController(IEntityService<HelloChild> svc, IEntityService<HelloParent> parent,
                                   ILogger<HelloChildrenController> log) : base(svc, parent, log) { _parent = parent; }

    [HttpPost]
    public override async Task<IActionResult> Create([FromBody] HelloChild resource, CancellationToken ct = default) {
        if (resource?.Spec is null) return BadRequest(ApiResponse<object>.ErrorResult("Invalid request", "Body required."));
        var parentId = RouteData.Values["parentId"]?.ToString();
        if (string.IsNullOrEmpty(parentId)) return BadRequest(ApiResponse<object>.ErrorResult("Invalid request", "parentId required."));
        if (await _parent.GetByIdAsync(parentId, ct) is null)
            return NotFound(ApiResponse<object>.ErrorResult("Not found", $"Parent '{parentId}' not found."));
        resource.Spec.ParentId = parentId;
        resource.OwnerWorkspaceId = GetWorkspaceIdFromRoute();
        try {
            var created = await Service.CreateAsync(resource, ct);   // validates, fires provisioning
            return StatusCode(StatusCodes.Status201Created, ApiResponse<HelloChild>.SuccessResult(created, "Created"));
        } catch (ArgumentException ex) {
            return BadRequest(ApiResponse<object>.ErrorResult("Invalid request", ex.Message));
        }
    }
}
```
> Route changes here are backend changes — **bump `manifest.version` before re-loading**, or old MVC routes linger
> (→ `AmbiguousMatchException`): [06](06-registration.md#reloading-changed-code--bump-manifestversion).

Nested route shape: `…/environment/<parentSeg>/{parentId}/<childSeg>`. The child's own `service` can resolve the
parent's details by injecting `IEntityService<HelloParent>` — **both resources register into the same per-extension
DI container** (`ExtensionRegistrar.RegisterExtension` registers each resource's repo + service +
`IEntityService<>`/`IResourceService<>` aliases), so the child can read its parent during
`GetExpandedSpecForAgentAsync` (e.g. to pass the parent's external id to the provisioning skill).

**Cascade delete**: when the parent is deleted or de-provisioned, delete its children in the parent's entity hook
(`OnPostDeleteAsync` / `OnPostUpdateAsync` guarded on `Status == DeProvisioned`) — worked in
`samples/parent-child`'s `HelloParentHooks`.

## Manifest: two resources + the `parent` link

`manifest.json` carries **two `resources[]` entries**; the child declares a `parent` block
(`ExtensionManifest.cs` → `ExtensionResourceManifest.parent`):

```jsonc
"resources": [
  {
    "ticketOriginType": "HelloParent", "restSegment": "extensions/hello-parents", "subType": "hello-parent",
    "archetype": "typed", "registrar": "DevOpsResource",
    "entityType": "…HelloParent", "specType": "…HelloParentSpec", "resultType": "…HelloParentResult",
    "hooksType": "…HelloParentHooks", "serviceType": "…HelloParentService"
  },
  {
    "ticketOriginType": "HelloChild", "restSegment": "hello-children", "subType": "hello-child",   // CHILD restSegment is BARE by design — the extensions/ namespacing comes from the parent route (00-naming carve-out)
    "archetype": "typed", "registrar": "DevOpsResource",
    "parent": {                                  // ← links child to parent (nested under it)
      "ticketOriginType": "HelloParent",
      "routeSegment": "extensions/hello-parents",   // namespaced; MUST equal the parent's restSegment
      "idRouteParam": "parentId"                    // child controller route nests: .../extensions/hello-parents/{parentId}/hello-children
    },
    "entityType": "…HelloChild", "specType": "…HelloChildSpec", "resultType": "…HelloChildResult",
    "hooksType": "…HelloChildHooks", "serviceType": "…HelloChildService"
  }
]
```

Each resource still gets its own skill-mapping entry (origin/subType → skill).

## Frontend: how the child shows up

There are **two surfacing patterns** — pick by how tightly coupled the child is.

### Pattern A — nested left-hand-side menu via `frontend.menus[]` (title-based)
Declare menus as an **array of trees** under `frontend.menus`. Each node has a `title`, optional `matIcon`/`order`,
and either a `relativeUrl` (a leaf → a route) or `children[]` (a group). The portal find-or-creates each node **by
title** and recurses (`mergeExtensionMenuItems`/`upsertMenuNodeByTitle` in `src/app/menu/menu.ts`):

- A top-level tree whose title doesn't exist yet becomes a **new top-level group** (e.g. `Jenkins`, `GCP`).
- A tree whose **root title matches an existing section** (e.g. `DevOps`) **nests into it** — the existing item is
  reused and your children appended. Matching is case-insensitive on the displayed title; **never reference an
  internal `parentGroupId`/id** — title is the only key.
- One extension may contribute **several** top-level groups (just add more entries to `menus[]`).
- Two extensions adding a same-titled group share it (first creator wins the node; children merge, deduped by title).
- Use `type: "collapsible-section"` for a group with children and `type: "item"` for leaves (the shape the Vuexy
  sidebar renders reliably).

**You (the agent) fill the ids** — the author only gives titles. Generate a deterministic `id` per node
(`<manifest.id>-<slug(title-path)>`), set each leaf's `relativeUrl` to `extensions/<slug>` (namespaced — never
`clouds/…`; see [00-naming](00-naming.md)), and add a matching `frontend.routes[]` entry with the same path.

```jsonc
// manifest.json → frontend.menus : one tree per top-level title (here a new "Hello" group)
"menus": [
  { "id": "duplo.examples.helloworld-hello", "title": "Hello", "type": "collapsible-section",
    "matIcon": "package-variant", "order": 60,
    "children": [
      { "id": "duplo.examples.helloworld-hello-parents", "title": "Parents", "type": "item",
        "matIcon": "folder-outline", "relativeUrl": "extensions/hello-parents", "order": 1 },
      { "id": "duplo.examples.helloworld-hello-children", "title": "All Children", "type": "item",
        "matIcon": "file-outline", "relativeUrl": "extensions/hello-children", "order": 2 }
    ]
  }
]
```

> Legacy: a single `frontend.menu = { parentGroupId, node }` still loads (merged into a group by id) but is
> **deprecated** — new extensions MUST use `menus[]`.

Add matching `frontend.routes[]`, including the nested form so a child detail keeps its parent in the URL. Every
`path` is namespaced under `extensions/` (the FE may nest for breadcrumbs; the **backend** child route stays flat —
see [00-naming](00-naming.md)):
```jsonc
"routes": [
  { "path": "extensions/hello-parents", "resourceType": "HelloParent", "subType": "hello-parent" },
  { "path": "extensions/hello-parents/:parentId/hello-children", "resourceType": "HelloChild", "subType": "hello-child" },
  { "path": "extensions/hello-parents/:parentId/hello-children/:childId", "resourceType": "HelloChild", "subType": "hello-child" }
]
```
`extension-route-registrar.ts` injects these under `suite/:tenantId` at runtime (no host rebuild). A child
resolver recovers `:parentId` by walking `ActivatedRoute.params`.

### Filing under an agent — the `agent` field
A **top-level** `menus[]` node may carry an optional `agent` string — the agent this extension is filed under.
Children never carry it. The portal groups every extension sharing an `agent` value under **one** left-nav heading,
titled with the agent name and marked with a shared agent icon; the extensions beneath keep their own icons.
`"DevOps"` merges into the platform's existing built-in **DevOps** group rather than creating a second one.

Ask the author to pick one (the starter list), or to type their own:

1. DevOps
2. Compliance
3. Observability
4. Release Management
5. Something else (type a name)

Write the chosen value **verbatim** as `agent` — no slugging. If the author declines, **omit the field**; never write
`agent: ""`. Title the node after the agent too (as below) and the portal folds its children straight into the agent's
heading; a node titled differently nests as its own sub-group under that heading.

```jsonc
// manifest.json → frontend.menus : filed under the DevOps agent
"menus": [
  { "id": "duplo.examples.helloworld-devops", "title": "DevOps", "type": "collapsible-section",
    "agent": "DevOps",
    "children": [
      { "id": "duplo.examples.helloworld-hello-world", "title": "Hello World", "type": "item",
        "matIcon": "star-outline", "relativeUrl": "extensions/helloworlds", "order": 40 }
    ]
  }
]
```

### Choosing `matIcon` — give the nav entry a real icon, not the template's placeholder
The portal renders every menu node as `<mat-icon svgIcon="{{ item.matIcon }}">`, resolved against two SVG sprites
it registers at startup (`app.component.ts` → `addSvgIconSet`):

- **`assets/images/icons/mdi.svg`** — a ~900-icon **SUBSET** of Material Design Icons, not the full 7k set.
- **`assets/images/icons/duplo.svg`** — the DuploCloud brand icons: `duplo-admin`, `duplo-ai`, `duplo-cicd`,
  `duplo-compliance`, `duplo-containers`, `duplo-cost`, `duplo-devops`, `duplo-docker`, `duplo-es`, `duplo-git`,
  `duplo-logo`, `duplo-region`, `duplo-s3`, `duplo-security`, `duplo-services`, `duplo-settings`, `duplo-tags`,
  `duplo-vnet`, `ai-service-desk`.

A name that is in neither sprite renders as an **empty box** — silently, with no build or console error. MDI names
are kebab-case (`shield-check`); **Material Symbols names with underscores (`waving_hand`, `account_tree`) and
plain words that only exist in Material Icons (`settings`, `calculate`) are NOT in the sprite** and render blank.

**Pick from what the extension IS.** Choose the closest match to the resource's purpose — a security scanner gets a
shield, a build runner gets a branch. Do not leave the `helloworld` template's placeholder `star-outline`, and do not
fall back to a generic `cog` when the requirement clearly names a domain. These are all verified present in the sprite:

| The extension is about… | `matIcon` |
|---|---|
| security, policy, guardrails, compliance | `shield-check` · `duplo-security` · `duplo-compliance` |
| secrets, credentials, keys, certs | `key-outline` · `shield-key-outline` · `lock-outline` |
| CI/CD, builds, pipelines, jobs | `source-branch` · `duplo-cicd` · `rocket` |
| git / source repos | `git` · `github` · `duplo-git` |
| networking, VPC, DNS, load balancers | `lan` · `network-outline` · `duplo-vnet` |
| servers, VMs, hosts, compute | `server` |
| Kubernetes, containers, images | `kubernetes` · `docker` · `duplo-containers` |
| cloud providers | `aws` · `microsoft-azure` · `google-cloud` · `cloud-outline` |
| storage, buckets, files | `duplo-s3` · `folder-outline` · `file-document-outline` |
| databases, data stores | `database` |
| cost, billing, budgets | `duplo-cost` · `cash` · `currency-usd` |
| metrics, reports, dashboards | `chart-line` · `view-dashboard` |
| logs, search, observability | `magnify` · `console` · `duplo-es` |
| alerts, notifications, incidents | `bell-outline` · `alert-outline` |
| users, teams, access | `account-group` |
| infrastructure-as-code, stacks | `terraform` · `layers` · `state-machine` |
| APIs, web services, endpoints | `web` |
| sync / reconcile / drift | `sync` |
| generic lists, inventories, catalogs | `format-list-bulleted` · `table-large` · `package-variant` |
| nothing above fits | `cog` · `puzzle` |

Both the top-level `collapsible-section` and each `item` leaf take a `matIcon` — give the section the broad
domain icon and each leaf the specific one (e.g. section `duplo-security`, leaves `shield-check` and `magnify`).

**Verify a name you are unsure about** against the sprite the target platform actually serves (the portal, not the
studio API — `UI_PORT` locally):
```bash
curl -fsS http://localhost:${UI_PORT:-4210}/assets/images/icons/mdi.svg | grep -c 'id="shield-check"'   # 1 = present, 0 = blank box
curl -fsS http://localhost:${UI_PORT:-4210}/assets/images/icons/duplo.svg | grep -o 'id="[a-z0-9-]*"'   # the brand set
```

### Pattern B — child inside the parent's detail view (tightly-coupled children)
Don't give the child its own menu entry. Instead, the parent's **view** component renders a tab of its children
with row links into the nested child route. Build the parent view on the Template-G detail shell
([19-detail-page](19-detail-page.md)) with a `Children` tab in the main card's Result strip, and render that tab
with a `<searchable-datatable [rows]="children" (filter)="filterUpdate()">` whose row click routes to
`extensions/hello-parents/:parentId/hello-children/:childId` (see
[02-authoring-guide](02-authoring-guide.md#frontend)). Wire the child tab's search box with
the same `filterUpdate()` + `FilterTableUtils.searchByFields` pattern as the List view (a bare `[rows]` makes the box
inert). This is how the platform surfaces a Namespace's ConfigMaps. Cleaner breadcrumb, child never appears
"loose" in the nav.

**When to use which:** independent/often-browsed children → **A** (nested menu). Children that only make sense in
the parent's context (a build under a job, a config under a namespace) → **B** (tab in parent view). You can do
both — a nested menu *and* a child table in the parent view.

## Frontend remote identity — REQUIRED for multi-extension installs
Every extension's Native Federation remote must declare a **globally unique `name`** — unique across every
extension installed on the same platform, not just within your repo. Two extensions both scaffolded from the
template keep the template's `name` and collide: the host's `extension-route-registrar` calls
`loadRemoteModule({ remoteEntry, exposedModule })`, and Native Federation reads the `name` out of the fetched
`remoteEntry.json` and registers the remote **by that name** — so distinct `remoteEntry` URLs do not save you.
The second remote aliases to the first, and clicking the second extension loads the FIRST extension's UI/list
("first-loaded wins"). Set it once, per extension:

```js
// frontend/federation.config.js — the ONE line to change per extension
const REMOTE_NAME = 'duploExtensionMyThing';           // must be globally unique
```
(The rest of the file — the `shared` subset and the `skip` list — is in
[02-authoring-guide](02-authoring-guide.md#native-federation-sharing--share-the-libs-di-peer-packages-avoids-nullinjectorerror).)

Keep the manifest's `frontend.remote.remoteName` equal to `REMOTE_NAME`. **`build-extension.sh` does not check
this** — the name/manifest mismatch is caught only by the standalone verifier, which you run yourself after
building:
```bash
node scripts/verify-remote-federation.js extensions/<name>
```
And even that only compares your remote against your own manifest — it cannot see an extension built in another
repo, so global uniqueness stays your responsibility, not the tooling's.

## Checklist
- [ ] Child spec extends `ParentRefSpec<TParent>`; child controller extends `ChildResourceController<>`, OVERRIDES
      `Create` (stamps `parentId`, creates via `Service.CreateAsync`, returns 201 — see top of this doc).
- [ ] Both controllers carry access-node declarations ([18-access-control](18-access-control.md)): parent
      `[AccessControl(Parent = typeof(Workspace), ParentIdProperty = "OwnerWorkspaceId")]`, child
      `[AccessControl(Parent = typeof(<Parent>), ParentIdProperty = "Spec.ParentId")]`. Declaring only the
      child fails the load — the parent entity must be declared as a node by some controller.
- [ ] Unique `REMOTE_NAME` → federation `name` == manifest `frontend.remote.remoteName` (multi-extension safety).
- [ ] Nested menu = TOP-LEVEL `collapsible-section` with `item` children (not a merged `collapsible`).
- [ ] Every menu node's `matIcon` is chosen from the extension's purpose and exists in the portal's sprite
      (see [Choosing `matIcon`](#choosing-maticon--give-the-nav-entry-a-real-icon-not-the-templates-placeholder)) — the
      template's `star-outline` is a placeholder, and a name absent from the sprite renders blank.
- [ ] Manifest has two `resources[]`; the child carries the `parent` block.
- [ ] Parent hook cascades delete to children.
- [ ] FE: a `frontend.menus[]` tree with `item` children (Pattern A) and/or a child table in the parent view
      (Pattern B); nested `routes[]` with `:parentId`.

See also: [03-base-classes](03-base-classes.md), [04-hooks](04-hooks.md),
[07-scope-credentials](07-scope-credentials.md) (if the child provisions against an external system).
