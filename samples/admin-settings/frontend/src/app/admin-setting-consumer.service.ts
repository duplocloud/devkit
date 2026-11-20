import { Injectable, inject } from '@angular/core';
import { Observable } from 'rxjs';
import { map } from 'rxjs/operators';
import { REMOTE_DuploHttpClient, REMOTE_UserSession } from './admin-setting.service';

// The WORKSPACE resource that consumes an admin setting. An ordinary workspace service: the route names the
// selected workspace, and the ticket opens in the service desk. The admin settings it picks from come from
// AdminSettingService.list('workspace') (the read-only view), never from the admin route — workspace members
// cannot call it. See reference/21-admin-resources.md → "Workspace resources that consume an admin resource".
const REST_SEGMENT = 'extensions/admin-setting-consumers';
const ORIGIN_TYPE = 'AdminSettingConsumer';
const SUB_TYPE = 'admin-setting-consumer';

export interface AdminSettingConsumer {
  id: string;
  name: string;
  status: string;
  subStatus?: string;
  blockedReason?: string;
  faults?: string[];
  createdAt?: string;
  updatedAt?: string;
  spec?: { adminSettingId?: string };
  result?: { summary?: string };
}

@Injectable({ providedIn: 'root' })
export class AdminSettingConsumerService {
  private readonly http = inject<any>(REMOTE_DuploHttpClient as any);
  private readonly session = inject<any>(REMOTE_UserSession as any);

  /** Current workspace/tenant id — from the host UserSession (route params aren't reliable in a federated remote). */
  workspaceId(): string {
    return this.session?.tenant?.TenantId ?? '';
  }

  private base(): string {
    return `/v1/aiservicedesk/user/data/workspaces/${this.workspaceId()}/environment/${REST_SEGMENT}`;
  }

  private unwrap = (r: any) => (r && r.data !== undefined ? r.data : r);

  list(): Observable<AdminSettingConsumer[]> {
    return this.http.get(this.base()).pipe(map((r: any) => {
      const d = this.unwrap(r);
      return (d?.items ?? d ?? []) as AdminSettingConsumer[];
    }));
  }

  get(id: string): Observable<AdminSettingConsumer> {
    return this.http.get(`${this.base()}/${id}`).pipe(map((r: any) => this.unwrap(r)));
  }

  create(name: string, spec: { adminSettingId: string }): Observable<AdminSettingConsumer> {
    return this.http.post(this.base(), { name, spec }).pipe(map((r: any) => this.unwrap(r)));
  }

  // PATCH replaces `spec` wholesale — always send the FULL spec (reference/04-hooks.md).
  update(id: string, spec: { adminSettingId: string }): Observable<AdminSettingConsumer> {
    return this.http.patch(`${this.base()}/${id}`, { spec }).pipe(map((r: any) => this.unwrap(r)));
  }

  /** Resolve the provisioning ticket (its `name` is the chat URL segment) via origin-context. */
  ticketName(id: string): Observable<string | null> {
    const url = `/v1/aiservicedesk/tickets/${this.workspaceId()}/origin-context`
      + `?type=${ORIGIN_TYPE}&id=${id}&subType=${SUB_TYPE}`;
    return this.http.get(url).pipe(map((r: any) => this.unwrap(r)?.name ?? null));
  }

  /** A workspace resource's ticket opens in the service desk of its own workspace. */
  ticketChatUrl(name: string): string {
    return `/ai/service-desk/${this.workspaceId()}/tickets/chat/${encodeURIComponent(name)}`;
  }
}
