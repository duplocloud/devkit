# worker-appstack — background-worker, multi-object provisioning

Demonstrates **worker** mode: a resource that maps to **multiple** Kubernetes objects (Deployment + Service),
reconciled by a **background worker** with retries — not the agent, not synchronous passthrough. The service
returns `Worker` from `NoSkillsFallbackMode`; `AppStackWorker` (a `ResourceWorkerBase`) does the cluster work on
its tick. The worker is registered via an `IDuploExtension` (`AppStackExtension`).

## Hooks used (and why)
| Member | Why |
|---|---|
| `AppStackService.NoSkillsFallbackMode => Worker` | Route create/update/delete through the background worker. |
| `AppStackWorker.ApplyAsync` | Create Deployment then Service (dependency order) via `IScopeClientFactory`. |
| `AppStackWorker.VerifyDriftAsync` | Drift check (no-op in this demo). |
| `AppStackWorker.DeleteSubResourcesAsync` | Delete Service then Deployment (reverse order). |
| `AppStackWorker.WaitForDeletionAsync` | Return true once the Deployment is gone (worker re-ticks until then). |
| `AppStackExtension : IDuploExtension` | `Configure` registers `AddHostedService<AppStackWorker>()`. |

> The hot-load loader starts the worker directly (it scans the assembly for `IHostedService`); `Configure`'s
> `AddHostedService` is what the boot-time replay uses after a studio restart. The base worker
> (`ResourceWorkerBase`) drives the tick loop, status transitions, and retries.

## Frontend
List (`Name | Namespace | Image | Replicas | Status`), a create/edit form (Name, Namespace, Image, Replicas —
submit button says **"Create"**), and a Spec/Result view. Deliberately **no Track-Provisioning UI and no
`ticketName()`** — worker mode creates no provisioning ticket (the `origin-context` lookup would always
return 204); progress arrives via status/subStatus. Edits go through `PATCH {id}` with the FULL spec (spec
is replaced wholesale), which re-triggers the worker's reconcile.

## Deprovision
`DeprovisionAsync` → `DeprovisionInitiated`; the worker tick runs `DeleteSubResourcesAsync` + `WaitForDeletionAsync`,
then the worker hard-deletes the row itself. See `reference/11-deprovisioning.md`.

## Build
```bash
# The scripts read the target platform from .env (scripts/_target.sh).
./scripts/build-extension.sh  samples/worker-appstack
./scripts/deploy-extension.sh samples/worker-appstack/dist/agent.zip
```
