import { Component, DestroyRef, LOCALE_ID, OnInit, computed, inject, signal } from '@angular/core';
import { formatDate } from '@angular/common';
import { ActivatedRoute, Router } from '@angular/router';
import { Subscription, interval } from 'rxjs';
import { CommonLibComponentsModule } from '@duplocloud-internal/ng-common-lib';
import { HelloService, HelloWorld } from '../hello.service';
import { HelloAnalytics } from '../analytics';
import { StatusBadgeComponent } from '../shared/status-badge.component';
import { LifecyclePhase, LifecycleRailComponent, RailFact } from '../shared/lifecycle-rail.component';

// Detail view on the Extension Studio's Template-G shell (reference/19-detail-page.md):
//  • header WITHOUT a card — icon tile · name + status badge (+ working pulse) · meta row · actions
//    (Spec | Result segmented switcher, primary "Ask agent", ⋮ menu);
//  • body grid — the main card left (Spec tiles, or the Result tab strip), the lifecycle rail right;
//  • the rail's Lifecycle card is the provisioning timeline, with "Track status" INSIDE it (no footer);
//  • the Result body is hand-written for THIS resource — never a declarative template.
//
// This is an AGENT-mode resource: a provisioning ticket exists, so "Ask agent" / "Track status" open it and
// the phase ladder includes "Needs your input" (Blocked / WaitingForApproval). Worker and Passthrough
// resources drop those (see samples/worker-compute, samples/passthrough-configmap).
//
// CommonLibComponentsModule re-exports CommonModule (date pipe), NgbModule (ngbNav, ngbDropdown) and
// scrollable-nav-tab, so it is the only platform import this view needs.
@Component({
  selector: 'hw-view',
  imports: [CommonLibComponentsModule, StatusBadgeComponent, LifecycleRailComponent],
  styleUrl: '../shared/detail-page.scss',
  template: `
    @if (item(); as it) {
      <div class="ext-detail-page">

        <header class="g-head">
          <span class="g-tile-ic"><i data-feather="user" size="26"></i></span>
          <div class="g-head-main">
            <div class="g-head-t">
              <h1>{{ it.name }}</h1>
              <app-status-badge [status]="it.status"></app-status-badge>
              @if (working()) {
                <span class="dots-loader text-warning"><span></span><span></span><span></span></span>
              }
            </div>
            <div class="g-meta">
              @if (it.createdAt) {
                <span class="g-meta-item"><span class="k">Created:</span> {{ it.createdAt | date:'medium' }}</span>
                <span class="sep">·</span>
              }
              <span class="g-meta-item">
                <span class="k">Requested:</span>
                <span class="mono">{{ it.spec?.firstName || '—' }} {{ it.spec?.lastName || '' }}</span>
              </span>
            </div>
          </div>
          <div class="g-actions">
            <div class="seg" role="group" aria-label="View">
              <button type="button" [class.active]="view() === 'spec'" (click)="view.set('spec')">Spec</button>
              <button type="button" [class.active]="view() === 'result'" (click)="view.set('result')">Result</button>
            </div>
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
            @if (view() === 'spec') {
              <div class="g-sec pt-1">
                <div class="g-sec-h"><h3>Requested spec</h3></div>
                <div class="g-tiles c3">
                  @for (t of specTiles(); track t.label) {
                    <div class="g-tile">
                      <div class="g-tl">{{ t.label }}</div>
                      <span class="g-tv">{{ t.value }}</span>
                    </div>
                  }
                </div>
              </div>
            } @else {
              <scrollable-nav-tab>
                <ul ngbNav #resultNav="ngbNav" class="nav nav-tabs flat-tabs g-tabs" [(activeId)]="activeTab">
                  <li [ngbNavItem]="'overview'">
                    <a ngbNavLink>Overview</a>
                    <ng-template ngbNavContent>
                      @if (it.faults?.length) {
                        <div class="alert alert-danger py-1 px-2 mb-1">
                          @for (f of it.faults; track f) { <div>{{ f }}</div> }
                        </div>
                      }
                      <div class="g-sec">
                        <div class="g-sec-h"><h3>Greeting</h3></div>
                        <div class="g-tiles c3">
                          <div class="g-tile wide">
                            <div class="g-tl">Full name</div>
                            <span class="g-tv">
                              {{ it.result?.fullName || '—' }}
                              @if (!it.result?.fullName) { <small>Generated by the agent once provisioning completes</small> }
                            </span>
                          </div>
                          <div class="g-tile">
                            <div class="g-tl">Status</div>
                            <span class="g-tv"><app-status-badge [status]="it.status"></app-status-badge></span>
                          </div>
                        </div>
                      </div>
                    </ng-template>
                  </li>
                </ul>
              </scrollable-nav-tab>
              <div [ngbNavOutlet]="resultNav" class="mt-50"></div>
            }
          </section>

          <ext-lifecycle-rail
            [phases]="phases()"
            [attached]="attached()"
            [trackable]="true"
            [trackBusy]="tracking()"
            (track)="track()" />
        </div>
      </div>
    } @else {
      <div class="text-muted p-2">Loading…</div>
    }
  `,
})
export class ViewHelloComponent implements OnInit {
  // Statuses that end a provisioning run. Anything else means the agent is still working, so the page polls.
  private static readonly WAITING = ['Blocked', 'WaitingForApproval'];
  private static readonly READY = ['Complete', 'Updated'];
  private static readonly TEARDOWN = ['DeProvisioning', 'DeprovisionInitiated', 'DeProvisioned', 'DeprovisionFailed'];

