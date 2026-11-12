# Angular 22 pattern catalogue for extension frontends

Every API below was verified present in the dev-kit's pinned `@angular/core@22.1.0` /
`@angular/common@22.1.0` / `@angular/forms@22.1.0`. Each entry says what replaces what, and — where it
differs from generic Angular advice — what it means **inside a federated extension remote**.

Legend: **✅ use** · **⚠️ allowed, with a caveat** · **❌ do not use here**

---

## 1. Component declaration

### 1.1 Standalone is the default ✅
Angular 19 flipped `standalone` to `true` for `@Component`, `@Directive` and `@Pipe`. Do not write
`standalone: true` — it is noise. Only write `standalone: false` when a component is genuinely declared in
a surviving NgModule (an unmigrated Angular-15 extension — see the migration skill); no dev-kit sample has one.

```ts
@Component({ selector: 'xx-list', imports: [SearchableDatatableModule], template: `…` })
```

### 1.2 Per-component `imports` ✅
Each component imports exactly what its own template uses. **NgModules are legal in `imports[]`** — this
is how `@duplocloud-internal/ng-common-lib` is consumed, since most of it is still NgModule-based.

Which lib module gives you what:

| Need | Import |
|---|---|
| `searchable-datatable`, `ngx-datatable-column`, `ngbDropdown*` | `SearchableDatatableModule` (re-exports `NgbModule` + `NgxDatatableModule`) |
| `form-field`, `validation-state`, `validation-errors`, `form-group-errors`, `FormsModule` | `SharedFormsModule` |
| `scrollable-nav-tab`, `ngbNav`, `ngbDropdown`, `CommonModule`, `NgbModule` (the detail shell itself is raw Template-G markup — `duplo-extension-dev/reference/19-detail-page.md`) | `CommonLibComponentsModule` |

> **Attribute directives fail silently.** A missing component import is `NG0304 unknown element`, but a
> missing *directive* import just… does nothing. `ngbDropdown` with no `NgbModule` renders a dead button
> with no error. Check the table above rather than guessing.

### 1.3 `changeDetection` omitted ✅ — see [SKILL.md](../SKILL.md)
`OnPush = 0`, `Eager = 1`. Omitting the property means OnPush. Keep it omitted and use signals.
`ChangeDetectionStrategy.Eager` is a bulk-migration shim only.

### 1.4 `host` object, not `@HostBinding`/`@HostListener` ✅
```ts
@Component({ host: { '[class.is-open]': 'open()', '(keydown.escape)': 'close()' } })
```

---

## 2. Reactivity

### 2.1 `signal()` — all mutable component state ✅
```ts
protected readonly rows = signal<Thing[]>([]);
this.rows.set(next);
this.rows.update(rs => [...rs, one]);
```
`.mutate()` no longer exists — use `.update()` with a new reference.

### 2.2 `computed()` — every derived value ✅
Replaces getters used in templates. A getter re-runs on each check; a `computed` recomputes only when a
dependency changes and caches otherwise.

```ts
protected readonly style = computed(() => badgeFor(this.status()));
```

### 2.3 `linkedSignal()` — writable state that resets on a source ⚠️ `@publicApi 20.0`
For a selection that must reset when its list reloads.
```ts
readonly selected = linkedSignal({ source: this.rows, computation: rows => rows[0] ?? null });
```

### 2.4 `effect()` — last resort ⚠️
For syncing to something outside Angular (localStorage, a non-Angular widget). **Not** for deriving state
(use `computed`) and **not** for reacting to inputs to set other state. Writing signals inside an effect is
how loops start.

### 2.5 `untracked()` ⚠️
Reads a signal without subscribing. Needed only inside `effect`/`computed` when a read must not create a
dependency.

---

## 3. Dependency injection

