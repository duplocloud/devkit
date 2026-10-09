import { Component, OnInit, inject, signal, viewChild } from '@angular/core';
import { ActivatedRoute, Router } from '@angular/router';
import { FormGroupErrorsComponent, SharedFormsModule } from '@duplocloud-internal/ng-common-lib';
import { AdminSettingService } from '../admin-setting.service';

// Add/Edit form in the platform's 3-column `panel-form-accordion` layout: title+description (left), inputs
// (center), per-field help (right). One component serves both routes — `edit/:id` carries data.action='Edit'.
// The platform ships these column widths as an SCSS *mixin* that each host component @includes (it is NOT
// global CSS, and the published lib ships compiled CSS only) — so a remote must carry the layout rules in
// its own component `styles` (below).
//
// Forms stay template-driven (the platform convention), but each field is a signal bound one-way with an
// explicit (ngModelChange) writer: `[(ngModel)]="sig"` would compile to `sig = $event`, which cannot assign
// to a signal. Signals also keep the component correct under Angular 22's default OnPush strategy — the
// edit-mode prefill below arrives from an async subscribe, which would not repaint a plain field.
// SharedFormsModule re-exports FormsModule plus form-field and every validation directive used here.
@Component({
  selector: 'as-add',
  imports: [SharedFormsModule],
  styles: [`
    :host { display: block; }
    .panel-form-accordion { background: #fff; padding: 1.25rem 0 1rem 1.5rem; }
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
          <h4 class="font-weight-bolder">{{ isEdit ? 'Edit' : 'Create' }} Admin Setting</h4>
          <p class="panel-content-title-sub-text text-muted">
            A platform-wide setting only administrators manage. The agent applies it and records a summary.
          </p>
        </div>

        <div class="panel-content-form">
          @if (loading()) {
            <div class="text-muted p-1">Loading…</div>
          } @else {
            <form name="AddAdminSettingForm" #f="ngForm" class="form form-vertical" (ngSubmit)="f.valid && submit()">
              <div class="form-container" form-group-errors #formGroupErrors showDetailsWhen="submitted">
                <form-field>
                  <label class="element-label">Name *</label>
                  <!-- The name identifies the resource, so it is fixed once provisioned. Keep the hyphen
                       escaped: browsers compile pattern with the RegExp v flag, under which a bare hyphen
                       in a class throws and the validator fails open. -->
                  <input type="text" class="form-control" name="name"
                         [ngModel]="name()" (ngModelChange)="name.set($event)" [readonly]="isEdit"
                         placeholder="e.g. maintenance-banner" required validation-state validation-errors
                         minlength="2" maxlength="60" pattern="^[a-zA-Z0-9]([a-zA-Z0-9\\-]*[a-zA-Z0-9])?$" />
                </form-field>
                <form-field>
                  <label class="element-label">Setting Key *</label>
                  <input type="text" class="form-control" name="settingKey"
                         [ngModel]="settingKey()" (ngModelChange)="settingKey.set($event)"
                         placeholder="maintenance-banner" required validation-state validation-errors />
                </form-field>
                <form-field>
                  <label class="element-label">Setting Value *</label>
                  <input type="text" class="form-control" name="settingValue"
                         [ngModel]="settingValue()" (ngModelChange)="settingValue.set($event)"
                         placeholder="Back at 18:00 UTC" required validation-state validation-errors />
                </form-field>

                <div class="d-flex justify-content-end mt-1">
                  <button type="button" class="btn btn-outline-secondary mr-1" (click)="cancel()">Cancel</button>
                  <button type="submit" class="btn btn-primary" [disabled]="saving()">
                    {{ isEdit ? 'Save' : 'Provision' }}
                  </button>
                </div>
              </div>
            </form>
          }
        </div>

        <div class="panel-content-sidenav">
          <div class="help-item">
            <p class="help-item-title">Name</p>
            <small class="text-muted">A unique identifier for this Admin Setting resource.</small>
          </div>
          <div class="help-item">
            <p class="help-item-title">Setting Key / Value</p>
            <small class="text-muted">The provisioning agent applies the value and writes a <code>summary</code>.</small>
          </div>
        </div>

      </div>
    </div>
  `,
})
export class AddAdminSettingComponent implements OnInit {
  private readonly svc = inject(AdminSettingService);
  private readonly router = inject(Router);
  private readonly route = inject(ActivatedRoute);

  protected readonly name = signal('');
  protected readonly settingKey = signal('');
  protected readonly settingValue = signal('');
  protected readonly saving = signal(false);
  protected readonly loading = signal(false);

  protected readonly isEdit = this.route.snapshot.data['action'] === 'Edit';
  private readonly id: string = this.route.snapshot.params['id'];
  /** Full spec as loaded in edit mode — spread into the PATCH body (spec is replaced wholesale). */
  private loadedSpec: Record<string, any> = {};

  // Platform error reporter: the form-group-errors directive (already on the <form>) surfaces the real
  // API error via extractErrorMessage (reads response `errors`, not just the generic `message` title).
  private readonly formErrors = viewChild(FormGroupErrorsComponent);

  ngOnInit(): void {
    if (!this.isEdit) {
      return;
    }
    this.loading.set(true);
    this.svc.get(this.id).subscribe({
      next: item => {
        // Keep the WHOLE loaded spec: PATCH {spec} replaces the spec wholesale, so any field this form
        // doesn't edit must be spread back on save or it is silently erased.
        this.loadedSpec = item?.spec ?? {};
        this.name.set(item?.name ?? '');
        this.settingKey.set(item?.spec?.settingKey ?? '');
        this.settingValue.set(item?.spec?.settingValue ?? '');
        this.loading.set(false);
      },
      error: () => this.loading.set(false),
    });
  }

  protected submit(): void {
    this.saving.set(true);
    // Spec is replaced WHOLESALE by PATCH (no deep merge) — always send the FULL spec; never echo `result`.
    const spec = { ...this.loadedSpec, settingKey: this.settingKey(), settingValue: this.settingValue() };
    const call = this.isEdit
      ? this.svc.update(this.id, spec)
      : this.svc.create(this.name(), spec);
    call.subscribe({
      next: () => this.back(),
      error: (err) => {
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
