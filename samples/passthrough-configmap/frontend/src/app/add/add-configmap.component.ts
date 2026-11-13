import { Component, OnInit, inject, signal, viewChild } from '@angular/core';
import { ActivatedRoute, Router } from '@angular/router';
import { FormGroupErrorsComponent, SharedFormsModule } from '@duplocloud-internal/ng-common-lib';
import { ConfigMapDemo, ConfigMapService } from '../configmap.service';

// Create/Edit form in the platform's 3-column `panel-form-accordion` layout: title+description (left),
// inputs (center), per-field help (right). The platform ships these column widths as an SCSS *mixin* each
// host component @includes (NOT global CSS, and the published lib ships compiled CSS only) — so a remote
// carries the layout rules in its own component `styles` (below).
//
// The `data` map is edited as REPEATABLE key/value rows (indexed control names + add/remove — the same
// primitives-based row pattern as network-stack's subnets; the lib ships no repeatable-rows widget).
// The model is signal-held: the edit-mode prefill arrives from a subscribe — outside any template event —
// so under the OnPush default a plain-field reassignment would not repaint. ngModel writing to the held
// object's PROPERTIES is fine (template events mark the view dirty).
@Component({
  selector: 'cm-add',
  imports: [SharedFormsModule],
  styles: [`
    :host { display: block; }
    .panel-form-accordion { background: var(--surface); padding: 1.25rem 0 1rem 1.5rem; }
    .panel-content-title { width: 265px; min-width: 265px; }
    .panel-content-title-sub-text { max-width: 220px; }
    .panel-content-form { max-width: 768px; flex: 1 1 auto; margin: 0 1rem; padding: 0 1rem; }
    .panel-content-sidenav { width: 265px; min-width: 265px; margin-left: 2rem; }
    .panel-content-sidenav .help-item { padding-bottom: 1rem; }
    .panel-content-sidenav .help-item-title { margin: 0; font-weight: 600; font-size: 0.9rem; }
    .kv-row { display: flex; gap: .75rem; align-items: flex-start; }
    .kv-row form-field { flex: 1 1 0; }
  `],
  template: `
    <div class="card panel-form-accordion">
      <div class="d-flex justify-content-between">

        <div class="panel-content-title">
          <h4 class="font-weight-bolder">{{ isEdit ? 'Edit ConfigMap' : 'Create ConfigMap' }}</h4>
          <p class="panel-content-title-sub-text text-muted">
            A Kubernetes ConfigMap applied synchronously to the selected cluster — no ticket, no agent.
          </p>
        </div>

        <div class="panel-content-form">
          <form name="AddConfigMapForm" #f="ngForm" class="form form-vertical" (ngSubmit)="f.valid && submit()">
            <div class="form-container" form-group-errors #formGroupErrors showDetailsWhen="submitted">
              <form-field>
                <label class="element-label">Name *</label>
                <!-- Keep the hyphen escaped: browsers compile pattern with the RegExp v flag, under
                     which a bare hyphen in a character class throws and the validator fails open. -->
                <input type="text" class="form-control" name="name"
                       [ngModel]="model().name" (ngModelChange)="setName($event)"
                       placeholder="e.g. app-settings" required [disabled]="isEdit"
                       validation-state validation-errors
                       minlength="2" maxlength="60" pattern="^[a-z0-9]([a-z0-9\\-]*[a-z0-9])?$" />
              </form-field>
              <form-field>
                <label class="element-label">Namespace *</label>
                <input type="text" class="form-control" name="namespace"
                       [ngModel]="model().namespace" (ngModelChange)="setNamespace($event)"
                       placeholder="default" required validation-state validation-errors />
              </form-field>

              <label class="element-label d-block">Data (key / value) *</label>
              @for (row of model().rows; track $index; let i = $index) {
                <div class="kv-row">
                  <form-field>
                    <input type="text" class="form-control" [name]="'dataKey' + i" [(ngModel)]="row.key"
                           placeholder="key (e.g. LOG_LEVEL)" required validation-state validation-errors />
                  </form-field>
                  <form-field>
                    <input type="text" class="form-control" [name]="'dataValue' + i" [(ngModel)]="row.value"
                           placeholder="value (e.g. info)" required validation-state validation-errors />
                  </form-field>
                  <button type="button" class="btn btn-outline-danger btn-sm mt-25" (click)="removeRow(i)"
                          [disabled]="model().rows.length === 1">
                    <i data-feather="trash-2"></i>
                  </button>
                </div>
              }
              <button type="button" class="btn btn-outline-primary btn-sm" (click)="addRow()">
                <i data-feather="plus" class="mr-50"></i> Add entry
              </button>

              <div class="d-flex justify-content-end mt-1">
                <button type="button" class="btn btn-outline-secondary mr-1" (click)="cancel()">Cancel</button>
                <button type="submit" class="btn btn-primary" [disabled]="saving()">
                  {{ isEdit ? 'Save' : 'Create' }}
                </button>
              </div>
            </div>
          </form>
        </div>

        <div class="panel-content-sidenav">
          <div class="help-item">
            <p class="help-item-title">Name / Namespace</p>
            <small class="text-muted">The ConfigMap's Kubernetes name and target namespace.</small>
          </div>
          <div class="help-item">
            <p class="help-item-title">Data</p>
            <small class="text-muted">Key/value entries written to the ConfigMap's <code>data</code>.</small>
          </div>
        </div>

      </div>
    </div>
  `,
})
export class AddConfigMapComponent implements OnInit {
  private readonly svc = inject(ConfigMapService);
  private readonly router = inject(Router);
  private readonly route = inject(ActivatedRoute);