### 3.1 `inject()` ✅
```ts
private readonly svc = inject(ThingService);
// The host provides these under STRING keys. Functional inject() is typed for ProviderToken, so a
// bare string does NOT compile (TS2345) — cast it. Constructor @Inject(...) accepts a bare string.
private readonly http = inject<any>(REMOTE_DuploHttpClient as any);
private readonly session = inject<any>(REMOTE_UserSession as any);
```
Field initialisers run in an injection context, so no constructor is needed. Options:
`inject(X, { optional: true })`, `{ host: true }`, `{ self: true }`, `{ skipSelf: true }`.

### 3.2 `DestroyRef` + `takeUntilDestroyed()` ✅
Replaces a manual `destroy$` Subject.
```ts
this.svc.poll().pipe(takeUntilDestroyed()).subscribe(…);          // in an injection context
this.svc.poll().pipe(takeUntilDestroyed(this.destroyRef)).subscribe(…);  // elsewhere
```

### 3.3 `providedIn: 'root'` for extension services ✅
The remote's service class registers into the **host's** root injector on first inject. That is why a
service can depend on `REMOTE_DuploHttpClient`, which the host provides at root.

### 3.4 `@Service` — the v22 shorthand for a root singleton ⚠️ `@publicApi`
Angular 22 adds a `Service` decorator (`@angular/core`), and Angular's own best-practices file says to
**prefer it over `@Injectable({providedIn: 'root'})` for new singleton services**.

```ts
@Service()
export class ThingService { … }
```

The dev-kit samples still use `@Injectable({ providedIn: 'root' })`, which remains correct and is what the
`helloworld` template shows. Either is fine; do not mix styles within one extension.

---

## 4. Inputs, outputs, queries

| Legacy | Angular 22 | Note |
|---|---|---|
| `@Input() x` | `readonly x = input<T>()` | returns `Signal<T \| undefined>` |
| `@Input({required:true}) x` | `readonly x = input.required<T>()` | |
| `@Input({transform:booleanAttribute})` | `input(false, { transform: booleanAttribute })` | `''` → `true` |
| `@Output() y = new EventEmitter()` | `readonly y = output<T>()` | `.emit()` unchanged |
| two-way `x`/`xChange` | `readonly x = model<T>()` | `[(x)]` works on components |
| `@ViewChild(C) c` | `readonly c = viewChild(C)` | **signal — call it**: `this.c()?.foo()` |
| `@ViewChild(C,{static:true})` | `viewChild.required(C)` | |
| `@ViewChildren` / `@ContentChild(ren)` | `viewChildren()` / `contentChild()` / `contentChildren()` | |
| — | `outputFromObservable(obs$)` | expose an observable as an output |

Signal inputs are read in the template as `x()`, and are **the** reason OnPush works by default.

---

## 5. Async data

### 5.1 `subscribe` + `signal.set` ✅ — the baseline
What the `helloworld` template does. Explicit, no new API surface, correct under OnPush.

### 5.2 `toSignal()` ⚠️
```ts
readonly rows = toSignal(this.svc.list(), { initialValue: [] as Thing[] });
```
Fine for a fire-once load. Gives you no `loading`/`error` state and no re-fetch trigger.

### 5.3 `rxResource()` ✅ `@publicApi 22.0` — the good fit for `view/:id`
Gives `value()` / `status()` / `error()` / `reload()` and cancels a stale request when the param changes.
```ts
private readonly id = signal(this.route.snapshot.params['id']);
readonly item = rxResource({ params: () => ({ id: this.id() }), stream: ({ params }) => this.svc.get(params.id) });
// template: @if (item.isLoading()) { … } @else if (item.value(); as it) { … }
```

### 5.4 `resource()` ✅ `@publicApi 22.0`
Same, promise-based. Use `rxResource` since the platform HTTP token returns observables.

### 5.5 `httpResource()` ❌ here
`@publicApi 22.0` and genuinely good — but it resolves Angular's `HttpClient` from `provideHttpClient`.
An extension talks to the host through the opaque `REMOTE_DuploHttpClient` token, which is not that
provider. Use `rxResource` over the token instead.

---

## 6. Templates

