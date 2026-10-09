# SDK Reference — Base Classes

Every type a platform extension subclasses, with its real members and when they run. Names/signatures
are taken from the SDK source (paths cited per section). Namespaces:

- `Duplo.Ai.Model.Resource` — `Entity`, `ResourceBase<,>`, `BaseSpec`, `BaseResult`, `ParentRefSpec<>`, `TicketContext`, `ResourceStatus`, `ProvisioningMode`, `WorkerState`
- `Duplo.Ai.Model.Attributes` — `[BsonCollection]`
- `Duplo.Ai.Model.Interfaces` — `IEntityHooks<>`, `DefaultEntityHooks<>`, `IEntityService<>`
- `Duplo.Ai.DataManagement.Interfaces` — `IRepository<>`
- `Duplo.Ai.DataManagement.Services` — `GenericService<>`, `ResourceServiceBase<,,>`
- `Duplo.Ai.DataManagement.Controllers.User.Resource` — `ResourcesController<,,>`, `ChildResourceController<,,,>`
- `Duplo.Ai.DataManagement.Controllers.Admin.Resource` — `AdminResourcesController<,,>` (SDK ≥ 1.0.7)

> A typed extension compiles against these from the SDK NuGet feed (`ExcludeAssets=runtime`); at load the
> host's Default ALC supplies the real assemblies, so your subclasses share type identity with the host.
> See [06-registration.md](06-registration.md).

---

## 1. Entity model (`Duplo.Ai.Model/Duplo.Ai.Model/DataContracts/`)

### `Entity` (`Entity.cs`) — base of everything persisted
| Member | Purpose |
|---|---|
| `string Id` `[BsonId]` | Unique id (Mongo ObjectId string). |
| `string Name` `[BsonRequired]` | Entity name. Uniqueness is enforced per scope by the service. |
| `string? Description` | Free-form description. |
| `DateTime CreatedAt / UpdatedAt` | Stamped by the repository. |
| `bool IsActive` | Soft-delete flag. |
| `long Version` | Optimistic-concurrency token; incremented per write. |
| `Dictionary<string,string>? MetaData` | Arbitrary key/values. |
| `string GetMetaDataValue(string key)` | Reads a MetaData value (""/empty if absent). |
| `virtual IReadOnlyList<GroupingAttribute> GetGroupingAttributes()` | Natural grouping (workspace/RG/…); used by workers/aggregators. |
| `virtual void CleanupBeforeSave()` | Override to sanitize before every create/update. Called by `DefaultEntityHooks.OnPre{Create,Update}`. |

### `ResourceBase<TSpec,TResult>` (`Resource/ResourceBase.cs:164`) — base of every provisionable resource
`public abstract class ResourceBase<TSpec,TResult> : Entity, IResource where TSpec : BaseSpec where TResult : BaseResult`

| Member | Purpose |
|---|---|
| `string? OwnerWorkspaceId` | Owning workspace (tenant). Immutable after create (enforced by `ResourceHooksBase`). |
| `List<string> AllowedWorkspaceIds` | Cross-workspace read sharing. |
| `ResourceStatus Status` | Lifecycle state (see enum below). |
| `bool EverCompleted` | One-way latch: true once `Complete` is reached. |
| `string? BlockedReason` | Set when `Status == Blocked`. |
| `string? DeprovisionMessage` | Why a deprovision failed. |
| `string? SubStatus` | Free-form live progress text (the agent sets this). |
| `TicketContext? TicketContext` | Link to the provisioning ticket (id + last-triggered + detailed status). |
| `bool ProvisionedByHelpdesk` | True when provisioned synchronously by the backend (no agent ticket). |
| `Guid SpecVersion` | Fresh GUID on every spec-changing write (drift/worker signal). |
| `WorkerState? WorkerState` | Worker-mode retry/backoff state (null otherwise). |
| `ProvisioningMode? ProvisionedMode` | The mode chosen at create; immutable for the row's life. |
| `TSpec? Spec` / `TResult? Result` | Your strongly-typed inputs/outputs. |
| `abstract string GetTicketOriginType()` | **You implement.** Origin type (e.g. `"HelloWorld"`); drives skill-mapping + ticket origin. |
| `abstract string GetTicketOriginSubType()` | **You implement.** Sub-type (e.g. `"hello-world"`). |
| `override GetGroupingAttributes()` | Appends `("Workspace", OwnerWorkspaceId)`. |

