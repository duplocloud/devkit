# 14 — Forms & multi-step wizards

Extension forms are **template-driven** (`ngForm` + `ngModel` — no Reactive Forms) and built from the platform UI
library `@duplocloud-internal/ng-common-lib`. This doc covers the field components you get for free, and the
**multi-step wizard** pattern (which the library does *not* ship a component for).

## Field components you can reuse (`SharedFormsModule`)

Import `SharedFormsModule` and use:
- `<form-field>` wrapping a `<input class="form-control" …>` / `<textarea>` — the standard labelled field.
- Validation directives: `validation-state`, `validation-errors` on the control; `form-group-errors` +
  `#fge showDetailsWhen="submitted"` on the container.
- **`<ng-select>`** — re-exported by `SharedFormsModule` (single, `[multiple]`, `[items]`). No separate import.
- `<password-field>`, `<key-val-field>` (name/value pairs), and `FormElementsCollapsableGroupComponent` (collapsible
  section) for richer inputs.
- Toggle/switch: there is no dedicated lib toggle — use a Bootstrap 4 `custom-control custom-switch` + `ngModel`
  (the host ships the Vuexy theme CSS).

The single-page create form is the `panel-form-accordion` 3-column layout — see
[02-authoring-guide](02-authoring-guide.md) and `samples/helloworld`.

## AI-use disclosure (Agent mode)

DuploCloud is ISO 42001 certified: a form whose submit hands work to an AI agent (Agent mode — the resource maps a
skill in `manifest.skillMappings`) must say so at the point of use. Every Agent-mode Add/Edit form renders the
library's `<app-ai-disclosure />` (import `AiDisclosureComponent` from `@duplocloud-internal/ng-common-lib`):

- **Single-page form** — last element inside `.form-container`, under the Cancel/Provision row (see `samples/helloworld`).
- **Wizard** — pass `[aiDisclosure]="true"` to the copied `wizard-stepper`; it renders under the footer on every step.
- **Modal form** — inside `.modal-footer`, above the buttons.

The text and link come from the deployment's branding config (brand name included) — never hardcode them. Worker,
Passthrough and No-provision forms do **not** carry it. `scripts/build-extension.sh` fails an Agent-mode extension
with no `app-ai-disclosure` under `frontend/src`.

## Multi-step wizards — there is NO library stepper

The library ships **no stepper/wizard component**, and the host's own multi-step forms (AppService, etc.) hand-roll
one in portal-internal code you can't import. So a wizard extension **copies a small local component**:
`samples/network-stack/frontend/src/app/wizard/wizard-stepper.component.ts` — `<duplo-wizard-stepper>` renders the
numbered step header (done ✓ / active / todo + progress line) and the **Back / "Step N of M" / Cancel / Next→**
footer. Only this chrome is bespoke; the step **bodies** use the field components above.

### The per-step validation pattern (template-driven)

Wrap everything in **one** `<form>`; put each step's fields in an **`ngModelGroup`**; toggle steps with **`[hidden]`
(NOT `*ngIf`)** so hidden controls stay registered; gate Next/Finish on the **current group's** validity:

```html
<form #f="ngForm" (ngSubmit)="f.valid && finish()">
  <duplo-wizard-stepper [steps]="steps" [activeIndex]="activeIndex"
                        [nextDisabled]="isStepInvalid(f)" [saving]="saving"
                        (back)="back()" (next)="next(f)" (cancel)="cancel()" (finish)="finish()">
    <div [hidden]="activeIndex !== 0" ngModelGroup="step0"> …form-field inputs… </div>
    <div [hidden]="activeIndex !== 1" ngModelGroup="step1"> …ng-select, custom-switch, etc.… </div>
  </duplo-wizard-stepper>
</form>
```
```ts
isStepInvalid(f: NgForm) { const g = f.form.get(this.steps[this.activeIndex].key); return !!g && g.invalid; }
next(f: NgForm) { if (!this.isStepInvalid(f) && this.activeIndex < this.steps.length - 1) this.activeIndex++; }
back()          { if (this.activeIndex > 0) this.activeIndex--; }
finish()        { this.svc.create(name, this.model).subscribe(…); }   // assemble spec on the last step
```

