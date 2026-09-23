---
name: duplo-extension-dev
description: Build and load a DuploCloud platform extension (a typed extension — C# ResourcesController + service + entity, plus an Angular remote and a provisioning skill) and hot-load it into the platform. Works both inside an Extension resource's provisioning ticket and locally (you supply the platform URL + an admin token). Scaffolds from the hello-world example, compiles the backend with dotnet against the host SDK feed, packages, and registers — no host restart.
---

# duplo-extension-dev — write a DuploCloud platform extension

You build a **platform extension**: a brand-new, first-class DuploCloud **Resource type** with its own
C# `ResourcesController` + service + entity (own Mongo collection + REST route), an Angular
Native-Federation remote (list/add/view), and a provisioning skill. The studio **hot-loads** the
compiled DLL — per-extension DI container + live routes, no restart — so the result is indistinguishable
from a built-in resource (Network, Namespace, …).

> ⚠️ **Writing any frontend code? Load the [`use-ng22`](../use-ng22/SKILL.md) skill first.** It is the
> ruling on the Angular 22 shape every extension UI is written in — standalone components, signals, the
> **OnPush-by-default trap** that silently stops async data from rendering, `inject()`, `@if`/`@for`, and a
> `Routes` export instead of an NgModule. The `helloworld` template is already written to it.

> **The reference docs in [`reference/`](reference/) are the source of truth.** Each topic has one owner:
> [00-naming](reference/00-naming.md) — every customer-facing name, and what the build gate enforces ·
> [01-architecture](reference/01-architecture.md) — the resource model, provisioning modes, the loop, hot-load ·
> [02-authoring-guide](reference/02-authoring-guide.md) — the common path: classes, manifest, frontend, install, federation ·
> [03-base-classes](reference/03-base-classes.md) — every SDK base class and member ·
> [04-hooks](reference/04-hooks.md) — every hook/seam and when it fires ·
> [05-custom-actions](reference/05-custom-actions.md) — endpoints beyond CRUD and how the remote consumes them ·
> [06-registration](reference/06-registration.md) — in-platform vs local load, SDK pinning, reloading changed code ·
> [07-scope-credentials](reference/07-scope-credentials.md) — reading the selected scopes' credentials in a skill ·
> [08-parent-child-and-menus](reference/08-parent-child-and-menus.md) — multi-resource extensions and `frontend.menus[]` ·
> [09-result-templates](reference/09-result-templates.md) — the declarative renderer is not supported ·
> [10-sdk-api](reference/10-sdk-api.md) — cloud access from C# (`IScopeCredentials`, `IScopeClientFactory`) ·
> [11-deprovisioning](reference/11-deprovisioning.md) — delete/deprovision per mode ·
> [12-enrichment-and-live-state](reference/12-enrichment-and-live-state.md) — live infra state on GET, `[BsonIgnoreExtraElements]` ·
> [13-current-user](reference/13-current-user.md) — the logged-in user in FE, backend, and skill ·
> [14-forms-and-wizards](reference/14-forms-and-wizards.md) — form fields and the multi-step wizard ·
> [15-error-handling](reference/15-error-handling.md) — surfacing the real API error ·
> [16-ask-ai](reference/16-ask-ai.md) — **opt-in** Ask AI chat sessions on a resource (build ONLY when asked) ·
> [17-custom-result-views](reference/17-custom-result-views.md) — the hand-written Result content: Overview tiles, tabs, panels ·
> [18-access-control](reference/18-access-control.md) — the `[AccessControl]` declaration and named actions ·
> [19-detail-page](reference/19-detail-page.md) — the detail-page shell, the lifecycle rail, per-resource phases per mode ·
> [20-ui-library](reference/20-ui-library.md) — every `ng-common-lib` export, a "need X → use Y" picker, verified recipes, and what works in a remote.

> **Every dev-kit extension is TYPED — there is no archetype choice.** A typed extension ships a compiled
> .NET DLL (`manifest.archetype = "typed"`) with the resource's own controller/route/collection, an Angular
> Native-Federation remote, and a provisioning skill. Start from [`./templates/helloworld/`](templates/helloworld/)
> — keep its `backend/`. **Never ask the user to choose an archetype and never offer skill-based** —
> proceed typed unconditionally. (The dev ticket's message `"… provision extension"` and `spec.archetype`
> defaulting to `"typed"` are not archetype questions.)

## Phase 0 — detect the mode

- **In-platform** (run inside an Extension resource's provisioning ticket): `$DUPLO_TOKEN` **and**
  `$DUPLO_HOST` are already set (the platform never sets `DUPLO_BASE` — that is the local-mode variable;
  scripts read `${DUPLO_BASE:-$DUPLO_HOST}`, and a skill must NEVER overwrite `DUPLO_TOKEN`/`DUPLO_HOST`).
  The spec is at `shared/extension.json`; the scoped token authorizes ONLY this resource's
  `…/{id}/status|results|load-bundle` (it cannot GET arbitrary routes, and `{id}/load` stays admin-only).
  Load via the **resource-scoped** endpoint and report status back on the Extension resource.
- **Local** (a developer runs this skill in Claude): those env vars are absent. **Ask the developer for
  the platform base URL and an admin bearer token** (a user with the `Administrator` role); export them
  as `DUPLO_BASE` and `DUPLO_TOKEN`. Load via the **admin** endpoint. Gather the resource shape
  conversationally (no ticket spec file).

Everything between Phase 1 and Phase 5 is identical in both modes; only the load step (Phase 6) differs.
Full mechanics: [06-registration](reference/06-registration.md).

> **Getting the working copy.** The dev-kit repo is **PRIVATE**, so a **GitHub scope is required**; its token reaches
> `gh` (`.config/gh/hosts.yml` + `GH_CONFIG_DIR`), so clone with **`gh repo clone …`** (never an unauthenticated
> `git clone` of the dev-kit). 🔒 **Never read/print a credentials file** (`cat`/`echo`/`head`/`grep` of `hosts.yml`,
> `.aws/credentials`, …) — to verify GitHub auth use **`gh auth status`**, never `cat hosts.yml`.
> - **`spec.gitRepo` set (user's own repo):** `gh repo clone <orgName>/<name> repo` (with `-b <branch>`). If the repo
>   is **EMPTY**, overlay the dev-kit's content EXCEPT `.git` so the user repo keeps its own `.git`/ownership:
>   `gh repo clone duplocloud/devkit /tmp/devkit && rsync -a --exclude=.git /tmp/devkit/ repo/`.
>   If it **already has** dev-kit content, just work in it — but **enumerate first**: `ls extensions/*/manifest.json`.
>   Other developers' extensions may live beside yours; the requirement decides whether you MODIFY an existing
>   `extensions/<name>/` or scaffold a NEW `extensions/<name2>/` (ask when ambiguous), and before scaffolding new,
>   read a sibling to match its conventions. **Hot-load is on-demand**, **push is user-initiated only**
>   (chat or the result-page badge); prompt to **commit**/**resync** and report `result.gitStatus` after each git op.
> - **No `spec.gitRepo`:** `gh repo clone duplocloud/devkit` and work in it (throwaway, hot-load only).
> - **Local (human-cloned):** you already cloned the dev-kit. First time, run `./scripts/change_git_owner.sh <your-repo>`
>   to adopt it; if your repo already has dev-kit content, just work in it.
>
> In every case, author the extension in **`extensions/<extension_name>/`** at the repo root.

## Phase 1 — settle the resource shape (GATE: build nothing until this is unambiguous)

This is a hard gate. Do **not** run Phase 2 (or any scaffolding/build) until every item below is settled. A
loose one-line description (`"… provision extension"`, `"build me a thing for X"`) is **not** enough — derive what
you can, then **ask for the rest**. Guessing a shape and scaffolding it is a failure, not initiative.

**First, listen.** Get the user's requirement in plain English (in-platform: read `spec.description`). Do not fire
a checklist of questions before you have it. Then derive what you can and ask only for what's still ambiguous.

Settle before building (derive, else ask — **after** listening):
- **Name** — derive a suggested name from the requirement and **propose it back to the user to confirm or
  change** (never ask for a name before hearing the requirement). The agreed name gives **originType** (PascalCase
  → e.g. `HelloWorld`), **subType** (kebab, e.g. `hello-world`), and **restSegment** — which **MUST** be namespaced
  under `extensions/` → `extensions/<feature>-<resource>`. The frontend `routes[].path` and menu `relativeUrl` use
  the **same** value. Never a bare or `clouds/…` segment — [00-naming](reference/00-naming.md) is canonical and the
  build gate enforces it. In a repo that already holds extensions, the name must collide with **no sibling** —
  including the frontend's federation remote `name` and the Mongo `extension_<entity>` collection name.
- **Spec fields** — each with name, type, and required/optional. **Result fields** — same.
- **Provisioning MODE** — decide HOW this resource is provisioned. **Do not default to an agent skill.** Pick by
  what the work actually is (derive from the requirement; confirm if unsure):
  | Mode | Choose when the requirement is… | Wiring | Sample |
  |---|---|---|---|
  | **Worker** | a **deterministic** job: pure compute, or **reconcile/apply multiple objects** with retry/drift; words like *"worker", "background", "compute", "reconcile", "keep in sync"*. **No LLM needed.** | service `NoSkillsFallbackMode => ProvisioningMode.Worker`; **no** skill / `skillMappings`; a `ResourceWorkerBase` whose `ApplyAsync` does the work + `SaveProgressAsync`; register `AddHostedService` in `IDuploExtension.Configure` | `samples/worker-compute` (compute) · `samples/worker-appstack` (k8s) |
  | **Agent** | the work genuinely needs the **LLM / open-ended automation** (multi-step cloud orchestration, CFN, talking to a SaaS API by reasoning). | map a skill (`skills` + `skillMappings`); the skill reads `shared/<subtype>.json`, does the work, POSTs `results`+`status` | `samples/helloworld` · `samples/network-stack` (long-running terraform + C# enrich + on-demand actions) |
  | **Passthrough** | create **one** external object **synchronously**, no agent, no loop. | override `ProvisionDirectAsync`/`UpdateDirectAsync`/`DeprovisionDirectAsync` (default `NoSkillsFallbackMode` = Passthrough) | `samples/passthrough-configmap` |
  | **No-provision** | **observe-only** / on-demand; nothing to create on save. | `IsProvisioningNeeded => false` | (one override — [04-hooks](reference/04-hooks.md)) |
  > A resource that just transforms/computes its own inputs (e.g. "take two numbers, return sum and product") is a
  > **Worker**, NOT an agent skill — an agent skill is wasteful + non-deterministic for work the backend can do in
  > C#. Enrichment (live read-state) is **orthogonal** and composes with any mode ([12](reference/12-enrichment-and-live-state.md)).
- **Left-nav icon** — pick a `matIcon` for each `frontend.menus[]` node from what the extension actually *is*
  (a security scanner → `shield-check`, a build runner → `source-branch`, a cost report → `duplo-cost`), so it
  shows up with a sensible icon out of the box. **Never keep the `helloworld` template's placeholder `star-outline`** — and never
  invent a name: anything absent from the portal's sprite (e.g. Material Symbols names like `waving_hand`) renders
  as an empty box. Use the domain → icon
  table in [08-parent-child-and-menus](reference/08-parent-child-and-menus.md#choosing-maticon--give-the-nav-entry-a-real-icon-not-the-templates-placeholder).
- **Ask AI sessions (OPT-IN — never by default)** — build them ONLY when the requirement explicitly asks ("ask AI",
  "AI chat sessions", "on-demand tickets"); never offer or scaffold them unprompted. When requested, settle the
  prefilled context block and implement from [16-ask-ai](reference/16-ask-ai.md).
- **Pick the matching SAMPLE and copy its patterns.** The samples are worked references — reaching the right one is
  half the battle. They live at the **dev-kit repo root: `<repo-root>/samples/<name>/`** (NOT under `.claude/skills/`).
  Note the two `helloworld`s: **`templates/helloworld`** is the scaffold you copy to *start*; **`samples/helloworld`**
  is a worked reference. This index maps requirement → sample on both axes (provisioning mode above, UI shape here):

  | The requirement / UI shape is… | Copy patterns from | Don't confuse with |
  |---|---|---|
  | a **simple** create form — a few flat fields | `templates/helloworld` (scaffold) · `samples/helloworld` | — |
  | a **linear, step-by-step / wizard** flow (Step 1→2→3, Next/Back) | `samples/network-stack` (its 3-step add wizard + `wizard/wizard-stepper.component.ts`) | — |
  | **many fields / conditional sections / repeatable rows** | `samples/network-stack` (repeatable subnet rows in the Network step) | — |
  | one resource that **owns many** of another (parent → child) | `samples/parent-child` | flat independent multi-resource |
  | provision real infra **and** show live state on every GET | `samples/network-stack` (`EnrichResultAsync` + the Network tab) | — |
  | **long-running provisioning** (background terraform/process watched by the agent), on-demand **plan/apply** actions, execution **logs**, **tabbed results** | `samples/network-stack` | — |
  | create/update/delete **one** object synchronously (Passthrough) | `samples/passthrough-configmap` | — |
  | **reconcile/apply multiple** objects with retry (Worker, real infra) | `samples/worker-appstack` | worker-compute (compute-only) |
  | pure **compute**, no cloud/scope (Worker) | `samples/worker-compute` | worker-appstack (real infra) |
  | **observe-only** (No-provision) | `IsProvisioningNeeded => false` ([04-hooks](reference/04-hooks.md)); on-demand actions: `samples/network-stack` | — |

  **Forms tiebreaker:** linear steps, or lots of fields/toggles/repeatable rows → copy from **network-stack**'s wizard;
  a handful of flat fields → **helloworld**. The form axis and the mode axis are independent — pick one row from each.
- **Deprovision / cleanup — REQUIRED whenever provisioning creates real infra.** Settle what a delete must **tear
  down** and where that teardown lives, per mode ([11-deprovisioning](reference/11-deprovisioning.md)). If provisioning
  creates nothing durable (pure compute, name-combining, observe-only), say so. If it creates real infra (k8s objects,
  a cloud stack, a SaaS record, a bucket) you **must** ship the matching teardown *in the same step as the
  provisioning* — a create-only resource orphans infra on delete and is a bug, not a v2. Also decide
  retain-vs-hard-delete the row (`AutoDeleteOnDeProvision`) and any cascade guard (`ValidateCanDeprovisionAsync`).
- **Access control** — where the resource sits in the permission tree: top-level under the Workspace (the default the
  scaffold ships), under a parent entity (child resources), or grouped under the extension's own category node. Does
  any **custom endpoint** need an explicitly granted **named action** instead of plain CRUD (restart / console /
  credential-minting / apply-infrastructure)? — [18-access-control](reference/18-access-control.md).
- **Menu placement** — ask where it appears in the AI Suite left-nav (by **title**, never silently default to
  DevOps): a **new top-level group** (e.g. `Jenkins`, `GCP`), **nested under an existing section** (e.g. `DevOps`), or
  **no menu**. The user gives titles; **you** generate ids, `relativeUrl`s and the matching `frontend.routes[]` —
  [08-parent-child-and-menus](reference/08-parent-child-and-menus.md). Also settle **title** + **`matIcon`** per
  item — derive the icon from the extension's purpose, per the Left-nav icon bullet above.
- **One or many resources?** — **flat** (independent — e.g. `GCP` → network/cluster/database) or **parent → child**
  (`samples/parent-child`); several top-level menu groups are fine — [08](reference/08-parent-child-and-menus.md).

**Present the settled shape for approval** (local: the plan you `ExitPlanMode` with; in-platform: the `Processing`
summary you post) **as a structured shape, not a prose blurb:** a **Spec** field table (name · type ·
required/optional), a **Result** field table (name · type), the **provisioning mode** with a one-line reason, the
**detail view's shape** — the **lifecycle phases** this resource goes through (label + the status/result field that
drives each; [19-detail-page](reference/19-detail-page.md) → "Deriving phases") and the **Result tabs** (Overview at
minimum; name each further tab; [17-custom-result-views](reference/17-custom-result-views.md)) — and a short
**user-experience** walkthrough: left-nav placement, the add form, the list, the detail page, and what provisioning
does end-to-end. Do this per resource for multi-resource extensions.

**Where the answers come from / how to ask:**
- **In-platform:** read `spec.description`/`spec.icon` from `shared/extension.json`. If anything required is missing
  or ambiguous, POST status **`Blocked`** with a `blockedReason` that lists the specific questions (and post the
  same as a ticket chat message), then **stop** — do not scaffold. On the next invocation re-read
  `shared/extension.json` + the latest chat reply and proceed **only** once every required item is unambiguous.
  Once clear, POST `Processing` and continue (Phase 6 shows the curl).
  ```bash
  curl -fsS -X POST "$RES/status" -H "Authorization: Bearer $DUPLO_TOKEN" -H "Content-Type: application/json" \
    -d '{ "status": "Blocked", "blockedReason": "Need before I can build: (1) menu placement — section id / \"top-level\" / none? (2) spec fields + types. ..." }'
  ```
- **Local:** ask the developer conversationally and **wait** for answers. Do not scaffold until clear.

## Phase 2 — scaffold from the template

Only enter Phase 2 once Phase 1's gate has passed (every required item unambiguous).
**In-platform: POST status `Processing` / `subStatus: "Authoring code"` BEFORE the first file you create or
edit** — on the initial scaffold and again on every refinement turn that touches code (the Studio lifecycle
wizard keys its "Authoring code" stage off this beat). Set `manifest.frontend.menus[]` to the placement the
user chose — do **not** copy the template's example menu blindly.

In a **clone-and-own repo** (adopted via `scripts/change_git_owner.sh` or `scripts/init-project.sh`), each
extension lives in its own **`extensions/<name>/`** dir. Scaffold from the bundled template (skip if a starter was
already seeded — then adapt what's there):
```bash
[ -d "extensions/<name>" ] || cp -r "$(dirname "$0")/templates/helloworld" "extensions/<name>"
```
(In-platform inside a provisioning ticket, scaffold into the ticket workdir instead — same steps, different dir.)

Adapt inside `extensions/<name>/` — rename `HelloWorld`→`<Name>` consistently **across backend AND frontend**
(the build fails on leftover `HelloWorld`/`HelloService`/`hw-` identifiers). Per [02-authoring-guide](reference/02-authoring-guide.md):
- `backend/HelloWorld.cs` — your `Spec`/`Result` fields; entity `[BsonCollection("extension_<entity>")]` (the
  lowercased entity name — NOT derived from the restSegment; [00](reference/00-naming.md)),
  `GetTicketOriginType()`/`GetTicketOriginSubType()`. `[BsonIgnoreExtraElements]` on every concrete class
  ([12](reference/12-enrichment-and-live-state.md)). Override hooks only if needed ([04](reference/04-hooks.md)).
- `backend/HelloWorldController.cs` — `: ResourcesController<…>` at `[Route(".../environment/<restSegment>")]`
  (the FULL namespaced `extensions/<feature>-<resource>`) **plus the access-node declaration decided in Phase 1**
  ([18](reference/18-access-control.md)). Class name `<Name>sController` in file `<Name>Controller.cs` (platform
  convention; the manifest never references the controller type). Custom endpoints per [05](reference/05-custom-actions.md).
- `backend/Duplo.Extension.HelloWorld.csproj` — rename to `Duplo.Extension.<Name>.csproj` (keep the SDK
  PackageReference `ExcludeAssets="runtime"` + `nuget.config`).
- `frontend/src/app/*` — list/add/view for your fields. **Set the service's `REST_SEGMENT` to the FULL namespaced
  `extensions/<feature>-<resource>` (== manifest `restSegment`; a bare leaf 404s).** Rename every FE `Hello`/`hw`
  identifier (files, classes, selectors, routes, and a **unique** `federation.config.js` `name`) per the rename table
  in [02](reference/02-authoring-guide.md#frontend). List = `searchable-datatable` with the filter + workspace-refresh
  wiring; Add/Edit = `panel-form-accordion` + `form-field`; Detail = the **Template-G shell the scaffold already
  carries** — keep `shared/` as copied and **rewrite the two things that are the resource's own**: the `phases()`
  computed (your lifecycle ladder, per mode) and the Result strip's Overview tiles + any further tabs
  ([19](reference/19-detail-page.md), [17](reference/17-custom-result-views.md)). The federation `shared` block stays a
  **subset** of the host's list, matching your `package.json` ([02](reference/02-authoring-guide.md#native-federation-sharing--share-the-libs-di-peer-packages-avoids-nullinjectorerror)).
- `manifest.json` — `id`, `version`, `backend.{assemblyDir=<id>/<version>/backend, entryAssembly}`,
  the `resources[]` entry (`archetype:"typed"`, `registrar:"DevOpsResource"`, + the five FQ type names),
  `skills`/`skillMappings` (**Agent mode only** — omit for Worker/Passthrough/No-provision), `frontend`.

### Wire the chosen provisioning mode (the helloworld template is AGENT-shaped — convert it)
After picking the mode in Phase 1, make the backend match it — **a missing piece silently falls back to
Passthrough and create fails with "no skill mapping and does not implement ProvisionDirectAsync".** Do **all**
items for the chosen mode. Each mode has a **mandatory deprovision seam** — wire it in the same pass
([11-deprovisioning](reference/11-deprovisioning.md)); the ticket UI (header "Ask agent", the rail's "Track
status", the "Needs your input" phase) exists **only in Agent mode** ([19](reference/19-detail-page.md) → Ladders).
- **Worker** (scaffold the extra pieces from [`samples/worker-compute`](../../../samples/worker-compute)):
  1. service overrides `protected override ProvisioningMode NoSkillsFallbackMode => ProvisioningMode.Worker;`
  2. add `<Name>Worker : ResourceWorkerBase<<Name>,<Name>Spec,<Name>Result>` — `ApplyAsync` does the work + sets
     `entity.Result` + `await SaveProgressAsync(scope, entity, "...", ct)`; **deprovision seam:** `DeleteSubResourcesAsync`
     deletes every object `ApplyAsync` created in reverse order and `WaitForDeletionAsync` polls until gone (no-ops /
     `=> true` ONLY for pure compute — `samples/worker-compute`; real infra: `samples/worker-appstack`).
  3. add an `IDuploExtension` whose `Configure` calls `builder.Services.AddHostedService<<Name>Worker>();` — hot-load
     starts the worker directly; `Configure` is what the boot-time replay uses ([10](reference/10-sdk-api.md) Gotchas).
  4. **delete** the `skills/` dir and ship **no** `skills`/`skillMappings` in the manifest.
  5. **FE:** remove the ticket UI, drop the "Needs your input" phase, compute the Worker ladder from `workerState`
     (copy `samples/worker-compute`'s `phases()`), remove `track()`/`ticketName()` and the list-row "Track Provisioning"
     item, label the add button **"Create"** (not "Provision").
- **Agent**: keep `skills/provision-*/SKILL.md` (+ `provision.sh`, write to the OWN route) and the manifest
  `skills` + `skillMappings`; keep the ticket UI. **Deprovision seam (if it creates real infra):** the platform reuses the
  SAME ticket and sends the generic teardown message — there is **no separate deprovision skill mapping**, so the
  provision `SKILL.md` needs a **Deprovision** section + an idempotent `deprovision.sh`, or a second skill in the same
  `skillNames` ([11](reference/11-deprovisioning.md)). Once your skill POSTs `DeProvisioned`, the platform hard-deletes
  the row by default.
- **Passthrough**: override `ProvisionDirectAsync`/`UpdateDirectAsync`/**`DeprovisionDirectAsync`**; delete `skills/`;
  no `skillMappings`; FE as Worker step 5 with the Passthrough ladder. (`samples/passthrough-configmap`.)
- **No-provision**: `IsProvisioningNeeded => false`; delete `skills/`; no `skillMappings`; FE as Worker step 5.

## Phases 3–5 shortcut (clone-and-own repo)

If you're in a cloned dev-kit repo, **`./scripts/build-extension.sh extensions/<name>`** (or `./scripts/build-all.sh`
for every extension) does Phases 3–5 in one step (naming gate, fetch + pin the SDK, `dotnet publish`,
`npm ci && npm run build`, trim the bundle to your extension's own assemblies, assemble
`extensions/<name>/dist/extension.zip`). The manual steps below are the equivalent — use them in-platform or when
there's no script. After it succeeds, skip to Phase 6.

## Phase 3 — fetch the host SDK feed (pin the exact version)

```bash
# Capture then validate (don't pipe straight to jq — a redirect/error page yields a cryptic jq parse error).
# -L follows http→https redirects.
SDK_RESP=$(curl -fsSL -H "Authorization: Bearer $DUPLO_TOKEN" "${DUPLO_BASE:-$DUPLO_HOST}/v1/aiservicedesk/extensions/sdk-version")
SDK_VER=$(printf '%s' "$SDK_RESP" | jq -r '.version // empty')
[ -n "$SDK_VER" ] || { echo "Bad sdk-version response (is DUPLO_HOST the studio base URL, reachable, https?): $SDK_RESP" >&2; exit 1; }
curl -fsSL -H "Authorization: Bearer $DUPLO_TOKEN" "${DUPLO_BASE:-$DUPLO_HOST}/v1/aiservicedesk/extensions/sdk-bundle" -o /tmp/sdk.zip
unzip -o /tmp/sdk.zip -d extensions/<name>/backend/sdk-packages
```
Write `$SDK_VER` into `manifest.json` `sdkVersion` — the loader rejects a mismatch
([06-registration](reference/06-registration.md#sdk-version-pinning--why-exactness-matters)).

## Phase 4 — build backend + frontend

```bash
( cd extensions/<name>/backend && dotnet publish Duplo.Extension.<Name>.csproj -c Release -o ../dist/backend -p:DuploSdkVersion="$SDK_VER" )
( cd extensions/<name>/frontend && { [ -f package-lock.json ] && npm ci || npm install; } && npm run build )
```
**Keep the scaffold's `package-lock.json`** and use `npm ci` whenever it exists (plain strict `npm install` only as
the no-lock fallback). Never loosen an install with npm's legacy peer-dependency flag — peer conflicts are pinned
with the `overrides` block in `package.json`. The lib installs from the vendored tarball, so no registry config or
token is needed ([02](reference/02-authoring-guide.md#install-vendored-tarball--no-registry-no-token)).
`dotnet publish` copies the SDK's whole transitive closure into `dist/backend`; only your own DLL(s) belong in the
bundle (Phase 5 strips the rest — shipping it trips HTTP 413). `frontend/dist` has `remoteEntry.json` plus its
sibling ESM chunks — ship the whole directory. Run each command in its own subshell `( cd … && … )` so a failed
`cd` can't strand later commands in the wrong directory.

## Phase 5 — assemble the bundle

Zip ROOT = `manifest.json` + `backend/` (your DLL only) + `fe/` (FE dist) + `skills/`:
```bash
PKG=extensions/<name>/dist/pkg; rm -rf "$PKG"; mkdir -p "$PKG/backend" "$PKG/fe" "$PKG/skills"
cp    extensions/<name>/manifest.json   "$PKG/manifest.json"
# Ship ONLY your extension's own assemblies — NOT dist/backend/* (the full SDK closure the host already
# provides) and NOT runtimes/ (host-provided natives). Copying everything trips HTTP 413 on upload.
cp    extensions/<name>/dist/backend/Duplo.Extension.*.dll "$PKG/backend/"   # + any extra third-party DLL your csproj adds beyond the SDK
cp -r extensions/<name>/frontend/dist/* "$PKG/fe/"
cp -r extensions/<name>/skills/*        "$PKG/skills/"
rm -f extensions/<name>/dist/extension.zip   # zip updates in place — drop the stale archive so the bundle actually shrinks
( cd "$PKG" && zip -r ../extension.zip . )
```

## Phase 6 — load (mode-specific) + write back

**In-platform** (resource-scoped token; the Extension resource itself lives under `environment/extension-studio/…`,
NOT `environment/extensions/…` — that namespace is for the resources extensions contribute:
`RES=${DUPLO_HOST}/v1/aiservicedesk/user/data/workspaces/<ownerWorkspaceId>/environment/extension-studio/<id>`):
```bash
curl -fsS -X POST "$RES/load-bundle" -H "Authorization: Bearer $DUPLO_TOKEN" \
  -H "Content-Type: application/zip" --data-binary @extensions/<name>/dist/extension.zip
curl -fsS -X POST "$RES/status" -H "Authorization: Bearer $DUPLO_TOKEN" -H "Content-Type: application/json" \
  -d '{ "status": "Complete", "subStatus": "Extension loaded" }'
```
**Local** (admin token) — in a clone-and-own repo just use the script (reads the target from `.env`/env):
```bash
./scripts/deploy-extension.sh extensions/<name>/dist/extension.zip
```
Equivalent raw call:
```bash
curl -fsS -X POST "${DUPLO_BASE}/v1/aiservicedesk/admin/extensions/load-bundle" \
  -H "Authorization: Bearer $DUPLO_TOKEN" -H "Content-Type: application/zip" \
  --data-binary @extensions/<name>/dist/extension.zip
```
On failure, capture the endpoint's error body (e.g. SDK-version mismatch, missing entry assembly); in
in-platform mode POST status `Failed` with a `faults` array. **Bump `manifest.version` before re-loading changed
backend code** ([06](reference/06-registration.md#reloading-changed-code--bump-manifestversion)).

## Phase 7 — verify

- **In-platform:** the `load-bundle` response already confirms success — it returns the loaded record
  with `result.addedResource` (originType, restSegment, remoteEntry) + `skillNames`. Treat a 200 there
  as the verification, then POST status `Complete`. **Do NOT** try to `GET …/environment/<restSegment>`
  with the resource-scoped `$DUPLO_TOKEN` — that token is not authorized for arbitrary routes and will
  return 403/404 even though the extension loaded fine.
- **Local (admin token):** you may confirm the live route directly: `GET …/environment/<restSegment>` → 200,
  and `GET …/admin/extensions` lists it. Create one → it persists to its `extension_<entity>` collection, fires a
  provisioning ticket (Agent mode), your skill runs and fills the Result. (Teardown: `DELETE …/admin/extensions/{id}`
  → route withdraws live.)

