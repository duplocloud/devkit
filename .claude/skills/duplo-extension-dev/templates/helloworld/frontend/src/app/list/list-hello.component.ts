import { Component, DestroyRef, OnInit, computed, inject, signal, viewChild } from '@angular/core';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';
import { ActivatedRoute, Router } from '@angular/router';
import { FilterTableUtils, SearchableDatatableComponent, SearchableDatatableModule } from '@duplocloud-internal/ng-common-lib';
import { HelloService, HelloWorld, REMOTE_UserSession } from '../hello.service';
import { HelloAnalytics } from '../analytics';
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
  selector: 'hw-list',
  imports: [SearchableDatatableModule, StatusBadgeComponent],
  template: `
    <div class="card datatable-card">
      <searchable-datatable
        [showAdd]="true"
        addLabel="Create Hello World"
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

        <ngx-datatable-column name="First Name" [flexGrow]="120">
          <ng-template ngx-datatable-cell-template let-row="row">{{ row.spec?.firstName || '—' }}</ng-template>
        </ngx-datatable-column>

        <ngx-datatable-column name="Last Name" [flexGrow]="120">
          <ng-template ngx-datatable-cell-template let-row="row">{{ row.spec?.lastName || '—' }}</ng-template>
        </ngx-datatable-column>

        <ngx-datatable-column name="Full Name" [flexGrow]="150">
          <ng-template ngx-datatable-cell-template let-row="row">{{ row.result?.fullName || '—' }}</ng-template>
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
export class ListHelloComponent implements OnInit {
  private readonly svc = inject(HelloService);
  private readonly router = inject(Router);
  private readonly route = inject(ActivatedRoute);
  // The host provides this under a STRING key. Functional inject() is typed for ProviderToken, so the
  // token needs a cast — unlike constructor @Inject(...), which accepts a bare string.
  private readonly session = inject<any>(REMOTE_UserSession as any);
  private readonly destroyRef = inject(DestroyRef);
  private readonly analytics = inject(HelloAnalytics);

  // The <searchable-datatable> owns the search box + term; we read its `searchTerm` when filtering.
  private readonly table = viewChild(SearchableDatatableComponent);

  /** Full unfiltered set from the last fetch. */
  private readonly allRows = signal<HelloWorld[]>([]);
  private readonly filterTerm = signal('');

  // Plain string fields or dot-paths only — searchByFields uses lodash `get`; no method calls.
  private readonly searchFields = ['name', 'status', 'spec.firstName', 'spec.lastName', 'result.fullName'];

  /** Rows shown in the table. Derived, so a fetch or a keystroke repaints without any manual wiring. */
  protected readonly rows = computed(() => {
    const term = this.filterTerm();
    const all = this.allRows();
    return term ? all.filter(r => FilterTableUtils.searchByFields(r, this.searchFields, term)) : all;
  });

  ngOnInit(): void {
    this.analytics.pageView('hello-list');
    // Re-fetch on first load, on every workspace switch, AND on each poll tick — no page reload needed.
    // getTenantRefreshTimer emits [tenant, tenantChanged]; the flag is true only when the workspace changed.
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

  // The search box lives inside <searchable-datatable>; it emits (filter) on each keystroke. We hold the
  // term in a signal and let `rows` recompute from it.
  protected filterUpdate(): void {
    this.filterTerm.set(this.table()?.searchTerm?.toLowerCase()?.trim() ?? '');
  }

  protected add(): void {
    this.router.navigate(['add'], { relativeTo: this.route });
  }

  protected view(r: HelloWorld): void {
    this.router.navigate(['view', r.id], { relativeTo: this.route });
  }

  protected edit(r: HelloWorld): void {
    this.router.navigate(['edit', r.id], { relativeTo: this.route });
  }

  protected track(r: HelloWorld): void {
    this.analytics.action('track-provisioning');
    this.svc.ticketName(r.id).subscribe(name => {
      if (!name) {
        return;
      }
      this.router.navigate(['/ai/service-desk', this.svc.workspaceId(), 'tickets', 'chat', name]);
    });
  }
}
