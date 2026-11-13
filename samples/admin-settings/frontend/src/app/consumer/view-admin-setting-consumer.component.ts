import { Component, DestroyRef, LOCALE_ID, OnInit, computed, inject, signal } from '@angular/core';
import { formatDate } from '@angular/common';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';
import { ActivatedRoute, Router } from '@angular/router';
import { timer } from 'rxjs';
import { exhaustMap, takeWhile, tap } from 'rxjs/operators';
import { CommonLibComponentsModule, SharedAlertsService, extractErrorMessage } from '@duplocloud-internal/ng-common-lib';
import { AdminSetting, AdminSettingService } from '../admin-setting.service';
import { AdminSettingConsumer, AdminSettingConsumerService } from '../admin-setting-consumer.service';
import { StatusBadgeComponent } from '../shared/status-badge.component';
import { LifecyclePhase, LifecycleRailComponent, RailFact } from '../shared/lifecycle-rail.component';

// Detail view for the workspace resource that consumes an admin setting — the same Template-G shell and
// polling stream as view-admin-setting.component.ts (see the comments there). Cross-scope part: the "Admin
// setting" tiles come from the read-only workspace view of that setting, so they show its name, key and status
// but never its value.
@Component({
  selector: 'asc-view',
  imports: [CommonLibComponentsModule, StatusBadgeComponent, LifecycleRailComponent],
  styleUrl: '../shared/detail-page.scss',
  template: `
    @if (loadError(); as e) {
      <div class="alert alert-danger py-1 px-2 m-1">Could not load this setting consumer: {{ e }}</div>
    }
    @if (item(); as it) {
      <div class="ext-detail-page">

        <header class="g-head">
          <span class="g-tile-ic"><i data-feather="refresh-cw" size="26"></i></span>
          <div class="g-head-main">
            <div class="g-head-t">
              <h1>{{ it.name }}</h1>
              <app-status-badge [status]="it.status"></app-status-badge>
              @if (working()) {
                <span class="dots-loader text-warning"><span></span><span></span><span></span></span>
              }
            </div>
            <div class="g-meta">
              <span class="g-meta-item">
                <span class="k">Admin setting:</span>
                <span class="mono">{{ setting()?.name || it.spec?.adminSettingId || '—' }}</span>
              </span>
            </div>
          </div>
          <div class="g-actions">
            <button type="button" class="btn btn-sm btn-primary" [disabled]="tracking()" (click)="track()">
              <i data-feather="terminal" class="mr-50"></i>Ask agent
            </button>
            <div ngbDropdown container="body" placement="bottom-right">
              <button type="button" class="btn btn-sm hide-arrow" aria-label="More actions" ngbDropdownToggle>
                <i data-feather="more-vertical"></i>
              </button>
              <div ngbDropdownMenu>
                <a ngbDropdownItem (click)="edit()"><i data-feather="edit" class="mr-50"></i> Edit</a>
              </div>
            </div>
          </div>
        </header>

        <div class="g-cols">
          <section class="g-card g-main">
            @if (it.faults?.length) {
              <div class="alert alert-danger py-1 px-2 mb-1">
                @for (f of it.faults; track f) { <div>{{ f }}</div> }
              </div>
            }
            <div class="g-sec pt-1">
              <div class="g-sec-h"><h3>Admin setting</h3></div>
              <div class="g-tiles c3">
                <div class="g-tile"><div class="g-tl">Name</div><span class="g-tv">{{ setting()?.name || '—' }}</span></div>
                <div class="g-tile"><div class="g-tl">Key</div><span class="g-tv mono">{{ setting()?.spec?.settingKey || '—' }}</span></div>
                <div class="g-tile">
                  <div class="g-tl">Status</div>
                  <span class="g-tv">
                    @if (setting(); as s) { <app-status-badge [status]="s.status"></app-status-badge> }
                    @else { <small>Not found — an administrator may have removed it</small> }
                  </span>
                </div>
              </div>
            </div>
            <div class="g-sec">
              <div class="g-sec-h"><h3>Applied in this workspace</h3></div>
              <div class="g-tiles c3">
                <div class="g-tile wide">
                  <div class="g-tl">Summary</div>
                  <span class="g-tv">
                    {{ it.result?.summary || '—' }}
                    @if (!it.result?.summary) { <small>Written by the agent once provisioning completes</small> }
                  </span>
                </div>
              </div>
            </div>
          </section>

          <ext-lifecycle-rail
            [phases]="phases()"
            [attached]="attached()"
            [trackable]="true"
            [trackBusy]="tracking()"
            (track)="track()" />
        </div>
      </div>
    } @else if (!loadError()) {
      <div class="text-muted p-2">Loading…</div>
    }
  `,
})
export class ViewAdminSettingConsumerComponent implements OnInit {
  private static readonly WAITING = ['Blocked', 'WaitingForApproval'];
  private static readonly READY = ['Complete', 'Updated'];
  private static readonly TEARDOWN = ['DeProvisioning', 'DeprovisionInitiated', 'DeProvisioned', 'DeprovisionFailed'];

