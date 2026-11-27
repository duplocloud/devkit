# SDK Reference — Hooks & Lifecycle

Two hook layers fire on every resource operation:

1. **Entity hooks** (`IEntityHooks<T>` → `DefaultEntityHooks<T>` → `ResourceHooksBase<,,>`) — invariants &
   side effects that run inside the repository write path.
2. **Service seams** (`GenericService<T>` / `ResourceServiceBase<,,>` `protected virtual` methods) — the
   business workflow (validation, provisioning-mode dispatch, ticket creation).

Pick the layer by intent: **invariants that must hold on every DB write** → hooks; **workflow/validation/
provisioning** → service seams. Most extensions override nothing and rely on the defaults.

---

## Entity hooks — `IEntityHooks<T>` (`Duplo.Ai.Model/.../Interfaces/IEntityHooks.cs`)

| Hook | Fires | Use for |
|---|---|---|
| `OnPostReadAsync(entity, ct)` | after every read (GetById/GetAll/Find) | decrypt/transform/mask in-memory (not persisted) |
| `OnPreCreateAsync(entity, ct)` | before insert | validate, defaults, derived fields; throw to block |
| `OnPostCreateAsync(entity, ct)` | after insert | notifications, async side effects |
| `OnPreUpdateAsync(existing, updated, ct)` | before update | validate transitions, enforce invariants; throw to block |
| `OnPostUpdateAsync(entity, ct)` | after update | update dependents, **cascade** (e.g. delete children when `Status==DeProvisioned`) |
| `OnPreDeleteAsync(entity, ct)` | before delete | block deletion if referenced |
| `OnPostDeleteAsync(id, ct)` | after delete | cleanup / cascading deletes |
| `ValidateAsync(entity, isUpdate, ct)` | create & update | field/format/uniqueness; throw `ArgumentException` |

### `DefaultEntityHooks<T>` — the base you usually extend
All methods are `virtual` no-ops **except**: `OnPreCreateAsync` and `OnPreUpdateAsync` call
`entity.CleanupBeforeSave()`. If you override these two, call `base` first. An extension whose entity needs
no invariants can use `DefaultEntityHooks<MyResource>` directly.

### `ResourceHooksBase<TResource,TSpec,TResult>` — invariants for resources
(`Duplo.Ai.DataManagement/.../Hooks/ResourceHooksBase.cs`) — extend this instead of `DefaultEntityHooks`
when your resource needs the standard guardrails. Ctor: `(ILogger logger, IServiceProvider serviceProvider)`.

It overrides `OnPreUpdateAsync` to enforce: **OwnerWorkspaceId immutability**, **immutable spec fields**
(once past `New`), **Import-mode deprovision guard**, and a **busy-ticket block** (no spec edits while the
ticket is Running). It overrides `OnPreDeleteAsync` to enforce the **delete-status gate**. You supply only:

| Override | Default | Purpose |
|---|---|---|
| `string[] GetImmutableSpecFields()` | `[]` | Spec property names (PascalCase) frozen after `New`. |
| `ResourceStatus[] GetDeletableStatuses(resource)` | `New, Failed, DeProvisioned` | When a non-imported resource may be deleted. |

(Imported resources are always deletable — no cloud object to tear down.)

---

## Service seams — `ResourceServiceBase<,,>`

These run in the **service** layer (`Duplo.Ai.DataManagement/.../Services/ResourceServiceBase.cs`). Defaults
give you full agent-based provisioning with zero overrides.

### Create — `CreateAsync`
1. `ResolveAndValidateExternalAsync` (pre-lock cloud/HTTP/DNS; may stamp the entity)
2. *(collection lock)* → `ValidateAsync` → `ValidateName`/`ValidateNameFormat` → `ValidateSpecAsync`
3. `OnBeforeCreateAsync` → `PopulateExpandedPropertiesAsync` → `ValidateWorkspaceExistsAsync`
4. Entity hook `OnPreCreateAsync` → DB insert → `OnPostCreateAsync`
5. If **Passthrough** mode → `ProvisionDirectAsync` (inline; set `Status=Complete` + `Result`)
6. *(lock released)* → `OnAfterCreateAsync` → if provisioning needed, fires the ticket via
   `IResourceProvisioningManager` in the background (HelpdeskAgent mode). **This is automatic — do not
   re-implement it in a hook.**