  protected readonly saving = signal(false);
  protected isEdit = false;
  private editId: string | null = null;
  /** Loaded spec on edit — spread back on save so unmapped fields (e.g. scopeIds) survive the PATCH. */
  private loadedSpec: ConfigMapDemo['spec'] = undefined;

  protected readonly model = signal<{ name: string; namespace: string; rows: { key: string; value: string }[] }>({
    name: '',
    namespace: 'default',
    rows: [{ key: '', value: '' }],
  });

  // Platform error reporter: the form-group-errors directive (already on the <form>) surfaces the real
  // API error via extractErrorMessage. viewChild() returns a signal — call it.
  private readonly formErrors = viewChild(FormGroupErrorsComponent);

  ngOnInit(): void {
    this.editId = this.route.snapshot.params['id'] ?? null;
    this.isEdit = !!this.editId;
    if (this.isEdit && this.editId) {
      this.svc.get(this.editId).subscribe(it => {
        this.loadedSpec = it.spec;
        const entries = Object.entries(it.spec?.data ?? {});
        this.model.set({
          name: it.name,
          namespace: it.spec?.namespace ?? 'default',
          rows: entries.length ? entries.map(([key, value]) => ({ key, value })) : [{ key: '', value: '' }],
        });
      });
    }
  }

  protected setName(v: string): void { this.model.update(m => ({ ...m, name: v })); }
  protected setNamespace(v: string): void { this.model.update(m => ({ ...m, namespace: v })); }

  protected addRow(): void {
    this.model().rows.push({ key: '', value: '' });
  }

  protected removeRow(i: number): void {
    if (this.model().rows.length > 1) {
      this.model().rows.splice(i, 1);
    }
  }

  protected submit(): void {
    this.saving.set(true);
    const data: Record<string, string> = {};
    for (const r of this.model().rows) {
      if (r.key) { data[r.key] = r.value; }
    }
    // Spec is replaced WHOLESALE by PATCH — spread the loaded spec so fields this form doesn't edit survive.
    const spec = { ...(this.loadedSpec ?? {}), namespace: this.model().namespace, data };
    const call = this.isEdit && this.editId
      ? this.svc.update(this.editId, spec)
      : this.svc.create(this.model().name, spec);
    call.subscribe({
      next: () => this.router.navigate([this.isEdit ? '../..' : '..'], { relativeTo: this.route }),
      error: err => {
        this.saving.set(false);
        this.formErrors()?.reportError(err);
      },
    });
  }

  protected cancel(): void {
    this.router.navigate([this.isEdit ? '../..' : '..'], { relativeTo: this.route });
  }
}
