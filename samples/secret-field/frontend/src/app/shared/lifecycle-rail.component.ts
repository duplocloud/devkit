import { Component, input, output } from '@angular/core';
import { NgClass } from '@angular/common';

// One row of the provisioning timeline. The VIEW computes these from the resource's own status/result
// (see reference/19-detail-page.md → "Deriving phases"); this component only draws them.
export type LifecyclePhaseState = 'done' | 'now' | 'todo' | 'warn' | 'fail';

export interface LifecyclePhase {
  label: string;
  /** Live beat on the active phase (subStatus / blockedReason), a timestamp on a finished one, or a static explainer. */
  subtitle?: string;
  state: LifecyclePhaseState;
  /** Inline action rendered after the subtitle — the Studio's "Review" link while the agent waits on the user. */
  action?: { label: string; run: () => void };
}

export interface RailFact {
  label: string;
  value: string | number;
}

export interface RailCallout {
  text: string;
  /** Second line, rendered monospace (a repo ref, a resource id, a CIDR). */
  detail?: string;
  tone?: 'warn' | 'info';
  /** Feather icon name. */
  icon?: string;
}

// The Template-G right rail of a detail page: `Lifecycle` (phase timeline + Track status), `Attached`
// (counts / facts), and an optional data-derived callout. Mirrors the Extension Studio page's <aside
// class="g-rail"> — the host element is the rail column of the page's .g-cols grid.
//
// "Track status" lives HERE, inside the lifecycle card, not in a page footer: it opens the provisioning
// ticket, so it belongs beside the phases it explains. Only Agent-mode resources have a ticket — Worker
// and Passthrough views leave `trackable` false and the button is not rendered.
@Component({
  selector: 'ext-lifecycle-rail',
  imports: [NgClass],
  styleUrl: './lifecycle-rail.component.scss',
  template: `
    <div class="g-rcard">
      <div class="g-rh">{{ title() }}</div>
      <div class="g-tl-list">
        @for (p of phases(); track p.label) {
          <div class="g-ev" [ngClass]="p.state">
            <span class="dot"></span>
            <div>
              <b>{{ p.label }}</b>
              @if (p.subtitle || p.action) {
                <small>
                  {{ p.subtitle }}
                  @if (p.action; as a) {
                    <button type="button" class="g-ev-action" (click)="a.run()">{{ a.label }}</button>
                  }
                </small>
              }
            </div>
          </div>
        }
      </div>
      @if (trackable()) {
        <button type="button" class="btn btn-sm g-btn-ghost" [disabled]="trackBusy()" (click)="track.emit()">
          <i data-feather="activity" class="mr-50"></i>{{ trackLabel() }}
        </button>
      }
    </div>

    @if (attached().length) {
      <div class="g-rcard">
        <div class="g-rh">{{ attachedTitle() }}</div>
        @for (a of attached(); track a.label) {
          <div class="g-att"><span>{{ a.label }}</span><b>{{ a.value }}</b></div>
        }
      </div>
    }

    @if (callout(); as c) {
      <div class="g-callout" [ngClass]="c.tone ?? 'warn'">
        <i [attr.data-feather]="c.icon ?? 'alert-triangle'" size="16"></i>
        <div>
          <b>{{ c.text }}</b>
          @if (c.detail) { <div class="mono">{{ c.detail }}</div> }
        </div>
      </div>
    }
  `,
})
export class LifecycleRailComponent {
  readonly phases = input.required<LifecyclePhase[]>();
  readonly title = input('Lifecycle');
  readonly attached = input<RailFact[]>([]);
  readonly attachedTitle = input('Attached');
  readonly callout = input<RailCallout | null>(null);
  /** Render the Track button — true only when a provisioning ticket exists (Agent mode). */
  readonly trackable = input(false);
  readonly trackBusy = input(false);
  readonly trackLabel = input('Track status');
  readonly track = output<void>();
}
