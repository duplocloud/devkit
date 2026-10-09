import { Component, DestroyRef, OnInit, computed, inject, signal, viewChild } from '@angular/core';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';
import { ActivatedRoute, Router } from '@angular/router';
import { FilterTableUtils, SearchableDatatableComponent, SearchableDatatableModule } from '@duplocloud-internal/ng-common-lib';
import { AdminSettingService, AdminSetting } from '../admin-setting.service';
import { StatusBadgeComponent } from '../shared/status-badge.component';

// List view built on the platform UI library's <searchable-datatable> (from
// @duplocloud-internal/ng-common-lib) so it matches the rest of the suite — search, paging, and the
// actions dropdown come for free. Columns are projected as <ngx-datatable-column> children.
//
// Standalone with no `changeDetection` line: Angular 22 components are OnPush by default, and every
// piece of async state here is a signal, so writes mark the view dirty on their own.
// SearchableDatatableModule re-exports NgbModule + NgxDatatableModule, which is where ngbDropdown and
// ngx-datatable-cell-template come from — importing it alone covers this template.
@Component({
  selector: 'as-list',
  imports: [SearchableDatatableModule, StatusBadgeComponent],
  template: `
    <div class="card datatable-card">
      <searchable-datatable
        [showAdd]="true"
        addLabel="Create Admin Setting"
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

        <ngx-datatable-column name="Key" [flexGrow]="120">
          <ng-template ngx-datatable-cell-template let-row="row">{{ row.spec?.settingKey || '—' }}</ng-template>
        </ngx-datatable-column>

        <ngx-datatable-column name="Value" [flexGrow]="150">
          <ng-template ngx-datatable-cell-template let-row="row">{{ row.spec?.settingValue || '—' }}</ng-template>
        </ngx-datatable-column>

        <ngx-datatable-column name="Applied" [flexGrow]="150">
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
export class ListAdminSettingComponent implements OnInit {
  private readonly svc = inject(AdminSettingService);
  private readonly router = inject(Router);
  private readonly route = inject(ActivatedRoute);
  // The host provides this under a STRING key. Functional inject() is typed for ProviderToken, so the
  // token needs a cast — unlike constructor @Inject(...), which accepts a bare string. Used only for the
  // list-refresh timer: an admin-scoped list never reads the selected tenant.
  private readonly session = inject<any>('REMOTE_UserSession' as any);
  private readonly destroyRef = inject(DestroyRef);

  // The <searchable-datatable> owns the search box + term; we read its `searchTerm` when filtering.
  private readonly table = viewChild(SearchableDatatableComponent);

  /** Full unfiltered set from the last fetch. */
  private readonly allRows = signal<AdminSetting[]>([]);
  private readonly filterTerm = signal('');

  // Plain string fields or dot-paths only — searchByFields uses lodash `get`; no method calls.
  private readonly searchFields = ['name', 'status', 'spec.settingKey', 'spec.settingValue', 'result.summary'];

  /** Rows shown in the table. Derived, so a fetch or a keystroke repaints without any manual wiring. */
  protected readonly rows = computed(() => {
    const term = this.filterTerm();
    const all = this.allRows();
    return term ? all.filter(r => FilterTableUtils.searchByFields(r, this.searchFields, term)) : all;
  });

  ngOnInit(): void {
    // Re-fetch on first load and on each poll tick. Admin-scoped rows all belong to the Admin Workspace, so
    // a workspace switch changes nothing: use the plain refresh timer, not getTenantRefreshTimer.
    let first = true;
    this.session.getRefreshTimer(true)
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe(() => {
        this.refresh(first);
        first = false;
      });
  }

  private refresh(showLoading: boolean): void {
    if (showLoading) {
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

  // The search box lives inside <searchable-datatable>; it emits (filter) on each keystroke. We hold the
  // term in a signal and let `rows` recompute from it.
  protected filterUpdate(): void {
    this.filterTerm.set(this.table()?.searchTerm?.toLowerCase()?.trim() ?? '');
  }

  protected add(): void {
    this.router.navigate(['add'], { relativeTo: this.route });
  }

  protected view(r: AdminSetting): void {
    this.router.navigate(['view', r.id], { relativeTo: this.route });
  }

  protected edit(r: AdminSetting): void {
    this.router.navigate(['edit', r.id], { relativeTo: this.route });
  }

  protected track(r: AdminSetting): void {
    this.svc.ticketName(r.id).subscribe(name => {
      if (!name) {
        return;
      }
      // Admin-scoped: the ticket lives in the hidden Admin Workspace, so it opens under AI Admin.
      this.router.navigateByUrl(this.svc.ticketChatUrl(name));
    });
  }
}
