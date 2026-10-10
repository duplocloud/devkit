import { Component, OnInit, inject, signal, viewChild } from '@angular/core';
import { ActivatedRoute, Router } from '@angular/router';
import { AiDisclosureComponent, FormGroupErrorsComponent, SharedFormsModule } from '@duplocloud-internal/ng-common-lib';
import { HelloAnalytics } from '../analytics';
import { HelloService } from '../hello.service';

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
  selector: 'hw-add',
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
          <h4 class="font-weight-bolder">{{ isEdit ? 'Edit' : 'Create' }} Hello World</h4>
          <p class="panel-content-title-sub-text text-muted">
            Enter a name and the person's first / last name. The agent combines them into a full name.
          </p>
        </div>

        <div class="panel-content-form">
          @if (loading()) {
            <div class="text-muted p-1">Loading…</div>
          } @else {
            <form name="AddHelloForm" #f="ngForm" class="form form-vertical" (ngSubmit)="f.valid && submit()">
              <div class="form-container" form-group-errors #formGroupErrors showDetailsWhen="submitted">
                <form-field>
                  <label class="element-label">Name *</label>
                  <!-- The name identifies the resource, so it is fixed once provisioned. -->
                  <input type="text" class="form-control" name="name"
                         [ngModel]="name()" (ngModelChange)="name.set($event)" [readonly]="isEdit"
                         placeholder="e.g. greet-jane" required validation-state validation-errors
                         minlength="2" maxlength="60" pattern="^[a-zA-Z0-9]([a-zA-Z0-9\\-]*[a-zA-Z0-9])?$" />
                  <!-- Keep the hyphen ESCAPED: browsers compile "pattern" with the RegExp v flag, under
                       which a bare hyphen inside a class throws — the validator fails open (any name passes). -->
                </form-field>
                <form-field>
                  <label class="element-label">First Name *</label>
                  <input type="text" class="form-control" name="firstName"
                         [ngModel]="firstName()" (ngModelChange)="firstName.set($event)"
                         placeholder="Jane" required validation-state validation-errors />
                </form-field>
                <form-field>
                  <label class="element-label">Last Name *</label>
                  <input type="text" class="form-control" name="lastName"
                         [ngModel]="lastName()" (ngModelChange)="lastName.set($event)"
                         placeholder="Doe" required validation-state validation-errors />
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
            <small class="text-muted">A unique identifier for this Hello World resource.</small>
          </div>
          <div class="help-item">
            <p class="help-item-title">First / Last Name</p>
            <small class="text-muted">The provisioning agent concatenates these into <code>fullName</code>.</small>
          </div>
        </div>

      </div>
    </div>
  `,
})
export class AddHelloComponent implements OnInit {
  private readonly svc = inject(HelloService);
  private readonly router = inject(Router);
  private readonly route = inject(ActivatedRoute);
  private readonly analytics = inject(HelloAnalytics);

  protected readonly name = signal('');
  protected readonly firstName = signal('');
  protected readonly lastName = signal('');
  protected readonly saving = signal(false);
  protected readonly loading = signal(false);

  protected readonly isEdit = this.route.snapshot.data['action'] === 'Edit';
  private readonly id: string = this.route.snapshot.params['id'];
  /** Full spec as loaded in edit mode — spread into the PATCH body (spec is replaced wholesale). */
  private loadedSpec: Record<string, any> = {};

  // The platform's error reporter: the `form-group-errors` directive (already on the <form> for client-side
  // validation) also implements ErrorReporter. reportError(err) unwraps the API error via extractErrorMessage
  // (reads the response `errors` detail, not just the generic `message` title) and shows it as the form's
  // summary banner — the same pattern the portal's own add-forms use. Do NOT read e.error.message directly.
  private readonly formErrors = viewChild(FormGroupErrorsComponent);

  ngOnInit(): void {
    this.analytics.pageView('hello-form');
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
        this.firstName.set(item?.spec?.firstName ?? '');
        this.lastName.set(item?.spec?.lastName ?? '');
        this.loading.set(false);
      },
      error: () => this.loading.set(false),
    });
  }

  protected submit(): void {
    this.saving.set(true);
    // Spec is replaced WHOLESALE by PATCH (no deep merge) — always send the FULL spec; never echo `result`.
    const spec = { ...this.loadedSpec, firstName: this.firstName(), lastName: this.lastName() };
    const call = this.isEdit
      ? this.svc.update(this.id, spec)
      : this.svc.create(this.name(), spec);
    call.subscribe({
      next: () => {
        this.analytics.action(this.isEdit ? 'update-hello' : 'create-hello');
        this.back();
      },
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
