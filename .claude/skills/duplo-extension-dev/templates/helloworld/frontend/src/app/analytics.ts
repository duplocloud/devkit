import { Injectable, inject } from '@angular/core';
import { ExtensionAnalytics, REMOTE_ExtensionAnalytics } from '@duplocloud-internal/ng-common-lib';

// Default analytics: page views + user actions, NO custom properties. The host namespaces every event as
// `<EXTENSION_ID>.<page>.viewed` / `<EXTENSION_ID>.<name>` and adds extension_id / extension_version itself.
//
// Properties are opt-in ONLY, via manifest `frontend.analytics.properties` (an allowlist the host enforces).
// Do NOT add a props parameter here unless the user explicitly asks for one — see reference/21-analytics.md.
//
// EXTENSION_ID MUST equal manifest.json `id`; the host drops events from ids it has not registered.
export const EXTENSION_ID = 'duplo.examples.helloworld';

@Injectable({ providedIn: 'root' })
export class HelloAnalytics {
  // optional: the host token is absent in standalone runs / unit tests — tracking then no-ops instead of throwing.
  private readonly tracker = inject<ExtensionAnalytics>(REMOTE_ExtensionAnalytics as any, { optional: true })
    ?.for(EXTENSION_ID);

  pageView(page: string): void {
    this.tracker?.pageView(page);
  }

  action(name: string): void {
    this.tracker?.action(name);
  }
}
