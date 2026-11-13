import { Component, computed, input } from '@angular/core';

// Self-contained status badge for extension list/detail views, in the Extension Studio's Template-G shape:
// a soft (badge-light-*) square-cornered 6px badge with a 6px currentColor dot in front of the label —
// NOT the Vuexy pill, which is the pre-G look.
//
// The platform's <status-with-style> is NOT exported by the lib's CommonLibComponentsModule, so an extension
// that uses it renders a blank unknown element. This badge reproduces the Studio's `badgeCssClass` mapping
// with no lib dependency. Import it into whichever component renders <app-status-badge [status]="…">.
@Component({
  selector: 'app-status-badge',
  template: `<span class="badge badge-light-{{ style() }} g-badge">{{ label() }}</span>`,
  styles: [`
    .g-badge {
      border-radius: 6px;
      display: inline-flex;
      gap: 6px;
      align-items: center;
      padding: 3px 8px 3px 7px;
      font-size: 11.5px;
      font-weight: 500;
      line-height: 1.2;
    }
    .g-badge::before {
      content: "";
      width: 6px;
      height: 6px;
      border-radius: 50%;
      background: currentColor;
      flex: none;
    }
  `],
})
export class StatusBadgeComponent {
  readonly status = input<string>();

  // computed(), not a getter: recomputes only when `status` actually changes rather than on every
  // change-detection pass, and keeps the component correct under the default OnPush strategy.
  protected readonly style = computed(() => {
    const s = (this.status() || '').toLowerCase();
    if (['complete', 'completed', 'updated', 'ready', 'active', 'available', 'succeeded', 'ok'].includes(s)) {
      return 'success';
    }
    if (['failed', 'error', 'rejected', 'deprovisionfailed'].includes(s)) {
      return 'danger';
    }
    if (['blocked', 'waitingforapproval'].includes(s)) {
      return 'warning';
    }
    if (['deprovisioned', 'deprovisioning', 'deprovisioninitiated'].includes(s)) {
      return 'secondary';
    }
    if (s) {
      return 'info'; // new, ticketcreated, processing, …
    }
    return 'secondary';
  });

  // Human label: "WaitingForApproval" → "Waiting for approval", "DeProvisioned" → "Deprovisioned".
  protected readonly label = computed(() => {
    const raw = this.status();
    if (!raw) {
      return '—';
    }
    const spaced = raw.replace(/([a-z])([A-Z])/g, '$1 $2').replace(/De Provision/g, 'Deprovision');
    return spaced.charAt(0).toUpperCase() + spaced.slice(1).toLowerCase();
  });
}
