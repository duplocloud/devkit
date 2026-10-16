import { Component, OnInit, inject, signal, viewChild } from '@angular/core';
import { ActivatedRoute, Router } from '@angular/router';
import { AiDisclosureComponent, FormGroupErrorsComponent, SharedFormsModule } from '@duplocloud-internal/ng-common-lib';
import { SecretFieldServiceAccountService } from '../secret-field-service-account.service';

// Add/Edit form — see reference/02-authoring-guide.md for the panel-form-accordion layout this mirrors
// (copied from templates/helloworld's add-hello.component.ts) and reference/21-secrets.md for the ONE
// thing this component demonstrates beyond that template: a write-only password field.
//
// The password field uses a plain `<input type="password">` rather than the library's `<password-field>`
// — reference/14-forms-and-wizards.md documents the same markup for a dynamically-rendered password kind,
// and it's what this sample verifies end to end; swap in `<password-field>` if your extension prefers it.
@Component({
  selector: 'sf-add',
  imports: [SharedFormsModule, AiDisclosureComponent],
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
          <h4 class="font-weight-bolder">{{ isEdit ? 'Edit' : 'Create' }} Service Account</h4>
          <p class="panel-content-title-sub-text text-muted">
            Enter a name, username, and password. The provisioning agent never sees the password in
            plaintext — see reference/21-secrets.md.
          </p>
        </div>

        <div class="panel-content-form">
          @if (loading()) {
            <div class="text-muted p-1">Loading…</div>
          } @else {
            <form name="AddSecretFieldServiceAccountForm" #f="ngForm" class="form form-vertical" (ngSubmit)="f.valid && submit()">
              <div class="form-container" form-group-errors #formGroupErrors showDetailsWhen="submitted">
                <form-field>
                  <label class="element-label">Name *</label>
                  <!-- The name identifies the resource, so it is fixed once provisioned. -->
                  <input type="text" class="form-control" name="name"
                         [ngModel]="name()" (ngModelChange)="name.set($event)" [readonly]="isEdit"
                         placeholder="e.g. billing-bot" required validation-state validation-errors
                         minlength="2" maxlength="60" pattern="^[a-zA-Z0-9]([a-zA-Z0-9\\-]*[a-zA-Z0-9])?$" />
                </form-field>
                <form-field>
                  <label class="element-label">Username *</label>
                  <input type="text" class="form-control" name="username"
                         [ngModel]="username()" (ngModelChange)="username.set($event)"
                         placeholder="svc-billing" required validation-state validation-errors />
                </form-field>
                <form-field>
                  <label class="element-label">Password {{ isEdit ? '' : '*' }}</label>
                  <!-- WRITE-ONLY (reference/21-secrets.md): the GET response never carries the real value
                       (backend: [SecretValue(ExcludeFromResponse = true)]), so on Edit there is nothing to
                       pre-populate. The model starts blank either way; the placeholder communicates that a
                       value IS stored without ever showing it, and the field is required only on Create. -->
                  <input type="password" class="form-control" autocomplete="new-password" name="password"
                         [ngModel]="password()" (ngModelChange)="password.set($event)"
                         [required]="!isEdit"
                         [placeholder]="isEdit ? '•••• — leave blank to keep' : 'Choose a password'"
                         validation-state validation-errors />
                  @if (isEdit) {
                    <div class="text-muted font-small-3 mt-25">
                      Leave blank to keep the current password. To retrieve the current value instead of
                      replacing it, use "Reveal password" on the detail page.
                    </div>
                  }
                </form-field>

                <div class="d-flex justify-content-end mt-1">
                  <button type="button" class="btn btn-outline-secondary mr-1" (click)="cancel()">Cancel</button>
                  <button type="submit" class="btn btn-primary" [disabled]="saving()">
                    {{ isEdit ? 'Save' : 'Provision' }}
                  </button>
                </div>
                <!-- Agent mode only (ISO 42001): remove with the ticket UI when converting to Worker/Passthrough. -->
                <app-ai-disclosure class="mt-1" />
              </div>
            </form>
          }
        </div>

        <div class="panel-content-sidenav">
          <div class="help-item">
            <p class="help-item-title">Name</p>
            <small class="text-muted">A unique identifier for this service account resource.</small>
          </div>
          <div class="help-item">
            <p class="help-item-title">Password</p>
            <small class="text-muted">
              Stored encrypted; never returned by the API. Reveal it explicitly from the detail page, or
              rotate it by typing a new one here.
            </small>
          </div>
        </div>

      </div>
    </div>
  `,
})
export class AddSecretFieldServiceAccountComponent implements OnInit {
  private readonly svc = inject(SecretFieldServiceAccountService);
  private readonly router = inject(Router);
  private readonly route = inject(ActivatedRoute);

  protected readonly name = signal('');
  protected readonly username = signal('');
  protected readonly password = signal(''); // ALWAYS starts blank — see the write-only note on the template.
  protected readonly saving = signal(false);
  protected readonly loading = signal(false);

  protected readonly isEdit = this.route.snapshot.data['action'] === 'Edit';
  private readonly id: string = this.route.snapshot.params['id'];
  /** Full spec as loaded in edit mode (never carries `password` — see the service interface). */
  private loadedSpec: Record<string, any> = {};

  private readonly formErrors = viewChild(FormGroupErrorsComponent);

  ngOnInit(): void {
    if (!this.isEdit) {
      return;
    }
    this.loading.set(true);
    this.svc.get(this.id).subscribe({
      next: item => {
        this.loadedSpec = item?.spec ?? {};
        this.name.set(item?.name ?? '');
        this.username.set(item?.spec?.username ?? '');
        this.loading.set(false);
      },
      error: () => this.loading.set(false),
    });
  }

  protected submit(): void {
    this.saving.set(true);
    // Spec is replaced WHOLESALE by PATCH — always send the FULL spec. `password` is included ONLY when
    // the user actually typed one; an empty string is never sent, so the backend's "absent = keep" rule
    // (reference/21-secrets.md) leaves the stored password untouched on an edit that doesn't change it.
    const spec: { username: string; password?: string } = { ...this.loadedSpec, username: this.username() };
    if (this.password()) {
      spec.password = this.password();
    }
    const call = this.isEdit
      ? this.svc.update(this.id, spec)
      : this.svc.create(this.name(), spec as { username: string; password: string });
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

  private back(): void {
    this.router.navigate([this.isEdit ? '../..' : '..'], { relativeTo: this.route });
  }
}
