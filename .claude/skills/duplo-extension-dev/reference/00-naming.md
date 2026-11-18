# 00 — Canonical naming & API surface (READ FIRST — non-negotiable)

This is the **single source of truth** for how an extension names its API, routes, menu, and storage. Every other
doc, template, and sample defers to this file. The platform runs all extensions in **one shared runtime** (routes,
Mongo, ticket origin types) and does **not** auto-namespace you — collisions are silent and break your pages.

## The one rule: every customer-facing name is namespaced under `extensions/`

| Surface | MUST be | Example | Never |
|---|---|---|---|
| `resources[].restSegment` (+ controller `[Route]`) | `extensions/<feature>-<resource>` — **carve-out: a CHILD resource's `restSegment` is the BARE leaf** (`<feature>-children`), because the namespacing comes from the parent's nested route (see 08) | `extensions/terraform-deployments` | bare `terraform-deployments` on a TOP-LEVEL resource; a built-in segment |
| Backend route (full) | `…/environment/extensions/<feature>-<resource>` | `…/environment/extensions/terraform-deployments` | `…/environment/<bare>` |
| `frontend.routes[].path` | `extensions/<feature>-<resource>` | `extensions/terraform-deployments` | `clouds/…` (built-in — silently shadows you) |
| `frontend.menus[]…children[].relativeUrl` | `extensions/<feature>-<resource>` — MUST equal a `routes[].path` | `extensions/terraform-deployments` | `clouds/…` |
| FE service **data-call URL** (the `REST_SEGMENT` const the service builds `…/environment/${REST_SEGMENT}` from) | `extensions/<feature>-<resource>` — **MUST equal `restSegment`** | `…/environment/extensions/terraform-deployments` | a bare leaf `terraform-deployments` → **404** |
| Mongo `[BsonCollection("…")]` | `extension_<entity>` (lowercase) | `extension_tfdeployment` | a built-in collection name |
| `ticketOriginType` | descriptive PascalCase, distinct from built-ins | `TerraformDeployment` | terse/collision-prone `TfState` |
| Entity class name (= its **access-node type** once the controller declares one — [18-access-control](18-access-control.md)) | feature-prefixed PascalCase, unique across the host and every loaded extension | `TerraformDeployment` | a name a built-in or another extension already uses (`Cluster`, `Network`) — **the load is rejected** |
| Menu shape | `frontend.menus[]` (array) | — | legacy singular `frontend.menu` (deprecated) |
| `frontend.remote.remoteEntry` | `/v1/aiservicedesk/extensions/<id>/fe/remoteEntry.json` | — | a Webpack `.js` entry — the host loads Native Federation `.json` entries only |

**Why `extensions/` for the frontend route:** the host registers built-in `clouds/*` routes **first**, so a duplicate
`clouds/*` path resolves to the built-in module — your page renders blank or shows the wrong data. `extensions/*` is
reserved for customer extensions and mounts at `/ai/suite/{tenant}/extensions/…`.

## Parent / child (`ChildResourceController` — nested)
- **Parent** is a normal top-level resource: `restSegment` = `extensions/<feature>-parents`.
- **Child** is **nested under the parent**. Its backend controller declares the nested route
  `…/environment/extensions/<feature>-parents/{parentId}/<feature>-children`, and the base
  `ChildResourceController` takes `parentId` **from the route** (stamps `Spec.ParentId`, auto-filters the list by
  `spec.parentId`). Do **not** flatten the child route or read `parentId` from the body.
- In the manifest the child's own `restSegment` is the **leaf** (e.g. `<feature>-children`, **not**
  `extensions/…`); the namespace comes from `parent.routeSegment`, which **MUST** equal the parent's `restSegment`
  (`extensions/<feature>-parents`). `parent.idRouteParam` is the route param name (e.g. `parentId`).
- **FE routes** nest to match (`extensions/<feature>-parents/:parentId/<feature>-children`) — still under
  `extensions/`. Skill callbacks for the child use the full nested path
  `…/environment/extensions/<feature>-parents/{parentId}/<feature>-children/{id}/…`.

## Skill callbacks
Any `…/environment/<segment>/{id}/results|status` URL a skill posts to MUST use the extension's namespaced
`restSegment` — keep skill scripts/phase-docs in sync with the manifest + controller `[Route]`, or status/result
callbacks hit the wrong controller.

## Enforcement
`scripts/build-extension.sh` runs a naming gate before it builds anything (fails fast, no network needed) and
**fails the build** on almost every rule above:
- `resources[].restSegment` and `resources[].parent.routeSegment` start with `extensions/`;
- `frontend.routes[].path` and every `frontend.menus` `relativeUrl` start with `extensions/` (never `clouds/`);
- the legacy singular `frontend.menu` key is absent — that row's "Never" condition;
- every backend `[BsonCollection("…")]` is `extension_`-prefixed;
- every controller `[Route]` containing `environment/` sits under `environment/extensions/` (the platform's
  reserved `environment/extension-studio` is the only other accepted prefix);
- the FE service's `REST_SEGMENT` is the full `extensions/<…>` path **and**, for a single top-level resource,
  equals the manifest `resources[].restSegment` — so the FE data-call URL can't drift from the backend route;
- a renamed extension ships no leftover `HelloWorld`/`HelloService`/`hw-` identifiers.

Two rows in the table are **not** enforced by it. `ticketOriginType` is checked nowhere — a name that collides
with a built-in is caught only at review. `frontend.remote.remoteEntry` is `verify-remote-federation.js`'s job,
a standalone step you run yourself after `npm run build` (it is not wired into `build-extension.sh`).
Skill-callback URLs are **warned** about but not failed: the gate prints a `!` line for any
`…/environment/<segment>` under `skills/` that isn't namespaced, then continues.

## Legacy opt-out
An extension that **takes over an existing built-in feature** keeps that feature's customer-facing URLs, REST
routes and Mongo collections, because live customer data, bookmarks and permission rules already point at them.
It declares that in `manifest.json`:

```json
"naming": { "legacy": true, "reason": "Live customer data and routes predate extension naming" }
```

- It skips only the namespacing rules: the `extensions/` path checks, `extension_` collections, controller and
  skill-callback routes, and the `REST_SEGMENT` checks. The legacy `frontend.menu` key and leftover template
  identifiers still fail the build.
- `reason` is required; an empty one fails the build. The gate prints it on every build
  (`naming.legacy: <reason>`), so the exception stays visible in every log.
- It is not for new extensions. A new extension has no existing names to keep, and its non-namespaced names
  collide with built-ins at runtime exactly as described above.