### 6.1 Built-in control flow ✅
```
@if (item(); as it) { … } @else if (loading()) { … } @else { … }
@for (row of rows(); track row.id) { … } @empty { <p>Nothing yet</p> }
@switch (panel()) { @case ('spec') { … } @default { … } }
```
`@for` **requires** `track` — it is a compile error without it. Block syntax is compiler-level, so no
`CommonModule` import is needed for it (you still need `CommonModule` for pipes like `date`, which
`CommonLibComponentsModule` re-exports).

### 6.2 `@let` ✅
```
@let full = item().spec.firstName + ' ' + item().spec.lastName;
```
Template-local, read-only, scoped to its block.

### 6.3 `@defer` ⚠️
`@defer (on viewport) { <heavy-chart/> } @placeholder { … } @loading { … } @error { … }`
Triggers: `on idle | viewport | interaction | hover | immediate | timer(…)`, `when <expr>`, `prefetch on …`.
Rarely worth it in an extension — the whole remote is already route-lazy.

### 6.4 `class` / `style` bindings, not `ngClass` / `ngStyle` ✅
`NgClass` and `NgStyle` are still exported by `@angular/common`, but Angular's guidance is to stop using
them. Native bindings are faster and need no import.

```html
<span [class.badge-success]="isOk()" [class]="extraClasses()" [style.width.px]="w()"></span>
```

### 6.5 Async pipe ⚠️
`obs$ | async` is still correct and is OnPush-safe. Prefer converting to a signal (`toSignal`) so the whole
component reads uniformly, but the pipe is not wrong.

### 6.6 Inline templates for small components ✅
The samples keep list/add/view templates inline in the `@Component`. Keep it that way for anything that
fits on a screen or two; use `templateUrl` only when it genuinely grows. If you do split, paths are
relative to the component `.ts`.

### 6.7 No ambient globals in templates ❌
Do not call `new Date()`, `Math.*`, `window.*` from a template expression. Compute in the component and
expose a signal or `computed`.

### 6.8 `NgOptimizedImage` for static images ⚠️
Angular's guidance for any static image. Extensions ship almost no images, and it does **not** work with
inline base64 — so in practice this rarely applies here. Use it if you add real image assets.

### 6.9 Structural directives ❌
`*ngIf`, `*ngFor`, `*ngSwitchCase` are legacy. One live exception, documented in
`duplo-extension-dev/reference/14-forms-and-wizards.md`: a **multi-step wizard hides inactive steps with
`[hidden]`, not `@if`**, so their controls stay registered with the form. That rule is about
`[hidden]`-vs-destroying-the-DOM and applies to `@if` exactly as it did to `*ngIf`.

---

## 7. Routing

### 7.1 `Routes` export as the federation entry ✅
```ts
export const Extension: Routes = [ { path: '', component: ListThingComponent }, … ];
```
`loadChildren` accepts routes or an NgModule; the host registrar resolves the export named `Extension`.
The exported name is load-bearing — do not rename it.

### 7.2 `loadComponent` ✅
```ts
{ path: 'view/:id', loadComponent: () => import('./view/view-thing.component').then(m => m.ViewThingComponent) }
```

### 7.3 Functional guards and resolvers ✅
```ts
export const thingResolver: ResolveFn<Thing> = (route) => inject(ThingService).get(route.params['id']);
export const canSee: CanActivateFn = () => inject(ThingService).allowed();
```
Class-based `Resolve`/`CanActivate` are deprecated.

### 7.4 Relative navigation depth ⚠️
Relative segments count **URL** segments, not route-config entries. From `edit/:id` (two segments) the
list is `['../..']`; from `add` (one) it is `['..']`. Getting this wrong navigates somewhere plausible and
wrong.

### 7.5 `withComponentInputBinding()` ❌ in a remote
Host-level router config. The host owns `provideRouter`; a remote must not re-provide it.

---

## 8. Forms

### 8.1 Template-driven with `NgModel` ✅ — required here
The platform's `form-field`, `validation-state`, `validation-errors`, `form-group-errors`, `[notExists]`
are `NgModel`-based. Use them, or the form stops matching the suite.

