import { Injectable, inject } from '@angular/core';
import { ActivatedRoute } from '@angular/router';
import { Observable } from 'rxjs';
import { map } from 'rxjs/operators';

// Host-provided string DI tokens (no @common-lib import). REMOTE_DuploHttpClient exposes get/post
// returning RxJS Observables. REMOTE_UserSession is read ONLY for the workspace (read-only) side's route
// workspace — admin-side requests carry no workspace at all.
export const REMOTE_DuploHttpClient = 'REMOTE_DuploHttpClient';
export const REMOTE_UserSession = 'REMOTE_UserSession';

/**
 * Which side the page was opened from. The host stamps `scope` on the extension's lazy route, and the
 * remote's routes are its componentless children, so they inherit it. `admin` = AI Admin (full CRUD);
 * `workspace` = AI DevOps, where the same pages are READ-ONLY.
 */
export type ViewScope = 'admin' | 'workspace';

export function routeScope(route: ActivatedRoute): ViewScope {
  return route.snapshot.data['scope'] === 'admin' ? 'admin' : 'workspace';
}

// This is a TYPED resource: the extension ships its own controller, so we call its OWN REST segment.
// Admin requests never name a workspace: the admin route is complete on its own, for CRUD and for the
// provisioning ticket (`{id}/ticket-status`). See reference/21-admin-resources.md.
const REST_SEGMENT = 'extensions/admin-settings';

// The lifecycle fields every ResourceBase serializes — the detail view's phase timeline reads them
// (status → which phase is active; subStatus → its live beat; blockedReason → why the agent is waiting;
// faults → the failure text; updatedAt → when the last phase finished). See reference/19-detail-page.md.
export interface AdminSetting {
  id: string;
  name: string;
  status: string;
  subStatus?: string;
  blockedReason?: string;
  faults?: string[];
  createdAt?: string;
  updatedAt?: string;
  // settingValue and result are absent on the workspace (read-only) side: AdminSettingsReadController
  // returns AdminSettingView, which leaves out the value and the summary that embeds it.
  spec?: { settingKey?: string; settingValue?: string };
  result?: { summary?: string };
}

@Injectable({ providedIn: 'root' })
export class AdminSettingService {
  // inject() with the platform's string DI tokens (use-ng22 rule — no constructor parameters).
  private readonly http = inject<any>(REMOTE_DuploHttpClient as any);
  private readonly session = inject<any>(REMOTE_UserSession as any);

  // Admin route: no {workspaceId} segment — it must equal the AdminSettingsController [Route]. The workspace
  // route is AdminSettingsReadController's: list + get only, for any member of the selected workspace.
  private base(scope: ViewScope = 'admin'): string {
    if (scope === 'workspace') {
      const tenant = this.session?.tenant?.TenantId ?? '';
      return `/v1/aiservicedesk/user/data/workspaces/${tenant}/environment/${REST_SEGMENT}`;
    }
    return `/v1/aiservicedesk/admin/data/environment/${REST_SEGMENT}`;
  }

  // DuploHttpClient does NOT unwrap the envelope: user/data endpoints return {data: …} while tickets/*
  // return bare bodies — normalize both here.
  private unwrap = (r: any) => (r && r.data !== undefined ? r.data : r);

  list(scope: ViewScope = 'admin'): Observable<AdminSetting[]> {
    return this.http.get(this.base(scope)).pipe(map((r: any) => {
      const d = this.unwrap(r);
      return (d?.items ?? d ?? []) as AdminSetting[];
    }));
  }

  get(id: string, scope: ViewScope = 'admin'): Observable<AdminSetting> {
    return this.http.get(`${this.base(scope)}/${id}`).pipe(map((r: any) => this.unwrap(r)));
  }

  create(name: string, spec: { settingKey: string; settingValue: string }): Observable<AdminSetting> {
    const body = { name, spec };
    return this.http.post(this.base(), body).pipe(map((r: any) => this.unwrap(r)));
  }

  // `PATCH {id}` merges at the ENTITY level (TicketContext/Status preserved → the ticket is reused), but
  // `spec` is replaced WHOLESALE — always send the FULL spec. `PUT` would bind the whole entity from the
  // body and null out TicketContext/Status/Result — see reference/04-hooks.md.
  update(id: string, spec: { settingKey: string; settingValue: string }): Observable<AdminSetting> {
    return this.http.patch(`${this.base()}/${id}`, { spec }).pipe(map((r: any) => this.unwrap(r)));
  }

  /**
   * Resolve the provisioning ticket's name (the chat URL segment) from the resource's own admin
   * `{id}/ticket-status` — no workspace id needed. Null when the row has no ticket yet.
   */
  ticketName(id: string): Observable<string | null> {
    return this.http.get(`${this.base('admin')}/${id}/ticket-status`)
      .pipe(map((r: any) => this.unwrap(r)?.ticketName ?? null));
  }

  /**
   * Where an admin resource's provisioning ticket opens: the AI Admin ticket page, which looks it up by name
   * alone. The service-desk chat route needs a workspace from the user's list, so it cannot open these.
   */
  ticketChatUrl(name: string): string {
    return `/ai/suite/admin/tickets/chat/${encodeURIComponent(name)}`;
  }
}
