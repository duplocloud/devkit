# Authoring Guide — the common path

How to build a platform extension in practice. This is the 20% you need; the full reference is in
[03-base-classes.md](03-base-classes.md) and [04-hooks.md](04-hooks.md).

## The five classes + one controller

For a top-level resource you write (rename `HelloWorld` to your resource):

| File | Class | Base | You implement |
|---|---|---|---|
| `backend/HelloWorld.cs` | `HelloWorldSpec` | `BaseSpec` | your input fields |
| | `HelloWorldResult` | `BaseResult` | your output fields |
| | `HelloWorld` | `ResourceBase<Spec,Result>` | `[BsonCollection("extension_…")]`, `GetTicketOriginType()`, `GetTicketOriginSubType()` |
| | `HelloWorldHooks` | `DefaultEntityHooks<>` (or `ResourceHooksBase<>`) | nothing, or `GetImmutableSpecFields`/`GetDeletableStatuses` |
| | `HelloWorldService` | `ResourceServiceBase<Entity,Spec,Result>` | usually nothing (ctor only) |
| `backend/HelloWorldController.cs` | `HelloWorldsController` | `ResourcesController<Entity,Spec,Result>` | the `[Route]` + the access-node declaration `[AccessControl(Parent = typeof(Workspace), ParentIdProperty = "OwnerWorkspaceId")]` ([18-access-control](18-access-control.md)) |