### 8.2 Signals + `NgModel` together ✅
`[(ngModel)]="sig"` works on a `WritableSignal` (Angular 17.2+ calls `sig.set($event)`). The explicit pair
below is equivalent and makes the write visible:
```html
<input name="firstName" [ngModel]="firstName()" (ngModelChange)="firstName.set($event)"
       required validation-state validation-errors />
```
This keeps NgModel registration, validation and the platform directives intact while the value stays a
signal — which matters when an edit form prefills from an async `get()`.

### 8.3 Signal Forms (`@angular/forms/signals`) ❌ here — a deliberate deviation

> **This is where the platform overrides Angular's own advice, so be explicit about it.** Angular's
> shipped best-practices file says: *"Prefer Signal Forms (`@angular/forms/signals`) for new forms. They
> are stable in Angular v22+"*, and *"When not using Signal Forms, prefer Reactive forms instead of
> Template-driven ones."* Extension forms follow **neither** recommendation.

Signal Forms are real and stable in 22.1.0 — `form`, `schema`, `apply`, `submit`, `required`, `validate`,
the `Field` directive are all exported, and only `provideExperimentalWebMcpForms` carries `@experimental`.

The reason to decline them is not maturity, it is the platform: `form-field`, `validation-state`,
`validation-errors`, `form-group-errors` and `[notExists]` are all built on `NgModel`. Signal Forms replace
`NgModel` wholesale, so adopting them means giving up every platform form widget and hand-rolling markup
that does not match the suite. Revisit when `ng-common-lib` ships a signal-forms binding.

### 8.4 Reactive forms ⚠️
`ReactiveFormsModule` is re-exported by `SharedFormsModule` and works. Angular prefers it over
template-driven, but the platform's form widgets and every dev-kit sample are template-driven — so
template-driven wins here. Do not mix the two within one form.

---

## 9. Lifecycle and rendering

| Need | API |
|---|---|
| One-time setup with DI | field initialisers + `inject()` |
| Work needing resolved `@Input`s | `ngOnInit` (still correct and still the convention) |
| Read/measure DOM once after first render | `afterNextRender(() => …)` |
| React to DOM after renders | `afterRenderEffect(() => …)` |
| Cleanup | `DestroyRef` / `takeUntilDestroyed()` over `ngOnDestroy` |

`afterNextRender` runs browser-only, which is what makes it safe for measuring — relevant because
**`ngx-datatable` measures its own width on init**, so never create it inside a `display:none` host. Use
`@if` to withhold it while loading, not `[hidden]`, or `columnMode="force"` sizes every column to 0.

---

## 10. Change-detection configuration ❌ in a remote

The host bootstraps with `provideZoneChangeDetection()` and the remote shares that `NgZone`. A remote must
provide **neither** `provideZoneChangeDetection()` nor `provideZonelessChangeDetection()` — a second zone
forks change detection and produces views that update on unrelated events. Zone config is a host decision.

---

## 11. Build and federation

| Rule | Value |
|---|---|
| Builder | `@angular/build:application` via `@angular-architects/native-federation` |
| `outputPath` | `{ "base": "dist", "browser": "" }` — otherwise Angular 22 emits `dist/browser/` and the bundle layout breaks |
| `exposes` | `{ './Extension': './src/app/extension.routes.ts' }` |
| Entry | `src/main.ts` calls `initFederation()` only — no bootstrap, no `index.html`, no dev server |
| Manifest | `remoteEntry.json` (Native Federation), never `remoteEntry.js` |
| `shared` | a **subset** of `duplo-ui/portal/federation.shared.js`, each entry its own object literal |
| Install | plain `npm install`; pin peer conflicts with `overrides`, never a legacy-peer-deps flag |

`@duplocloud-internal/ng-common-lib` is deliberately **not** shared, so the host and the remote each
compile their own copy. The resulting `NG0912 Component ID generation collision` warnings for
`searchable-datatable`, `view-header-card`, `form-field` etc. are expected and harmless.

