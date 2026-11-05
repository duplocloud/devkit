import { Component, DestroyRef, OnInit, computed, inject, signal, viewChild } from '@angular/core';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';
import { ActivatedRoute, Router } from '@angular/router';
import {
  FilterTableUtils, SearchableDatatableComponent, SearchableDatatableModule, SharedAlertsService, extractErrorMessage,
} from '@duplocloud-internal/ng-common-lib';
import { AdminSettingService, REMOTE_UserSession } from '../admin-setting.service';
import { AdminSettingConsumer, AdminSettingConsumerService } from '../admin-setting-consumer.service';
import { StatusBadgeComponent } from '../shared/status-badge.component';

// List of the WORKSPACE resources that consume an admin setting. A normal workspace list — it re-fetches on
// workspace switch (getTenantRefreshTimer) — plus one cross-scope column: the name of the admin setting each
// row uses, resolved from the read-only admin view (members cannot call the admin route).
@Component({
  selector: 'asc-list',
  imports: [SearchableDatatableModule, StatusBadgeComponent],
  template: `
    <div class="card datatable-card">
      <searchable-datatable
        [showAdd]="true"
        addLabel="Use an Admin Setting"
        (add)="add()"
        [rows]="rows()"
        (filter)="filterUpdate()"
        columnMode="force">

        <ngx-datatable-column [width]="50" [sortable]="false" [canAutoResize]="false" cellClass="actions">
          <ng-template ngx-datatable-cell-template let-row="row">
            <div ngbDropdown container="body">
              <button class="btn btn-sm hide-arrow" ngbDropdownToggle>
                <i data-feather="more-vertical"></i>
              </button>
              <div ngbDropdownMenu>
                <a ngbDropdownItem (click)="view(row)"><i data-feather="eye" class="mr-50"></i><span>View</span></a>
                <a ngbDropdownItem (click)="edit(row)"><i data-feather="edit" class="mr-50"></i><span>Edit</span></a>
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

        <ngx-datatable-column name="Admin Setting" [flexGrow]="140">
          <ng-template ngx-datatable-cell-template let-row="row">{{ settingLabel(row.spec?.adminSettingId) }}</ng-template>
        </ngx-datatable-column>

        <ngx-datatable-column name="Applied" [flexGrow]="160">
          <ng-template ngx-datatable-cell-template let-row="row">{{ row.result?.summary || '—' }}</ng-template>
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
export class ListAdminSettingConsumerComponent implements OnInit {
  private readonly svc = inject(AdminSettingConsumerService);
  private readonly settings = inject(AdminSettingService);
  private readonly router = inject(Router);
  private readonly route = inject(ActivatedRoute);
  private readonly session = inject<any>(REMOTE_UserSession as any);
  private readonly destroyRef = inject(DestroyRef);
  private readonly alerts = inject(SharedAlertsService);

  private readonly table = viewChild(SearchableDatatableComponent);
  private readonly allRows = signal<AdminSettingConsumer[]>([]);
  private readonly filterTerm = signal('');
  /** Admin setting id → name, for the "Admin Setting" column. */
  private readonly settingNames = signal<Record<string, string>>({});

  private readonly searchFields = ['name', 'status', 'result.summary'];

  protected readonly rows = computed(() => {
    const term = this.filterTerm();
    const all = this.allRows();
    return term ? all.filter(r => FilterTableUtils.searchByFields(r, this.searchFields, term)) : all;
  });

  ngOnInit(): void {
    this.settings.list('workspace').pipe(takeUntilDestroyed(this.destroyRef)).subscribe({
      next: list => this.settingNames.set(Object.fromEntries(list.map(s => [s.id, s.name]))),
      error: () => this.settingNames.set({}),
    });
    // A workspace resource: getTenantRefreshTimer emits [tenant, tenantChanged] on first load, each poll tick
    // and every workspace switch; the flag is true only when the workspace changed.
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

  protected settingLabel(id?: string): string {
    return id ? (this.settingNames()[id] ?? id) : '—';
  }

  protected filterUpdate(): void {
    this.filterTerm.set(this.table()?.searchTerm?.toLowerCase()?.trim() ?? '');
  }

  protected add(): void {
    this.router.navigate(['add'], { relativeTo: this.route });
  }

  protected view(r: AdminSettingConsumer): void {
    this.router.navigate(['view', r.id], { relativeTo: this.route });
  }

  protected edit(r: AdminSettingConsumer): void {
    this.router.navigate(['edit', r.id], { relativeTo: this.route });
  }

  protected track(r: AdminSettingConsumer): void {
    this.svc.ticketName(r.id).pipe(takeUntilDestroyed(this.destroyRef)).subscribe({
      next: name => {
        if (!name) {
          this.alerts.reportError(`'${r.name}' has no provisioning ticket yet.`);
          return;
        }
        this.router.navigateByUrl(this.svc.ticketChatUrl(name));
      },
      error: err => this.alerts.reportError(extractErrorMessage(err), 'Could not open the provisioning ticket'),
    });
  }
}
