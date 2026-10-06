import { Component, OnInit, computed, inject, signal } from '@angular/core';
import { ActivatedRoute, Router } from '@angular/router';
import { NgForm } from '@angular/forms';
import { NgSelectModule } from '@ng-select/ng-select';
import { extractErrorMessage, SharedFormsModule } from '@duplocloud-internal/ng-common-lib';
import { NetworkStack, NetworkStackService, NetworkStackSubnet } from '../network-stack.service';
import { WizardStep, WizardStepperComponent } from '../wizard/wizard-stepper.component';

// Multi-step WIZARD create/edit form (the dev-kit's wizard reference — reference/14): ONE <form> wraps
// the <duplo-wizard-stepper>; each step's fields sit in an `ngModelGroup` toggled with [hidden] (NOT
// @if) so their controls stay registered while hidden; `nextDisabled` is the CURRENT group's `.invalid`.
// Step 2 shows a REPEATABLE row group (subnets) — each row's controls get index-suffixed names.
// Template-driven throughout; `model` stays a plain mutable object (the [(ngModel)] trap is only
// binding onto a signal); signals hold the state written outside template events.
@Component({
  selector: 'ns-add',
  imports: [SharedFormsModule, NgSelectModule, WizardStepperComponent],
  styles: [`
    :host { display: block; }
    .step-title { font-weight: 600; font-size: 1.05rem; margin-bottom: 1rem; }
    /* Centered, narrower than the card: fields read better than full-bleed under the stepper. */
    .form-narrow { max-width: 640px; margin: 0 auto; }
    .subnet-row { display: flex; gap: .75rem; align-items: flex-start; }
    .subnet-row form-field { flex: 1 1 0; }
    .review dt { font-weight: 600; }
    /* Per-field guidance/empty-state notes (kept generic so extensions inherit the class name). */
    .field-hint { font-size: .85rem; }
  `],
  template: `
    <form #f="ngForm" class="form form-vertical" (ngSubmit)="f.valid && finish()">
      <duplo-wizard-stepper
        [title]="isEdit ? 'Edit Network Stack' : 'Create Network Stack'"
        [aiDisclosure]="true"
        subtitle="A VPC with subnets and a security group, provisioned by terraform in the background — the view page tracks the modules live and offers on-demand Plan/Apply."
        [steps]="steps"
        [activeIndex]="activeIndex()"
        [nextDisabled]="isStepInvalid(f) || stepBusy()"
        [saving]="saving()"
        [error]="error()"
        [finishLabel]="isEdit ? 'Save' : 'Create'"
        (back)="back()"
        (next)="next(f)"
        (cancel)="cancel()"
        (finish)="finish()">

        <div class="form-container form-narrow" form-group-errors showDetailsWhen="submitted">

          <!-- Step 1 — Basics -->
          <div [hidden]="activeIndex() !== 0" ngModelGroup="step0">
            <div class="step-title">Basics</div>
            <form-field>
              <label class="element-label">Name *</label>
              <input type="text" class="form-control" name="name" [(ngModel)]="model().name"
                     placeholder="e.g. edge-network" required [disabled]="isEdit"
                     validation-state validation-errors
                     minlength="2" maxlength="60" pattern="^[a-z0-9]([a-z0-9\\-]*[a-z0-9])?$" />
            </form-field>
            <form-field>
              <label class="element-label">Region *</label>
              <!-- [addTag] lets users type ANY region — regionOptions is a suggestion list, not the
                   catalog: the backend accepts any region and hardcoding a cloud vocabulary would lock
                   out scopes living elsewhere (ap-south-1, GovCloud, …). -->
              <ng-select name="region" [(ngModel)]="model().region" [items]="regionOptions"
                         [addTag]="true" [clearable]="false" required
                         placeholder="Select or type a region"
                         validation-state validation-errors></ng-select>
            </form-field>
            <form-field>
              <label class="element-label">AWS Scope *</label>
              <!-- The scope's credentials run terraform AND the live-state enrichment (reference/07).
                   Async-fed selects carry their state: [loading] + a placeholder per load/empty state,
                   and an empty state that says HOW to fix it — not just that the list is empty. -->
              <ng-select name="scopeId" [(ngModel)]="model().scopeId" [items]="scopeOptions()"
                         bindLabel="name" bindValue="id"
                         [loading]="scopesLoading()"
                         [placeholder]="scopesLoading() ? 'Loading scopes…' : (scopeOptions().length ? 'Select the AWS scope' : 'No AWS scope in this workspace')"
                         required validation-state validation-errors></ng-select>
              @if (!scopesLoading() && !scopeOptions().length) {
                <div class="text-muted field-hint mt-25">
                  Attach an AWS scope to this workspace (Scopes → Add), then reopen this form.
                </div>
              }
            </form-field>
          </div>

          <!-- Step 2 — Network (repeatable subnet rows) -->
          <div [hidden]="activeIndex() !== 1" ngModelGroup="step1">
            <div class="step-title">Network</div>
            <form-field>
              <label class="element-label">VPC CIDR *</label>
              <input type="text" class="form-control" name="vpcCidr" [(ngModel)]="model().vpcCidr"
                     placeholder="10.20.0.0/16" required validation-state validation-errors
                     pattern="^\\d{1,3}(\\.\\d{1,3}){3}/\\d{1,2}$" />
              <div class="text-muted field-hint mt-25">
                The VPC's address space — every subnet below must fit inside it.
              </div>
            </form-field>

            <form-field>
              <label class="element-label d-block">DNS hostnames</label>
              <!-- The worked toggle: custom-switch with a live value label, [id]/[for] paired. -->
              <div class="custom-control custom-switch">
                <input type="checkbox" class="custom-control-input" id="enableDnsHostnames"
                       name="enableDnsHostnames" [(ngModel)]="model().enableDnsHostnames" />
                <label class="custom-control-label" for="enableDnsHostnames">
                  {{ model().enableDnsHostnames ? 'enabled' : 'disabled' }}
                </label>
              </div>
              <div class="text-muted field-hint mt-25">
                Gives instances public DNS names inside the VPC (terraform: enable_dns_hostnames).
              </div>
            </form-field>

            <label class="element-label d-block">Subnets *</label>
            @for (s of model().subnets; track $index; let i = $index) {
              <div class="subnet-row">
                <form-field>
                  <input type="text" class="form-control" [name]="'subnetName' + i" [(ngModel)]="s.name"
                         placeholder="name (e.g. app-a)" required validation-state validation-errors />
                </form-field>
                <form-field>
                  <input type="text" class="form-control" [name]="'subnetCidr' + i" [(ngModel)]="s.cidr"
                         placeholder="10.20.1.0/24" required validation-state validation-errors
                         pattern="^\\d{1,3}(\\.\\d{1,3}){3}/\\d{1,2}$" />
                </form-field>
                <form-field>
                  <input type="text" class="form-control" [name]="'subnetAz' + i" [(ngModel)]="s.az"
                         placeholder="AZ suffix (a, b, …) — optional" maxlength="2" />
                </form-field>
                <button type="button" class="btn btn-outline-danger btn-sm mt-25" (click)="removeSubnet(i)"
                        [disabled]="model().subnets.length === 1">
                  <i data-feather="trash-2"></i>
                </button>
              </div>
            }
            <button type="button" class="btn btn-outline-primary btn-sm" (click)="addSubnet()">
              <i data-feather="plus" class="mr-50"></i> Add subnet
            </button>
          </div>

          <!-- Step 3 — Review -->
          <div [hidden]="activeIndex() !== 2" ngModelGroup="step2">
            <div class="step-title">Review</div>
            <!-- The review shows EVERY earlier choice — resolved to human labels (scope NAME, not its id),
                 with '(empty)' for blanks. A review that omits a step defeats confirm-before-provision. -->
            <dl class="review">
              <dt>Name</dt><dd>{{ displayValue(model().name) }}</dd>
              <dt>Region</dt><dd>{{ displayValue(model().region) }}</dd>
              <dt>AWS Scope</dt><dd>{{ displayValue(selectedScopeName()) }}</dd>
              <dt>VPC CIDR</dt><dd>{{ displayValue(model().vpcCidr) }}</dd>
              <dt>DNS hostnames</dt><dd>{{ model().enableDnsHostnames ? 'enabled' : 'disabled' }}</dd>
              <dt>Subnets</dt>
              <dd>
                @for (s of model().subnets; track $index) {
                  <div>{{ displayValue(s.name) }} — {{ displayValue(s.cidr) }}{{ s.az ? ' (' + model().region + s.az + ')' : '' }}</div>
                }
              </dd>
            </dl>
            <p class="text-muted font-small-3">
              {{ isEdit
                 ? 'Saving updates the spec on the SAME long-lived ticket — run a Plan afterwards to preview, then Apply.'
                 : 'Create opens the provisioning ticket: terraform runs in the background and the view page tracks the modules live.' }}
            </p>
          </div>

        </div>
      </duplo-wizard-stepper>
    </form>
  `,
})
export class AddNetworkStackComponent implements OnInit {
  private readonly svc = inject(NetworkStackService);
  private readonly router = inject(Router);
  private readonly route = inject(ActivatedRoute);

