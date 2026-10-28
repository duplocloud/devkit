import { Component, DestroyRef, OnInit, inject, input, signal } from '@angular/core';
import { Subscription, forkJoin, interval } from 'rxjs';
import { CommonLibComponentsModule } from '@duplocloud-internal/ng-common-lib';
import { NetworkStack, NetworkStackService, RunMeta } from '../network-stack.service';
import { AnsiStripPipe } from './ansi-strip.pipe';
import { AutoScrollBottomDirective } from './auto-scroll-bottom.directive';

// Logs tab body: the run history (plans + applies, newest first) with click-to-open raw terraform logs.
// Self-loads in ngOnInit — ngbNavContent instantiates a tab's content only when it is first shown, so
// ngOnInit IS the "tab opened" hook and no data is fetched for tabs the user never opens (reference/17).
// The files behind this live in the ticket workdir; the backend serves them via ITicketService
// (reference/05 §7 — GET {id}/plan-history | apply-history | plans/{runId} | applies/{runId}).
@Component({
  selector: 'ns-logs-panel',
  imports: [CommonLibComponentsModule, AnsiStripPipe, AutoScrollBottomDirective],
  styles: [`
    /* min-height keeps the console from collapsing between live-tail fetches; the terminal tokens are the same in both modes. */
    .console { background: var(--terminal-bg); color: var(--terminal-fg); border-radius: 6px; padding: .75rem;
      min-height: 160px; max-height: 420px; overflow: auto; font-size: .8rem; white-space: pre-wrap; }
    .run-row { cursor: pointer; }
    .run-row.active { background: color-mix(in srgb, var(--primary) 8%, transparent); }
    .live-dot { width: 8px; height: 8px; border-radius: 50%; background: var(--success); display: inline-block;
      margin-right: .35rem; animation: ns-pulse 1.2s ease-in-out infinite; }
    @keyframes ns-pulse { 50% { opacity: .35; } }
  `],
  template: `
    <div class="p-1">
      <div class="d-flex align-items-center mb-50">
        <h6 class="text-muted mb-0 mr-auto">Runs</h6>
        <button class="btn btn-outline-secondary btn-sm" (click)="reload()" [disabled]="loading()">
          {{ loading() ? 'Refreshing…' : 'Refresh' }}
        </button>
      </div>

      @if (runs().length) {
        <div class="list-group list-group-flush mb-1">
          @for (r of runs(); track r.runId) {
            <a class="list-group-item d-flex align-items-center px-50 py-50 run-row"
               [class.active]="r.runId === openRunId()" (click)="open(r)">
              <span class="badge badge-pill mr-75"
                    [class.badge-success]="r.success" [class.badge-danger]="!r.success && !r.running"
                    [class.badge-info]="r.running">
                {{ r.running ? 'running' : (r.success ? 'ok' : 'failed') }}
              </span>
              <span class="text-capitalize font-weight-bold mr-75">{{ r.verb }}</span>
              <span class="text-muted text-truncate mr-auto">{{ r.summary || '—' }}</span>
              <small class="text-muted">{{ r.ranAt | date:'medium' }}</small>
            </a>
          }
        </div>
      } @else {
        <p class="text-muted font-small-3">No runs yet — the first appears when provisioning starts.</p>
      }

      @if (log(); as l) {
        @if (tailing()) {
          <div class="text-muted font-small-3 mb-25"><span class="live-dot"></span>live — following the run</div>
        }
        <pre class="console" autoScrollBottom>{{ l | ansiStrip }}</pre>
      }
    </div>
  `,
})
export class LogsPanelComponent implements OnInit {
  private readonly svc = inject(NetworkStackService);
  private readonly destroyRef = inject(DestroyRef);

  readonly item = input.required<NetworkStack>();

  protected readonly runs = signal<RunMeta[]>([]);
  protected readonly loading = signal(false);
  protected readonly openRunId = signal<string | null>(null);
  protected readonly log = signal<string | null>(null);
  /** True while the open run is still running and this panel is live-tailing its log. */
  protected readonly tailing = signal(false);

  // The panel owns its own tail poll: the PARENT's poll follows resource status, but a run's log keeps
  // growing between status posts — tail it here every 3s while the run's meta says running (reference/17:
  // a panel whose data changes after the parent's poll stopped polls itself).
  private tail?: Subscription;

  ngOnInit(): void {
    this.reload();
    this.destroyRef.onDestroy(() => this.tail?.unsubscribe());
  }

  protected reload(): void {
    const id = this.item().id;
    this.loading.set(true);
    // Plans and applies are separate stores; fetch them IN PARALLEL and merge newest-first for the UI.
    forkJoin([this.svc.planHistory(id), this.svc.applyHistory(id)]).subscribe(([plans, applies]) => {
      const all = [...plans, ...applies]
        .sort((a, b) => (b.ranAt || '').localeCompare(a.ranAt || ''));
      this.runs.set(all);
      this.loading.set(false);
    });
  }

  // Consecutive tail fetches that returned nothing — a persistently failing endpoint must not poll forever.
  private tailMisses = 0;

  protected open(r: RunMeta): void {
    this.openRunId.set(r.runId);
    this.log.set(null);
    this.stopTail();
    this.fetchLog(r);
    if (r.running) {
      this.tailing.set(true);
      this.tailMisses = 0;
      this.tail = interval(3000).subscribe(() => this.fetchLog(r));
    }
  }

  // NOTE (sample-scale trade-off): each tick refetches the WHOLE log — fine for a few MB; a production
  // extension should add a byte-offset param to the log endpoint and append only the delta.
  private fetchLog(r: RunMeta): void {
    const kind = r.verb === 'plan' ? 'plans' : 'applies';
    this.svc.runDetail(this.item().id, kind, r.runId).subscribe(d => {
      // Stale-response guard: the user may have opened another run while this fetch was in flight — a
      // late response must neither paint the wrong log nor kill the newly-opened run's tail.
      if (this.openRunId() !== r.runId) {
        return;
      }
      if (d === null) {
        // transient failure — keep the last log; give up tailing after ~1 min of consecutive misses
        if (this.tail && ++this.tailMisses >= 20) {
          this.stopTail();
        }
        this.log.set(this.log() ?? '(log unavailable)');
        return;
      }
      this.tailMisses = 0;
      this.log.set(d.log ?? '(log unavailable)');
      // The run finished: stop tailing and refresh the run list so its badge flips.
      if (this.tail && d.meta && !d.meta.running) {
        this.stopTail();
        this.reload();
      }
    });
  }

  private stopTail(): void {
    this.tail?.unsubscribe();
    this.tail = undefined;
    this.tailing.set(false);
  }
}
