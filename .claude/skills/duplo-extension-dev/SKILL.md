---
name: duplo-extension-dev
description: Build and load a DuploCloud platform extension (a typed extension — C# ResourcesController or AdminResourcesController + service + entity, plus an Angular remote and a provisioning skill) and hot-load it into the platform. Works both inside an Extension resource's provisioning ticket and locally (you supply the platform URL + an admin token). Scaffolds from the hello-world example, compiles the backend with dotnet against the host SDK feed, packages, and registers — no host restart.
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
> [07-scope-credentials](reference/07-scope-credentials.md) — reading the selected scopes' credentials in a skill, and the shared provider types the setup page connects ·
> [08-parent-child-and-menus](reference/08-parent-child-and-menus.md) — multi-resource extensions and `frontend.menus[]` ·
> Navbar buttons: `frontend.headerActions[]` — [02-authoring-guide](reference/02-authoring-guide.md#frontendheaderactions) ·
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
> [20-ui-library](reference/20-ui-library.md) — every `ng-common-lib` export, a "need X → use Y" picker, verified recipes, the connections kit, and what works in a remote ·
> [21-theming](reference/21-theming.md) — Light/Dark and brand themes: the `$g-*` colour names, rules, editors and charts.
> [21-admin-resources](reference/21-admin-resources.md) — **admin-scoped** resources: `AdminResourcesController`, the admin route, the Admin Workspace, AI Admin menus/routes, and the skill write-back URL. ·
> [23-secrets](reference/23-secrets.md) — a Spec/Result field that holds a password/token/key: `[SecretValue]`/`[AgentSecretValue]`, encryption-at-rest, the reveal endpoint, write-only forms.

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

> **Getting the working copy.** The dev-kit repo (`duplocloud/devkit`) is public: a plain `git clone` works. In-platform
> the bootstrap has already cloned it (honouring the admin's `spec.devKitRepo`/`spec.devKitBranch`), so work in that
> copy. The user's own repo (`spec.gitRepo`) needs the **GitHub scope**, whose token reaches `gh`
> (`.config/gh/hosts.yml` + `GH_CONFIG_DIR`), so clone that one with **`gh repo clone …`**. 🔒 **Never read/print a credentials file** (`cat`/`echo`/`head`/`grep` of `hosts.yml`,
> `.aws/credentials`, …) — to verify GitHub auth use **`gh auth status`**, never `cat hosts.yml`.
> - **`spec.gitRepo` set (user's own repo):** `gh repo clone <orgName>/<name> repo` (with `-b <branch>`). If the repo
>   is **EMPTY**, overlay the dev-kit's content EXCEPT `.git` so the user repo keeps its own `.git`/ownership:
>   `git clone https://github.com/duplocloud/devkit /tmp/devkit && rsync -a --exclude=.git /tmp/devkit/ repo/`.
>   If it **already has** dev-kit content, just work in it — but **enumerate first**: `ls extensions/*/manifest.json`.
>   Other developers' extensions may live beside yours; the requirement decides whether you MODIFY an existing
>   `extensions/<name>/` or scaffold a NEW `extensions/<name2>/` (ask when ambiguous), and before scaffolding new,
>   read a sibling to match its conventions. **Hot-load is on-demand**, **push is user-initiated only**
>   (chat or the result-page badge); prompt to **commit**/**resync** and report `result.gitStatus` after each git op.
> - **No `spec.gitRepo`:** work in the dev-kit copy (throwaway, hot-load only).
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
- **Extension scope — workspace or admin** (per resource; not the same thing as the *Provider scopes* that carry
  credentials). **Workspace** (the default) = a tenant's resource, used by workspace members, rendered in AI
  DevOps. **Admin** = platform-wide configuration administrators manage (a VPN server, an SSO integration, a
  notification setting): its controller derives from `AdminResourcesController` and carries the usual
  `[AccessControl(Parent = typeof(Workspace), ParentIdProperty = "OwnerWorkspaceId")]`, its route is
  `v1/aiservicedesk/admin/data/environment/extensions/<…>` (no `{workspaceId}`), every row belongs to the system
  Admin Workspace, access is administrators plus anyone granted the Admin Workspace, and its menu renders in AI
  Admin. Derive it from the requirement ("only admins", "platform-wide", "global setting" → admin); if unsure, ask;
  never default to admin. For an admin resource also settle:
  - **which Provider scopes provisioning needs.** The Admin Workspace starts with none: an administrator must
    first attach them to it (PUT on the Admin Workspace's `scopeIds`), and `spec.scopeIds` must be a subset of
    those — the platform skips any other id.
  - **whether workspace resources consume it** (pick it, read its details). That is the common case — model it
    the way `samples/admin-settings`' `AdminSettingConsumer` does.
  - for **parent → child**, that the child controller applies the admin overrides itself (there is no admin child
    controller in the SDK) and is then administrators-only — see reference/21.
  Admin needs a host SDK that ships `AdminResourcesController`; the build probes for it. Full rules:
  [21-admin-resources](reference/21-admin-resources.md).
- **Spec fields** — each with name, type, and required/optional. **Result fields** — same. For every field,
  ask: is this a password/API token/key, or anything else sensitive? Don't wait for the user to volunteer
  it — a field named `apiKey`/`password`/`token`/`secret` (or described that way) always gets this question.
  If yes, settle whether it's actually an external-system credential (→ a Scope/Credential,
  [07-scope-credentials](reference/07-scope-credentials.md), not a raw field) or an inherent attribute of
  the resource itself (→ [23-secrets](reference/23-secrets.md): `[SecretValue]`/`[AgentSecretValue]`,
  encryption-at-rest, a reveal endpoint, a write-only edit form) — present the field table with a
  **Sensitive?** column so the answer is visible when you ask for approval.
- **Provisioning MODE** — decide HOW this resource is provisioned. **Do not default to an agent skill.** Pick by
  what the work actually is (derive from the requirement; tell the user your pick by its plain name from
  [Talking to the user](#talking-to-the-user)):
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
- **Admin setup page (always — not a question)** — settle what it sets up: **one connection per external
  provider** the agent uses (ClickUp, Slack, Jira, a custom API) and the agent's own admin-wide settings. Use
  the shared provider type and field keys for a well-known system
  ([07](reference/07-scope-credentials.md#shared-provider-types)). An agent with no
  provider and no settings still ships the page. Built in Phase 2 → "The admin setup page".
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
  | **admin-managed, platform-wide** configuration (AI Admin menu, `AdminResourcesController`), and workspace resources that consume it | `samples/admin-settings` | `samples/helloworld` (workspace-scoped) |

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
- **Menu placement** — the items it adds **inside** its left-nav section, or **no menu**. With an **Agent** (below),
  the Agent decides the section, and every top-level `menus[]` node lands under it, so settle only the item titles
  and their order within the section. Without
  one, placement is by **title**: a **new top-level group** (e.g. `Jenkins`, `GCP`) or **nested under an existing
  section** (e.g. `Infrastructure`). Default to its own group and state it in the summary; ask only when the
  requirement points two ways. An **admin** resource's tree goes in the **AI Admin** nav: its top-level node carries
  `"scope": "admin"`, and so does each `routes[]` entry it links to ([21](reference/21-admin-resources.md#frontend)). The user gives titles; **you** generate ids, `relativeUrl`s and the matching `frontend.routes[]` —
  [08-parent-child-and-menus](reference/08-parent-child-and-menus.md). Also settle **title** + **`matIcon`** per
  item — derive the icon from the extension's purpose, per the Left-nav icon bullet above.
- **Agent** — the top-level left-nav section the extension sits in: an **existing** section (`Infrastructure`, or
  any other built-in heading by its exact title) or a **new** one (`Compliance`, `Release Management`, or a typed
  name). Ask it with the Agent row in the table below, which also offers the position.
  Write it as the **manifest-root** `agent` field (sibling of `id` / `name` / `version`; never on a menu node; one
  agent per extension):
  - **Existing section** → the plain string, e.g. `"agent": "Infrastructure"`. A built-in section keeps its own
    position, so never add an order. Never write `"DevOps"`: the built-in heading is now Infrastructure, and
    `"DevOps"` creates a second, separate heading.
  - **New section** → **always** the object form with an order, e.g.
    `"agent": { "name": "Release Management", "order": 85 }`. Without an order a new section defaults to `0` and
    sits at the very top of the nav, above HelpDesk. Use `85` (just above Settings) unless the author picks a
    position; "after <section>" is that section's number + 5, "at the top" is `5`. Built-in numbers: HelpDesk 10,
    Projects 20, Infrastructure 30, Scopes 40, KB 50, Resources 60, Agent Studio 70, Analytics 80, Settings 90.
  Every extension's default section comes from its own manifest `agent` (DuploCloud's own extensions included); an
  admin can override the section and position from the Marketplace, and that override wins and survives upgrades.
  The name must be non-empty, at most 64
  characters, with no control characters, and `order` an integer — an invalid value is rejected at upload (HTTP 400)
  and fails the provisioning when deployed through a resource.
  Every top-level `menus[]` node then renders as a child of the agent's heading, so don't wrap menus
  in a node titled after the agent ([08 → Filing under an agent](reference/08-parent-child-and-menus.md#filing-under-an-agent--the-root-agent-field)).
  If the author declines to pick one, delete the template's `agent` line - omit the field entirely, never write `agent: ""`.
- **One or many resources?** — **flat** (independent — e.g. `GCP` → network/cluster/database) or **parent → child**
  (`samples/parent-child`); several top-level menu groups are fine — [08](reference/08-parent-child-and-menus.md).

### Talking to the user

The list above is your checklist; its words are yours. The user knows their problem: what people type in, what
they want to see afterwards, who manages it, which outside system it talks to. Settle the checklist from that, and
put questions to the user in their words, once, in one batch:

- **Always ask:** the Name, Agent, Spec fields and Result fields rows, each as your guess for the user to confirm, and
  the Sensitive fields row for any field that looks like a password, token or key. For the Agent row, put your guess
  first ("I'd put it in a new **Release Management** section just above Settings") and keep the row's choices and the
  position offer, so the user sees both what a section is and that they can move it.
  In-platform, when these four are all the batch holds, they ride the pause below instead of a separate ask.
- **Also ask:** any other row where the requirement points two ways and a wrong guess changes what gets built.
- **Every other row:** state your choice as a default in the summary below. The user approves the summary before
  you build, so a stated default is a decision.

Never put a checklist term to the user (spec, result, resource, scope, provider, provisioning, mode, CRUD,
endpoint, controller, section id), except under **Technical details** in the summary, which is for reviewers. Examples below use a Jenkins job; use the user's own system and words.

| Decision | Ask the user | Default when the requirement is silent |
|---|---|---|
| Name | "I'll call it **Jenkins Jobs**. Keep that name?" (derive the ids yourself) | derived from the requirement |
| Extension scope | "Who manages these: people in a workspace, or only platform admins?" | people in a workspace |
| Provider scopes for testing | "To test this I need to reach Jenkins. Which saved connection should I use?" List them by name, plus "it doesn't need one". | none when the work touches no outside system. In-platform the create form's Scopes field answers this and the ticket cannot list connections: when the field is empty and the work needs one, state "No Jenkins connection was picked, so I'll build it without testing against Jenkins." |
| Spec fields | "When someone adds one, what do they fill in? My guess: job name (required), branch (default main)." | the requirement's Inputs section |
| Sensitive fields | Per field that looks like a password, token or key: "Should **API key** stay hidden once it's saved, like a password? Is it how this signs in to Jenkins, or does each job have its own?" | hidden; signing in to the outside system belongs to its connection |
| Result fields | "When it's done, what should the page show? My guess: build number, status, duration, a link to the log." | the requirement's Result section |
| Provisioning mode | Never asked. State it: "This is a fixed set of steps, so it runs as a **background job** with no AI. Tell me if it needs AI judgement." | derived (table below) |
| Custom endpoints | "Besides add, edit and delete, does it need any buttons? For example **Run now** or **View logs**." | none |
| Access control | Only when a button does something sensitive: "Can anyone in the workspace press **Restart**, or only people you allow?" | anyone in the workspace |
| One or many resources | Only with more than one thing, and never when one only uses the other (an admin thing that workspaces pick): "Does one **Pipeline** hold many **Jobs**?" | flat; an admin thing plus a workspace thing that picks it follows `samples/admin-settings` |
| Agent | Always asked: "Your agent gets a section in the left menu in the DuploCloud AI platform. Should it join an existing section, like **Infrastructure**, or start a new one: **Compliance**, **Release Management**, or a name of your own? A new section goes just above **Settings** unless you want it somewhere else, for example right after Infrastructure." | Infrastructure for infrastructure work; a new section at 85 (just above Settings) |
| Menu placement | Only when the requirement points two ways: "Inside that section, should it be one **Jenkins Jobs** page, or separate **Jobs** and **Pipelines** pages?" | one page per resource |
| Deprovision / teardown | "When someone deletes one here, should the Jenkins job be deleted too?" | delete what provisioning created |
| Outside auth | "How does Jenkins sign in: username and API token, or a single token?" | from the chosen connection |
| Admin setup page | Only when the requirement hints at admin-wide settings: "Is there anything an admin should set once for everyone, for example a default Jenkins folder?" | one connection per outside system the requirement names; no settings |

The four provisioning modes, as the user hears them:

| Mode | Plain name | What the agent says |
|---|---|---|
| Worker | **Background job** | Runs a fixed set of steps in the background and retries until done. No AI. |
| Agent | **AI agent** | An AI works out the steps each time. For open-ended work. |
| Passthrough | **Instant** | Creates one thing the moment you save. |
| No-provision | **Read-only** | Shows information and creates nothing. |

The form shape (simple form, step-by-step setup, repeatable rows, one-holds-many, tabbed results) is your pick from
the sample index above. Describe it in plain words in the summary ("a three-step setup: Connection, Job,
Schedule"); the user can ask for a different one.

**The summary the user approves** (local: the plan you `ExitPlanMode` with; in-platform: the "Build this?" ask below),
per resource for multi-resource extensions:

1. **What you'll get**: five to eight plain lines. Its name, where it appears in the menu (AI DevOps or AI Admin, and for AI DevOps the left-menu section and its
   position, e.g. "a new **Release Management** section just above Settings"), what someone
   fills in, what happens after they save (name the pattern by its plain name; in Agent mode, that the add form
   tells users AI does the work), what the page shows, which values stay hidden, what delete does, and what an admin sets up once.
2. One line per default the user has not confirmed, so they can object.
3. **Technical details**, as a structured shape: a **Spec** field table (name · type · required/optional · sensitive?), a
   **Result** field table (name · type · sensitive?), the **extension scope** (workspace / admin) and the **provisioning mode**,
   each with a one-line reason, and the **detail view's shape** — the **lifecycle phases** this resource goes through
   (label + the status/result field that drives each; [19-detail-page](reference/19-detail-page.md) → "Deriving
   phases") and the **Result tabs** (Overview at minimum; name each further tab;
   [17-custom-result-views](reference/17-custom-result-views.md)) — and the **setup page's steps** (one connection per
   provider, then the settings).

**Where the answers come from / how to ask:**
- **In-platform:** read `spec.description`/`spec.icon`/`spec.scopeIds` from `shared/extension.json` (plus
  `shared/uploads/*`). Ask through the bootstrap's protocol (`duplo-extension-ticket`, "Questions — ask in chat, never
  park"): POST `Blocked` with `subStatus` `Needs more details` and a `blockedReason` of one plain line, then ONE
  `ask_human` call holding the whole batch (skip it when it holds only the four always-ask guesses). When the answers
  arrive, go straight to the pause.
  Then pause before any code, whatever the batch held. POST `Blocked` with the `blockedReason` "Review what I'll build":
  ```bash
  curl -fsS -X POST "$RES/status" -H "Authorization: Bearer $DUPLO_TOKEN" -H "Content-Type: application/json" \
    -d '{ "status": "Blocked", "subStatus": "Needs more details", "blockedReason": "Review what I'\''ll build" }'
  ```
  then ask ONE `ask_human` `yes_no` question: the summary, ending "Build this?". Add no options of your own: the
  platform's "Chat about this" row is where the user says what to change.
  - **Yes** → POST `Processing` / `Authoring code` and go to Phase 2.
  - **No / anything else** → the reply is the change request. Revise the summary and repeat the pause: the `Blocked`
    POST before every ask, then the question.
  - Never scaffold before a **Yes**.
- **Local:** ask the batch in one message (`AskUserQuestion` when the session has it) and **wait** for answers. The
  summary is the plan you `ExitPlanMode` with. Do not scaffold until it is approved.

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
cd "$(git rev-parse --show-toplevel)"   # the repo root; in-platform, the clone the bootstrap made
[ -d "extensions/<name>" ] || cp -r ".claude/skills/duplo-extension-dev/templates/helloworld" "extensions/<name>"
```
In-platform the bootstrap clones the dev-kit (or the user's repo) into the ticket workdir and works from that clone's
root, so `extensions/<name>/` and the template are both inside it.

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
  **Admin scope:** derive from `AdminResourcesController<…>`
  (`using Duplo.Ai.DataManagement.Controllers.Admin.Resource;`) and route it at
  `v1/aiservicedesk/admin/data/environment/<restSegment>` — no `{workspaceId}`, and **the same** access-node
  declaration as a workspace controller (mandatory: access follows the Admin Workspace's grants, and the host
  rejects an admin controller whose entity is not a registered node)
  ([21](reference/21-admin-resources.md#backend), worked example `samples/admin-settings`).
- `backend/Duplo.Extension.HelloWorld.csproj` — rename to `Duplo.Extension.<Name>.csproj` (keep the SDK
  PackageReference `ExcludeAssets="runtime"` + `nuget.config`).
- `frontend/src/app/*` — list/add/view for your fields. **Set the service's `REST_SEGMENT` to the FULL namespaced
  `extensions/<feature>-<resource>` (== manifest `restSegment`; a bare leaf 404s).** Rename every FE `Hello`/`hw`
  identifier (files, classes, selectors, routes, and a **unique** `federation.config.js` `name`) per the rename table
  in [02](reference/02-authoring-guide.md#frontend). List = `searchable-datatable` with the filter + workspace-refresh
  wiring; Add/Edit = `panel-form-accordion` + `form-field`; **Agent mode: every Add/Edit form ends with `<app-ai-disclosure />`** (ISO 42001; the scaffold carries it, [14](reference/14-forms-and-wizards.md#ai-use-disclosure-agent-mode)); Detail = the **Template-G shell the scaffold already
  carries** — keep `shared/` as copied and **rewrite the two things that are the resource's own**: the `phases()`
  computed (your lifecycle ladder, per mode) and the Result strip's Overview tiles + any further tabs
  ([19](reference/19-detail-page.md), [17](reference/17-custom-result-views.md)). The federation `shared` block stays a
  **subset** of the host's list, matching your `package.json` ([02](reference/02-authoring-guide.md#native-federation-sharing--share-the-libs-di-peer-packages-avoids-nullinjectorerror)).
  **Admin scope:** the service's `base()` is `/v1/aiservicedesk/admin/data/environment/${REST_SEGMENT}`, it
  drops `REMOTE_UserSession`, and **no admin request names a workspace** — the backend resolves the Admin
  Workspace itself. Look the provisioning ticket up with `GET <base>/{id}/ticket-status` (`ticketName`, not
  `tickets/<ws>/origin-context`), and link it to `/ai/suite/admin/tickets/chat/<name>` — never the
  service-desk route, which rejects the hidden Admin Workspace.
- `manifest.json` — `id`, `version`, `backend.{assemblyDir=<id>/<version>/backend, entryAssembly}`,
  the `resources[]` entry (`archetype:"typed"` + the five FQ type names; there is no `registrar` field),
  `skills`/`skillMappings` (**Agent mode only** — omit for Worker/Passthrough/No-provision), `frontend`. **Admin scope:** add `"scope": "admin"` to the top-level `menus[]` node and to each
  `routes[]` entry that tree links to (`path`/`relativeUrl` stay `extensions/<…>`). The build gate checks the
  controller route, the `scope` values, menu↔route scope parity, and that the FE calls the admin route.
  Keep the setup route and `frontend.setup` (next section).

### The admin setup page — every agent has one
Admins finish an agent's setup at **AI Admin → Agent Setup → {agent name}**. The template carries it; full contract
in [02](reference/02-authoring-guide.md#frontendsetup).
- **New agent:** keep all three pieces from the template. `<idName>` below is the last segment of the manifest
  `id` (template: `helloworld`); the path is unique as long as the id's last segment is. For a reverse-DNS id like
  `com.duplocloud.issue-reporter` it is `extensions/issue-reporter-setup`, not `com.duplocloud…` or the folder name:
  - the admin route `{ "path": "extensions/<idName>-setup", "scope": "admin" }` in `frontend.routes[]`;
  - `"setup": { "title": "Set up", "relativeUrl": "extensions/<idName>-setup" }` in `frontend` (same path);
  - the page `frontend/src/app/setup/*` + `settings.service.ts`, and in `extension.routes.ts` the `canMatch`
    entry that matches the setup mount by path: set `SETUP_PATH` to the same `extensions/<idName>-setup`.
    Rename per the FE rename table in [02](reference/02-authoring-guide.md#frontend). Replace the sample
    `HELLO_WORLD_TYPE` with one type definition per provider.
  - **Settings endpoint:** the platform has none for agents. Add a plain `[Authorize]` `ControllerBase` routed at
    `SETTINGS_URL` (`v1/aiservicedesk/admin/extensions/<idName>/settings`) that serves GET/PUT of one settings
    object ([02](reference/02-authoring-guide.md#frontendsetup)). Until then the localStorage fallback keeps
    values in one browser only, and provisioning can't read them. Once the controller exists, delete the 404
    fallback (the `catchError` branches, `FALLBACK_KEY`, the `local` note).
  - To use a connection at provisioning, attach its scope to the workspace or the Admin Workspace
    ([07](reference/07-scope-credentials.md#creating-the-connection--the-connections-kit) step 3) and read it from
    `spec.ScopeIds`.
- **Existing agent:** whenever you change one, check for the setup page (`frontend.setup`, its admin route, the
  page). Check in this order; the first match wins:
  1. Setup page present → update it to match the agent's features: one connection per provider the agent uses,
     plus the agent's own settings. Drop steps for features you removed.
  2. Already has an admin settings page or endpoint → make that the setup page. Mount it on the setup route through
     the `canMatch` entry and `SETUP_PATH`. Replace its provider pickers with the kit. Keep its own settings
     service; don't copy `settings.service.ts`.
     - **Hand-made providers:** if its docs or earlier versions had admins create providers by hand (usually
       Type `Other`), pass those types in `alsoTypes`, or saved connections show "Connection not found". Find
       them in the agent's README and setup docs, and the category its old picker used
       ([07](reference/07-scope-credentials.md#connections-made-by-hand)).
     - **The page must work on the admin mount**, where the URL and session have no workspace. A guard that
       rebuilds a workspace URL must allow on the setup mount (the host already admin-guards it). Hide "Back"
       links and workspace-relative navigation there, or route them sensibly. A workspace-only call must not
       block the page. Tell the mounts apart with the template's `canMatch` / `SETUP_PATH`
       (`extension.routes.ts`).
     - **Old settings route:** keep it, with a guard that returns a `UrlTree` to
       `/ai/suite/admin/<relativeUrl>` (not `redirectTo`, which keeps the old URL so the setup mount check misses).
       The guard must not fire on the setup mount itself. Remove the old menu entries and buttons that linked to it.
       Reference: the `settings` route in duploai-issue-reporter's `extension.routes.ts` (setup check in `setup-mount.ts`;
       until it merges, both are on [duploai-issue-reporter#23](https://github.com/duplocloud-internal/duploai-issue-reporter/pull/23)).
  3. No setup page → add it from the template. In the copied `settings.service.ts`, re-point the
     `REMOTE_DuploHttpClient` import to the agent's own service.
  - All three need `ng-common-lib` ≥ 0.8.0. Upgrade an older agent first
    ([UPGRADING-ng-common-lib](../../../docs/UPGRADING-ng-common-lib.md)).
- **Pick the kit level** ([20](reference/20-ui-library.md#connections-the-setup-kit)):
  1. **Level 1 `<duplo-connection-field>`** — the default; one field per provider.
  2. **Level 2 parts** (`<duplo-provider-picker>`, `<duplo-credential-form>`, `<duplo-scope-picker>`) — only when
     setup needs its own steps between provider, credential and scope.
  3. **Level 3 `ConnectionsService`** — only for a non-form UX.
- **Shared provider types:** ClickUp, Slack and Jira use the agreed type names and field keys in
  [07](reference/07-scope-credentials.md#shared-provider-types); the first registration wins.
  Form rules (error keys, your own `required` message): [14](reference/14-forms-and-wizards.md#connections-in-a-form).
- **Build check:** `scripts/validate-setup.sh <manifest.json>` runs inside `build-extension.sh` and fails the build
  on an invalid `frontend.setup` (the portal would silently drop it) or a `SETUP_PATH` that differs from it. The
  gate also fails on leftover template setup names (`hw-setup`, `HELLO_WORLD_TYPE`, `extensions/helloworld-setup`).

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
  5. **FE:** remove the ticket UI and the `<app-ai-disclosure />` (Agent-only), drop the "Needs your input" phase, compute the Worker ladder from `workerState`
     (copy `samples/worker-compute`'s `phases()`), remove `track()`/`ticketName()` and the list-row "Track Provisioning"
     item, label the add button **"Create"** (not "Provision").
- **Agent**: keep `skills/provision-*/SKILL.md` (+ `provision.sh`, write to the OWN route) and the manifest
  `skills` + `skillMappings`; keep the ticket UI and the `<app-ai-disclosure />` on every Add/Edit form. **Admin scope:** the skill writes back to the admin route —
  `RES=${DUPLO_BASE:-$DUPLO_HOST}/v1/aiservicedesk/admin/data/environment/<restSegment>/<id>` (no workspace id);
  the provisioning token covers only that resource's admin `status`/`results`. **Deprovision seam (if it creates real infra):** the platform reuses the
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
Write `$SDK_VER` into `manifest.json` `sdkVersion` — the loader checks it against the range it loads
([06-registration](reference/06-registration.md#sdk-version-pinning--why-exactness-matters)).

## Phase 4 — build backend + frontend

```bash
# SDK 1.2.0 and later ship net10.0 reference assemblies, older ones net8.0, and a net10.0 build does not load on a
# .NET 8 host. Restore runs first because a property given to publish does not reach its implicit restore.
case "$SDK_VER" in 0.*|1.0.*|1.1.*) TFM=net8.0 ;; *) TFM=net10.0 ;; esac
( cd extensions/<name>/backend && dotnet restore Duplo.Extension.<Name>.csproj -p:TargetFramework="$TFM" -p:DuploSdkVersion="$SDK_VER" \
    && dotnet publish Duplo.Extension.<Name>.csproj --no-restore -c Release -o ../dist/backend -p:TargetFramework="$TFM" -p:DuploSdkVersion="$SDK_VER" )
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
- **Local (admin token):** you may confirm the live route directly: `GET …/environment/<restSegment>` → 200
  (admin extension scope: `GET …/admin/data/environment/<restSegment>` → 200 for an admin, 403 for a user without an Admin Workspace grant, created
  rows are owned by the Admin Workspace, not your workspace, and the menu shows only in AI Admin),
  and `GET …/admin/extensions` lists it. Create one → it persists to its `extension_<entity>` collection, fires a
  provisioning ticket (Agent mode), your skill runs and fills the Result. **AI Admin → Agent Setup** lists the
  agent and opens its setup page. (Teardown: `DELETE …/admin/extensions/{id}` → route withdraws live.)