Why `[hidden]` and not `*ngIf`: `*ngIf` destroys a hidden step's controls, so they drop out of the form and can't be
validated as a group; `[hidden]` keeps them registered while off-screen.

Conditional required fields (e.g. HPA/LB blocks) use `[required]="condition"` so a hidden block doesn't block Next.

**On create failure**, surface the REAL server error — see [15-error-handling](15-error-handling.md). Standard forms
call `formGroupErrors.reportError(err)`; the wizard sample feeds `extractErrorMessage(err)` into
`<duplo-wizard-stepper [error]>`. Never read `err.error.message` (that's the generic "Invalid request" title).

## Accordion multi-panel (V2) — the non-linear alternative

Choose the **stepper** for linear Step 1→2→3 flows; choose the **accordion multi-panel** shape when the form
is a few parallel PANELS the user can jump between (the platform's own add-workspace V2 shape: Basic /
Advanced). No sample ships this today — build it from this recipe:

- Wrapper: `card panel-form-accordion` with a title row, then one `panel-form-panel` accordion item per
  panel. **Ng-Bootstrap 21 has only the DIRECTIVE accordion API** — `ngbAccordion` / `[ngbAccordionItem]` /
  `ngbAccordionCollapse` / `ngbAccordionBody` with an inner `<ng-template>`; the pre-15 `<ngb-accordion>` +
  `<ngb-panel>` component API is not in ng-bootstrap 21.
  ```html
  <div ngbAccordion #acc="ngbAccordion" [closeOthers]="true" [animation]="true" [destroyOnHide]="false">
    <div [ngbAccordionItem]="'basic'" class="panel-form-panel" [collapsed]="false">
      <div ngbAccordionCollapse><div ngbAccordionBody><ng-template>
        <div class="d-flex justify-content-between">
          <div class="panel-content-title"><h4>Basic</h4><p class="panel-content-title-sub-text">…</p></div>
          <div class="panel-content-form">
            <form #basicForm="ngForm" (ngSubmit)="submitBasic()" novalidate> … <button>Next</button> </form>
          </div>
          <ng-template *ngTemplateOutlet="panelSideNav; context: { $implicit: 'basic' }"></ng-template>
        </div>
      </ng-template></div></div>
    </div>
    <!-- one more [ngbAccordionItem]="'advanced'" panel … -->
  </div>
  ```
- `[destroyOnHide]="false"` keeps collapsed panels' controls registered (values + validity survive jumps).
- **Side-nav jump navigation**: ONE shared `<ng-template #panelSideNav let-active>` rendered per panel via
  `*ngTemplateOutlet`, listing every panel with the active one highlighted and each title clickable —
  `viewChild(NgbAccordionDirective)` + `acc().expand(id)` jumps.
- **Validation is per-panel**: each panel has its own `NgForm` (`viewChild<NgForm>('basicForm')`), the panel's
  Next submits it, and Create is gated on ALL panels valid — on a failed Create, `markAllAsTouched()` every
  panel form so errors show in panels the user never opened.
- **Remote caveats** (host V2 code uses two things an extension remote cannot): `*blockUI`/`@BlockUI` —
  ng-block-ui is neither an extension dependency nor a shared singleton; use a local `saving` signal for the
  submit button. `SUCCESS_REPORTER`/`ERROR_REPORTER` — host-provided InjectionTokens; a remote bundles its own
  lib copy, identities differ, injection throws **NG0201** — render form-level errors inline instead.
- Hide the accordion's own header chrome in the component SCSS; navigation is the side nav + Next buttons.

## Wizard polish checklist — what "looks finished" means

Every item is worked in `samples/network-stack`'s add component; a generated wizard missing these reads as a
prototype:

- **Title + subtitle via the stepper's `[title]`/`[subtitle]` inputs** — never wrap the stepper in another
  card to fake a heading. The stepper is a centered card (`[maxWidth]`, default 900px).
- **Form column ~640px, centered** (`.form-narrow { max-width: 640px; margin: 0 auto; }`) — fields never
  hug the left edge of a full-bleed body.
- **Next gated on in-flight fetches** — `[nextDisabled]="isStepInvalid(f) || stepBusy()"`; the user must not
  be able to advance past a still-loading dropdown.
- **Async ng-selects carry their state**: `[loading]`, and a placeholder per state
  (`'Loading…'` / `'Select …'` / `'No … in this workspace'`). Rich options via `<ng-template ng-option-tmp>`
  (secondary muted text). Dependent selects: `[disabled]` until the parent has a value, and RESET the
  dependent value + errors when the parent changes.
- **Empty states say HOW to fix it** (a `.field-hint` under the control: "Attach an AWS scope to this
  workspace, then reopen this form") — not just that the list is empty.
- **Per-field guidance** — a one-line `.field-hint` under non-obvious fields; per-field ASYNC errors render
  under their control (the stepper's `[error]` banner is for submit failures only).
- **The Review step shows EVERY earlier choice**: ids resolved to human labels (the scope's NAME via a
  computed lookup, never a GUID), secrets masked (`••••••`), blanks rendered `(empty)` — a review that
  omits a step defeats confirm-before-provision.
- **Contextual error fallback**: `extractErrorMessage(err) || 'Could not create the <resource>.'` — name
  the action that failed.
- **AI-use disclosure** — Agent-mode wizards pass `[aiDisclosure]="true"` to the stepper
  ([above](#ai-use-disclosure-agent-mode)).

## Dynamic fields from a remote schema

When step N's fields are DEFINED by data fetched after a step-(N-1) selection (a job's parameters, a chart's
values, a provider's options): fetch the definitions on the parent's `(ngModelChange)`, seed typed defaults
into a `values` map, and render one control per definition —

```html
@if (defsLoading()) { <p class="text-muted">Loading fields…</p> }
@for (def of defs(); track def.name) {
  <form-field>
    <label class="element-label">{{ def.label }}{{ def.required ? ' *' : '' }}</label>
    @switch (def.kind) {
      @case ('bool') {
        <div class="custom-control custom-switch">
          <input type="checkbox" class="custom-control-input" [id]="'f_' + def.name"
                 [name]="'field_' + def.name" [(ngModel)]="values[def.name]" />
          <label class="custom-control-label" [for]="'f_' + def.name">
            {{ values[def.name] ? 'true' : 'false' }}
          </label>
        </div>
      }
      @case ('textarea') {
        <textarea class="form-control" rows="4" [name]="'field_' + def.name"
                  [(ngModel)]="values[def.name]" [required]="def.required"
                  validation-state validation-errors></textarea>
      }
      @case ('password') {
        <input type="password" class="form-control" autocomplete="new-password"
               [name]="'field_' + def.name" [(ngModel)]="values[def.name]"
               [required]="def.required" validation-state validation-errors />
      }
      @default {
        <input type="text" class="form-control" [name]="'field_' + def.name"
               [(ngModel)]="values[def.name]" [required]="def.required"
               validation-state validation-errors />
      }
    }
    @if (def.description) { <div class="text-muted field-hint mt-25">{{ def.description }}</div> }
  </form-field>
}
```

Rules: reset `values` + per-field errors whenever the parent selection changes; gate Next on the fetch
(`stepBusy()`); mask `password` kinds in the Review step. (The `custom-switch`/textarea/password markup
above doubles as the worked snippets for those widgets.)

## Sample

- **`samples/network-stack`** — the worked wizard: a 3-step linear add form (Basics → Network → Review) with
  per-step validation, repeatable subnet rows, a `custom-switch` (DNS hostnames), loading-aware selects, an
  empty-state hint, a label-resolved Review step, and the self-contained
  `wizard/wizard-stepper.component.ts` (title/subtitle/maxWidth inputs) to copy.

## Challenges / constraints (know before you build)

- **No reusable stepper** anywhere (library or host) → copy the sample's `wizard-stepper.component.ts`.
- **`panel-form-accordion` is markup, not a component**, and the lib ships **compiled CSS only** → any layout/stepper
  chrome CSS lives in the component's `styles` (see the samples).
- **Template-driven only** — Reactive Forms are forbidden by house style.
- **No composite widgets** beyond `key-val-field` (no repeatable-rows/tabs-per-item component) → assemble rich
  sections from primitives + `@for`/`@if` (see `network-stack`'s repeatable subnet rows).
