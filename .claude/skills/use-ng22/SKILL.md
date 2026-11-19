---
name: use-ng22
description: The Angular 22 patterns a DuploCloud extension frontend must be written in — standalone components, signals, the OnPush default, inject(), the @if/@for/@switch block syntax, and a Routes export instead of an NgModule. Use when writing or reviewing any component, service, route or template in an extension's frontend/, when scaffolding a new extension's UI, or when deciding whether an Angular 22 API (resource, httpResource, signal forms, zoneless) is allowed in the extension context. Also the source of the rules that duplo-extension-dev scaffolds to and duplo-extension-ng22-migration modernizes toward.
---

# use-ng22 — how extension frontends are written on Angular 22

Every DuploCloud extension remote runs **inside the portal's Angular 22 host**, sharing its `@angular/core`,
its `NgZone` and its injector. That makes some Angular 22 patterns mandatory, some merely available, and a
few actively wrong here even though they are current Angular elsewhere. This skill is the ruling on all
three.

**The exhaustive per-API catalogue is [`reference/patterns.md`](reference/patterns.md).** This file is the
short version: the default shape, the rules that bite, and the verification gate.

Both are reconciled against Angular's own shipped guidance
(`node_modules/@angular/core/resources/best-practices.md`, what `ng mcp`'s `get_best_practices` serves) and
every API was verified present in the pinned `@angular/*@22.1.0`. Where the platform overrides Angular's
default advice — forms, chiefly — the catalogue says so explicitly rather than quietly differing.

The worked reference is the `helloworld` template in
[`duplo-extension-dev/templates/helloworld/frontend/`](../duplo-extension-dev/templates/helloworld/frontend/).

---

## The one that silently breaks everything

**Angular 22 defaults a component with no `changeDetection` property to `OnPush`** — the enum is
`OnPush = 0`, `Eager = 1`, where `Eager` is the old `Default`.

This does not error. The build passes, unit tests pass, the shell renders — and then a field assigned from
a `subscribe`/`setTimeout`/promise never repaints. A list sits empty forever while the network tab shows the
data arrived. It is invisible until you load the page in the host.

**The fix is not to add `Eager`.** Hold async state in `signal()` and leave the property off — a signal
write marks the view dirty, which is what makes the modern default correct rather than a trap. (`Eager` is
a bulk-migration shim; `duplo-ui/portal` uses it on 898 of 904 components because retrofitting them to
signals was not feasible. A new extension has no such excuse.)

---

## Default component shape

Scaffold every new component like this. No `standalone`, no `changeDetection`, no constructor DI.

```ts
import { Component, OnInit, inject, signal } from '@angular/core';
import { ActivatedRoute, Router } from '@angular/router';
import { SearchableDatatableModule } from '@duplocloud-internal/ng-common-lib';
import { ThingService, Thing } from '../thing.service';

@Component({
  selector: 'xx-list',
  imports: [SearchableDatatableModule],   // NgModules are fine in a standalone imports[]
  template: `
    @if (loading()) {
      <div class="card p-2 text-muted">Loading…</div>
    } @else {
      <searchable-datatable [rows]="rows()" columnMode="force">…</searchable-datatable>
    }
  `,
})
export class ListThingComponent implements OnInit {
  private readonly svc = inject(ThingService);
  private readonly router = inject(Router);
  private readonly route = inject(ActivatedRoute);

  protected readonly rows = signal<Thing[]>([]);
  protected readonly loading = signal(true);

  ngOnInit(): void {
    this.svc.list().subscribe({
      next: rows => { this.rows.set(rows ?? []); this.loading.set(false); },
      error: () => { this.rows.set([]); this.loading.set(false); },
    });
  }
}
```

Routes replace the NgModule entirely — `loadChildren` accepts a `Routes` array, and the host's
`extension-route-registrar.ts` resolves the export named `Extension`:

```ts
// src/app/extension.routes.ts  — federation.config.js: exposes { './Extension': './src/app/extension.routes.ts' }
export const Extension: Routes = [
  { path: '',          component: ListThingComponent },
  { path: 'add',       component: AddThingComponent },
  { path: 'edit/:id',  component: AddThingComponent, data: { action: 'Edit' } },
  { path: 'view/:id',  component: ViewThingComponent },
];
```

---

## Rules

1. **Standalone components, no `standalone: true`** — it is the default in Angular 19+; writing it is noise.
   Each component declares its own `imports`.
2. **No `changeDetection` property.** All async state in `signal()`. See above.
3. **`inject()`, not constructor parameters** — including for the platform's string tokens:
   `private readonly http = inject<any>(REMOTE_DuploHttpClient as any)` — the token cast is required,
   since these are string keys and `inject()` is typed for `ProviderToken` (a bare string is TS2345).
4. **`input()` / `output()` / `model()` / `viewChild()`**, not the `@Input`/`@Output`/`@ViewChild` decorators.
   `viewChild()` returns a signal — call it: `this.formErrors()?.reportError(err)`.
5. **`computed()`, never a getter**, for derived template values. A getter re-runs on every check; a
   `computed` recomputes only when an input signal changes.
6. **`@if` / `@for` / `@switch` / `@let`**, not `*ngIf` / `*ngFor` / `[ngSwitch]`. `@for` **requires**
   `track`. Block syntax needs no `CommonModule` import.
7. **A `Routes` export, not an NgModule.** Delete `extension.module.ts`.
8. **Template-driven forms stay** — see the constraint below.

---

## Constraints specific to running inside the portal

These are the ones a generic Angular 22 guide will get wrong.

| Angular 22 API | Verdict here | Why |
|---|---|---|
| Zoneless (`provideZonelessChangeDetection`) | **Forbidden** | The host bootstraps with `provideZoneChangeDetection()` and the remote shares its `NgZone`. Never provide either in a remote — a second zone forks change detection. |
| Signal Forms (`@angular/forms/signals`) | **Forbidden for platform forms** | Real and exported in 22.1.0, but the platform's `form-field`, `validation-state`, `validation-errors` and `form-group-errors` are built on `NgModel`. Signal Forms bypass all of them and the form stops looking and behaving like the suite. |
| `[(ngModel)]="someSignal"` | **Allowed** | Angular 17.2+ compiles two-way binding on a `WritableSignal` to `sig.set($event)`. The explicit `[ngModel]="sig()" (ngModelChange)="sig.set($event)"` pair is equally correct. |
| `httpResource` | **Not usable** | `@publicApi 22.0`, but it needs Angular's `HttpClient` from `provideHttpClient`. Extensions get the host's `REMOTE_DuploHttpClient` token, not that provider. Use `rxResource` or `toSignal` over the token's observables. |
| `resource` / `rxResource` | **Allowed** | `@publicApi 22.0`. Good fit for `view/:id` loads. Plain `subscribe` + `signal.set` is equally correct and is what the template uses. |
| `provideZoneChangeDetection` in the remote | **Forbidden** | Host-only concern; see zoneless row. |
| `@defer` | **Allowed, rarely useful** | The whole remote is already lazy-loaded by route. |
| `ng mcp` → `onpush_zoneless_migration` | **Ignore its output** | It plans a *zoneless* migration and tells you to add `ChangeDetectionStrategy.Eager` — contradicting Angular's own best-practices and re-adding the shim. Extensions run in a zone-based host. |

---

## Verification gate

**A green build proves nothing about change detection.** The OnPush trap, unresolved attribute directives,
and a missing `imports` entry can all compile cleanly.

Run these from `frontend/`. Everything under `src/app` — including the shared detail shell and every
result-view panel component (reference/17, reference/19) — is your code and must pass this gate.

```bash
OWN=$(find src/app -name '*.ts')

# 1. no component silently relying on the OnPush default while assigning plain fields
for f in $OWN; do
  grep -q "@Component(" "$f" || continue
  grep -q "changeDetection:" "$f" && continue
  grep -q "this\.[A-Za-z_]* = " "$f" && echo "CHECK: $f — no strategy, assigns plain fields"
done

# 2. no legacy structural directives or decorator queries left
grep -nE "\*ngIf|\*ngFor|ngSwitch|@Input\(|@Output\(|@ViewChild\(" $OWN || echo clean

# 3. build
npm run build
```

Both checks return clean on the `helloworld` template.

Then **load the page in the portal** and watch a list actually populate after its request resolves. That
is the only check that catches the failure this skill exists to prevent.

---

## Related

- [`reference/patterns.md`](reference/patterns.md) — the exhaustive per-API catalogue.
- [`duplo-extension-dev`](../duplo-extension-dev/SKILL.md) — scaffolding a new extension; its
  `helloworld` template is written to these rules.
- [`duplo-extension-ng22-migration`](../duplo-extension-ng22-migration/SKILL.md) — porting an Angular 15
  extension; migrate first, then modernize to this shape.
