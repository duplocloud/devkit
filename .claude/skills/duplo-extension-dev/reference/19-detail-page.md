# The detail page — the shell every resource view is built on

An extension's detail view must be indistinguishable from the platform's own resource pages. The
platform's resource pages follow one shell (**Template G**), and the Extension Studio details page
(`portal/ai-studio/src/app/environment/extensions/view-extension/` in duplo-ui) is its reference
implementation. This doc is that page's anatomy, ported for a remote, plus the one thing the platform page
can't give you: how to derive **your** resource's provisioning phases.

**The Result body is always hand-written for the resource** ([09-result-templates](09-result-templates.md)):
a result view is real markup — tiles, tables, panels — describing what *this* resource produced. What goes
inside the Result strip (lazy panels, polling, never a dead empty state) is
[17-custom-result-views](17-custom-result-views.md); this doc is the shell it sits in.

## What you copy from the scaffold

Every extension carries its own copy of the shell — as the platform does (the styles are imported **per
component**, never globally; the common-lib exports none of them). From
[`templates/helloworld/frontend/src/app/shared/`](../templates/helloworld/frontend/src/app/shared/):

| File | What it is |
|---|---|
| `_g-structure.scss` | Tokens (`$g-*` = platform CSS vars **with fallbacks**) + the G placeholders: `%g-card`, `%g-h`, `%g-tl`, `%g-tv`, `%g-tabs`, `%g-btn-ghost`, `@mixin g-dot-badge`, `@mixin dots-loader`. Emits nothing by itself. |
| `detail-page.scss` | The page rules — header, `.seg`, `.g-cols`, main card, `.g-tabs`, sections, tiles, `.g-kv`. Wire it with `styleUrl: '../shared/detail-page.scss'` on the **view** component. |
| `lifecycle-rail.component.ts` + `.scss` | `<ext-lifecycle-rail>` — the right rail: `Lifecycle` (phase timeline + **Track status**), `Attached` (facts), optional callout. You feed it phases; it only draws them. |
| `status-badge.component.ts` | `<app-status-badge>` in the G shape (square 6px, currentColor dot, soft `badge-light-*`). |

The `$g-*` tokens carry fallbacks (`var(--border-color, #ebe9f1)`) because `--primary-50` and the
`--neutral-*` vars are emitted by the portal build, not declared in the vendored `_theme-vars.scss`;
a missing var degrades to the same Vuexy default rather than to transparent. `dots-loader` is
vendored for the same reason (the host's `scss/dots-loader` isn't in the lib).

## Anatomy

```
<div class="ext-detail-page">                                    ← page inset (see caveat below)
  <header class="g-head">                                        ← NO card: a flex row on the page background
    <span class="g-tile-ic"><i data-feather="…"></i></span>       ← 56px icon tile, --primary-50
    <div class="g-head-main">
      <div class="g-head-t"> <h1>name</h1> <app-status-badge/> [dots-loader while working] </div>
      <div class="g-meta">   Created: … · <one key spec fact>  </div>
    </div>
    <div class="g-actions">
      <div class="seg"> Spec | Result </div>                     ← segmented switcher, DARK active segment
      [<button class="btn btn-sm g-btn-ghost">Plan</button> …]  ← resource-wide actions, ghost (optional)
      <button class="btn btn-sm btn-primary">Ask agent</button>  ← Agent mode only — opens the ticket
      <div ngbDropdown> ⋮ Edit · Deprovision/Delete </div>
    </div>
  </header>

  <div class="g-cols">                                           ← grid: minmax(0,1fr) 280px
    <section class="g-card g-main">                              ← the only white card on the left
      @if spec  → .g-sec.pt-1 "Requested spec" + .g-tiles.c3    ← 1rem top gap; FIRST child of .g-main
      @else     → <scrollable-nav-tab> ul.nav.nav-tabs.flat-tabs.g-tabs … </scrollable-nav-tab>
                  <div [ngbNavOutlet] class="mt-50">             ← the strip is the FIRST thing: no heading above it
                  (Overview first; Ask AI last when opted in)
    </section>
    <ext-lifecycle-rail [phases] [attached] [callout] [trackable] (track)/>
  </div>
</div>
```