### Update — `UpdateAsync`
`ResolveAndValidateExternalAsync` → *(lock)* `ValidateAsync`/`ValidateName` (if name changed) →
`OnBeforeUpdateAsync` (may flip `Complete→Processing` on a spec change to a skill-mapped resource) →
entity `OnPreUpdateAsync` (invariants) → DB update → *(if Passthrough + spec changed)* `UpdateDirectAsync`
→ *(unlock)* `OnAfterUpdateAsync` (re-fires provisioning or notifies the running agent of the spec change).

#### Editing a provisioned resource — reuse the ticket, don't spawn a new one
`OnAfterUpdateAsync` decides **create-vs-reuse purely on the ticket id** (SDK `ResourceServiceBase.cs`):
```
if (string.IsNullOrEmpty(updatedEntity.TicketContext?.TicketId))   // → first-time provisioning
    InitiateResourceProvisioningAsync(...)                          //   = a NEW ticket
else if (HasSpecChanged(...))                                       // → reuse the SAME ticket
    NotifySpecChangeAsync(...)   // re-materializes shared/<subtype>.json + sends a "spec updated" msg
                                 // (force-send is CALLER-decided via ForceSendOnSpecChange(); forced sends
                                 //  interrupt the in-flight turn, queued sends wait behind it)
```
So a normal spec edit on an already-provisioned resource **reuses its one ticket** — as long as
`TicketContext.TicketId` survives the update.

**The PUT-vs-PATCH trap.** The base `ResourcesController` **`PUT {id}`** binds the *whole entity* from the body
(`[FromBody] T resource`). A frontend that sends only `{ spec }` therefore arrives with `TicketContext = null`,
so `OnAfterUpdateAsync` sees an empty ticket id and **spawns a brand-new ticket on every edit** — which also
makes prior plan/apply logs "disappear", because run history is read from the ticket workdir keyed by
`TicketContext.TicketId` (see [05-custom-actions §7](05-custom-actions.md)). **`PATCH {id}`** instead *merges*
onto the DB entity — it overwrites only the fields present in the body and never touches
`TicketContext`/`Status`. Two refinements: PATCH **does** copy `Result` when the body carries one (never echo
`result` back), and `spec` is replaced **WHOLESALE** (no deep merge) — a partial `{spec:{a:1}}` silently drops
every sibling spec field, so edit forms must always send the FULL spec.
**Rule: edit forms must call `PATCH /{id}` with the full `{ spec }`, not `PUT`.**
(An action endpoint that loads the full entity, mutates one field, and calls `UpdateAsync` is also safe — the
entity it passes still carries `TicketContext`.)

**Status discipline for one long-lived ticket.** Ticket reuse works only while the resource keeps its
`TicketContext.TicketId`. If you want a single durable ticket that repeated edits/actions reconcile into, the
agent skill must **not** end the ticket after a run — post the terminal *resource* status
(`Complete`/`Failed`), then return to a standby wait loop. See the action-driven pattern in
[05-custom-actions §7](05-custom-actions.md).

**References:** SDK `ResourceServiceBase.cs` (`OnAfterUpdateAsync` ticket-id check),
`Controllers/User/Resource/ResourcesController.cs` (PUT binds whole entity vs PATCH merges), and
`ResourceProvisioningManager.NotifySpecChangeAsync`. Working models: the Terraform extension's `TfDeployment`
(edits via PATCH) and `TfState` (`POST {id}/actions`).

### Delete — `DeleteAsync`
entity `OnPreDeleteAsync` (status/Import gate via `ResourceHooksBase`) → DB delete → `OnPostDeleteAsync`.

