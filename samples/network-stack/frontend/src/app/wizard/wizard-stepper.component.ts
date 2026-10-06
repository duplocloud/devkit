import { Component, computed, input, output } from '@angular/core';
import { AiDisclosureComponent } from '@duplocloud-internal/ng-common-lib';

export interface WizardStep {
  key: string;
  label: string;
}

/**
 * Sample-local multi-step wizard chrome: a numbered step header (done ✓ / active / todo, with a connecting
 * progress line) plus a Back / "Step N of M" / Cancel / Next→ footer. The published UI library
 * (@duplocloud-internal/ng-common-lib) ships NO stepper/wizard component — the host's own multi-step forms
 * each hand-roll one (bs-stepper / ngb-accordion) in portal-internal code an extension can't import. So a
 * wizard extension copies THIS component. The step BODIES use SharedFormsModule (form-field + validation);
 * only this chrome is bespoke.
 *
 * The PARENT owns the step index and per-step validity: it renders every step's body inside
 * <duplo-wizard-stepper> and toggles them with [hidden], passes [nextDisabled] = current group's `.invalid`,
 * and advances/rewinds activeIndex on (next)/(back). (finish) fires on the last step; (cancel) any time.
 * Template-driven throughout — Reactive Forms are forbidden by house style.
 *
 * The lib ships COMPILED CSS only, so the circle/line styling lives here in `styles` (the same constraint the
 * samples already handle for the `panel-form-accordion` layout).
 */
@Component({
  selector: 'duplo-wizard-stepper',
  imports: [AiDisclosureComponent],
  styles: [`
    :host { display: block; }
    /* One centered card: title, stepper, body and footer share a single width so nothing drifts apart.
       Consumers must NOT wrap this in another card — pass [title]/[subtitle]/[maxWidth] instead. */
    .wz-card { background: #fff; border-radius: 6px; margin: 0 auto; box-shadow: 0 4px 24px rgba(34, 41, 47, .08); }
    .wz-title { padding: 1.25rem 1.5rem; border-bottom: 1px solid #ebe9f1; }
    .wz-title h4 { margin-bottom: .25rem; }
    .wz-head { display: flex; align-items: flex-start; padding: 1.25rem 1.5rem; border-bottom: 1px solid #ebe9f1; }
    .wz-step { display: flex; align-items: center; flex-direction: column; min-width: 90px; }
    .wz-circle {
      width: 34px; height: 34px; border-radius: 50%; display: flex; align-items: center; justify-content: center;
      font-weight: 600; font-size: 0.9rem; border: 2px solid #d8d6de; color: #b9b9c3; background: #fff;
    }
    .wz-step.active .wz-circle { background: #7367f0; border-color: #7367f0; color: #fff; }
    .wz-step.done   .wz-circle { background: #28c76f; border-color: #28c76f; color: #fff; }
    .wz-label { margin-top: .4rem; font-size: .82rem; color: #b9b9c3; white-space: nowrap; }
    .wz-step.active .wz-label { color: #7367f0; font-weight: 600; }
    .wz-step.done   .wz-label { color: #6e6b7b; }
    .wz-line { flex: 1 1 auto; height: 2px; background: #ebe9f1; margin: 17px .5rem 0; }
    .wz-line.done { background: #28c76f; }
    .wz-body { padding: 1.5rem; }
    .wz-foot { display: flex; align-items: center; padding: 1rem 1.5rem; border-top: 1px solid #ebe9f1; }
    .wz-count { color: #b9b9c3; font-size: .85rem; }
  `],
  template: `
    <div class="wz-card" [style.max-width]="maxWidth()">
      <!-- Page heading — what this wizard creates and what happens on finish -->
      @if (title()) {
        <div class="wz-title">
          <h4 class="font-weight-bolder">{{ title() }}</h4>
          @if (subtitle()) {
            <p class="text-muted mb-0">{{ subtitle() }}</p>
          }
        </div>
      }
      <!-- Numbered step header with connecting progress line -->
      <div class="wz-head">
        @for (s of steps(); track s.key; let i = $index, last = $last) {
          <div class="wz-step" [class.active]="i === activeIndex()" [class.done]="i < activeIndex()">
            <div class="wz-circle">
              @if (i < activeIndex()) {
                <i data-feather="check"></i>
              } @else {
                <span>{{ i + 1 }}</span>
              }
            </div>
            <div class="wz-label">{{ s.label }}</div>
          </div>
          @if (!last) {
            <div class="wz-line" [class.done]="i < activeIndex()"></div>
          }
        }
      </div>

      <!-- Active step body (projected by the parent) -->
      <div class="wz-body">
        <ng-content></ng-content>
        @if (error()) {
          <div class="alert alert-danger mt-1">{{ error() }}</div>
        }
      </div>

      <!-- Footer: Back (left) · Step N of M · Cancel · Next/Finish (right) -->
      <div class="wz-foot">
        @if (activeIndex() > 0) {
          <button type="button" class="btn btn-outline-secondary" (click)="back.emit()">
            <i data-feather="arrow-left" class="mr-50"></i> Back
          </button>
        }
        <div class="ml-auto d-flex align-items-center">
          <span class="wz-count mr-1">Step {{ activeIndex() + 1 }} of {{ steps().length }}</span>
          <button type="button" class="btn btn-outline-secondary mr-1" (click)="cancel.emit()">Cancel</button>
          @if (isLast()) {
            <!-- Derive the busy label from finishLabel — a hardcoded 'Creating…' misleads in edit mode. -->
            <button type="button" class="btn btn-primary" [disabled]="nextDisabled() || saving()"
                    (click)="finish.emit()">{{ saving() ? finishLabel() + '…' : finishLabel() }}</button>
          } @else {
            <button type="button" class="btn btn-primary" [disabled]="nextDisabled()"
                    (click)="next.emit()">Next <i data-feather="arrow-right" class="ml-50"></i></button>
          }
        </div>
      </div>
      @if (aiDisclosure()) {
        <app-ai-disclosure class="pb-1" />
      }
    </div>
  `,
})
export class WizardStepperComponent {
  readonly steps = input<WizardStep[]>([]);
  readonly activeIndex = input(0);
  /** Bind to the current step group's `.invalid` so Next/Finish is gated per step. */
  readonly nextDisabled = input(false);
  readonly saving = input(false);
  readonly finishLabel = input('Create');
  /** Agent-mode forms only (ISO 42001); the stepper is shared with Worker-mode extensions. */
  readonly aiDisclosure = input(false);
  readonly error = input('');
  /** Page heading rendered inside the card (never wrap the stepper in another card to fake one). */
  readonly title = input('');
  readonly subtitle = input('');
  /** The card is centered; cap its width so the wizard doesn't span the viewport. */
  readonly maxWidth = input('900px');

  readonly back = output<void>();
  readonly next = output<void>();
  readonly cancel = output<void>();
  readonly finish = output<void>();

  // computed(), not a getter: a getter in a template binding re-runs on every change-detection pass.
  protected readonly isLast = computed(() => this.activeIndex() >= this.steps().length - 1);
}