Rules the platform page follows and so do you:

- **The header has no background.** Only `.g-card` / `.g-rcard` / `.g-tile` are white. If you find
  yourself wrapping the header in a card, stop.
- **`Spec | Result` is the `.seg` switcher.** Default to **Result** when a result exists, else Spec.
- **Tabs live inside the main card**, styled by `.g-tabs` (quiet items, 2px primary underline). Overview
  first. Whatever the agent is waiting on (`Blocked` / `WaitingForApproval`) comes **first inside
  Overview**, then faults, then tile sections.
- **The Spec view is `.g-sec.pt-1`, the first child of `.g-main`.** That `pt-1` (1rem in this theme)
  on top of the card's 2px is the platform's gap. `detail-page.scss` also enforces it structurally
  (`.g-main > .g-sec:first-child { padding-top: 1rem }`) so a dropped utility class can't flatten the
  section heading against the card edge.
- **Tiles, not bootstrap rows.** `.g-sec` › `.g-sec-h h3` › `.g-tiles.c3` › `.g-tile` › `.g-tl` label +
  `.g-tv` value (`.mono`, `.trunc`, `<small>` hint). `.wide` spans 2, `.full` spans the row. Tables of
  key/values use `.g-kv`. Faults and errors are the platform's alert verbatim:
  `alert alert-danger py-1 px-2 mb-1`.
- **Actions have two homes — neither is above the tabs.** Resource-wide actions (Plan / Apply, Open in
  console, Refresh) are `btn btn-sm g-btn-ghost` buttons in the **header's `.g-actions`**, between the
  `.seg` and "Ask agent" (`samples/network-stack`). Actions on one tab's data live **inside that panel**,
  in a `.g-sec-h .g-sec-actions` row within the section. **Never a heading or action bar above the tab
  strip**: in the Result view the `<scrollable-nav-tab>` is the first element in the card.
- **The rail is the timeline.** "Track status" lives inside the `Lifecycle` card, beside the phases it
  explains. There is no footer, no `subStatus` strip — the live beat is the active phase's subtitle.
- **Badges are G badges.** Square 6px with a dot; `<app-status-badge>` already is. Don't mix in pills.
- **Poll while working, stop at terminal.** The timeline only moves if the resource refreshes; every
  sample runs a 3s `interval` while non-terminal and unsubscribes on `DestroyRef`.

### The page-inset caveat

`.ext-detail-page { margin: -10px -24px 0 -27px; padding: 12px 16px 24px; }` pulls the page back to
the platform's tighter inset — the same negative-margin trick the platform's own pages use against the
host layout's content padding. A remote mounts in that same content area, so it matches; if your
extension renders somewhere with different padding, **delete the block** rather than tune it.

## Deriving phases — the part that is yours

The Studio page hardcodes four phases for the Extension resource (Created → Authoring code → Needs
your input → Deployed) and computes their state from `ResourceStatus` plus its own result fields
(`loadState`, `version`). **Do the same for your resource**: name the real stages it goes through,
then map status + result onto them. A generic New→Processing→Complete ladder is not a timeline; it's
the status badge written vertically.

`LifecyclePhase = { label; subtitle?; state: 'done'|'now'|'todo'|'warn'|'fail'; action? }`. Compute
the array in a `computed()` from `item()`; the rail redraws when the poll refreshes it.

| Signal | Use it for |
|---|---|
| `status` | which phase is `now`, which are `done`/`todo`; `Failed` → `fail` on the phase that was running |
| `subStatus` | the **live subtitle** of the `now` phase (the agent's/worker's beat) |
| `blockedReason` | the subtitle of "Needs your input" while `Blocked`; `WaitingForApproval` → "Approval pending" |
| `faults[0]` | the subtitle of a `fail` phase when `subStatus` is empty |
| `createdAt`, `updatedAt` | timestamps on Created / the final phase |
| `result.*` | whether later phases actually happened (a `vpcId`, a `loadedAt`, a run log entry) — not just status |
| `workerState.*` (Worker) | `nextAttemptAt` while queued, `lastAttemptAt`/`retryCount` while reconciling, `lastVerifiedAt` when converged, `lastFailedCode` on failure |
| `action` | an inline link on the `now` phase — "Review" → open the ticket while the agent waits |