Every concrete Spec/Result/entity carries `[BsonIgnoreExtraElements]` ([12](12-enrichment-and-live-state.md)).
The skeleton is in [03-base-classes.md](03-base-classes.md#minimal-typed-resource-what-an-extension-ships)
and shipped as the hello-world template. That alone is a complete first-class resource — CRUD,
`status`/`results`, deprovision, and the provisioning lifecycle, with no boilerplate.

## How it provisions

The provisioning mode — Agent, Worker, Passthrough, No-provision — is chosen from what the work *is*, never
defaulted; the decision table is in `SKILL.md` Phase 1 and the mode mechanics in
[01-architecture](01-architecture.md). Agent mode maps a skill in `skillMappings` and overrides nothing in the
service; Passthrough overrides `ProvisionDirectAsync`/`UpdateDirectAsync`/`DeprovisionDirectAsync`; Worker returns
`Worker` from `NoSkillsFallbackMode` and ships a `ResourceWorkerBase`.

## Which hooks you'll actually override

Most extensions override none. When you do, the usual ones:

- `ValidateSpecAsync` — validate your spec fields.
- `ValidateAsync` — entity/name rules (call `base` first).
- `EnrichResultAsync` — show live cloud state on view ([12](12-enrichment-and-live-state.md)).
- `OnAfterStatusUpdateAsync` / `OnAfterResultUpdateAsync` — react to lifecycle transitions.
- `GetImmutableSpecFields` / `GetDeletableStatuses` (in `ResourceHooksBase`) — freeze fields / gate delete.

Decision table: [04-hooks.md](04-hooks.md#which-to-override--quick-guide).

## Resource-group-scoped (env-child) resources

First-party resources that live **under a Resource Group** (like a Kubernetes `Namespace`) use the DevOps
variants: entity `: ResourceGroupRef<Spec,Result>`, spec `: ResourceGroupSpecRef` (adds
`EnvironmentId`+`ResourceGroupId`), service `: ResourceGroupChildServiceBase<,,>`, controller
`: ResourceGroupControllerRef<,,>`.

> **Those DevOps types are not part of the extension SDK feed, and neither is the `ResourceGroup` entity** — an
> RG-scoped extension resource can be neither compiled against the published SDK nor declared as an RG-parented
> access node ([18-access-control](18-access-control.md)). Model the resource as workspace-scoped with an
> RG/environment id in its spec.

## The manifest (`manifest.json`)

Ties the bundle together. For a typed extension (see the hello-world manifest):

```jsonc
{
  "manifestVersion": "1.0",
  "id": "duplo.examples.helloworld", "name": "Hello World", "version": "0.1.0",
  "sdkVersion": "<from GET …/extensions/sdk-version>",
  "backend": { "assemblyDir": "duplo.examples.helloworld/0.1.0/backend",
               "entryAssembly": "Duplo.Extension.HelloWorld.dll" },
  "resources": [{
    "ticketOriginType": "HelloWorld", "restSegment": "extensions/helloworlds", "subType": "hello-world",
    "archetype": "typed", "registrar": "DevOpsResource",
    "entityType": "Duplo.Extension.HelloWorld.HelloWorld",
    "specType":   "Duplo.Extension.HelloWorld.HelloWorldSpec",
    "resultType": "Duplo.Extension.HelloWorld.HelloWorldResult",
    "hooksType":  "Duplo.Extension.HelloWorld.HelloWorldHooks",
    "serviceType":"Duplo.Extension.HelloWorld.HelloWorldService"
  }],
  "skills": [{ "folder": "duplo.examples.helloworld/0.1.0/skills/provision-helloworld", "isBuiltIn": true }],
  "skillMappings": [{ "originType": "HelloWorld", "subType": "hello-world",
                      "skillNames": ["provision-helloworld"], "timeout": { "provision": 300, "deprovision": 120 } }],
  "frontend": { "remote": { … }, "menus": [ … ], "routes": [ … ] }
}
```
Critical: `archetype` must be `"typed"` so the loader takes the DLL path; the five `*Type` names must be the
fully-qualified type names in your DLL; `backend.assemblyDir` is `<id>/<version>/backend`. **Bump `version` on
every backend code change** ([06](06-registration.md#reloading-changed-code--bump-manifestversion)).

### Naming

Every customer-facing name is namespaced so it cannot collide with the platform or another extension —
`extensions/<feature>-<resource>` for the REST segment, FE route and menu URL; `extension_<entity>` for the Mongo
collection; a descriptive PascalCase `ticketOriginType`. **[00-naming](00-naming.md) is canonical and the build gate
enforces it.** Two conventions it doesn't cover: the C# namespace is `Duplo.Extension.<Name>` (what the scaffold and
every sample use), and any `…/environment/<segment>/{id}/results|status` URL a skill script posts to MUST use the
extension's own `restSegment` — keep the skill in sync with the manifest and the controller `[Route]`.

### `frontend.menus[]`

`menus` is an **array of menu trees** matched into the left-nav **by title**: a root title that doesn't exist yet
becomes a new top-level group; a root that matches an existing section (`DevOps`) nests into it; omit `menus` for
no nav entry. The author supplies titles; you fill each node's `id`, `relativeUrl` and the matching
`frontend.routes[]`. Full rules, shapes and the legacy `frontend.menu` deprecation:
[08-parent-child-and-menus](08-parent-child-and-menus.md#frontend-how-the-child-shows-up).

## Build, package, load

The `duplo-extension-dev` skill (`../SKILL.md`) does this — both inside an Extension provisioning ticket and on
your local machine:

1. `GET …/extensions/sdk-version` → pin; `GET …/extensions/sdk-bundle` → unzip to `backend/sdk-packages`.
2. `dotnet publish backend -c Release -o dist/backend -p:DuploSdkVersion=<ver>` (SDK is compile-only).
3. `(cd frontend && npm ci && npm run build)` → `frontend/dist/remoteEntry.json` + its ESM chunks.
   The host parses ONLY a **Native Federation `remoteEntry.json`** — a Webpack `remoteEntry.js` will not load.
4. Zip `{manifest.json, backend/, fe/, skills/}`.
5. **Load:** in-platform → `POST …/environment/extension-studio/{id}/load-bundle` (scoped token); local →
   `POST …/admin/extensions/load-bundle` (admin token).

Then the new resource's route is live: `GET …/environment/<restSegment>` → 200, and it appears in the menu.

## Frontend

Ship an Angular **Native Federation** remote (list/add/view) and **use the platform UI library
`@duplocloud-internal/ng-common-lib`** so your pages match the rest of the suite — don't hand-roll tables or
forms. Reach host services via the string DI tokens `REMOTE_DuploHttpClient` and `REMOTE_UserSession`
(`workspaceId = session.tenant.TenantId`), call your own route `…/environment/<restSegment>`, and expose a
`Routes` array as `./Extension` (the host's registrar hands it straight to `loadChildren`).

**Component shape** — the full ruling, with the per-API catalogue, is the [`use-ng22`](../../use-ng22/SKILL.md)
skill; load it before writing frontend code. In short: standalone components that declare their own
`imports`, with **no `changeDetection` property** and all async state in `signal()`. Angular 22 defaults a
component with no strategy to `OnPush`, so a plain field assigned from a `subscribe` never repaints — the build
stays green and the list just sits empty. A signal write marks the view dirty, which is what makes the default
correct instead of a trap. Use `inject()`, `input()`/`computed()`/`viewChild()`, and the `@if`/`@for`/`@switch`
block syntax. Importing an NgModule (`SearchableDatatableModule`, `SharedFormsModule`, `CommonLibComponentsModule`)
from a standalone component's `imports` is fine and is how the lib is consumed.

**Toolchain** — match the host portal; a major skew degrades singleton sharing (with `strictVersion: false`
Native Federation still resolves one copy, but logs a version warning). Angular `^22.1.0`, TypeScript `6.0.3`,
npm `>= 10.9.0`, Node on Angular 22's supported line (`^22.22.3 || ^24.15.0 || >=26.0.0`). The remote is built by
`@angular-architects/native-federation` from `frontend/federation.config.js`; there is **no standalone dev
server** — no `serve` target, no `index.html`, no `bootstrap.ts`. The loop is **build → deploy → hot-load**
(`scripts/build-extension.sh` + `scripts/deploy-extension.sh`), and you see your pages inside the real portal.
In `angular.json`, set `outputPath` to `{ "base": "dist", "browser": "" }` — Angular 22 otherwise emits into
`dist/browser/`, which breaks the bundle layout (`build-extension.sh` copies `frontend/dist/.` straight into
`fe/`) and is rejected by `verify-remote-federation.js`.

> ⚠️ **The FE `REST_SEGMENT` MUST be the FULL namespaced segment — `extensions/<feature>-<resource>` — and equal
> the manifest `resources[].restSegment` and the controller `[Route]`.** It is NOT a bare leaf. The service builds
> `…/environment/${REST_SEGMENT}`, so a bare leaf 404s every list/get/create call. `build-extension.sh` fails the
> build if they don't match. (`origin-context`/`ticketName` use a different `/tickets/…` path — unaffected.)
> ```ts
> const REST_SEGMENT = 'extensions/widgets';   // == manifest restSegment == controller [Route]
> private base() { return `/v1/aiservicedesk/user/data/workspaces/${this.workspaceId()}/environment/${REST_SEGMENT}`; }
> ```

> **Rename the FE off the template, exactly as you rename the backend.** When you change the resource name you MUST
> also rename every frontend `Hello`/`hw` identifier (the build fails otherwise):
> | Template | Rename to |
> |---|---|
> | `hello.service.ts` | `<resource>.service.ts` |
> | class `HelloService` | `<Name>Service` |
> | interface `HelloWorld` | `<Name>` |
> | `add-/list-/view-hello.component.ts` + classes `Add/List/ViewHelloComponent` | `…<resource>.component.ts` + `Add/List/View<Name>Component` |
> | selectors `hw-add`/`hw-list`/`hw-view`/`hw-root` | `<slug>-add`/`<slug>-list`/`<slug>-view`/`<slug>-root` |
> | `federation.config.js` `name` (== manifest `frontend.remote.remoteName`) | unique `duploExtension<Name>` |
> Update the routes in `extension.routes.ts`, and each component's own `imports`, to the renamed classes.

Use these library pieces (import from `@duplocloud-internal/ng-common-lib`). The full catalog — every export,
and which ones don't work in a remote — is [20-ui-library](20-ui-library.md):
- **List** → `SearchableDatatableModule` (`<searchable-datatable [rows]="rows" (add)="…" (filter)="filterUpdate()">`
  with projected `<ngx-datatable-column>` cells, an actions `ngbDropdown`, and a status badge). Two things the list
  component **MUST** do — a plain `[rows]` + `(add)` binding that loads once in `ngOnInit` is the #1 pair of bugs:
  - **Wire the filter.** `<searchable-datatable>` owns the search box and emits `(filter)` on each keystroke, but it
    does **not** filter — it renders whatever `[rows]` you hand it. Keep a full `allRows` backing signal and derive
    the shown `rows` with `computed()`. Never bind `[rows]` to the raw fetch result with no `(filter)` handler:
    ```ts
    private readonly table = viewChild(SearchableDatatableComponent);
    private readonly allRows = signal<MyRes[]>([]);
    private readonly filterTerm = signal('');
    private readonly searchFields = ['name', 'status', 'spec.firstName'];   // string fields / dot-paths only (lodash get)
    protected readonly rows = computed(() => {
      const term = this.filterTerm();          // searchByFields never lowercases the needle — pass a PRE-lowercased term
      return term ? this.allRows().filter(r => FilterTableUtils.searchByFields(r, this.searchFields, term)) : this.allRows();
    });
    protected filterUpdate(): void { this.filterTerm.set(this.table()?.searchTerm?.toLowerCase()?.trim() ?? ''); }
    ```
  - **Re-fetch on workspace switch.** Do NOT load only in `ngOnInit` — that never re-runs when the user switches
    workspace, so the list shows the old workspace's rows until a full page reload. Subscribe to the host session's
    `getTenantRefreshTimer(true)` (it emits `[tenant, tenantChanged]` on first load, on every workspace switch, and on
    the poll tick — no reload needed) and re-call your `list()` each time, with `takeUntilDestroyed(this.destroyRef)`:
    ```ts
    private readonly session = inject<any>(REMOTE_UserSession as any);
    private readonly destroyRef = inject(DestroyRef);
    ngOnInit(): void {
      this.session.getTenantRefreshTimer(true).pipe(takeUntilDestroyed(this.destroyRef))
        .subscribe(([, changed]: [any, boolean]) => this.refresh(!!changed));
    }
    private refresh(changed: boolean): void {
      if (changed) { this.table()?.startLoading(); }
      this.svc.list().pipe(takeUntilDestroyed(this.destroyRef)).subscribe({
        next: rows => { this.allRows.set(rows ?? []); this.table()?.refresh(); },
        error: () => { this.allRows.set([]); this.table()?.stopLoading(); },
      });
    }
    ```
  `FilterTableUtils` and `SearchableDatatableComponent` import from `@duplocloud-internal/ng-common-lib`;
  `REMOTE_UserSession` is the same host token the FE service already injects. Worked reference: the scaffold's
  `list-hello.component.ts`.
- **Add / Edit** → the **`panel-form-accordion`** 3-column layout (title+description | inputs | per-field help).
  ⚠️ The column widths are a host **SCSS mixin** that each host component `@include`s — they are **NOT** global
  CSS, and the published lib ships compiled CSS only. So the remote must carry the column rules in its own
  component `styles` (Bootstrap utilities like `d-flex`/`justify-content-between` ARE global, but
  `.panel-content-title`/`.panel-content-form`/`.panel-content-sidenav` are not):
  ```scss
  .panel-content-title { width: 265px; min-width: 265px; }
  .panel-content-form  { max-width: 768px; flex: 1 1 auto; margin: 0 1rem; padding: 0 1rem; }
  .panel-content-sidenav { width: 265px; min-width: 265px; margin-left: 2rem; }
  ```
  Markup (all three columns — omitting the sidenav makes the title balloon):
  ```html
  <div class="card panel-form-accordion"><div class="d-flex justify-content-between">
    <div class="panel-content-title"><h4 class="font-weight-bolder">Create X</h4>
      <p class="panel-content-title-sub-text">…</p></div>
    <div class="panel-content-form">
      <form #f="ngForm" class="form form-vertical" (ngSubmit)="f.valid && submit()">
        <div class="form-container" form-group-errors #formGroupErrors showDetailsWhen="submitted">
          <form-field><label class="element-label">Name *</label>
            <input class="form-control" name="name" [ngModel]="name()" (ngModelChange)="name.set($event)" required validation-state validation-errors></form-field>
          …
        </div></form>
    </div>
    <div class="panel-content-sidenav">   <!-- 3rd column: per-field help -->
      <div class="help-item"><p class="help-item-title">Name</p><small class="text-muted">…</small></div>
    </div>
  </div></div>
  ```
  `form-field` + `validation-state`/`validation-errors`/`form-group-errors` are from `SharedFormsModule`.
  **Template-driven only** (`ngForm` + `ngModel`) — no Reactive Forms. Multi-step forms and the polish checklist:
  [14-forms-and-wizards](14-forms-and-wizards.md). Surfacing the real create error: [15-error-handling](15-error-handling.md).
- **Detail view** → the detail-page shell the scaffold already carries: a card-less header with the
  `Spec | Result` switcher, the main card (Spec tiles, or the Result tab strip) and the lifecycle rail whose phase
  timeline you derive from **your** resource's status + result. The anatomy, the rules, the per-mode ladders and
  the per-mode ticket UI (Agent only) are all in [19-detail-page](19-detail-page.md); what goes inside the Result
  strip — Overview tiles, a tab per concern, panels, polling — is [17-custom-result-views](17-custom-result-views.md).
  Keep the shared `shared/` files as copied; rewrite `phases()` and the Result content.

> **Host-only components — do NOT use in a remote:** `app-sub-status-display` injects a host-only
> `SUCCESS_REPORTER` token that can't resolve in a remote. The status pill `status-with-style` is **NOT exported**
> by the lib's `CommonLibComponentsModule` — using `<status-with-style>` renders a blank unknown element; ship the
> scaffold's `app-status-badge`. `scrollable-nav-tab`, `ngbNav`, `ngbDropdown`, `searchable-datatable` and the
> form components are importable from the lib.

### Install (vendored tarball — no registry, no token)
`@duplocloud-internal/ng-common-lib` is not published to a registry you can reach. Every frontend in this
repo installs it from a **committed tarball** via a `file:` specifier, and npm reads a `file:` dependency
straight off disk without contacting a registry — so **no `.npmrc` and no auth token are needed**;
a plain `npm install` just works from a fresh clone. Two schemes coexist:

- **The samples** share one copy at repo-root `packages/`, since they never leave this repo:
  ```json
  "@duplocloud-internal/ng-common-lib": "file:../../../packages/duplocloud-internal-ng-common-lib-0.2.0.tgz",
  ```
- **The skill template** (`templates/helloworld/frontend/`) keeps its **own** copy under `vendor/`, because it
  gets copied out to `extensions/<name>/` or a provisioning workdir and must stay self-contained:
  ```json
  "@duplocloud-internal/ng-common-lib": "file:vendor/duplocloud-internal-ng-common-lib-0.2.0.tgz",
  ```

Scaffolding from the template carries the tarball and the specifier with it — keep both when you copy.
Maintainers bump the version across every frontend with `scripts/refresh-common-lib.sh <new-tgz>` (see
[docs/UPGRADING-ng-common-lib.md](../../../../docs/UPGRADING-ng-common-lib.md)).

Add the lib's UI peers to `dependencies` alongside it — **every package you list in `shared` must be a declared
dependency here**, because that is where `requiredVersion: 'auto'` looks it up (see the next section):
`@ngx-translate/core`, `@ng-bootstrap/ng-bootstrap`, `@ng-select/ng-select`, `@swimlane/ngx-datatable`,
`ngx-toastr`, `ngx-markdown`, `ngx-monaco-editor-v2`, `@angular/cdk`, `@angular/material`,
`@ngbracket/ngx-layout` (`^22.0.1`), `ngx-echarts` (`^22.0.0`), `angularx-flatpickr` (`^8.1.0`) — plus `bootstrap`.
Pin them to the **same majors the host portal ships** (`@ng-bootstrap/ng-bootstrap` ^21,
`@swimlane/ngx-datatable` ^25 — check `duplo-ui/portal/package.json`): they are shared singletons, and
`verify-remote-federation.js` reports a major mismatch against the host. `bootstrap` (^4.6.2) is the exception —
CSS-only, not in the host's shared list, and not federated at all. A dependency with no Angular 22 release
(`ngx-toastr`) is pinned with the `overrides` block in `package.json`, never by loosening the whole install.

### Native Federation sharing — share the lib's DI peer packages (avoids `NullInjectorError`)
Do **not** share `@duplocloud-internal/ng-common-lib` itself (the host bundles its own copy under a different
specifier, so it's bundled into your remote). **But you MUST share the lib's DI-providing peer packages as
singletons**, or the lib's components fail at runtime with `NullInjectorError: No provider for …` — because a
peer service provided by the host's `forRoot()` (e.g. `@ngx-translate/core`'s `TranslateService`) has a
different class identity than your remote's bundled copy. Sharing makes the remote use the host's instances.
The remote declares its shared set in `frontend/federation.config.js`. That set must be a **subset** of the
host's `duplo-ui/portal/federation.shared.js`, using the same options per entry — a **subset, not a mirror**,
for two reasons:
- **Share only packages your own `frontend/package.json` declares.** `requiredVersion: 'auto'` makes `share()`
  call `lookupVersion()`, which **throws at config load** for any package it can't find in your `package.json`.
  The host shares utilities an extension has no dependency on (e.g. `yaml`) — copy those across and the build
  dies before it starts.
- **Never share a package the host does not publish.** `verify-remote-federation.js` enforces remote ⊆ host, so
  a subset passes and a remote-only package is reported as a failure.

Give every entry its **own object literal**. Do NOT hoist a shared `const S = {…}` and reuse it: `share()`
shallow-copies the map and then **mutates each value in place** (stamping `requiredVersion`/`version`, deleting
`includeSecondaries`). With one reused object the first key stamps its version onto it, every later key then
sees `requiredVersion !== 'auto'` and skips its own lookup — so the remote ships Angular's version for
`ngx-toastr`, `@ng-bootstrap/ng-bootstrap` and the rest. `strictVersion: false` stops that being a hard failure,
which is exactly why it goes unnoticed.
```js
// frontend/federation.config.js
const { withNativeFederation, share, NG_SKIP_LIST } =
  require('@angular-architects/native-federation/config');

const REMOTE_NAME = 'duploExtensionMyThing';   // ← unique per extension (see 08-parent-child-and-menus)

module.exports = withNativeFederation({
  name: REMOTE_NAME,
  exposes: { './Extension': './src/app/extension.routes.ts' },
  shared: {
    ...share({
      // Angular + RxJS framework — must be a single instance across host + remotes.
      '@angular/core':              { singleton: true, strictVersion: false, requiredVersion: 'auto' },
      '@angular/common':            { singleton: true, strictVersion: false, requiredVersion: 'auto' },
      '@angular/forms':             { singleton: true, strictVersion: false, requiredVersion: 'auto' },
      '@angular/router':            { singleton: true, strictVersion: false, requiredVersion: 'auto' },
      '@angular/platform-browser':  { singleton: true, strictVersion: false, requiredVersion: 'auto' },
      '@angular/cdk':               { singleton: true, strictVersion: false, requiredVersion: 'auto' },
      '@angular/material':          { singleton: true, strictVersion: false, requiredVersion: 'auto' },
      'rxjs':                       { singleton: true, strictVersion: false, requiredVersion: 'auto' },
      // UI library peers that provide DI services / module-scoped providers.
      '@ng-bootstrap/ng-bootstrap': { singleton: true, strictVersion: false, requiredVersion: 'auto' },
      '@ngx-translate/core':        { singleton: true, strictVersion: false, requiredVersion: 'auto' },
      'ngx-toastr':                 { singleton: true, strictVersion: false, requiredVersion: 'auto' },
      '@ng-select/ng-select':       { singleton: true, strictVersion: false, requiredVersion: 'auto' },
      '@swimlane/ngx-datatable':    { singleton: true, strictVersion: false, requiredVersion: 'auto' },
      'ngx-markdown':               { singleton: true, strictVersion: false, requiredVersion: 'auto' },
      'ngx-monaco-editor-v2':       { singleton: true, strictVersion: false, requiredVersion: 'auto' },
      // ng-common-lib peers carrying DI services / forRoot config. CoreCommonModule imports plain
      // FlexLayoutModule, whose SERVER_TOKEN only .withConfig() provides — the host does that, so a
      // privately bundled copy here fails with NG0201 FlexLayoutServerLoaded.
      '@ngbracket/ngx-layout':      { singleton: true, strictVersion: false, requiredVersion: 'auto' },
      'ngx-echarts':                { singleton: true, strictVersion: false, requiredVersion: 'auto' },
      'angularx-flatpickr':         { singleton: true, strictVersion: false, requiredVersion: 'auto' },
    }),
  },
  // `skip` REPLACES the built-in list, so NG_SKIP_LIST must be spread in explicitly — dropping it would
  // un-skip es-module-shims, zone.js and @softarc/native-federation*. The regex excludes @angular/cdk's
  // Node-only "./schematics" entry point, which cannot survive browser bundling. @ngbracket/ngx-layout/server
  // is the same class of entry — NF's secondary-entry-point expansion picks it up and it imports
  // @angular/platform-server, which a browser-only app does not install.
  skip: [...NG_SKIP_LIST, /\/schematics(\/|$)/, '@ngbracket/ngx-layout/server'],
});
```
`@ngbracket/ngx-layout`, `ngx-echarts`, and `angularx-flatpickr` are required here even though your extension's
own code never imports them — ng-common-lib's components reach their DI tokens transitively, and omitting any
of the three throws `NG0201` at runtime on every common-lib page.

Share parent packages only — Native Federation resolves secondary entry points (`@angular/common/http`,
`rxjs/operators`) through the parent. `@angular/animations` is not shared because the host does not ship it.

After building, check the remote against the host yourself — nothing in `build-extension.sh` runs it for you:
```bash
node scripts/verify-remote-federation.js extensions/<name> [path/to/host/remoteEntry.json]
```
It checks that `dist/remoteEntry.json` exists and is flat (no `dist/browser/`), that its `name` equals the
manifest's `remoteName`, that the exposed module is present, and — when given the host entry — that every shared
package the remote declares is published by the host at the same major.

Bootstrap 4 + the Vuexy theme are served globally by the host, so the remote ships no CSS. Build with a strict
`npm ci` / `npm install` — never npm's legacy peer-dependency flag.

### Viewing the result

The Result view is design work done from the settled Result fields — there is no generic renderer
([09](09-result-templates.md)). Per resource: the **phases** the lifecycle rail shows
([19-detail-page](19-detail-page.md) → "Deriving phases"), the **Overview tiles** (every result fact gets a tile;
planned values from the spec until the result lands), and the **tabs** beyond Overview (one standalone panel per
distinct concern, lazy-loaded, fed by your controller endpoints) — [17-custom-result-views](17-custom-result-views.md);
worked example `samples/network-stack`. Action buttons: [05-custom-actions](05-custom-actions.md).

### Canvas renderers — render your own agent artifacts
When your skill writes a canvas document (an artifact under `./canvas-documents/`), the platform opens it in the
chat canvas panel. To render it with **your own component** instead of the plain file view, register a canvas
renderer from a component of yours that is alive while the ticket is open — **no host change required**. (The
platform's ticket-page shell `ResourceTicketModule` is not exported by the lib, so a remote cannot wrap the ticket
page itself; register from your detail view or a panel instead.)

1. **Register a renderer** in `ngOnInit`. Inject the registry via the **`REMOTE_CanvasRendererRegistry`
   token** (the host owns the one instance; your remote bundles its own copy of the lib, so inject the token, not
   the class). Unregister on destroy so it only applies while your view is mounted:
   ```ts
   import { CanvasRendererRegistry, REMOTE_CanvasRendererRegistry } from '@duplocloud-internal/ng-common-lib';
   private readonly registry = inject<CanvasRendererRegistry>(REMOTE_CanvasRendererRegistry as any);
   ngOnInit() {
     this.registry.register({
       id: 'myext:my-doc',                 // unique; re-register replaces
       title: 'My Preview',
       priority: 10,                       // >0 wins over platform built-ins
       match: a => !!a.id?.endsWith('my-doc.yaml'),
       component: MyPreviewComponent,      // your standalone component
     });
     inject(DestroyRef).onDestroy(() => this.registry.unregister('myext:my-doc'));
   }
   ```

2. **Author the renderer component.** It receives the doc id + a content stream via the injected `CANVAS_DOC`
   token (not an `input()` — the host mounts it through `ngComponentOutlet`):
   ```ts
   import { CANVAS_DOC, CanvasDoc } from '@duplocloud-internal/ng-common-lib';
   private readonly doc = inject<CanvasDoc>(CANVAS_DOC as any);
   ngOnInit() { this.doc.content$.subscribe(text => /* parse + render */); }
   ```

**Namespace your canvas filename** (`<feature>-<doc>.yaml`) so it can't collide with another extension; `priority`
is the explicit override knob if you intentionally replace a built-in renderer.

Next: [05-custom-actions.md](05-custom-actions.md) · [19-detail-page.md](19-detail-page.md) ·
[17-custom-result-views.md](17-custom-result-views.md) · [06-registration.md](06-registration.md).
