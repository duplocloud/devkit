import { Component, OnInit, inject, signal, viewChild } from '@angular/core';
import { ActivatedRoute, Router } from '@angular/router';
import { FormGroupErrorsComponent, SharedFormsModule } from '@duplocloud-internal/ng-common-lib';
import { CalculatorService } from '../calculator.service';

// Forms stay template-driven (the platform convention), but each field is a signal bound one-way with an
// explicit (ngModelChange) writer: `[(ngModel)]="sig"` would compile to `sig = $event`, which cannot assign
// to a signal. Signals also keep the component correct under Angular 22's default OnPush strategy.
@Component({
  selector: 'calc-add',
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
          <h4 class="font-weight-bolder">{{ isEdit ? 'Edit' : 'Create' }} Calculator</h4>
          <p class="panel-content-title-sub-text text-muted">
            Enter two numbers. A background worker computes their sum and product.
          </p>
        </div>

        <div class="panel-content-form">
          @if (loading()) {
            <div class="text-muted p-1">Loading…</div>
          } @else {
            <form name="AddCalcForm" #f="ngForm" class="form form-vertical" (ngSubmit)="f.valid && submit()">
              <div class="form-container" form-group-errors #formGroupErrors showDetailsWhen="submitted">
                <form-field>
                  <label class="element-label">Name *</label>
                  <!-- The name identifies the resource, so it is fixed once created. Keep the hyphen
                       escaped: browsers compile pattern with the RegExp v flag, under which a bare hyphen
                       in a character class throws and the validator fails open. -->
                  <input type="text" class="form-control" name="name"
                         [ngModel]="name()" (ngModelChange)="name.set($event)" [readonly]="isEdit"
                         placeholder="e.g. calc-1" required validation-state validation-errors
                         minlength="2" maxlength="60" pattern="^[a-zA-Z0-9]([a-zA-Z0-9\\-]*[a-zA-Z0-9])?$" />
                </form-field>
                <form-field>
                  <label class="element-label">A *</label>
                  <input type="number" class="form-control" name="a"
                         [ngModel]="a()" (ngModelChange)="a.set($event)"
                         required validation-state validation-errors step="any" />
                </form-field>
                <form-field>
                  <label class="element-label">B *</label>
                  <input type="number" class="form-control" name="b"
                         [ngModel]="b()" (ngModelChange)="b.set($event)"
                         required validation-state validation-errors step="any" />
                </form-field>

                <div class="d-flex justify-content-end mt-1">
                  <button type="button" class="btn btn-outline-secondary mr-1" (click)="cancel()">Cancel</button>
                  <button type="submit" class="btn btn-primary" [disabled]="saving()">
                    {{ isEdit ? 'Save' : 'Create' }}
                  </button>
                </div>
              </div>
            </form>
          }
        </div>

        <div class="panel-content-sidenav">
          <div class="help-item">
            <p class="help-item-title">A / B</p>
            <small class="text-muted">The worker computes <code>sum = A + B</code> and <code>product = A * B</code>.</small>
          </div>
        </div>

      </div>
    </div>
  `,
})
export class AddCalculatorComponent implements OnInit {
  private readonly svc = inject(CalculatorService);
  private readonly router = inject(Router);
  private readonly route = inject(ActivatedRoute);

  protected readonly name = signal('');
  protected readonly a = signal(0);
  protected readonly b = signal(0);
  protected readonly saving = signal(false);
  protected readonly loading = signal(false);

  protected readonly isEdit = this.route.snapshot.data['action'] === 'Edit';
  private readonly id: string = this.route.snapshot.params['id'];
  /** Full spec as loaded in edit mode — spread into the PATCH body (spec is replaced wholesale). */
  private loadedSpec: Record<string, any> = {};

  // Platform error reporter: the form-group-errors directive (already on the <form>) surfaces the real
  // API error via extractErrorMessage. viewChild() returns a signal — call it.
  private readonly formErrors = viewChild(FormGroupErrorsComponent);

  ngOnInit(): void {
    if (!this.isEdit) {
      return;
    }
    this.loading.set(true);
    this.svc.get(this.id).subscribe({
      next: item => {
        // Keep the WHOLE loaded spec — PATCH replaces spec wholesale (BaseSpec fields like Mode/ScopeIds
        // would otherwise be erased on save).
        this.loadedSpec = item?.spec ?? {};
        this.name.set(item?.name ?? '');
        this.a.set(item?.spec?.a ?? 0);
        this.b.set(item?.spec?.b ?? 0);
        this.loading.set(false);
      },
      error: () => this.loading.set(false),
    });
  }

  protected submit(): void {
    this.saving.set(true);
    // FULL spec on edit — PATCH replaces `spec` wholesale (a partial spec drops sibling fields).
    // Saving a changed spec is what re-ticks the background worker.
    const spec = { ...this.loadedSpec, a: Number(this.a()), b: Number(this.b()) };
    const call = this.isEdit
      ? this.svc.update(this.id, spec)
      : this.svc.create(this.name(), spec);
    call.subscribe({
      next: () => this.back(),
      error: err => {
        this.saving.set(false);
        this.formErrors()?.reportError(err);
      },
    });
  }

  protected cancel(): void {
    this.back();
  }

  // 'add' is one URL segment, 'edit/:id' is two — climb the right number to land back on the list.
  private back(): void {
    this.router.navigate([this.isEdit ? '../..' : '..'], { relativeTo: this.route });
  }
}