  protected readonly steps: WizardStep[] = [
    { key: 'step0', label: 'Basics' },
    { key: 'step1', label: 'Network' },
    { key: 'step2', label: 'Review' },
  ];

  protected readonly activeIndex = signal(0);
  protected readonly saving = signal(false);
  protected readonly error = signal('');
  protected readonly scopeOptions = signal<{ id: string; name: string }[]>([]);
  protected readonly scopesLoading = signal(true);

  /** The review step shows the scope's NAME — never surface a raw id to the user. */
  protected readonly selectedScopeName = computed(() =>
    this.scopeOptions().find(s => s.id === this.model().scopeId)?.name ?? '');

  // Common suggestions only — the select has [addTag] so any region string is accepted.
  protected readonly regionOptions = ['us-east-1', 'us-east-2', 'us-west-1', 'us-west-2', 'eu-west-1', 'eu-central-1'];

  protected isEdit = false;
  private editId: string | null = null;
  /** Full spec as loaded in edit mode — spread into the PATCH body (spec is replaced wholesale). */
  private loadedSpec: NonNullable<NetworkStack['spec']> | Record<string, never> = {};

  // Signal-held model (use-ng22): the edit-mode prefill arrives from a subscribe — outside any template
  // event — so under the OnPush default a plain-field reassignment would not repaint. ngModel writing to the
  // held object's PROPERTIES is fine (template events mark the view dirty); only the async reassignment
  // needs the signal.
  protected readonly model = signal<{ name: string; region: string; scopeId: string | null; vpcCidr: string; enableDnsHostnames: boolean; subnets: NetworkStackSubnet[] }>({
    name: '',
    region: 'us-east-1',
    scopeId: null,
    vpcCidr: '10.20.0.0/16',
    enableDnsHostnames: true,
    subnets: [{ name: 'app-a', cidr: '10.20.1.0/24', az: '' }],
  });

