import { Component, DestroyRef, OnInit, computed, inject, signal, viewChild } from '@angular/core';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';
import { ActivatedRoute, Router } from '@angular/router';
import { FormGroupErrorsComponent, SharedFormsModule } from '@duplocloud-internal/ng-common-lib';
import { AdminSetting, AdminSettingService } from '../admin-setting.service';
import { AdminSettingConsumerService } from '../admin-setting-consumer.service';

// Add/Edit for the workspace resource that consumes an admin setting. The cross-scope part is the picker: it is
// fed by the READ-ONLY workspace view of the admin settings (AdminSettingsReadController — name, key, status;
// never the value) and offers only Complete ones, the same rule the backend's ValidateSpecAsync enforces.
// Layout and signal-per-field conventions are the ones add-admin-setting.component.ts explains.
@Component({
  selector: 'asc-add',
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
          <h4 class="font-weight-bolder">{{ isEdit ? 'Edit' : 'Create' }} Setting Consumer</h4>
          <p class="panel-content-title-sub-text text-muted">
            Use a platform-wide admin setting in this workspace. The agent applies it here.
          </p>
        </div>

        <div class="panel-content-form">
          @if (loading()) {
            <div class="text-muted p-1">Loading…</div>
          } @else {
            <form name="AddAdminSettingConsumerForm" #f="ngForm" class="form form-vertical" (ngSubmit)="f.valid && submit()">
              <div class="form-container" form-group-errors #formGroupErrors showDetailsWhen="submitted">
                <form-field>
                  <label class="element-label">Name *</label>
                  <input type="text" class="form-control" name="name"
                         [ngModel]="name()" (ngModelChange)="name.set($event)" [readonly]="isEdit"
                         placeholder="e.g. banner-for-team-a" required validation-state validation-errors
                         minlength="2" maxlength="60" pattern="^[a-zA-Z0-9]([a-zA-Z0-9\\-]*[a-zA-Z0-9])?$" />
                </form-field>
                <form-field>
                  <label class="element-label">Admin Setting *</label>
                  <ng-select name="adminSettingId" [items]="options()" bindLabel="label" bindValue="id"
                             [ngModel]="adminSettingId()" (ngModelChange)="adminSettingId.set($event)"
                             [loading]="settingsLoading()"
                             [placeholder]="settingsLoading() ? 'Loading admin settings…'
                               : options().length ? 'Pick an admin setting' : 'No admin setting is ready yet'"
                             required validation-state validation-errors></ng-select>
                </form-field>

                <div class="d-flex justify-content-end mt-1">
                  <button type="button" class="btn btn-outline-secondary mr-1" (click)="back()">Cancel</button>
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
            <p class="help-item-title">Admin Setting</p>
            <small class="text-muted">
              Administrators manage these in AI Admin. Only settings that finished provisioning are listed.
            </small>
          </div>
        </div>

      </div>
    </div>
  `,
})
export class AddAdminSettingConsumerComponent implements OnInit {
  private readonly svc = inject(AdminSettingConsumerService);
  private readonly settings = inject(AdminSettingService);
  private readonly router = inject(Router);
  private readonly route = inject(ActivatedRoute);
  private readonly destroyRef = inject(DestroyRef);

  protected readonly name = signal('');
  protected readonly adminSettingId = signal<string | null>(null);
  protected readonly saving = signal(false);
  protected readonly loading = signal(false);
  protected readonly settingsLoading = signal(true);
  private readonly allSettings = signal<AdminSetting[]>([]);

  // Complete settings only — plus, on edit, the one already chosen: the backend accepts keeping it even while
  // an administrator re-provisions it.
  protected readonly options = computed(() => this.allSettings()
    .filter(s => s.status === 'Complete' || s.id === this.adminSettingId())
    .map(s => ({ id: s.id, label: `${s.name} (${s.spec?.settingKey ?? '—'})` })));

  protected readonly isEdit = this.route.snapshot.data['action'] === 'Edit';
  private readonly id: string = this.route.snapshot.params['id'];
  private loadedSpec: Record<string, any> = {};

  private readonly formErrors = viewChild(FormGroupErrorsComponent);

  ngOnInit(): void {
    this.settings.list('workspace').pipe(takeUntilDestroyed(this.destroyRef)).subscribe({
      next: list => {
        this.allSettings.set(list);
        this.settingsLoading.set(false);
      },
      error: err => {
        this.settingsLoading.set(false);
        this.formErrors()?.reportError(err);
      },
    });
    if (!this.isEdit) {
      return;
    }
    this.loading.set(true);
    this.svc.get(this.id).pipe(takeUntilDestroyed(this.destroyRef)).subscribe({
      next: item => {
        this.loadedSpec = item?.spec ?? {};
        this.name.set(item?.name ?? '');
        this.adminSettingId.set(item?.spec?.adminSettingId ?? null);
        this.loading.set(false);
      },
      error: () => this.loading.set(false),
    });
  }

  protected submit(): void {
    this.saving.set(true);
    // Spec is replaced WHOLESALE by PATCH — always send the FULL spec.
    const spec = { ...this.loadedSpec, adminSettingId: this.adminSettingId() ?? '' };
    const call = this.isEdit ? this.svc.update(this.id, spec) : this.svc.create(this.name(), spec);
    call.pipe(takeUntilDestroyed(this.destroyRef)).subscribe({
      next: () => this.back(),
      error: (err) => {
        this.saving.set(false);
        // The backend's ValidateSpecAsync reasons (missing / not Complete) arrive here.
        this.formErrors()?.reportError(err);
      },
    });
  }

  // 'add' is one URL segment, 'edit/:id' is two — climb the right number to land back on the list.
  protected back(): void {
    this.router.navigate([this.isEdit ? '../..' : '..'], { relativeTo: this.route });
  }
}
