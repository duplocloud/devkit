# 20 — The UI library: what `@duplocloud-internal/ng-common-lib` gives you

Everything the platform UI library exports, what each piece is for, how to import it, and whether it works
inside an extension remote. Check here before hand-rolling a table, form control, viewer or modal — the
platform almost certainly ships it already, and using it is what makes your pages match the suite.

Written against **0.3.0**. The source of truth is `portal/common-lib/public-api.ts` in duplo-ui; exact
signatures are in the installed package — see [Checking an exact API](#checking-an-exact-api).

## Rules

1. **Look here before writing markup.** Tables, form fields, validators, JSON/YAML viewers, copy buttons,
   confirm dialogs, spinners and terminals all exist. Hand-rolling one is the most common way an extension
   stops looking like the platform.
2. **Import from the package root only** — `@duplocloud-internal/ng-common-lib`. Never a deep path into it.
3. **Standalone piece → add the class to `imports`. Non-standalone → import the module that exports it**
   ([Importing](#importing)). `CommonLibComponentsModule` covers most of them.
4. **Host services come through `REMOTE_*` tokens, never the class** ([Host services](#host-services--use-the-remote_-tokens)).
5. **Don't gate UI with `disableForReadonlyUser` / `hideForReadonlyUser`** — they do nothing in a remote.
6. **Input types are not checked.** The frontends build with `strictTemplates: false`: a misspelled input
   fails the build (`NG8002`), but a wrong *shape* — say `string[]` where `FilterPill[]` is expected — compiles
   and renders wrong. Match the types in the [Recipes](#recipes), or read them from the `.d.ts`.
7. **The detail-page shell and result tiles are not chosen here** — [19-detail-page](19-detail-page.md) and
   [17-custom-result-views](17-custom-result-views.md) rule those.

## Pick a component

| You need | Use | Recipe |
|---|---|---|
| A list of resources | `searchable-datatable` | [02](02-authoring-guide.md#frontend) + [table slots](#table-slots-filters-actions-alert) |
| A facet next to the table's search box | `app-filter-pills` in `[datatable-filters]` | [table slots](#table-slots-filters-actions-alert) |
| Row actions beyond Add / Edit | `searchable-datatable` `[extraActions]` | [table slots](#table-slots-filters-actions-alert) |
| A short child list inside a detail tab | `app-expandable-list` | [expandable list](#expandable-list) |
| A form field, validator or error summary | `SharedFormsModule` | [14-forms-and-wizards](14-forms-and-wizards.md) |
| The real reason an API call failed | `extractErrorMessage`, `[form-group-errors]` | [15-error-handling](15-error-handling.md) |
| A delete / deprovision confirmation | `DeleteConfirmationModalService.openGeneric` | [confirm dialogs](#confirm-dialogs) |
| A yes/no confirmation | `ConfirmationModalService.openWithMessage` | [confirm dialogs](#confirm-dialogs) |
| Raw spec or result as JSON / YAML | `app-view-json-comp` / `app-view-yaml-comp` | [JSON / YAML viewer](#json--yaml-viewer) |
| A copy button next to an ID, ARN or command | `copy-to-clipboard` / `app-code-block-with-copy` | [copy buttons](#copy-buttons) |
| Log or command output | `app-xterm-block` | [terminal output](#terminal-output) |
| An inline loading indicator | `app-spinner` | [small pieces](#small-pieces) |
| "3 minutes ago", pretty-printed JSON | `timeAgo`, `prettyJson` pipes | [small pieces](#small-pieces) |
| A breadcrumb for an add / edit page | `REMOTE_CoreConfigService` | [breadcrumbs](#breadcrumbs) |

## Read first — how the lib reaches your remote

The lib is **bundled into your remote, not shared with the host**
([`federation.config.js`](../templates/helloworld/frontend/federation.config.js): *"deliberately NOT shared"*).
Your remote runs its own copy of every lib class. That splits the exports four ways:

| Kind | Works in a remote? | Why |
|---|---|---|
| Components, directives, pipes, utils, models | **Yes** | They hold no host state. Their DI peers (`@ng-bootstrap`, `ngx-datatable`, `ngx-translate`, …) *are* shared, so they resolve the host's instances. |
| Host services — session, HTTP client, config | **Only via a `REMOTE_*` token** | Injecting the lib's class gives you your remote's own fresh instance, not the host's. See [Host services](#host-services--use-the-remote_-tokens). |
| Host-app plumbing — guards, interceptors, `forRoot` modules | **No** | They wire the host application. See [Not for remotes](#not-for-remotes). |
| Read-only-user directives | **No effect** | They read `userRoleInfo`, which only the host's session holds. Your copy has none, so the element is never disabled. The server enforces permissions anyway — [18-access-control](18-access-control.md). |

## Importing

Two shapes. Import whichever the piece needs into your standalone component's `imports`:

- **Through an NgModule** — non-standalone pieces only come this way. Importing an NgModule from a standalone
  component is fine and is how the samples do it.
- **The class directly** — standalone components. Some are also re-exported by a module; either works.

| Module | Brings in |
|---|---|
| `CommonLibComponentsModule` | The broad one. `CommonModule`, `NgbModule`, Material icons, the detail-view and list-view families, `scrollable-nav-tab`, `copy-to-clipboard`, JSON/YAML viewers, sidecards, mini-card, filter pills, status filter — **and** it re-exports `SearchableDatatableModule`, `ConfirmationModalModule`, `HelpModule`, `BlockUIModule` and `RestrictElementAccessModule`, so you rarely need those separately |
| `SharedFormsModule` | Every form field, validator and error component (45 exports) |
| `SearchableDatatableModule` | `searchable-datatable` + `NgbModule`, `NgxDatatableModule` — for a list component that needs nothing else |
| `ServersideDatatableModule` / `TokenPaginatedDatatableModule` | The two server-paged tables |
| `ConfirmationModalModule` | The confirm / delete-confirm modal components |
| `CorePipesModule` | 8 of the 11 pipes |
| `HelpModule` | `help-icon`, `[navHelp]` |
| `CoreDirectivesModule` | `[data-feather]` icons, `[rippleEffect]` |

A component mixing both shapes. No `changeDetection` property, state in signals — [use-ng22](../../use-ng22/SKILL.md):

```ts
import { Component } from '@angular/core';
import {
  CommonLibComponentsModule,   // NgModule: viewers, copy-to-clipboard, scrollable-nav-tab, the table, modals
  SpinnerComponent,            // standalone: add the class itself
  TimeAgoPipe,                 // standalone pipe
} from '@duplocloud-internal/ng-common-lib';

@Component({
  selector: 'wd-result-panel',
  imports: [CommonLibComponentsModule, SpinnerComponent, TimeAgoPipe],
  template: `…`,
})
export class ResultPanelComponent {}
```

## Lists & tables

| Selector | Import | Use for | Example |
|---|---|---|---|
| `searchable-datatable` | `SearchableDatatableModule` | Client-side list: search box, paging, Add button, row actions. It emits `(filter)` but **does not filter** — see [02](02-authoring-guide.md#frontend). | every sample |
| `serverside-datatable` | `ServersideDatatableModule` | Server-side search and paging; debounces the search and emits page requests. | — |
| `token-paginated-datatable` | `TokenPaginatedDatatableModule` | APIs that page by continuation token (`(loadPage)`). | — |
| `app-list-header` · `app-list-stats` · `app-list-stat-card` | `CommonLibComponentsModule` | Page title row plus a strip of summary count cards above a table. | — |
| `app-filter-pills` | `CommonLibComponentsModule` | Single-select facet pills (`options`, `value`, `(valueChange)`). | — |
| `app-flat-status-filter` / `app-flat-dropdown-filter` | module / class | Status tabs; a flat dropdown filter. | — |
| `app-card-grid-toolbar` · `app-list-card` · `app-list-card-grid` · `app-list-page-header` | class | A card-grid list instead of a table: toolbar with search and sort, cards, count header. | — |
| `app-expandable-list` | class | A short list whose rows expand in place, with its own search. Row body via an `#elRow` template. | — |

`FilterTableUtils.searchByFields()` / `.searchInAllFields()` filter rows for any of these.

## Detail pages

| Selector | Import | Use for |
|---|---|---|
| `app-detail-layout` · `app-detail-header` · `app-detail-section` | `CommonLibComponentsModule` | Page shell, header (mark, title, status, actions), body sections |
| `app-detail-fact` · `app-stat-grid` · `app-stat-card` | `CommonLibComponentsModule` | Label/value facts and stat tiles |
| `app-detail-kv` · `app-detail-empty` | `CommonLibComponentsModule` | Key/value table; empty state with an action |
| `app-detail-attached` · `app-detail-timeline` · `app-detail-callout` | `CommonLibComponentsModule` | Side-rail panels: attached facts, event timeline, callout |
| `scrollable-nav-tab` | `CommonLibComponentsModule` | Horizontally scrolling `ngbNav` tab strip — every sample |
| `view-with-sidecards` · `view-header-card` · `sidecard` · `mini-card` | `CommonLibComponentsModule` | The older detail layout; the portal is migrating off it |

> **The detail-page shell is ruled by [19-detail-page](19-detail-page.md), not by this table.** Extension
> detail pages use the Template-G shell so they match the Extension Studio page they sit next to. The
> `app-detail-*` family is listed so you know it exists; don't switch the shell to it.

## Forms & validation

Everything below comes from `SharedFormsModule`. Field usage and the wizard pattern: [14-forms-and-wizards](14-forms-and-wizards.md).

| What | Selectors |
|---|---|
| Field wrapper, label, errors | `form-field`, `form-field-errors`, `form-field-alert`, `[validation-state]`, `[validation-errors]` |
| Whole-form error summary | `[form-group-errors]` — also the `ErrorReporter` for API errors ([15-error-handling](15-error-handling.md)) |
| Special inputs | `password-field`, `generic-form-field`, `app-form-key-val-field`, `app-key-val-config-field`, `app-form-elements-collapsable-group`, `form-field[expandableModalField]` |
| Uniqueness / list checks | `[notExists]`, `[notExistsCase]`, `[notStartsWith]`, `[notStartsWithCase]`, `[asyncNotExists]` |
| Format checks | `[jsonObject]`, `[jsonArray]`, `[jsonKeyStringValue]`, `[yaml-validation]`, `[yaml-map-validation]`, `[xml-validation]`, `[ini-validation]`, `[validCron]`, `[unicode]`, `[portRangeValidator]`, `[notEqualValidator]` |
| Parent-form access | `form` (`FormRefDirective`) makes the form injectable into child components; `[use-parent-form]` joins a child's controls to it |

> **Two directives attach on their own.** `InputTextTrimDirective` matches every `input[type="text"][name]` and
> trims whitespace from the model value. `EmailValidatorDirective` matches every `[type="email"]`. Both are live
> wherever `SharedFormsModule` is imported — a leading space the user typed will not reach your model.

Standalone extra: `[yamlValue]` (`YamlValueValidationDirective`). Programmatic validators: `DuploValidators`.

## Viewers & editors

Apart from the JSON/YAML viewers, each of these is a standalone class, so it and its dependency are only
bundled into your remote if you import it. Dependencies marked *shared* come from the host at runtime instead.

| Selector | Import | Use for | Depends on |
|---|---|---|---|
| `app-view-json-comp` · `app-view-yaml-comp` | `CommonLibComponentsModule` | Read-only (or editable) JSON / YAML with download | `file-saver` |
| `app-code-editor` | class | Editable code with syntax highlighting | CodeMirror |
| `markdown-editor` · `app-markdown-edit-modal` | class | Markdown edit + preview | CodeMirror, `ngx-markdown` *(shared)* |
| `app-yaml-snippet-editor` | class | YAML editor with insertable snippets | `ngx-monaco-editor-v2` *(shared)* |
| `app-diff-render` · `app-diff-merge` | class | Side-by-side diff; two-way merge | `diff2html` / `ngx-monaco-editor-v2` *(shared)* |
| `app-render-file` · `app-render-file-preview-modal` | class | Preview a file by type, incl. DOCX and PPTX | `docx-preview`, `pptx-renderer` (lazy) |
| `app-xterm-block` · `app-xterm-socket` | class | Static terminal output; live terminal over a socket | xterm.js (+ `socket.io-client`) |
| `app-file-editor-wrapper` · `app-entity-file-editor-wrapper` | class | File tree + tabs + editor | CodeMirror |
| `app-code-block-with-copy` · `copy-to-clipboard` | `CommonLibComponentsModule` | Code block with a copy button; copy any value | — |

The file editor's parts also work on their own: `app-file-tree` (+ `app-file-tree-node`), `app-file-tabs`,
`app-file-icon`, `app-file-details-modal`.

The JSON/YAML viewers' **edit** control uses the read-only-user check, so in a remote it never locks for
read-only users. Viewing is unaffected.

## Modals & feedback

| Symbol | Use for |
|---|---|
| `DeleteConfirmationModalService` | Delete confirmation — `samples/network-stack` |
| `ConfirmationModalService` | Any yes/no confirmation |
| `ViewDataModalService` · `ViewJsonModalService` · `MarkdownEditModalService` | Open a data / JSON / markdown viewer in a modal |

Open modals through these services — the matching `*ModalComponent` classes are what they render.

| Symbol | Use for |
|---|---|
| `app-spinner` (class) · `ng-block-ui` exports (`BlockUIModule`, `@BlockUI`) | Inline spinner; loading overlay |
| `extractErrorMessage()` · `ErrorReporter` / `ERROR_REPORTER` | Surface the real API error — [15-error-handling](15-error-handling.md) |
| `status-with-style` (class) | A status label with its colour |

> **Report form and action errors inline** — the form banner, per [15-error-handling](15-error-handling.md).
> Toasts do reach the host: `ngx-toastr` is a shared singleton, so `SharedAlertsService` shows the host's
> toast, and the two confirm dialogs raise one **on their own** ([confirm dialogs](#confirm-dialogs)). Don't
> report the same failure a second time.

## Help & small UI

`help-icon`, `[navHelp]` (`HelpModule`) · `[data-feather]`, `[rippleEffect]` (`CoreDirectivesModule`) ·
`IconModule` (Material icons).

## Pipes

| Pipe | Standalone | Does |
|---|---|---|
| `prettyJson` · `prettyYaml` | yes | Pretty-print an object as JSON / YAML |
| `timeAgo` | yes | "3 minutes ago" |
| `ansiToHtml` | yes | Render ANSI-coloured log output |
| `filter` · `orderby` · `initials` · `striphtml` · `safe` | via `CorePipesModule` | Filter / sort an array, initials, strip HTML, bypass sanitizing |
| `uiConfig` | via `CorePipesModule` | Read a host UI setting (`window.DUPLO_UI_CONFIG[key]`) |

`safe` bypasses Angular's sanitizer — never feed it user-controlled HTML.

## Utilities

| Export | Use for |
|---|---|
| `FilterTableUtils` | Row search for tables — every sample |
| `extractErrorMessage` | Pull the human reason out of an API error |
| `EnumUtils` (+ `EnumSelectOption`, …) | Enum → dropdown options, enum value maps |
| `NameUtils` | Platform name prefixes and length limits (`withAndWithout`, `fieldAllowedLength`) |
| `StringUtils` | `isEmpty`, `safetrim`, URL / base64 encoding, casing |
| `DateUtils` · `JSONUtils` · `YamlUtils` · `CommonUtils` | Date, JSON, YAML and general helpers |
| `misc` — `generateUniqueId`, `downloadJsonAsFile`, `formatNumberWithK`, `openLinkInNewTab`, `scrollTo`, … | One-off helpers |
| `resolveAvatarColor` · `closeModalsOnNavigation` · `redirectToParentOnError` | Avatar colour; close modals on route change; resolver fallback |
| `SubDestroyService` | `takeUntil` teardown for subscribe-heavy code — prefer `takeUntilDestroyed` in new code ([use-ng22](../../use-ng22/SKILL.md)) |
| `DUPLOCONST`, `TENANT_CONSTS`, `DUPLO_CUSTOM_EVENTS` | Platform constants |

Models (`UserTenant`, `UserPrincipal`, `KeyValuePair`, workspace / settings / infrastructure types) are exported
for typing responses. They are types only — they give you no data.

## Recipes

Each one is checked against the lib's source. Signals for state, `@if`/`@for`, standalone — [use-ng22](../../use-ng22/SKILL.md).

### Table slots: filters, actions, alert

`searchable-datatable` takes four kinds of projected content. The filter / refresh wiring every list needs is
in [02](02-authoring-guide.md#frontend); this adds the rest.

```html
<searchable-datatable [rows]="rows()" (filter)="filterUpdate()" (add)="add()" addLabel="Add Widget"
                      [extraActions]="actions" (action)="onAction($event)" [showAlert]="!!notice()">
  <app-filter-pills datatable-filters [options]="statusPills" [value]="status()" (valueChange)="status.set($event)" />
  <button datatable-actions type="button" class="btn btn-sm btn-outline-primary" (click)="export()">Export</button>
  <ngb-alert type="warning" [dismissible]="false">{{ notice() }}</ngb-alert>
  <ngx-datatable-column name="Name" prop="name"></ngx-datatable-column>
</searchable-datatable>
```

```ts
import { FilterPill, SearchableDatatableExtraAction } from '@duplocloud-internal/ng-common-lib';

protected readonly statusPills: FilterPill[] = [{ value: 'Complete', label: 'Complete' }, { value: 'Failed', label: 'Failed' }];
protected readonly status = signal('');   // '' is the All pill
protected readonly actions = [new SearchableDatatableExtraAction({ name: 'sync', label: 'Sync now', icon: 'refresh-cw' })];
protected onAction(name: string): void { /* name === 'sync' */ }
```

- **`[datatable-filters]`** sits beside the search box. The pill only reports a value — fold `status()` into the
  same `computed()` that applies the search term, as in [02](02-authoring-guide.md#frontend).
- **`[datatable-actions]`** goes in the toolbar's action area.
- **`ngb-alert`** renders only while `[showAlert]` is true.
- **The default slot** takes your `<ngx-datatable-column>`s.
- **`[extraActions]`** become items in the toolbar's "Actions" dropdown (`extraActionsButtonCaption` renames it);
  `icon` is a feather name; `(action)` emits the clicked action's `name`.
- **`addLabel`** is the Add button's text — Title Case, matching the page it opens.

### Expandable list

A short list whose rows open in place, for a child collection inside a detail tab. Import the class
`ExpandableListComponent`.

```html
<app-expandable-list [items]="children()" [loading]="loading()" [searchFields]="['name', 'status']"
                     emptyMessage="No children yet." noMatchMessage="No children match that search.">
  <ng-template #elRow let-child let-expanded="expanded">
    <span class="font-weight-bolder">{{ child.name }}</span>
    @if (!expanded) { <div class="small text-muted">{{ child.description }}</div> }
  </ng-template>
  <ng-template #elDetail let-child>{{ child.description }}</ng-template>
  <ng-template #elActions let-child>
    <a class="btn btn-sm btn-outline-primary" [routerLink]="['../', child.id]">View</a>
  </ng-template>
</app-expandable-list>
```

- **It filters itself** over `searchFields` (case-insensitive) — unlike the table, no `computed()` needed.
- Rows are read by `id` / `name` / `description` — rename with `idKey` / `titleKey` / `descriptionKey`.
- The template reference names are fixed: `#elRow`, `#elDetail`, `#elActions`, `#elMark`, `#elToolbar`.
- Each template gets `$implicit` (the item — `let-child`), `expanded` and `index`.
- One row opens at a time; `[multiExpand]="true"` allows several.

### Confirm dialogs

```ts
import { firstValueFrom } from 'rxjs';
import { DeleteConfirmationModalService } from '@duplocloud-internal/ng-common-lib';

private readonly deleteModal = inject(DeleteConfirmationModalService);

protected remove(it: Widget): void {
  this.deleteModal
    .openGeneric('Widget', it.name, () => firstValueFrom(this.svc.remove(it.id)))
    .then(() => this.router.navigate(['../..'], { relativeTo: this.route }))
    .catch(() => undefined);
}
```

`openGeneric(entityType, entityIdentifier, onconfirm, blockUI?, action?, successMessage?, errorMessage?)`:

- The user must **type `entityIdentifier`** before the confirm button enables.
- **`onconfirm` must return a Promise** — wrap an Observable in `firstValueFrom`.
- **The returned Promise rejects on cancel as well as on failure** — always end with `.catch`, or a cancel
  becomes an unhandled rejection.
- **It toasts the outcome itself**: success, and the failure's real reason via `extractErrorMessage`. Don't
  also report the failure from inside `onconfirm`.
- For deprovision, pass `action`: `openGeneric('Widget', it.name, fn, undefined, 'Deprovision')` — the title,
  message and toast all use it.

A plain yes/no works the same way: `ConfirmationModalService.openWithMessage(header, message, successMessage,
onconfirm)` — same Promise contract, same toasts, no typed confirmation.

### JSON / YAML viewer

For a "Raw" tab showing the spec or result as the API returned it. Both come from `CommonLibComponentsModule`.

```html
<app-view-json-comp [messageObject]="it.result" downloadFileName="widget-result.json" [heightToReduce]="420" />
<app-view-yaml-comp [messageObject]="it.spec" downloadFileName="widget-spec.yaml" [heightToReduce]="420" />
```

- **Pass the object** — the viewer serializes it.
- **Height is the window height minus `heightToReduce`** (default `100`), sized for a modal. Inside a detail
  tab, raise it so the editor doesn't run past the page.
- Read-only by default. `[enableEdit]` (JSON) / `[canEditYml]` (YAML) + `(editedMessage)` turn on editing.

### Copy buttons

```html
<span class="mono">{{ it.result?.arn }}</span> <copy-to-clipboard [source]="it.result?.arn" />
<app-code-block-with-copy [code]="loginCommand()" />
<app-code-block-with-copy [code]="token()" displayCode="••••••••" />
```

- `copy-to-clipboard` is an icon that confirms with a tooltip. `[source]` takes a string or an `ElementRef`
  (copies its text).
- `app-code-block-with-copy` renders the value in a code block and confirms with a **toast**. `displayCode`
  shows a mask while copying the real `code`.

### Terminal output

Import the class `XtermBlockComponent`.

```html
<app-xterm-block [cmdOutput]="finalLog()" [rows]="24" />
```

- Plain `\n` line breaks are fine (converted for the terminal); ANSI colour codes render.
- **`[cmdOutput]` is written once, when the terminal first renders — later changes are ignored.** For output
  that grows, call `writeOutput(fullText, true)` on a `viewChild(XtermBlockComponent)`; it redraws, so pass the
  whole text each time.

### Small pieces

```html
@if (loading()) { <app-spinner [size]="14" /> }
<span [title]="it.createdAt | date: 'medium'">{{ it.createdAt | timeAgo }}</span>
<pre class="mb-0" [innerHTML]="it.result | prettyJson"></pre>
```

- **`prettyJson` returns highlighted HTML** — bind it to `[innerHTML]`. Inside `{{ }}` you get the raw tags.
  Takes an object or a JSON string.
- **`timeAgo` doesn't tick.** It recomputes only when its input changes.
- `SpinnerComponent`, `TimeAgoPipe` and `PrettyJsonPipe` are standalone — import the classes.

### Breadcrumbs

```ts
import { REMOTE_CoreConfigService } from '@duplocloud-internal/ng-common-lib';

private readonly coreConfig = inject<any>(REMOTE_CoreConfigService as any);

ngOnInit(): void {
  this.coreConfig.setExtraBreadcrumbs([{ name: this.editMode ? 'Edit Widget' : 'Add Widget', isLink: false }]);
}
```

- Each entry is `{ name, isLink, link? }`. `setLastExtraBreadcrumbs(label)` is the one-entry shorthand.
- The host resets them on every navigation, so set them in `ngOnInit` and never clear them.

## Host services — use the `REMOTE_*` tokens

Inject by token, never by class. All seven are provided by the host (`src/app/app.module.ts`).

```ts
private readonly session = inject<any>(REMOTE_UserSession as any);
```

| Token | Gives you | Covered in |
|---|---|---|
| `REMOTE_UserSession` | The logged-in user, current workspace, `getTenantRefreshTimer()` | [02](02-authoring-guide.md#frontend), [13-current-user](13-current-user.md) |
| `REMOTE_DuploHttpClient` | The host's HTTP client, with auth attached | [02](02-authoring-guide.md#frontend) |
| `REMOTE_SystemFeatures` | Feature flags | — |
| `REMOTE_CoreConfigService` | Host layout config, breadcrumbs | [breadcrumbs](#breadcrumbs) |
| `REMOTE_AuthNZService` | Auth state | — |
| `REMOTE_AIAutomationService` | AI UI-automation hooks | — |
| `REMOTE_CanvasRendererRegistry` | Register a canvas renderer | [02](02-authoring-guide.md#frontend) |

## Not for remotes

| Export | Why |
|---|---|
| `CommonLibModule.forRoot` | Host bootstrap — sets the app-wide API URL and analytics config |
| `RootImportsModule` | `CommonLibComponentsModule` already re-exports it; don't import it a second time |
| `[appTableHelp]`, `customDataKeyToValue` | Exported, but no module declares them, so no template can use them |
| `AuthNZGuard`, `SubscriptionsGuard`, `SystemSettingGuard` | Host routing; your routes are already behind them |
| `BearerTokenInterceptor`, `DuploApiInterceptor`, `ErrorInterceptor`, the `DuploCi*` interceptors | Host HTTP pipeline; `REMOTE_DuploHttpClient` already goes through it |
| `UserSession`, `DuploHttpClient`, `SystemFeatures`, `CoreConfigService` (the classes) | Use the `REMOTE_*` token instead |
| `CoreMenuService`, `MixpanelService`, `AnalyticsConsentService`, `CoreTranslationService` | Host-level state |
| `AISystemSettings*`, `WorkspaceSystemSettings*`, `HdUserProfileDataSource` | Platform-internal API wrappers — call your own route instead ([02](02-authoring-guide.md#frontend)) |
| `[disableForReadonlyUser]`, `[hideForReadonlyUser]` | No effect in a remote (see [Read first](#read-first--how-the-lib-reaches-your-remote)) |

## Checking an exact API

After `npm install`, the full typed surface is one file:

```bash
grep -A40 'declare class SearchableDatatableComponent' \
  frontend/node_modules/@duplocloud-internal/ng-common-lib/types/duplocloud-internal-ng-common-lib.d.ts
```

The `static ɵcmp` line lists the selector, every input (with `"required": true` marking the mandatory ones)
and every output. A symbol missing from that file is not exported — don't deep-import around it.
