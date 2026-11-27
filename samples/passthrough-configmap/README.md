# passthrough-configmap — synchronous single-object provisioning

Demonstrates **passthrough** mode: one Kubernetes ConfigMap created/updated/deleted **synchronously** on CRUD,
no agent and no worker. With **no skill mapping**, the base sets `ProvisionedMode = Passthrough` and calls the
`*Direct*` seams. The k8s client comes from the SDK's `IScopeClientFactory`.

## Hooks used (and why)
| Hook | Why |
|---|---|
| `ProvisionDirectAsync` | Create the ConfigMap synchronously on resource create (`client.CoreV1.CreateNamespacedConfigMapAsync`). |
| `UpdateDirectAsync` | Re-apply on update (`ReplaceNamespacedConfigMapAsync`). |
| `DeprovisionDirectAsync` | Delete the ConfigMap on deprovision (`DeleteNamespacedConfigMapAsync`). |
| `AutoDeleteOnDeProvision => true` | Hard-delete the row once the object is gone (passthrough default; shown explicitly). |

No skill mapping in `manifest.json` → passthrough. Attach a **kubernetes** scope; create with `namespace` + `data`.

## Frontend
List (`Name | Namespace | Keys | UID | Status`), a create/edit form (Name, Namespace, repeatable key/value
rows for `data` — submit button says **"Create"**, since the apply is synchronous), and a Spec/Result view.
Deliberately **no Track-Provisioning UI and no `ticketName()`** — passthrough creates no provisioning ticket
(the `origin-context` lookup would always return 204). Edits go through `PATCH {id}` with the FULL spec
(spec is replaced wholesale), which reaches `UpdateDirectAsync`.

## Deprovision
`DeprovisionAsync` → `DeProvisioning` → `DeprovisionDirectAsync` (sync delete) → `DeProvisioned` →
`AutoDeleteOnDeProvision` removes the row. See `reference/11-deprovisioning.md`.

## Build
```bash
# The scripts read the target platform from .env (scripts/_target.sh).
./scripts/build-extension.sh  samples/passthrough-configmap
./scripts/deploy-extension.sh samples/passthrough-configmap/dist/agent.zip
```
