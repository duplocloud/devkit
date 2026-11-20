import { Component, OnInit, inject, signal, viewChild } from '@angular/core';
import { ActivatedRoute, Router } from '@angular/router';
import { FormGroupErrorsComponent, SharedFormsModule } from '@duplocloud-internal/ng-common-lib';
import { AppStack, AppStackService } from '../appstack.service';

// Create/Edit form in the platform's 3-column `panel-form-accordion` layout: title+description (left),
// inputs (center), per-field help (right). The platform ships these column widths as an SCSS *mixin* each
// host component @includes (NOT global CSS, and the published lib ships compiled CSS only) — so a remote
// carries the layout rules in its own component `styles` (below).
//
// The model is signal-held: the edit-mode prefill arrives from a subscribe — outside any template event —
// so under the OnPush default a plain-field reassignment would not repaint. ngModel writing to the held
// object's PROPERTIES is fine (template events mark the view dirty).
@Component({
  selector: 'as-add',
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
  `],
  template: `
    <div class="card panel-form-accordion">
      <div class="d-flex justify-content-between">

        <div class="panel-content-title">
          <h4 class="font-weight-bolder">{{ isEdit ? 'Edit App Stack' : 'Create App Stack' }}</h4>
          <p class="panel-content-title-sub-text text-muted">
            A Deployment + Service reconciled by a background worker — no ticket, no agent.
          </p>
        </div>

        <div class="panel-content-form">
          <form name="AddAppStackForm" #f="ngForm" class="form form-vertical" (ngSubmit)="f.valid && submit()">
            <div class="form-container" form-group-errors #formGroupErrors showDetailsWhen="submitted">
              <form-field>
                <label class="element-label">Name *</label>
                <!-- Keep the hyphen escaped: browsers compile pattern with the RegExp v flag, under
                     which a bare hyphen in a character class throws and the validator fails open. -->
                <input type="text" class="form-control" name="name"
                       [ngModel]="model().name" (ngModelChange)="patch('name', $event)"
                       placeholder="e.g. web-frontend" required [disabled]="isEdit"
                       validation-state validation-errors
                       minlength="2" maxlength="60" pattern="^[a-z0-9]([a-z0-9\\-]*[a-z0-9])?$" />
              </form-field>
              <form-field>
                <label class="element-label">Namespace *</label>
                <input type="text" class="form-control" name="namespace"
                       [ngModel]="model().namespace" (ngModelChange)="patch('namespace', $event)"
                       placeholder="default" required validation-state validation-errors />
              </form-field>
              <form-field>
                <label class="element-label">Container Image *</label>
                <input type="text" class="form-control" name="image"
                       [ngModel]="model().image" (ngModelChange)="patch('image', $event)"
                       placeholder="nginx:1.25" required validation-state validation-errors />
              </form-field>
              <form-field>
                <label class="element-label">Replicas *</label>
                <input type="number" class="form-control" name="replicas"
                       [ngModel]="model().replicas" (ngModelChange)="patch('replicas', $event)"
                       min="1" max="20" required validation-state validation-errors />
              </form-field>

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
            <p class="help-item-title">Namespace / Image / Replicas</p>
            <small class="text-muted">What the worker applies as a Deployment (+ a port-80 Service).</small>
          </div>
          <div class="help-item">
            <p class="help-item-title">Editing</p>
            <small class="text-muted">Saving a change re-triggers the worker's reconcile.</small>
          </div>
        </div>

      </div>
    </div>
  `,
})
export class AddAppStackComponent implements OnInit {
  private readonly svc = inject(AppStackService);
  private readonly router = inject(Router);
  private readonly route = inject(ActivatedRoute);

  protected readonly saving = signal(false);
  protected isEdit = false;
  private editId: string | null = null;
  /** Loaded spec on edit — spread back on save so unmapped fields (e.g. scopeIds) survive the PATCH. */
  private loadedSpec: AppStack['spec'] = undefined;

  protected readonly model = signal<{ name: string; namespace: string; image: string; replicas: number }>({
    name: '',
    namespace: 'default',
    image: '',
    replicas: 1,
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
        this.model.set({
          name: it.name,
          namespace: it.spec?.namespace ?? 'default',
          image: it.spec?.image ?? '',
          replicas: it.spec?.replicas ?? 1,
        });
      });
    }
  }

  protected patch(key: 'name' | 'namespace' | 'image' | 'replicas', v: any): void {
    this.model.update(m => ({ ...m, [key]: v }));
  }

  protected submit(): void {
    this.saving.set(true);
    // Spec is replaced WHOLESALE by PATCH — spread the loaded spec so fields this form doesn't edit survive.
    const spec = {
      ...(this.loadedSpec ?? {}),
      namespace: this.model().namespace,
      image: this.model().image,
      replicas: this.model().replicas,
    };
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
