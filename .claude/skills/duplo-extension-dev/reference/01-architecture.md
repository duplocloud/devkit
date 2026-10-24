# Resource Provisioning Architecture

This is the model every DuploCloud "resource" follows — first-party resources (Network, Namespace, RDS)
and extension resources alike. An **extension** is just this same stack, compiled to a DLL and **hot-loaded**
at runtime instead of baked into the host build.

## What a "resource" is

A resource is a typed entity with a **spec** (desired inputs) and a **result** (realized outputs), moved
through a lifecycle by a **provisioner**. The platform gives you, for free:

- **Workspace (tenant) multitenancy** — every resource has `OwnerWorkspaceId`; routes are workspace-scoped.
  An **admin-scoped** resource (`AdminResourcesController`) instead lives on an admin-only route with no workspace,
  and its `OwnerWorkspaceId` is always the system Admin Workspace — same pipeline otherwise
  ([21-admin-resources.md](21-admin-resources.md)).
- **Persistence** — its own Mongo collection (`[BsonCollection]`), optimistic concurrency (`Version`).
- **A REST surface** — full CRUD + `status`/`results`/`deprovision` (inherited).
- **A status state machine** + **fault reconciliation** (a background worker raises faults for stuck rows).
- **Provisioning orchestration** — a ticket carrying your mapped skill, a scoped token, and the spec.

You contribute five small classes (spec, result, entity, hooks, service) + a controller. See
[02-authoring-guide.md](02-authoring-guide.md) and [03-base-classes.md](03-base-classes.md).

## Status state machine (`ResourceStatus`)

```
New ──▶ TicketCreated ──▶ Processing ──▶ Complete
  │                          │             │
  │                          ├──▶ Failed   │ (spec edit) ──▶ Updated ──▶ …
  │                          └──▶ Blocked / WaitingForApproval
  └────────────────────────────────────────┘
Complete ──▶ DeprovisionInitiated ──▶ DeProvisioning ──▶ DeProvisioned ( ──▶ row deleted )
                                                  └──▶ DeprovisionFailed
```
`EverCompleted` latches true once `Complete` is reached. The agent advances status via `POST {id}/status`.

## Provisioning modes (`ProvisioningMode`)

Chosen at create time (immutable for the row) based on whether a skill is mapped:

| Mode | When | Who does the work |
|---|---|---|
| **HelpdeskAgent** | a skill is mapped to `originType/subType` | the **agent** runs the skill in a ticket; writes back via `status`/`results` |
| **Passthrough** | no skill, default fallback | the **service** runs `ProvisionDirectAsync` inline (synchronous) |
| **Worker** | no skill, `NoSkillsFallbackMode = Worker` | a **background worker** reconciles + retries with backoff |

The mode is chosen from what the work *is* — deterministic reconcile → Worker, one synchronous object →
Passthrough, work that needs the LLM → HelpdeskAgent (the decision table is in `SKILL.md` Phase 1). The
hello-world example is agent-based: a skill (`provision-helloworld`) reads the spec and writes the result.

## The provisioning loop (HelpdeskAgent)

1. User creates the resource (`POST …/environment/<restSegment>`). `Status=New`.
2. `ResourceServiceBase.OnAfterCreateAsync` → `IResourceProvisioningManager.InitiateResourceProvisioningAsync`:
   - resolves the skill(s) from `originType/subType`,
   - writes the expanded spec to the ticket at `shared/<subtype>.json`,
   - mints a **resource-scoped JWT** (48 h) good for `…/{id}/status`, `…/{id}/results` and the agent-callback
     path (and for Extension resources, additionally `…/{id}/load-bundle` — `{id}/load` stays admin-only) — on the workspace route, or on the admin route
     (`…/admin/data/environment/*/{id}/…`) for a resource owned by the Admin Workspace,
   - streams an initial message carrying only `duplo_base_url` + `duplo_token`; the backend then stamps
     `platform_context` (scopes, skills, secrets, user email) onto **every** message — it is wire-only,
     never a file.
3. The agent runs the skill: reads `shared/<subtype>.json`, does the work (optionally using the selected
   scope's cloud credentials in `platform_context.scopes`), posts `Processing` with progress `subStatus`,
   then `POST {id}/results` and `POST {id}/status Complete`.
4. `FaultDetectionWorker` reconciles any stuck/failed rows.

(Full registration mechanics + the local-developer path: [06-registration.md](06-registration.md).)

## How an extension becomes a first-class resource (hot-load)

A typed extension ships a compiled DLL containing your `ResourceBase`/`ResourceServiceBase`/`ResourcesController`
subclasses. On `load-bundle` the host:

1. Unpacks the bundle to `ExtensionStudioPath/<id>/<version>/{backend,fe,skills}` and reads `manifest.json`.
2. Loads `backend/<entryAssembly>.dll` into a **collectible `AssemblyLoadContext`** (per extension). SDK
   types resolve from the host (Default ALC), so your `ResourceBase<>` **is** the host's `ResourceBase<>`.
3. Builds a **per-extension DI child container**: registers `IRepository<TEntity>` (+ hooks), your service,
   and the `IEntityService<>`/`IResourceService<>`/`IResourceService` aliases — exactly like a first-party
   `AddDevOpsResource<>`. Inner scopes chain child→root so your service can resolve host services/repos.
4. Rebuilds the access-control registries over your controllers ([18-access-control](18-access-control.md)),
   adds the assembly as an MVC `ApplicationPart` and signals a route refresh → your controller's routes go
   **live with no restart**.
5. Starts any `IHostedService` the assembly ships (a Worker-mode `ResourceWorkerBase`), seeds your skills +
   skill-mappings and persists a `LoadedExtension` record (replayed on restart).

The result is indistinguishable from a built-in resource: its own route, its own collection, the standard
lifecycle, fault reconciliation, and a menu entry.

## Skill-based vs typed (archetypes)

- **Typed** (recommended, what this skill builds): ships a backend DLL → a genuine first-class resource at
  its own route. `manifest.archetype = "typed"`.
- **Skill-based** (no DLL): the host's generic `extension-resources` controller stores a JSON spec/result bag,
  discriminated by `subType`. Lighter, but not a real typed API. `archetype = "skill-based"`.

**This dev-kit only supports typed.** Skill-based is described here as platform background only — it is not
templated or buildable from this kit. Always build typed; never ask the user to choose an archetype.

## Two distinct entities (don't confuse them)
- **The Extension resource** — what a user creates in *Extension Studio*; its provisioning *produces* an extension.
- **The resource your extension adds** (e.g. `HelloWorld`) — the new resource type users then create.

## Two ticket kinds on a resource (don't confuse these either)
A resource can carry **two ticket kinds**: the **provisioning ticket** (≤1, platform-created, Agent mode only,
skill auto-attached) and **Ask AI sessions** (0..N, user-created chat tickets, subType `<sub-type>-askai` +
`originContext.metadata.purpose: "ask-ai"`, possible in every mode — but **opt-in**: built only when the user
explicitly asks, and rendered as the LAST tab of the Results tab strip). See [16-ask-ai](16-ask-ai.md); for
how the detail page and its Result content are built see [19-detail-page](19-detail-page.md) and
[17-custom-result-views](17-custom-result-views.md).

Next: [02-authoring-guide.md](02-authoring-guide.md).
