import { Component, DestroyRef, OnInit, computed, inject, signal, viewChild } from '@angular/core';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';
import { ActivatedRoute, Router } from '@angular/router';
import { FilterTableUtils, SearchableDatatableComponent, SearchableDatatableModule } from '@duplocloud-internal/ng-common-lib';
import { SecretFieldServiceAccountService, SecretFieldServiceAccount, REMOTE_UserSession } from '../secret-field-service-account.service';
import { StatusBadgeComponent } from '../shared/status-badge.component';

// List view — copied from templates/helloworld's list-hello.component.ts, columns swapped to this
// resource's own fields. Deliberately NO password column: the list response never carries the value
// (reference/21-secrets.md), so there is nothing to show — not even masked.
@Component({
  selector: 'sf-list',
  imports: [SearchableDatatableModule, StatusBadgeComponent],
  template: `
    <div class="card datatable-card">
      <searchable-datatable
        [showAdd]="true"
        addLabel="Create Service Account"
        (add)="add()"
        [rows]="rows()"
        (filter)="filterUpdate()"
        columnMode="force">

        <!-- Actions -->
        <ngx-datatable-column [width]="50" [sortable]="false" [canAutoResize]="false" cellClass="actions">
          <ng-template ngx-datatable-cell-template let-row="row">
            <div ngbDropdown container="body">
              <button class="btn btn-sm hide-arrow" ngbDropdownToggle>
                <i data-feather="more-vertical"></i>
              </button>
              <div ngbDropdownMenu>
                <a ngbDropdownItem (click)="view(row)">
                  <i data-feather="eye" class="mr-50"></i><span>View</span>
                </a>
                <a ngbDropdownItem (click)="edit(row)">
                  <i data-feather="edit" class="mr-50"></i><span>Edit</span>
                </a>
                <a ngbDropdownItem (click)="track(row)">
                  <i data-feather="activity" class="mr-50"></i><span>Track Provisioning</span>
                </a>
              </div>
            </div>
          </ng-template>
        </ngx-datatable-column>

        <ngx-datatable-column name="Name" [flexGrow]="160">
          <ng-template ngx-datatable-cell-template let-row="row">
            <a (click)="view(row)" class="text-primary font-weight-medium cursor-pointer">{{ row.name }}</a>
          </ng-template>
        </ngx-datatable-column>

        <ngx-datatable-column name="Username" [flexGrow]="140">
          <ng-template ngx-datatable-cell-template let-row="row">{{ row.spec?.username || '—' }}</ng-template>
        </ngx-datatable-column>

        <ngx-datatable-column name="Account Id" [flexGrow]="150">
          <ng-template ngx-datatable-cell-template let-row="row">{{ row.result?.accountId || '—' }}</ng-template>
        </ngx-datatable-column>

        <ngx-datatable-column name="Status" [flexGrow]="110" [maxWidth]="150">
          <ng-template ngx-datatable-cell-template let-row="row">
            <app-status-badge [status]="row.status"></app-status-badge>
          </ng-template>
        </ngx-datatable-column>

      </searchable-datatable>
    </div>
  `,
})
export class ListSecretFieldServiceAccountComponent implements OnInit {
  private readonly svc = inject(SecretFieldServiceAccountService);
  private readonly router = inject(Router);
  private readonly route = inject(ActivatedRoute);
  private readonly session = inject<any>(REMOTE_UserSession as any);
  private readonly destroyRef = inject(DestroyRef);

  private readonly table = viewChild(SearchableDatatableComponent);

  private readonly allRows = signal<SecretFieldServiceAccount[]>([]);
  private readonly filterTerm = signal('');

  // Plain string fields or dot-paths only — searchByFields uses lodash `get`; no method calls. `password`
  // is intentionally absent: it's never on `spec` to begin with (reference/21-secrets.md), and even if it
  // were, a secret field has no business being searchable/indexable client-side.
  private readonly searchFields = ['name', 'status', 'spec.username', 'result.accountId'];

  protected readonly rows = computed(() => {
    const term = this.filterTerm();
    const all = this.allRows();
    return term ? all.filter(r => FilterTableUtils.searchByFields(r, this.searchFields, term)) : all;
  });

  ngOnInit(): void {
    this.session.getTenantRefreshTimer(true)
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe(([, tenantChanged]: [any, boolean]) => this.refresh(!!tenantChanged));
  }

  private refresh(tenantChanged: boolean): void {
    if (tenantChanged) {
      this.table()?.startLoading();
    }
    this.svc.list().pipe(takeUntilDestroyed(this.destroyRef)).subscribe({
      next: rows => {
        this.allRows.set(rows ?? []);
        this.table()?.refresh();
      },
      error: () => {
        this.allRows.set([]);
        this.table()?.stopLoading();
      },
    });
  }

  protected filterUpdate(): void {
    this.filterTerm.set(this.table()?.searchTerm?.toLowerCase()?.trim() ?? '');
  }

  protected add(): void {
    this.router.navigate(['add'], { relativeTo: this.route });
  }

  protected view(r: SecretFieldServiceAccount): void {
    this.router.navigate(['view', r.id], { relativeTo: this.route });
  }

  protected edit(r: SecretFieldServiceAccount): void {
    this.router.navigate(['edit', r.id], { relativeTo: this.route });
  }

  protected track(r: SecretFieldServiceAccount): void {
    this.svc.ticketName(r.id).subscribe(name => {
      if (!name) {
        return;
      }
      this.router.navigate(['/ai/service-desk', this.svc.workspaceId(), 'tickets', 'chat', name]);
    });
  }
}
