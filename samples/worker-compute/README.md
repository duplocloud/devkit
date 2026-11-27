# worker-compute — WORKER mode, pure in-process compute (no cloud)

Demonstrates **worker provisioning** for work that is **not** a cloud object: a `CalcWorker` takes two numbers and
a background worker computes their sum + product into `Result`. Worker mode is for any multi-step / retry /
reconcile "provisioning" — it does **not** require Kubernetes or any scope.

## How it works
- The service maps **no** skill and returns `ProvisioningMode.Worker` from `NoSkillsFallbackMode`, so create/update
  route to the background `CalculatorWorker` (a `ResourceWorkerBase`) instead of the agent or a synchronous
  passthrough.
- The worker is registered via `IDuploExtension.Configure` → `AddHostedService<CalculatorWorker>()` for the
  boot-time replay; on hot-load the loader starts it directly by scanning the assembly for `IHostedService`
  (reference/10-sdk-api.md, Gotchas).
- `ApplyAsync` receives a **mutable** entity: it sets `entity.Result.Sum/Product` then calls
  `await SaveProgressAsync(scope, entity, "...", ct)` to persist the result. The base re-persists `Result` and
  flips `Status → Complete` on terminal success.
- Because there is no external system: `VerifyDriftAsync` / `DeleteSubResourcesAsync` are no-ops and
  `WaitForDeletionAsync` returns `true`. The spec needs no `ScopeIds` and the Add form shows no scope picker.

See `reference/04-hooks.md` (worker seams + `SaveProgressAsync`) and `reference/11-deprovisioning.md`.

## Hooks used (and why)
| Hook | Why |
|---|---|
| `NoSkillsFallbackMode => Worker` | No skill mapped → background worker owns create/update/delete. |
| `ApplyAsync` (+ `SaveProgressAsync`) | Compute `sum`/`product` into `entity.Result` and persist. |
| `VerifyDriftAsync` / `DeleteSubResourcesAsync` / `WaitForDeletionAsync` | No external state → no-ops / instant. |

## Try it
1. Create a CalcWorker with `a` + `b` (no scope needed).
2. Within a worker tick (~15s) it flips to `Complete`; GET shows `result.sum` (a+b) and `result.product` (a*b).

## Deprovision
Worker path: status → `DeprovisionInitiated`; the worker's `DeleteSubResourcesAsync` (no-op here) +
`WaitForDeletionAsync` (true) → `DeProvisioned`. See `reference/11-deprovisioning.md`.

## Build
```bash
# The scripts read the target platform from .env (scripts/_target.sh).
./scripts/build-extension.sh  samples/worker-compute
./scripts/deploy-extension.sh samples/worker-compute/dist/agent.zip
```
