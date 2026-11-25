# 6. Where to next

**What you'll do:** pick your next destination — there are four, and this page says when you'd want
each one rather than just what it is.

**What you need first:** [4. Build your first extension](build-your-first-extension.md) — a running
platform with an extension loaded into it. If you skipped ahead from an earlier page, everything below
still applies.

---

## 6.1 The authoring manual — when you need to know how something actually works

The guide you have just finished gets one extension running. It does not teach the extension model.
That is the 20 numbered guides in
[`.claude/skills/duplo-extension-dev/reference/`](../../.claude/skills/duplo-extension-dev/reference),
and **they are the source of truth** — the `/duplo-extension` authoring command reads them directly,
so what they say is what gets built.

| Guide | Reach for it when |
| --- | --- |
| [`00-naming.md`](../../.claude/skills/duplo-extension-dev/reference/00-naming.md) | Before anything else. REST segments, Mongo collection prefixes, and identifier rules that `build-extension.sh` validates and rejects |
| [`01-architecture.md`](../../.claude/skills/duplo-extension-dev/reference/01-architecture.md) | You want the provisioning architecture end to end before writing code |
| [`02-authoring-guide.md`](../../.claude/skills/duplo-extension-dev/reference/02-authoring-guide.md) | You are writing a straightforward extension and want the common path |
| [`03-base-classes.md`](../../.claude/skills/duplo-extension-dev/reference/03-base-classes.md) | You need to know what the SDK base classes already do for you before overriding them |
| [`04-hooks.md`](../../.claude/skills/duplo-extension-dev/reference/04-hooks.md) | You need to intervene in the lifecycle — which hook fires when, and what it may change |
| [`05-custom-actions.md`](../../.claude/skills/duplo-extension-dev/reference/05-custom-actions.md) | Your resource needs to do something that is not create/read/update/delete |
| [`06-registration.md`](../../.claude/skills/duplo-extension-dev/reference/06-registration.md) | You are wiring the manifest, or reconciling in-platform vs local registration and SDK versions |
| [`07-scope-credentials.md`](../../.claude/skills/duplo-extension-dev/reference/07-scope-credentials.md) | Your provisioning needs the cloud or cluster credentials behind the scope it was given |
| [`08-parent-child-and-menus.md`](../../.claude/skills/duplo-extension-dev/reference/08-parent-child-and-menus.md) | One resource owns many of another, or you want nested left-hand menu entries |
| [`09-result-templates.md`](../../.claude/skills/duplo-extension-dev/reference/09-result-templates.md) | You found a `view-template.json` in an older extension and want to know why it must go |
| [`10-sdk-api.md`](../../.claude/skills/duplo-extension-dev/reference/10-sdk-api.md) | You are calling cloud or Kubernetes APIs from your C# — the `Duplo.Ai.Studio.Extensibility.Infra` surface |
| [`11-deprovisioning.md`](../../.claude/skills/duplo-extension-dev/reference/11-deprovisioning.md) | You need deletion to be correct — it differs per provisioning mode |
| [`12-enrichment-and-live-state.md`](../../.claude/skills/duplo-extension-dev/reference/12-enrichment-and-live-state.md) | The detail view should show real current infrastructure state, not just what was persisted at create |
| [`13-current-user.md`](../../.claude/skills/duplo-extension-dev/reference/13-current-user.md) | You need the logged-in user in the frontend, the backend, or an agent skill |
| [`14-forms-and-wizards.md`](../../.claude/skills/duplo-extension-dev/reference/14-forms-and-wizards.md) | The create form is more than a handful of fields, or needs multiple steps |
| [`15-error-handling.md`](../../.claude/skills/duplo-extension-dev/reference/15-error-handling.md) | An API error is failing silently instead of showing up in the UI |
| [`16-ask-ai.md`](../../.claude/skills/duplo-extension-dev/reference/16-ask-ai.md) | You explicitly want on-demand Ask AI chat sessions on a resource (opt-in; the last tab of the Results tabs) |
| [`17-custom-result-views.md`](../../.claude/skills/duplo-extension-dev/reference/17-custom-result-views.md) | You are writing the Result content — Overview tiles, a tab per concern, live state, logs, polling |
| [`18-access-control.md`](../../.claude/skills/duplo-extension-dev/reference/18-access-control.md) | You want permission sets to govern who can see, manage, or run actions on your resources |
| [`19-detail-page.md`](../../.claude/skills/duplo-extension-dev/reference/19-detail-page.md) | You are building or restyling a detail page — the Studio's Template-G shell and how to derive your resource's provisioning phases for the lifecycle rail |

