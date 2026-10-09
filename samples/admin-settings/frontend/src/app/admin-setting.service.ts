import { Injectable, inject } from '@angular/core';
import { Observable } from 'rxjs';
import { map } from 'rxjs/operators';

// Host-provided string DI token (no @common-lib import). REMOTE_DuploHttpClient exposes get/post
// returning RxJS Observables. An ADMIN-scoped resource does not need REMOTE_UserSession: it never reads
// the selected tenant, because every row belongs to the system Admin Workspace.
export const REMOTE_DuploHttpClient = 'REMOTE_DuploHttpClient';

// This is a TYPED resource: the extension ships its own controller, so we call its OWN REST segment.
// originType/subType are used to look up the provisioning ticket via the origin-context endpoint.
const ORIGIN_TYPE = 'AdminSetting';
const SUB_TYPE = 'admin-setting';
const REST_SEGMENT = 'extensions/admin-settings';
// Fixed id of the system Admin Workspace (Workspace.AdminWorkspaceId on the backend). Admin-scoped resources
// and their provisioning tickets live under it. See reference/21-admin-resources.md.
export const ADMIN_WORKSPACE_ID = '000000000000000000000ad1';

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
  spec?: { settingKey?: string; settingValue?: string };
  result?: { summary?: string };
}

@Injectable({ providedIn: 'root' })
export class AdminSettingService {
  // inject() with the platform's string DI tokens (use-ng22 rule — no constructor parameters).
  private readonly http = inject<any>(REMOTE_DuploHttpClient as any);

  /** The workspace that owns every admin-scoped row (and its provisioning ticket). */
  workspaceId(): string {
    return ADMIN_WORKSPACE_ID;
  }

  // Admin route: no {workspaceId} segment — it must equal the AdminSettingsController [Route].
  private base(): string {
    return `/v1/aiservicedesk/admin/data/environment/${REST_SEGMENT}`;
  }

  // DuploHttpClient does NOT unwrap the envelope: user/data endpoints return {data: …} while tickets/*
  // return bare bodies — normalize both here.
  private unwrap = (r: any) => (r && r.data !== undefined ? r.data : r);

  list(): Observable<AdminSetting[]> {
    return this.http.get(this.base()).pipe(map((r: any) => {
      const d = this.unwrap(r);
      return (d?.items ?? d ?? []) as AdminSetting[];
    }));
  }

  get(id: string): Observable<AdminSetting> {
    return this.http.get(`${this.base()}/${id}`).pipe(map((r: any) => this.unwrap(r)));
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

  /** Resolve the provisioning ticket (its `name` is the chat URL segment) via origin-context. */
  ticketName(id: string): Observable<string | null> {
    const url = `/v1/aiservicedesk/tickets/${this.workspaceId()}/origin-context`
      + `?type=${ORIGIN_TYPE}&id=${id}&subType=${SUB_TYPE}`;
    return this.http.get(url).pipe(map((r: any) => this.unwrap(r)?.name ?? null));
  }

  /**
   * Where a provisioning ticket opens. The ticket lives in the hidden Admin Workspace, so it opens under AI
   * Admin — the service-desk chat route rejects workspaces outside the user's list.
   */
  ticketChatUrl(name: string): string {
    return `/ai/suite/admin/tickets/chat/${encodeURIComponent(name)}`;
  }
}