  ngOnInit(): void {
    this.svc.listScopes().subscribe({
      next: s => { this.scopeOptions.set(s); this.scopesLoading.set(false); },
      error: () => this.scopesLoading.set(false),
    });
    this.editId = this.route.snapshot.params['id'] ?? null;
    this.isEdit = !!this.editId && this.route.snapshot.data['action'] === 'Edit';
    if (this.isEdit && this.editId) {
      this.svc.get(this.editId).subscribe(it => {
        // Keep the WHOLE loaded spec: PATCH {spec} replaces the spec wholesale, so fields this form
        // doesn't edit (tags, lastRequestedAction, …) must be spread back on save or they are erased.
        this.loadedSpec = it.spec ?? {};
        this.model.set({
          name: it.name,
          region: it.spec?.region ?? 'us-east-1',
          scopeId: it.spec?.scopeIds?.[0] ?? null,
          vpcCidr: it.spec?.vpcCidr ?? '',
          enableDnsHostnames: it.spec?.enableDnsHostnames ?? true,
          subnets: it.spec?.subnets?.length ? it.spec.subnets.map(s => ({ ...s })) : [{ name: '', cidr: '', az: '' }],
        });
      });
    }
  }

  protected isStepInvalid(f: NgForm): boolean {
    const group = f?.form?.get(this.steps[this.activeIndex()].key);
    return !!group && group.invalid;
  }

  /** A step's data fetch is in flight — hold Next so the user can't skip past an empty dropdown. */
  protected stepBusy(): boolean {
    return this.activeIndex() === 0 && this.scopesLoading();
  }

  /** Review-step rendering: blanks show as '(empty)', never as a hole in the layout. */
  protected displayValue(v: string | null | undefined): string {
    return v?.trim() ? v : '(empty)';
  }

  protected next(f: NgForm): void {
    if (this.isStepInvalid(f)) {
      return;
    }
    if (this.activeIndex() < this.steps.length - 1) {
      this.activeIndex.update(i => i + 1);
    }
  }

  protected back(): void {
    if (this.activeIndex() > 0) {
      this.activeIndex.update(i => i - 1);
    }
  }

  protected addSubnet(): void {
    this.model().subnets.push({ name: '', cidr: '', az: '' });
  }

  protected removeSubnet(i: number): void {
    if (this.model().subnets.length > 1) {
      this.model().subnets.splice(i, 1);
    }
  }

  protected finish(): void {
    this.saving.set(true);
    this.error.set('');
    // PATCH replaces the spec WHOLESALE (no deep merge): spread the loaded spec first so fields this
    // form doesn't edit (tags, lastRequestedAction, …) survive the save. Never echo `result` back.
    const spec = {
      ...this.loadedSpec,
      region: this.model().region,
      vpcCidr: this.model().vpcCidr,
      enableDnsHostnames: this.model().enableDnsHostnames,
      subnets: this.model().subnets.map(s => ({ name: s.name, cidr: s.cidr, az: s.az || undefined })),
      scopeIds: this.model().scopeId ? [this.model().scopeId] : [],
    };
    const call = this.isEdit && this.editId
      ? this.svc.update(this.editId, spec)   // PATCH — reuses the existing ticket (reference/04)
      : this.svc.create(this.model().name, spec);
    call.subscribe({
      next: () => this.router.navigate([this.isEdit ? '../..' : '..'], { relativeTo: this.route }),
      error: err => {
        this.saving.set(false);
        // Contextual fallback: name the action that failed, never a generic "request failed".
        this.error.set(extractErrorMessage(err)
          || (this.isEdit ? 'Could not save the network stack.' : 'Could not create the network stack.'));
      },
    });
  }

  protected cancel(): void {
    this.router.navigate([this.isEdit ? '../..' : '..'], { relativeTo: this.route });
  }
}