  private readonly svc = inject(HelloService);
  private readonly router = inject(Router);
  private readonly route = inject(ActivatedRoute);
  private readonly destroyRef = inject(DestroyRef);
  private readonly locale = inject(LOCALE_ID);
  private readonly analytics = inject(HelloAnalytics);

  protected readonly item = signal<HelloWorld | undefined>(undefined);
  protected readonly view = signal<'spec' | 'result'>('spec');
  protected readonly tracking = signal(false);
  // ngbNav writes this from a template event — a plain field repaints fine under OnPush; don't make it a signal.
  protected activeTab = 'overview';

  private poll?: Subscription;

  /** The agent is mid-run: not waiting on the user, not finished, not failed, not tearing down. */
  protected readonly working = computed(() => {
    const s = this.item()?.status ?? '';
    return !!s && !ViewHelloComponent.WAITING.includes(s) && !ViewHelloComponent.READY.includes(s)
      && s !== 'Failed' && !ViewHelloComponent.TEARDOWN.includes(s);
  });

  /**
   * The provisioning timeline — THIS resource's phases, derived from status + result, not a generic status
   * ladder. The active phase carries the agent's live beat (subStatus / blockedReason); finished phases carry
   * a timestamp; pending ones a one-line explainer. See reference/19-detail-page.md → "Deriving phases".
   */
  protected readonly phases = computed<LifecyclePhase[]>(() => {
    const it = this.item();
    if (!it) {
      return [];
    }
    const s = it.status;
    const waiting = ViewHelloComponent.WAITING.includes(s);
    const ready = ViewHelloComponent.READY.includes(s);
    const failed = s === 'Failed';
    const working = this.working();

    return [
      { label: 'Created', subtitle: this.fmt(it.createdAt), state: 'done' },
      {
        label: 'Provisioning',
        subtitle: working ? (it.subStatus || 'The agent is working')
          : failed ? (it.subStatus || it.faults?.[0] || 'Failed — see faults')
          : 'The agent generates the greeting',
        state: failed ? 'fail' : working ? 'now' : 'done',
      },
      {
        label: 'Needs your input',
        subtitle: waiting
          ? (s === 'WaitingForApproval' ? 'Approval pending' : (it.blockedReason || 'Question pending'))
          : 'The agent asked a question or needs an approval',
        state: waiting ? 'now' : (ready ? 'done' : 'todo'),
        // Answer right from the timeline: the ticket is where the question lives.
        action: waiting ? { label: 'Review', run: () => this.track() } : undefined,
      },
      {
        label: 'Ready',
        subtitle: ready ? `${it.result?.fullName ? 'Greeting generated' : 'Complete'} · ${this.fmt(it.updatedAt)}` : undefined,
        state: ready ? 'done' : 'todo',
      },
    ];
  });

  protected readonly specTiles = computed(() => {
    const it = this.item();
    return [
      { label: 'First name', value: it?.spec?.firstName || '—' },
      { label: 'Last name', value: it?.spec?.lastName || '—' },
      { label: 'Created', value: this.fmt(it?.createdAt) },
    ];
  });

  protected readonly attached = computed<RailFact[]>(() => {
    const it = this.item();
    return [
      { label: 'Created', value: this.fmt(it?.createdAt) },
      { label: 'Updated', value: this.fmt(it?.updatedAt) },
    ];
  });

  ngOnInit(): void {
    this.analytics.pageView('hello-detail');
    this.refresh();
    this.destroyRef.onDestroy(() => this.poll?.unsubscribe());
  }

  /** GET + a 3s poll while the agent is working, so the active phase moves; the poll stops at a terminal status. */
  private refresh(): void {
    const id = this.route.snapshot.params['id'];
    this.svc.get(id).subscribe(i => {
      const first = !this.item();
      this.item.set(i);
      if (first) {
        this.view.set(i?.result?.fullName ? 'result' : 'spec');
      }
      if (this.working() && !this.poll) {
        this.poll = interval(3000).subscribe(() => this.refresh());
      }
      if (!this.working() && this.poll) {
        this.poll.unsubscribe();
        this.poll = undefined;
      }
    });
  }

  protected fmt(v?: string): string {
    return v ? formatDate(v, 'medium', this.locale) : '—';
  }

  // 'view/:id' is two URL segments, so climb both before addressing the sibling 'edit/:id'.
  protected edit(): void {
    const it = this.item();
    if (it) {
      this.router.navigate(['../..', 'edit', it.id], { relativeTo: this.route });
    }
  }

  /** Open the provisioning ticket's chat — "Ask agent" in the header and "Track status" in the rail both land here. */
  protected track(): void {
    const it = this.item();
    if (!it) {
      return;
    }
    this.tracking.set(true);
    this.svc.ticketName(it.id).subscribe({
      next: name => {
        this.tracking.set(false);
        if (!name) {
          return;
        }
        // Host routes can no-op from a remote — fall back to a hard navigation (reference/16 pitfalls).
        const url = `/ai/service-desk/${this.svc.workspaceId()}/tickets/chat/${name}`;
        this.router.navigateByUrl(url).then(ok => { if (!ok) window.location.assign(url); })
          .catch(() => window.location.assign(url));
      },
      error: () => this.tracking.set(false),
    });
  }
}