## 6.2 The samples — when you want to see a pattern already working

[`samples/`](../../samples) holds six extensions — a few big samples covering multiple use cases each,
plus focused mode references. Pick by the problem you have:

| Sample | What it demonstrates |
| --- | --- |
| [`helloworld`](../../samples/helloworld) | **Start here.** The canonical typed extension — C# `ResourcesController` + service + entity, an Angular Native-Federation remote (list/add/view on the platform detail shell), and a provisioning skill. Takes `firstName` + `lastName`, produces `fullName` |
| [`network-stack`](../../samples/network-stack) | **The big worked sample.** Long-running provisioning (background terraform watched by the agent with progressive module status), on-demand Plan/Apply actions after provisioning, execution logs with run history, a custom tabbed results view (Overview \| Network \| Logs \| Ask AI), C# enrichment for live state, and a multi-step create wizard |
| [`parent-child`](../../samples/parent-child) | Two typed resources in one DLL — a `HelloParent` owning many `HelloChild`, with the child mounted at a nested route and listed from the parent's view |
| [`passthrough-configmap`](../../samples/passthrough-configmap) | Passthrough mode: a Kubernetes ConfigMap created, updated, and deleted synchronously on CRUD — no agent, no worker |
| [`worker-appstack`](../../samples/worker-appstack) | Worker mode against real cloud objects: a Deployment plus a Service, reconciled in dependency order by a background worker with retries |
| [`worker-compute`](../../samples/worker-compute) | Worker mode for work that is not a cloud object at all — two numbers in, sum and product out, no scope required |

Every sample builds with a plain `npm install` + `npm run build`. There is no `ng serve` dev shell: an
extension frontend is a remote loaded into the portal, not a standalone app, so the loop is
build → deploy → hot-load.

## 6.3 The rest of the docs — when you need the reference, not the tour

The full index is [docs/README.md](../README.md). The pages you are most likely to want next:

| Page | Reach for it when |
| --- | --- |
| [architecture.md](../architecture.md) | You want to know what you have actually been running — how the studio, agent, UI, xterm, and Mongo fit together, and how the hot-load loop works |
| [configuration.md](../configuration.md) | You need to change something in `.env` and want to know the default, the effect, and whether it is managed for you |
| [cli-reference.md](../cli-reference.md) | You want a flag you did not use in this guide — every entry point in `run.sh`, `stop.sh`, `logs.sh`, and `scripts/`, including which commands destroy what |
| [upgrading.md](../upgrading.md) | A newer dev-kit version is out and you want it without losing your extensions or your configuration |
| [faq.md](../faq.md) | You have a question before something breaks — licensing, data, platform support, what happens on upgrade |

## 6.4 Going to production, and contributing back

**The Starter Tier can run in production**, within the limits your license sets (for example, the number of
users and Agents):

- [TERMS.md](../../TERMS.md) — links the DuploCloud Terms of Service, which cover the proprietary
  `quay.io/duplocloud/*` container images and the vendored UI library.
- [NOTICE](../../NOTICE) — the boundary drawn plainly: what the Apache-2.0
  [LICENSE](../../LICENSE) covers (the dev-kit source you have been editing) and what it does not
  (the images and the vendored library).
- **Need more than the Starter Tier allows?** Email **sales@duplocloud.net** about Pro or Enterprise licensing.

Contributing:

- [CONTRIBUTING.md](../../CONTRIBUTING.md) — **your own extensions stay in your repo.** The dev kit is
  clone-and-own, `extensions/` is yours, and nothing in it belongs upstream. Improvements to the
  *framework* — the scripts, the samples, the authoring skill, these docs — are what we take as PRs.
- [SUPPORT.md](../../SUPPORT.md) — where to ask and what to expect. GitHub Issues, best effort, no
  SLA. Read it before opening one; it lists exactly what to include.

---

That is the end of the path. Back to [the index](README.md) if you want to re-walk a page, or
[troubleshooting.md](../troubleshooting.md) if something is not behaving.

