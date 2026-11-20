# network-stack — the big worked sample

An AWS **network stack** (one VPC + subnets + a security group) provisioned by terraform. This is the
dev-kit's consolidated "real agent" reference: where `helloworld` teaches the minimal loop, this
sample teaches the patterns production agents actually combine —

| What it demonstrates | Where | Reference doc |
|---|---|---|
| **Long-running provisioning** — terraform launched DETACHED, watched with a sleep loop, progressive `Result.modules[]` posts | `skills/provision-network-stack/scripts/tf-run.sh` | [01](../../.claude/skills/duplo-extension-dev/reference/01-architecture.md), [07](../../.claude/skills/duplo-extension-dev/reference/07-scope-credentials.md) |
| **On-demand actions after provisioning** — Plan/Apply buttons → `POST {id}/plan\|apply` → stamp `spec.lastRequestedAction` → the SAME long-lived ticket | `backend/NetworkStack.cs` (`TriggerActionAsync`), `backend/NetworkStacksController.cs` | [05](../../.claude/skills/duplo-extension-dev/reference/05-custom-actions.md) |
| **Execution logs** — every run writes `canvas-documents/{plans,applies}/<runId>.{log,meta.json}` in the ticket workdir; the backend serves them via `ITicketService` | `backend/NetworkStack.cs` (`HistoryAsync`/`DetailAsync`), Logs tab | [05 §7](../../.claude/skills/duplo-extension-dev/reference/05-custom-actions.md) |
| **Custom tabbed Result view** — `ngbNav` INSIDE the Result panel: **Overview \| Network \| Logs \| Ask AI**, one lazy panel component per tab, planned-values-until-result, terminal-aware 3s polling | `frontend/src/app/view/view-network-stack.component.ts` + `shared/*-panel.component.ts` | [17](../../.claude/skills/duplo-extension-dev/reference/17-custom-result-views.md) |
| **Ask AI sessions** — the opt-in chat-ticket pattern, as the LAST results tab (`network-stack-askai` subType + `metadata.purpose: "ask-ai"`) | `frontend/src/app/shared/ask-ai-panel.component.ts` + the `askAi*` service methods | [16](../../.claude/skills/duplo-extension-dev/reference/16-ask-ai.md) |
| **Multi-step wizard Add form** — per-step `ngModelGroup` validation + a repeatable row group (subnets) | `frontend/src/app/add/add-network-stack.component.ts` + `wizard/wizard-stepper.component.ts` | [14](../../.claude/skills/duplo-extension-dev/reference/14-forms-and-wizards.md) |
| **Live-state enrichment on GET** — `EnrichResultAsync` reads current subnet state via `IScopeClientFactory` (guarded; never persisted) | `backend/NetworkStack.cs` (`EnrichResultAsync`), Network tab | [12](../../.claude/skills/duplo-extension-dev/reference/12-enrichment-and-live-state.md), [10](../../.claude/skills/duplo-extension-dev/reference/10-sdk-api.md) |
| **Deprovision = terraform destroy** on the same ticket, `DeProvisioning → DeProvisioned` | the skill's Deprovision section | [11](../../.claude/skills/duplo-extension-dev/reference/11-deprovisioning.md) |

```
backend/    typed C# — spec/result/entity/hooks/service + controller with plan/apply + history/log endpoints
frontend/   Angular 22 Native-Federation remote — list, 3-step wizard add/edit, tabbed results view
skills/     provision-network-stack — dispatches on spec.lastRequestedAction; tf-run.sh is the lesson
manifest.json  Agent mode: skills + skillMappings for NetworkStack/network-stack
```

The resource: spec `{ region, vpcCidr, subnets[]{name,cidr,az?}, tags, scopeIds }` → result
`{ vpcId, subnetIds[], securityGroupId, modules[], actions[] }`, collection `extension_networkstacks`,
route `…/environment/extensions/network-stacks`.

## The action loop (edit → plan → apply)

1. Create runs terraform apply automatically (the initial provision, recorded as action `provision`).
2. Edit saves the spec via PATCH (same ticket kept) — Apply is now refused.
3. **Plan** records a preview run (`plans/<runId>`); a plan failure never fails the resource.
4. **Apply** is enabled only after a successful plan (`Result.ApplyAllowed`, derived — nothing to clear).

## Deliberate simplifications (the upgrade path for a bigger agent)

- **A single flat tab strip**, not a pipeline-stepper-of-tab-strips — at 3 modules a pipeline row adds
  nothing; add one when your groups have their own sub-tabs.
- **Verbs are plan|apply only** — destroy is reachable only through the real deprovision lifecycle.
- **Terraform state is local to the ticket workdir** — a production agent uses a remote backend
  (S3 + locking).
- No deprovision approval workflow, edit-freeze policy, or manual-task queue.

## Build + package + load

Same flow as `helloworld` (see its README): pin the SDK (`sdk-version` → `-p:DuploSdkVersion`), unzip the
`sdk-bundle` into `backend/sdk-packages`, `dotnet publish`, `npm install && npm run build` in `frontend/`,
assemble `manifest.json + backend DLL + fe/ + skills/` and `load-bundle`. Or, from a clone-and-own repo:
`./scripts/build-extension.sh <path>`. The backend additionally references `AWSSDK.EC2` **compile-only**
(the host's SDK closure ships it — do not bundle a copy).
