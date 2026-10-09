import { Component, OnInit, inject, signal, viewChild } from '@angular/core';
import { ActivatedRoute, Router } from '@angular/router';
import { AiDisclosureComponent, FormGroupErrorsComponent, SharedFormsModule } from '@duplocloud-internal/ng-common-lib';
import { HelloParent, ParentChildService } from '../parentchild.service';

// Create/Edit form in the platform 3-column `panel-form-accordion` layout (title | inputs | help). The
// column widths are a host SCSS mixin (not global / not in the published lib), so a remote carries them in
// its own component `styles`. Fields use SharedFormsModule's form-field + validation; template-driven only —
// each field is a SIGNAL bound one-way with an explicit (ngModelChange) writer (`[(ngModel)]="sig"` cannot
// assign to a signal, and signals keep async prefills repainting under the OnPush default).
@Component({
  selector: 'pc-add-parent',
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
          <h4 class="font-weight-bolder">{{ isEdit ? 'Edit' : 'Create' }} Parent</h4>
          <p class="panel-content-title-sub-text text-muted">A parent owns many children. The agent derives a slug from the title.</p>
        </div>
        <div class="panel-content-form">
          @if (loading()) {
            <div class="text-muted p-1">Loading…</div>
          } @else {
            <form name="AddParentForm" #f="ngForm" class="form form-vertical" (ngSubmit)="f.valid && submit()">
              <div class="form-container" form-group-errors showDetailsWhen="submitted">
                <form-field>
                  <label class="element-label">Name *</label>
                  <!-- The name identifies the resource, so it is fixed once provisioned. Keep the hyphen
                       escaped: browsers compile pattern with the RegExp v flag, under which a bare hyphen
                       in a class throws and the validator fails open. -->
                  <input type="text" class="form-control" name="name"
                         [ngModel]="name()" (ngModelChange)="name.set($event)" [readonly]="isEdit"
                         required validation-state validation-errors minlength="2" maxlength="60"
                         pattern="^[a-zA-Z0-9]([a-zA-Z0-9\\-]*[a-zA-Z0-9])?$" />
                </form-field>
                <form-field>
                  <label class="element-label">Title *</label>
                  <input type="text" class="form-control" name="title"
                         [ngModel]="title()" (ngModelChange)="title.set($event)"
                         required validation-state validation-errors />
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
          <div class="help-item"><p class="help-item-title">Name</p>
            <small class="text-muted">A unique identifier for the parent.</small></div>
          <div class="help-item"><p class="help-item-title">Title</p>
            <small class="text-muted">Human-readable title; the agent slugifies it into <code>result.slug</code>.</small></div>
        </div>
      </div>
    </div>
  `,
})
export class AddParentComponent implements OnInit {
  private readonly svc = inject(ParentChildService);
  private readonly router = inject(Router);
  private readonly route = inject(ActivatedRoute);

  protected readonly name = signal('');
  protected readonly title = signal('');
  protected readonly saving = signal(false);
  protected readonly loading = signal(false);

  protected readonly isEdit = this.route.snapshot.data['action'] === 'Edit';
  private readonly id: string = this.route.snapshot.params['id'];
  // The loaded spec — spread into the PATCH body so unedited fields survive (spec is replaced wholesale).
  private loadedSpec: HelloParent['spec'] = {};

  // Platform error reporter: the form-group-errors directive (already on the <form>) surfaces the real
  // API error via extractErrorMessage (reads response `errors`, not just the generic `message` title).
  private readonly formErrors = viewChild(FormGroupErrorsComponent);

  ngOnInit(): void {
    if (!this.isEdit) {
      return;
    }
    this.loading.set(true);
    this.svc.getParent(this.id).subscribe({
      next: item => {
        this.loadedSpec = item?.spec ?? {};
        this.name.set(item?.name ?? '');
        this.title.set(item?.spec?.title ?? '');
        this.loading.set(false);
      },
      error: () => this.loading.set(false),
    });
  }

  protected submit(): void {
    this.saving.set(true);
    const call = this.isEdit
      ? this.svc.updateParent(this.id, { ...this.loadedSpec, title: this.title() })
      : this.svc.createParent(this.name(), this.title());
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