> Tag your entity with `[BsonCollection("extension_<plural>")]` to give it its own Mongo collection.

### `BaseSpec` (`Resource/ResourceBase.cs:407`) — base of every spec
| Member | Purpose |
|---|---|
| `List<string>? ScopeIds` | Cloud scopes whose credentials the agent/provisioner gets (`platform_context.scopes`). |
| `ResourceMode Mode` (`Create`\|`Import`, default `Create`) | Create vs import-existing. Import resources skip teardown on delete. |
| `Provisioner? Provisioner` | Provisioner config (defaults to CLI). |
| `SpecTicketContext? TicketContext` | Carries `SkillIds` for manual ticket creation. |
| `BsonDocument? AdditionalCustomSpec` | Escape hatch for extra config. |

Add your own input fields as plain properties (e.g. `public string? FirstName { get; set; }`).

### `BaseResult` (`Resource/ResourceBase.cs:381`) — base of every result
| Member | Purpose |
|---|---|
| `List<string>? Warnings` / `List<string>? Faults` | Surfaced in the UI / fault pipeline. |
| `BsonDocument? ExtraConfigs` | Implementation-only metadata (e.g. CFN stack id); not rendered. |

Add your own output fields as plain properties (e.g. `public string? FullName { get; set; }`).

> **Annotate every concrete entity/`Spec`/`Result` with `[BsonIgnoreExtraElements]`** (on the concrete class —
> inheriting it from `BaseSpec`/`BaseResult` is not enough). Why, and the write-side drop it guards against:
> [12-enrichment-and-live-state](12-enrichment-and-live-state.md#always-annotate--bsonignoreextraelements).

### `ParentRefSpec<TParent>` (`Resource/ParentRefSpec.cs`) — spec for a child resource
`public abstract class ParentRefSpec<TParent> : BaseSpec where TParent : Entity` — adds `string? ParentId`
(stamped from the nested route, immutable). Use with `ChildResourceController<>`.

### Enums & helper types
- **`ResourceStatus`** (`ResourceBase.cs:661`): `New, Updated, TicketCreated, Processing, Complete, Failed, Blocked, WaitingForApproval, DeProvisioning, DeProvisioned, DeprovisionInitiated, DeprovisionFailed`.
- **`ProvisioningMode`** (`ProvisioningMode.cs`): `Passthrough, Worker, HelpdeskAgent`.
- **`ResourceMode`**: `Create, Import`.
- **`TicketContext`** (`ResourceBase.cs:487`): `string? TicketId`, `DateTime? LastTriggeredTime`, `string? DetailedStatus`.
- **`ResourceStatusUpdate`** (`ResourceBase.cs:550`): the `POST {id}/status` body — `Status`, `SubStatus`, `BlockedReason`, `Warnings`, `Faults`.
- **`WorkerState`** (`WorkerState.cs`): `RetryCount`, `LastAttemptAt`, `NextAttemptAt`, `LastVerifiedAt`, `LastFailedCode`.

> **DevOps / ResourceGroup-scoped variants** (in `Duplo.Ai.Model.DevOps`, used by first-party env-child
> resources like `Namespace`): `ResourceGroupRef<TSpec,TResult>` (entity base), `ResourceGroupSpecRef`
> (spec base — adds `EnvironmentId` + `ResourceGroupId`). Origin types come from the
> `DevOpsTicketOriginTypes` string constants, not an enum. Extensions typically subclass `ResourceBase`
> directly; use the RG variants only for resources that live under a Resource Group.

---

## 2. Services (`Duplo.Ai.DataManagement/Duplo.Ai.DataManagement/Services/`)

### `GenericService<T>` (`GenericService.cs`) — generic CRUD + lifecycle hooks
`public abstract class GenericService<T> : IEntityService<T> where T : Entity`. Ctor:
`GenericService(IRepository<T> repository, ILogger logger)`.

**Read:** `GetByIdAsync`, `GetByIdOrThrowAsync`, `GetAllAsync`, `GetActiveAsync`, `GetPagedAsync`,
`FindAsync`, `CountAsync`, `ExistsAsync`, `GetMetadataAsync`.
**Write:** `CreateAsync`, `CreateManyAsync`, `UpdateAsync`, `DeleteAsync` → `Task<bool>`,
`SoftDeleteAsync` → `Task<bool>`, `PatchAsync`, `PatchManyAsync`, `CreateOrUpdateMetadataAsync`,
`DeleteMetadataAsync`. (All `virtual`.)
**Hooks (`protected virtual`, override these):** `ValidateAsync(T, bool isUpdate, ct, T? existingEntity)`,
`ValidateNameImmutability`, `OnBeforeCreateAsync`/`OnAfterCreateAsync`,
`OnBeforeUpdateAsync(existing, updated, ct)`/`OnAfterUpdateAsync(existing, updated, ct)`,
`OnBeforeDeleteAsync`/`OnAfterDeleteAsync`, `OnBeforeSoftDeleteAsync`/`OnAfterSoftDeleteAsync`,
`OnBeforePatchAsync`/`OnAfterPatchAsync`, and `bool LowercaseEntityName` (default `true`).
See [04-hooks.md](04-hooks.md) for firing order.

### `ResourceServiceBase<TResource,TSpec,TResult>` (`ResourceServiceBase.cs`) — the one you subclass
`: GenericService<TResource>, IResourceService<...>` with
`where TResource : ResourceBase<TSpec,TResult> where TSpec : BaseSpec where TResult : BaseResult, new()`.
Ctor (match it exactly):
```csharp
protected ResourceServiceBase(
    IRepository<TResource> repository,
    ILogger<MyService> logger,
    IServiceScopeFactory scopeFactory,
    IHttpContextAccessor httpContextAccessor)
```
It overrides `CreateAsync`/`UpdateAsync`/`GetByIdAsync` to run the full resource lifecycle (validation →
locks → provisioning-mode dispatch → ticket creation). You normally override only the seams below; the
base does the heavy lifting (most extensions override nothing and get agent-based provisioning for free).

**Validation & external I/O (`protected virtual`):**
| Member | When it runs / purpose |
|---|---|
| `ValidateSpecAsync(TSpec spec, bool isUpdate, TSpec? existingSpec, ct)` | Validate your spec fields (CIDR, region, …). |
| `ValidateAsync(TResource, bool isUpdate, ct, TResource? existing)` | Entity-level rules (name format, etc.); call `base` first. |
| `ValidateNameFormat(string?)` / `ValidateName(TResource, ct)` | Name format + uniqueness (workspace-scoped by default). |
| `ResolveAndValidateExternalAsync(entity, isUpdate, existing, ct)` | **Pre-lock** seam for cloud SDK / HTTP / DNS calls; may stamp fields on the entity. |
| `PrepareEntityForPersistenceAsync(entity, ct)` | Last chance before DB write (mask/sanitize secrets). |

**Provisioning (`protected virtual`):**
| Member | Purpose |
|---|---|
| `ProvisioningMode NoSkillsFallbackMode` (default `Passthrough`) | Mode when no skill is mapped. Return `Worker` for background reconcile. |
| `ProvisionDirectAsync(entity, ct)` | Passthrough create: do the work inline; set `Status=Complete` + populate `Result`. |
| `UpdateDirectAsync(entity, ct)` | Passthrough update. |
| `DeprovisionDirectAsync(entity, ct)` | Passthrough teardown; patch to `DeProvisioned`. |
| `string? GetProvisioningMessage(entity)` | The initial chat message the agent receives. |
| `bool IsProvisioningNeeded(entity)` (default `true`) | Skip provisioning for some instances. |
| `ResolveParentSkillIdsAsync(entity, ct)` | Inject skill ids for manual tickets. |

**Status/result + reactions (`public`/`protected virtual`):**
| Member | Purpose |
|---|---|
| `UpdateStatusAsync(ws, id, ResourceStatusUpdate, ct)` | Backs `POST {id}/status`. Auto-deletes if `DeProvisioned` and `AutoDeleteOnDeProvision` is true. |
| `UpdateResultAsync(ws, id, JsonObject, ct)` | Backs `POST {id}/results`. |
| `OnAfterStatusUpdateAsync(entity, ct)` | React to status transitions (e.g. unload on `DeProvisioned`). |
| `OnAfterResultUpdateAsync(entity, ct)` | React to results (e.g. create dependent resources). |
| `EnrichResultAsync(entity, ct)` | Runs on `GetByIdAsync` — inject **live, non-persisted** data (cloud detail). |
| `GetExpandedSpecForAgentAsync(resource, ct)` | The spec JSON written to `shared/<subtype>.json` for the agent; override to enrich. |
| `bool AutoDeleteOnDeProvision(entity)` | Hard-delete the row on `DeProvisioned`? Default `true` for Agent + Passthrough, `false` for Worker (the worker deletes its own row) — [11](11-deprovisioning.md). |

**Deprovision / reconcile / faults (`public virtual`):** `ValidateCanDeprovisionAsync`, `DeprovisionAsync`,
`ForceReconcileAsync` (Worker), `CreateTicketAsync`, `ReconcileAndRaiseFaults(IFaultStore, ct)`.
**Helper:** `FireInBackground(entity, Func<sp, entity, baseUrl, token, Task>)` — fire-and-forget outside the request scope.

---

## 3. Controllers (`Duplo.Ai.DataManagement/.../Controllers/`)

Subclass and add the `[Route]` plus the access-node declaration ([18](18-access-control.md)). Endpoints are
inherited — you write **no** CRUD code.

### `ResourcesController<T,TSpec,TResult>` (`User/Resource/ResourcesController.cs`)
`[Route("v1/aiservicedesk/user/data/workspaces/{workspaceId}/environment/[controller]")]`
Ctor: `(IEntityService<T> service, ILogger<MyController> logger)`. Endpoints:

| Verb · Route | Purpose |
|---|---|
| `GET ` | List (paged/filtered, workspace-scoped). |
| `GET {id}` | Get one. |
| `POST ` | Create (stamps `OwnerWorkspaceId` from route). |
| `PUT {id}` / `PATCH {id}` | Update / partial update. |
| `POST {id}/results` | Write `Result` (used by the provisioning agent). |
| `POST {id}/status` | Write `Status`/`SubStatus`/faults (used by the agent). |
| `DELETE {id}` | Hard delete (gated by `ResourceHooksBase` deletable statuses). |
| `GET {id}/can-deprovision` | Pre-check. |
| `POST {id}/deprovision` | Start deprovision (mode-dependent). |
| `POST {id}/reconcile` | Worker-mode force reconcile. |
| `POST {id}/ticket` · `GET {id}/ticket-status` | Manual ticket create / status (the backend path for on-demand tickets — see [16-ask-ai](16-ask-ai.md) §9). |
| `GET view-template` | Platform endpoint for legacy declarative view-templates — **unused by dev-kit views** (see [09-result-templates.md](09-result-templates.md)). |

> `GenericServiceController<T>` is the non-resource base (CRUD + `bulk`, `{id}/soft-delete`,
> `{id}/metadata`). `ResourcesController` derives from it.

> **Access control comes with the base.** `GenericServiceController<T>` carries a property-less
> `[AccessControl]` (attaches the enforcement filter, declares nothing) and `[AccessControl(List = true)]`
> on `GetAll`, so your list endpoint is filtered **inside the Mongo query** with `totalCount` and paging
> intact. `ResourcesController` also overrides the verb where the HTTP method misleads —
> `POST {id}/deprovision` enforces as DELETE, `status`/`results`/`reconcile` as PUT. You only add the
> class-level node declaration; the rest is inherited ([18-access-control](18-access-control.md)).

### `AdminResourcesController<T,TSpec,TResult>` (`Admin/Resource/AdminResourcesController.cs`, SDK ≥ 1.0.7)
`: ResourcesController<T,TSpec,TResult>` for **admin-scoped** resources. Same ctor, same endpoints. Declare
`[Route("v1/aiservicedesk/admin/data/environment/extensions/<…>")]` — no `{workspaceId}`. It overrides
`GetWorkspaceIdFromRoute()` to return `Workspace.AdminWorkspaceId` (`000000000000000000000ad1`), so create stamps
that as `OwnerWorkspaceId` and every read/write checks ownership against it, and re-declares `can-deprovision`,
`deprovision`, `reconcile`, `ticket` and `ticket-status` so they bind without a route workspace. Access is
administrators only (the platform's tenant policy guards `/aiservicedesk/admin`), plus the resource's provisioning
token on its own `status`/`results`. No admin child-controller variant exists; an admin child overrides
`GetWorkspaceIdFromRoute()` and the five actions itself (see 21-admin-resources). See
[21-admin-resources.md](21-admin-resources.md).

### `ChildResourceController<TChild,TParent,TSpec,TResult>` (`User/Resource/ChildResourceController.cs`)
For resources nested under a parent. Ctor adds `IEntityService<TParent> parentService`. Declare your own
`[HttpPost("~/…/{parentId}/[controller]")]` action and call the protected
`CreateUnderParentAsync(parentId, child, ct)` (validates the parent, stamps `ParentId`).

### `ResourceGroupControllerRef<T,TSpec,TResult>` (host-internal — not in the SDK feed)
The first-party base for RG-scoped resources: routes nested under
`…/environments/{envId}/resource-groups/{rgId}/[controller]`, stamping `EnvironmentId`/`ResourceGroupId`. It
lives in the DevOps assemblies, which the extension SDK feed does not ship — an extension cannot subclass it
([02](02-authoring-guide.md#resource-group-scoped-env-child-resources)).

---

## Minimal typed resource (what an extension ships)
```csharp
[BsonIgnoreExtraElements]   // on every concrete Spec/Result/entity — see the rule above
public class HelloWorldSpec   : BaseSpec   { public string? FirstName { get; set; } public string? LastName { get; set; } }
[BsonIgnoreExtraElements]
public class HelloWorldResult : BaseResult { public string? FullName  { get; set; } }

[BsonCollection("extension_helloworlds")]
[BsonIgnoreExtraElements]
public class HelloWorld : ResourceBase<HelloWorldSpec, HelloWorldResult> {
    public override string GetTicketOriginType()    => "HelloWorld";
    public override string GetTicketOriginSubType() => "hello-world";
}
public class HelloWorldHooks   : DefaultEntityHooks<HelloWorld> { }          // or ResourceHooksBase for invariants
public class HelloWorldService : ResourceServiceBase<HelloWorld, HelloWorldSpec, HelloWorldResult> {
    public HelloWorldService(IRepository<HelloWorld> repo, ILogger<HelloWorldService> log,
        IServiceScopeFactory sf, IHttpContextAccessor http) : base(repo, log, sf, http) { }
}

[ApiController]
[Route("v1/aiservicedesk/user/data/workspaces/{workspaceId}/environment/extensions/helloworlds")]
[AccessControl(Parent = typeof(Workspace), ParentIdProperty = "OwnerWorkspaceId")]   // access node — see 18-access-control.md
public class HelloWorldsController : ResourcesController<HelloWorld, HelloWorldSpec, HelloWorldResult> {
    public HelloWorldsController(IEntityService<HelloWorld> svc, ILogger<HelloWorldsController> log) : base(svc, log) { }
}
```
That's a full first-class resource: CRUD + status/results + provisioning lifecycle, no boilerplate.
Provisioning behavior comes from the skill mapped to `HelloWorld/hello-world` — see
[01-architecture.md](01-architecture.md) and [04-hooks.md](04-hooks.md).