Use `warn` for "done, but stale": a plan with changes nobody applied; a spec edited after the worker
converged (`Updated` with a result present); a live version behind the built one. The Studio's
Deployed phase does exactly this.

### Ladders by provisioning mode — and the ticket UI that goes with them

Only **Agent** mode has a provisioning ticket. So only Agent-mode views render the header **Ask agent**
button, the rail's **Track status** (`[trackable]="true"`) and a **"Needs your input"** phase; their Add/Edit forms carry the `<app-ai-disclosure />` ([14](14-forms-and-wizards.md#ai-use-disclosure-agent-mode)); they also
keep `track()`/`ticketName()` and the list-row "Track Provisioning" item. Worker, Passthrough and
No-provision views omit all of those, use the ladders below, and label the add button **"Create"**
(not "Provision"). Opt-in Ask AI sessions ([16-ask-ai](16-ask-ai.md)) are user-created and work in
every mode regardless.

**Agent**:

```
Created ──▶ Provisioning ──▶ Needs your input ──▶ Ready
            now while New/TicketCreated/Processing   now while Blocked/WaitingForApproval   done at Complete/Updated
            subtitle = subStatus                     subtitle = blockedReason · action Review
            fail at Failed (subStatus | faults[0])   done once Ready
```

Rename "Provisioning" and "Ready" to what the agent actually does — `samples/network-stack` splits the
middle into **Provisioned → Planned → Awaiting approval → Applied**, reading `result.actions` for the
plan/apply runs and `result.vpcId` for the initial stack.

**Worker** (`workerState` is the audit trail):

```
Created ──▶ Queued ──▶ Reconciling ──▶ Converged
            New/Updated  Processing        Complete
            nextAttemptAt  subStatus | Attempt N   Verified lastVerifiedAt
                           fail: lastFailedCode    warn when Updated with a result (spec changed, not yet re-converged)
```

**Passthrough** (the request itself is the work):

```
Created ──▶ Applying ──▶ Applied
            New/Processing (brief)   Complete/Updated · uid · updatedAt
            fail at Failed
```

**No-provision**: Created → Ready (`Complete` on save); enrichment fills the Result on read.

Deprovision states (`DeProvisioning`, `DeprovisionInitiated`, `DeProvisioned`, `DeprovisionFailed`) are
not "working" — the header badge already says what is happening, so the ladder shows neutral states
with no active pulse.

## Attached + callout

`Attached` is the rail's second card: two to four facts an operator wants at a glance — counts
(subnets, children, pods, keys), retries, last verified. `callout` is **data-derived and conditional**:
show it when the data says something is off (unapplied plan, failed reconcile code, missing scope),
never as decoration. Both are plain inputs on `<ext-lifecycle-rail>`.

## Worked examples

| Sample | Shows |
|---|---|
| [`templates/helloworld`](../templates/helloworld/frontend/src/app/view/view-hello.component.ts) | The annotated Agent-mode reference — every rule above, minimal result |
| [`samples/network-stack`](../../../../samples/network-stack/frontend/src/app/view/view-network-stack.component.ts) | Domain ladder from a run log, `warn` for unapplied changes, Plan/Apply as header ghost buttons, tabs + panels, callout |
| [`samples/worker-compute`](../../../../samples/worker-compute/frontend/src/app/view/view-calculator.component.ts) | Worker ladder from `workerState`, no Track, `warn` after a spec edit |
| [`samples/passthrough-configmap`](../../../../samples/passthrough-configmap/frontend/src/app/view/view-configmap.component.ts) | Passthrough ladder, `.g-kv` data table shared between Spec and Result via `ngTemplateOutlet` |
| [`samples/parent-child`](../../../../samples/parent-child/frontend/src/app/parents/view-parent.component.ts) | A `Children` tab with the `searchable-datatable` inside the main card, `.tab-count` |

## Scope

This shell is the **detail page**. List pages keep `searchable-datatable`; add/edit pages keep
`panel-form-accordion` ([02-authoring-guide](02-authoring-guide.md#frontend)).