### Deprovision — `DeprovisionAsync` (`POST {id}/deprovision`)
`ValidateCanDeprovisionAsync` → dispatch by `ProvisioningMode`: **Worker** → `DeprovisionInitiated`
(worker tears down); **Passthrough** → `DeprovisionDirectAsync` → `DeProvisioning`→`DeProvisioned`;
**HelpdeskAgent** → notifies the existing ticket. If `AutoDeleteOnDeProvision` → row is hard-deleted.

### Status / Result write-back (the agent's two APIs)
- `POST {id}/status` → `UpdateStatusAsync` → persists → `OnAfterStatusUpdateAsync` (react to transitions;
  e.g. an Agent resource unloads its DLL on `DeProvisioned`).
- `POST {id}/results` → `UpdateResultAsync` → persists → `OnAfterResultUpdateAsync` (e.g. auto-create a
  dependent resource).
- **Status and results are separate APIs — never fold the result into a status payload.**

### Read enrichment
`GetByIdAsync` → `EnrichResultAsync(entity)` before returning: inject **live, non-persisted** data
(e.g. current cloud state). See [05-custom-actions.md](05-custom-actions.md).

### Provisioning-mode hooks
`NoSkillsFallbackMode` (default `Passthrough`; return `Worker` for background reconcile),
`GetProvisioningMessage` (initial agent chat message), `GetExpandedSpecForAgentAsync` (spec JSON written to
`shared/<subtype>.json`), `IsProvisioningNeeded`, `ResolveParentSkillIdsAsync`.

---

## Which to override — quick guide
| Need | Override |
|---|---|
| Validate spec fields | `ValidateSpecAsync` |
| Validate name/entity rules | `ValidateAsync` (call `base` first) |
| Cloud preflight before save | `ResolveAndValidateExternalAsync` |
| Do the work synchronously (no agent) | `ProvisionDirectAsync` / `UpdateDirectAsync` / `DeprovisionDirectAsync` + return `Passthrough` |
| Show live cloud state on view | `EnrichResultAsync` |
| React after status/result write | `OnAfterStatusUpdateAsync` / `OnAfterResultUpdateAsync` |
| Freeze fields / restrict delete | `GetImmutableSpecFields` / `GetDeletableStatuses` (in `ResourceHooksBase`) |
| Cascade-clean children | entity `OnPostUpdateAsync` (on `DeProvisioned`) / `OnPostDeleteAsync` |
| Background reconcile + drift | return `Worker` from `NoSkillsFallbackMode` |

For agent-based provisioning (the common case) you override **nothing** — you map a skill to
`originType/subType` and the agent fills `Result` via `POST {id}/results` + `{id}/status`.

## Complete seam catalog (hook → when it fires → when to override → mode)
All are `protected virtual` unless noted. Signatures: [10-sdk-api](10-sdk-api.md); deprovision:
[11-deprovisioning](11-deprovisioning.md); enrichment: [12-enrichment-and-live-state](12-enrichment-and-live-state.md).

**CRUD (every entity — `GenericService<T>`):**
| Hook | Fires | Override when | Mode |
|---|---|---|---|
| `ValidateAsync` | before create/update persist | structural validation | all |
| `OnBeforeCreateAsync` / `OnAfterCreateAsync` | around insert | defaults / side-effects | all |
| `OnBeforeUpdateAsync` / `OnAfterUpdateAsync` | around update | guard changes / react | all |
| `OnBeforeDeleteAsync` / `OnAfterDeleteAsync` | around hard-delete | cascade guard / cleanup | all (esp. no-provision) |

**Provisioning (`ResourceServiceBase<…>`):**
| Hook | Fires | Override when | Mode |
|---|---|---|---|
| `ValidateSpecAsync` | before persist | spec/scope required-field checks | all |
| `ResolveAndValidateExternalAsync` | before persist | validate against external system | any |
| `IsProvisioningNeeded` | create/update | return `false` → complete, no provisioning ticket | no-provision |
| `NoSkillsFallbackMode` | mode decision | return `Worker` (else passthrough) | worker |
| `GetExpandedSpecForAgentAsync` | ticket creation | customize the spec JSON given to the agent | agent |
| `ProvisionDirectAsync` / `UpdateDirectAsync` / `DeprovisionDirectAsync` | create/update/delete | synchronous external apply | passthrough |
| `EnrichResultAsync` | on GET | inject live state | enrichment |
| `OnAfterStatusUpdateAsync` / `OnAfterResultUpdateAsync` | after agent/worker writes | react to status/result | agent/worker |
| `ValidateCanDeprovisionAsync` (public) | deprovision start | block while children exist | all |
| `AutoDeleteOnDeProvision` | reached `DeProvisioned` | retain vs hard-delete row | all |
| `DetectDriftAsync` | periodic (Complete) | CFN/desired-vs-actual drift | agent/CFN |