---

## 12. TypeScript

- Strict type checking; prefer inference where the type is obvious.
- Avoid `any`; use `unknown` when the type is genuinely uncertain.
- **The one sanctioned `any`:** the host DI tokens. `REMOTE_DuploHttpClient` and `REMOTE_UserSession` are
  string tokens whose types live in the portal, which the remote cannot import without coupling the build
  to it. `inject<any>(REMOTE_DuploHttpClient as any)` is deliberate — and the `as any` on the *token* is
  required, not stylistic: these are string keys and `inject()` is typed for `ProviderToken`. Contain it — type your own
  `HelloWorld`/`Thing` models properly and let the service be the only place `any` appears.

---

## 13. Accessibility

Angular's guidance is that generated UI **must** pass AXE checks and meet **WCAG AA** minimums: focus
management, colour contrast, and correct ARIA attributes. In practice, for extension pages:

- The platform components (`searchable-datatable`, `form-field`, `view-header-card`) carry their own
  semantics — using them rather than hand-rolled markup is most of the work.
- Icon-only buttons (the `more-vertical` row kebab) need an accessible name — `aria-label`.
- Do not convey status by colour alone; the status pill pairs colour with its text label for this reason.
- Anything you do hand-roll: real `<button>`/`<a>` elements, labels tied to inputs, visible focus.

---

## 14. Tooling — Angular's own MCP server

The Angular CLI ships an MCP server. From an extension's `frontend/`:

```bash
npx ng mcp          # stdio JSON-RPC; tools: get_best_practices, search_documentation,
                    # list_projects, onpush_zoneless_migration, run_target, devserver_*
```

`get_best_practices` returns the version-specific rules this catalogue is reconciled against (also readable
directly at `node_modules/@angular/core/resources/best-practices.md`).

> ⚠️ **`onpush_zoneless_migration` gives advice that is wrong for extensions.** It plans a migration to
> **zoneless**, and its heuristic is "no explicit `changeDetection` property ⇒ may rely on Zone.js", so it
> flags correct signal-based components. Its prescribed step is to add
> `changeDetection: ChangeDetectionStrategy.Eager` — which contradicts Angular's own best-practices file
> ("Do NOT set `changeDetection` explicitly; OnPush is the default in v22+") and would reintroduce the shim
> this catalogue exists to remove. Extensions run inside a **zone-based** host and cannot go zoneless
> anyway (§10). Ignore that tool's output here.

---

## 15. Anti-patterns

| Don't | Do | Why |
|---|---|---|
| omit `changeDetection` **and** assign plain fields | `signal()` | silent no-repaint; the bug this catalogue exists for |
| `changeDetection: Eager` in new code | omit it, use signals | shim for bulk migrations only |
| getter used in a template | `computed()` | re-runs every check |
| `constructor(private x: X)` | `inject(X)` | |
| `@ViewChild` + `AfterViewInit` | `viewChild()` signal | no lifecycle sequencing |
| `*ngIf` / `*ngFor` | `@if` / `@for … track` | |
| `effect()` to derive state | `computed()` | loops, extra ticks |
| `extension.module.ts` | `extension.routes.ts` | nothing left for a module to do |
| provide zone/zoneless CD in a remote | nothing | forks the host's NgZone |
| `httpResource` / Signal Forms | `rxResource` / `NgModel` | no `provideHttpClient`; platform widgets are NgModel-based |
| `ngClass` / `ngStyle` | `[class.x]` / `[style.x]` bindings | Angular guidance; no import needed |
| `@HostBinding` / `@HostListener` | `host: { … }` in the decorator | |
| `signal.mutate(...)` | `.set()` / `.update()` | does not exist in v22 |
| `new Date()` in a template | compute in the component | no ambient globals in expressions |
| `any` beyond the host tokens | real model types | see §12 |
| following `onpush_zoneless_migration` | ignore it here | plans a zoneless migration; re-adds `Eager` (§14) |
| trusting a green build | load it in the portal | build cannot catch OnPush or dead directives |
