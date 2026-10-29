import { Component, DestroyRef, LOCALE_ID, OnInit, computed, inject, signal } from '@angular/core';
import { formatDate } from '@angular/common';
import { ActivatedRoute, Router } from '@angular/router';
import { Subscription, interval } from 'rxjs';
import { CommonLibComponentsModule } from '@duplocloud-internal/ng-common-lib';
import { SecretFieldServiceAccountService, SecretFieldServiceAccount } from '../secret-field-service-account.service';
import { StatusBadgeComponent } from '../shared/status-badge.component';
import { LifecyclePhase, LifecycleRailComponent, RailFact } from '../shared/lifecycle-rail.component';

// Detail view on the Extension Studio's Template-G shell (reference/19-detail-page.md), copied from
// templates/helloworld's view-hello.component.ts. The one addition is the eye icon on the Password
// tile — the frontend half of reference/21-secrets.md's reveal-endpoint recipe: the real value is
// fetched on demand, shown inline in the SAME tile, and cleared back to masked on toggle or navigation
// — never cached anywhere longer than that.
@Component({
  selector: 'sf-view',
  imports: [CommonLibComponentsModule, StatusBadgeComponent, LifecycleRailComponent],
  styleUrl: '../shared/detail-page.scss',
  template: `
    @if (item(); as it) {
      <div class="ext-detail-page">

        <header class="g-head">
          <span class="g-tile-ic"><i data-feather="key" size="26"></i></span>
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
                <span class="k">Username:</span>
                <span class="mono">{{ it.spec?.username || '—' }}</span>
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
                  <div class="g-tile">
                    <div class="g-tl">Username</div>
                    <span class="g-tv">{{ it.spec?.username || '—' }}</span>
                  </div>
                  <!-- The ONE place the real password ever reaches the browser — fetched on demand,
                       shown inline here, cleared back to masked on toggle. Gated server-side by the
                       separately-grantable secretfield.secret.read action. See reference/21-secrets.md. -->
                  <div class="g-tile">
                    <div class="g-tl">Password</div>
                    <span class="g-tv">
                      @if (revealedPassword(); as pw) {
                        <span class="mono">{{ pw }}</span>
                        <button type="button" class="btn btn-sm btn-flat-secondary p-0 ml-50"
                                aria-label="Hide password" (click)="revealedPassword.set(null)">
                          <i data-feather="eye-off" size="14"></i>
                        </button>
                      } @else {
                        <span>••••</span>
                        <button type="button" class="btn btn-sm btn-flat-secondary p-0 ml-50"
                                aria-label="Reveal password" [disabled]="revealing()" (click)="revealPassword()">
                          <i data-feather="eye" size="14"></i>
                        </button>
                      }
                    </span>
                  </div>
                  <div class="g-tile">
                    <div class="g-tl">Created</div>
                    <span class="g-tv">{{ fmt(it.createdAt) }}</span>
                  </div>
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
                        <div class="g-sec-h"><h3>Account</h3></div>
                        <div class="g-tiles c3">
                          <div class="g-tile wide">
                            <div class="g-tl">Account id</div>
                            <span class="g-tv">
                              {{ it.result?.accountId || '—' }}
                              @if (!it.result?.accountId) { <small>Generated by the agent once provisioning completes</small> }
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
export class ViewSecretFieldServiceAccountComponent implements OnInit {
  private static readonly WAITING = ['Blocked', 'WaitingForApproval'];
  private static readonly READY = ['Complete', 'Updated'];
  private static readonly TEARDOWN = ['DeProvisioning', 'DeprovisionInitiated', 'DeProvisioned', 'DeprovisionFailed'];

  private readonly svc = inject(SecretFieldServiceAccountService);
  private readonly router = inject(Router);
  private readonly route = inject(ActivatedRoute);
  private readonly destroyRef = inject(DestroyRef);
  private readonly locale = inject(LOCALE_ID);

  protected readonly item = signal<SecretFieldServiceAccount | undefined>(undefined);
  protected readonly view = signal<'spec' | 'result'>('spec');
  protected readonly tracking = signal(false);
  protected readonly revealing = signal(false);
  /** The real password, fetched on demand — cleared by the user or on navigation; never cached elsewhere. */
  protected readonly revealedPassword = signal<string | null>(null);
  protected activeTab = 'overview';

  private poll?: Subscription;

  protected readonly working = computed(() => {
    const s = this.item()?.status ?? '';
    return !!s && !ViewSecretFieldServiceAccountComponent.WAITING.includes(s)
      && !ViewSecretFieldServiceAccountComponent.READY.includes(s)
      && s !== 'Failed' && !ViewSecretFieldServiceAccountComponent.TEARDOWN.includes(s);
  });

  protected readonly phases = computed<LifecyclePhase[]>(() => {
    const it = this.item();
    if (!it) {
      return [];
    }
    const s = it.status;
    const waiting = ViewSecretFieldServiceAccountComponent.WAITING.includes(s);
    const ready = ViewSecretFieldServiceAccountComponent.READY.includes(s);
    const failed = s === 'Failed';
    const working = this.working();

    return [
      { label: 'Created', subtitle: this.fmt(it.createdAt), state: 'done' },
      {
        label: 'Provisioning',
        subtitle: working ? (it.subStatus || 'The agent is working')
          : failed ? (it.subStatus || it.faults?.[0] || 'Failed — see faults')
          : 'The agent creates the account',
        state: failed ? 'fail' : working ? 'now' : 'done',
      },
      {
        label: 'Needs your input',
        subtitle: waiting
          ? (s === 'WaitingForApproval' ? 'Approval pending' : (it.blockedReason || 'Question pending'))
          : 'The agent asked a question or needs an approval',
        state: waiting ? 'now' : (ready ? 'done' : 'todo'),
        action: waiting ? { label: 'Review', run: () => this.track() } : undefined,
      },
      {
        label: 'Ready',
        subtitle: ready ? `${it.result?.accountId ? 'Account created' : 'Complete'} · ${this.fmt(it.updatedAt)}` : undefined,
        state: ready ? 'done' : 'todo',
      },
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
    this.refresh();
    this.destroyRef.onDestroy(() => this.poll?.unsubscribe());
  }

  private refresh(): void {
    const id = this.route.snapshot.params['id'];
    this.svc.get(id).subscribe(i => {
      const first = !this.item();
      this.item.set(i);
      if (first) {
        this.view.set(i?.result?.accountId ? 'result' : 'spec');
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

  protected edit(): void {
    const it = this.item();
    if (it) {
      this.router.navigate(['../..', 'edit', it.id], { relativeTo: this.route });
    }
  }

  /** Fetches the real password and shows it transiently — gated server-side by secretfield.secret.read. */
  protected revealPassword(): void {
    const it = this.item();
    if (!it || this.revealing()) {
      return;
    }
    this.revealing.set(true);
    this.svc.revealPassword(it.id).subscribe({
      next: value => {
        this.revealing.set(false);
        this.revealedPassword.set(value || null);
      },
      error: () => {
        this.revealing.set(false);
        this.revealedPassword.set(null);
      },
    });
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
        const url = `/ai/service-desk/${this.svc.workspaceId()}/tickets/chat/${name}`;
        this.router.navigateByUrl(url).then(ok => { if (!ok) window.location.assign(url); })
          .catch(() => window.location.assign(url));
      },
      error: () => this.tracking.set(false),
    });
  }
}