**No-provision — the complete wiring** (no dedicated sample; it is genuinely one override):
```csharp
protected override bool IsProvisioningNeeded(MyThing entity) => false;
```
Create then persists the row and completes immediately: status `Complete`, **no ticket**, no scope
validation, no skill/`skillMappings`. Typical uses: observe-only resources (pair with `EnrichResultAsync` —
see [12-enrichment-and-live-state](12-enrichment-and-live-state.md)) and form-only resources whose create
just records the spec. Delete is a plain CRUD delete (no deprovision ticket — see
[11-deprovisioning](11-deprovisioning.md)).

**Worker (`ResourceWorkerBase<…>`, worker mode only):** `ApplyAsync` (abstract — apply in dependency order),
`VerifyDriftAsync` (abstract), `DeleteSubResourcesAsync` (abstract — reverse order), `WaitForDeletionAsync`
(abstract — poll until gone), `EnrichSpecAsync`, `ShouldWaitForParentCascadeAsync`, `IsTerminalFailure`, + tuning
(`DefaultTickInterval`, `MaxRowsPerTick`, `DriftCadence`, `TerminalRetryThreshold`). Register it with
`AddHostedService` in `IDuploExtension.Configure`; how the loader starts it on hot-load vs boot replay is in
[10-sdk-api](10-sdk-api.md#gotchas).

The base also gives you two `protected readonly` fields — use them, don't invent your own:
`Logger` (an `ILogger`, so `Logger.LogWarning(...)` IS valid on a worker) and `ScopeFactory`
(an `IServiceScopeFactory`; per-tick services arrive as the `IServiceProvider scope` parameter anyway).
Helpers: `SaveProgressAsync` and `PatchEntityAsync` (both `protected static`). These are the complete
extension-facing surface — a member not listed here or in [10-sdk-api](10-sdk-api.md) doesn't exist.

### How a worker persists `Result` — `SaveProgressAsync`
`ApplyAsync` receives a **mutable** entity. To record outputs, set fields on `entity.Result` and call
`await SaveProgressAsync(scope, entity, "<sub-status>", ct)` (a `protected static` helper on the base) — it
patches `Result` + `SubStatus` to the DB mid-apply. The base also re-persists `entity.Result` and flips
`Status → Complete` on terminal success, so for a one-shot apply mutating `entity.Result` is enough; call
`SaveProgressAsync` to surface progress on long, multi-step applies (and so a delete racing the apply sees the
names). It never writes `Status` — status transitions belong to the base dispatcher.

```csharp
protected override async Task ApplyAsync(Calc e, IServiceProvider scope, CancellationToken ct)
{
    e.Result ??= new CalcResult();
    e.Result.Sum = (e.Spec?.A ?? 0) + (e.Spec?.B ?? 0);
    await SaveProgressAsync(scope, e, $"sum={e.Result.Sum}", ct);   // persist Result now
}
```

### A worker needs no cloud
Worker mode is for any multi-step or retry/reconcile "provisioning", **not only Kubernetes**. A pure in-process
computation (no scope, no external system) is a valid worker: `ApplyAsync` computes into `entity.Result` +
`SaveProgressAsync`; `VerifyDriftAsync`/`DeleteSubResourcesAsync` are no-ops and `WaitForDeletionAsync` returns
`true` (nothing to wait for). The Spec then needs no `ScopeIds` and the Add form shows no scope picker. Worked
example: `samples/worker-compute`.