  private readonly svc = inject(AdminSettingConsumerService);
  private readonly settings = inject(AdminSettingService);
  private readonly router = inject(Router);
  private readonly route = inject(ActivatedRoute);
  private readonly destroyRef = inject(DestroyRef);
  private readonly locale = inject(LOCALE_ID);
  private readonly alerts = inject(SharedAlertsService);

  protected readonly item = signal<AdminSettingConsumer | undefined>(undefined);
  /** The referenced admin setting, as the read-only workspace view returns it (no value). */
  protected readonly setting = signal<AdminSetting | undefined>(undefined);
  protected readonly tracking = signal(false);
  protected readonly loadError = signal<string | undefined>(undefined);

  protected readonly working = computed(() => {
    const s = this.item()?.status ?? '';
    const C = ViewAdminSettingConsumerComponent;
    return !!s && !C.WAITING.includes(s) && !C.READY.includes(s) && s !== 'Failed' && !C.TEARDOWN.includes(s);
  });

  protected readonly phases = computed<LifecyclePhase[]>(() => {
    const it = this.item();
    if (!it) {
      return [];
    }
    const C = ViewAdminSettingConsumerComponent;
    const waiting = C.WAITING.includes(it.status);
    const ready = C.READY.includes(it.status);
    const failed = it.status === 'Failed';
    const working = this.working();
    return [
      { label: 'Created', subtitle: this.fmt(it.createdAt), state: 'done' },
      {
        label: 'Provisioning',
        subtitle: working ? (it.subStatus || 'The agent is working')
          : failed ? (it.subStatus || it.faults?.[0] || 'Failed — see faults')
          : 'The agent applies the admin setting to this workspace',
        state: failed ? 'fail' : working ? 'now' : 'done',
      },
      {
        label: 'Needs your input',
        subtitle: waiting ? (it.blockedReason || 'Question pending') : 'The agent asked a question or needs an approval',
        state: waiting ? 'now' : (ready ? 'done' : 'todo'),
        action: waiting ? { label: 'Review', run: () => this.track() } : undefined,
      },
      { label: 'Ready', subtitle: ready ? `Applied · ${this.fmt(it.updatedAt)}` : undefined, state: ready ? 'done' : 'todo' },
    ];
  });

  protected readonly attached = computed<RailFact[]>(() => [
    { label: 'Created', value: this.fmt(this.item()?.createdAt) },
    { label: 'Updated', value: this.fmt(this.item()?.updatedAt) },
  ]);

  ngOnInit(): void {
    const id = this.route.snapshot.params['id'];
    timer(0, 3000).pipe(
      exhaustMap(() => this.svc.get(id)),
      tap(i => {
        const settingId = i?.spec?.adminSettingId;
        if (settingId && settingId !== this.item()?.spec?.adminSettingId) {
          this.loadSetting(settingId);
        }
        this.item.set(i);
      }),
      takeWhile(() => this.working()),
      takeUntilDestroyed(this.destroyRef),
    ).subscribe({
      error: err => this.loadError.set(extractErrorMessage(err)),
    });
  }

  private loadSetting(settingId: string): void {
    this.settings.get(settingId, 'workspace').pipe(takeUntilDestroyed(this.destroyRef)).subscribe({
      next: s => this.setting.set(s),
      error: () => this.setting.set(undefined),   // 404: removed by an administrator — the tile says so
    });
  }

  protected fmt(v?: string): string {
    return v ? formatDate(v, 'medium', this.locale) : '—';
  }

  protected edit(): void {
    const it = this.item();
    if (it) {
      this.router.navigate(['../..', 'edit', it.id], { relativeTo: this.route });
    }
  }

  protected track(): void {
    const it = this.item();
    if (!it) {
      return;
    }
    this.tracking.set(true);
    this.svc.ticketName(it.id).pipe(takeUntilDestroyed(this.destroyRef)).subscribe({
      next: name => {
        this.tracking.set(false);
        if (!name) {
          this.alerts.reportError(`'${it.name}' has no provisioning ticket yet.`);
          return;
        }
        const url = this.svc.ticketChatUrl(name);
        this.router.navigateByUrl(url).then(ok => { if (!ok) window.location.assign(url); })
          .catch(() => window.location.assign(url));
      },
      error: err => {
        this.tracking.set(false);
        this.alerts.reportError(extractErrorMessage(err), 'Could not open the provisioning ticket');
      },
    });
  }
}
