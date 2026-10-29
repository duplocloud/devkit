import { Injectable, inject } from '@angular/core';
import { Observable } from 'rxjs';
import { map } from 'rxjs/operators';

// Host-provided string DI tokens (no @common-lib import). REMOTE_DuploHttpClient exposes get/post
// returning RxJS Observables; REMOTE_UserSession carries the current tenant (.tenant.TenantId) —
// the same source the host's own resources use for the workspace id.
export const REMOTE_DuploHttpClient = 'REMOTE_DuploHttpClient';
export const REMOTE_UserSession = 'REMOTE_UserSession';

const ORIGIN_TYPE = 'SecretFieldServiceAccount';
const SUB_TYPE = 'secret-field-service-account';
const REST_SEGMENT = 'extensions/secret-field-service-accounts';
// REST_SEGMENT MUST equal the manifest `resources[].restSegment` AND the controller `[Route]`. See
// reference/00-naming.md.

// The lifecycle fields every ResourceBase serializes, plus `spec`/`result`.
//
// NOTE what's deliberately ABSENT from `spec` here: there is no `password` field on this interface.
// That isn't an oversight — the backend's [SecretValue(ExcludeFromResponse = true)] means the GET/List
// response never carries the real value, so there is nothing for this type to model. See
// reference/21-secrets.md. `result.accountId` is NOT sensitive (an identifier, not a credential), so it's
// modelled normally.
export interface SecretFieldServiceAccount {
  id: string;
  name: string;
  status: string;
  subStatus?: string;
  blockedReason?: string;
  faults?: string[];
  createdAt?: string;
  updatedAt?: string;
  spec?: { username?: string };
  result?: { accountId?: string };
}

@Injectable({ providedIn: 'root' })
export class SecretFieldServiceAccountService {
  private readonly http = inject<any>(REMOTE_DuploHttpClient as any);
  private readonly session = inject<any>(REMOTE_UserSession as any);

  workspaceId(): string {
    return this.session?.tenant?.TenantId ?? '';
  }

  private base(): string {
    return `/v1/aiservicedesk/user/data/workspaces/${this.workspaceId()}/environment/${REST_SEGMENT}`;
  }

  // DuploHttpClient does NOT unwrap the envelope: user/data endpoints return {data: …} while tickets/*
  // return bare bodies — normalize both here.
  private unwrap = (r: any) => (r && r.data !== undefined ? r.data : r);

  list(): Observable<SecretFieldServiceAccount[]> {
    return this.http.get(this.base()).pipe(map((r: any) => {
      const d = this.unwrap(r);
      return (d?.items ?? d ?? []) as SecretFieldServiceAccount[];
    }));
  }

  get(id: string): Observable<SecretFieldServiceAccount> {
    return this.http.get(`${this.base()}/${id}`).pipe(map((r: any) => this.unwrap(r)));
  }

  /** `password` is required here — there is no prior stored value to fall back to on a fresh create. */
  create(name: string, spec: { username: string; password: string }): Observable<SecretFieldServiceAccount> {
    const body = { name, spec };
    return this.http.post(this.base(), body).pipe(map((r: any) => this.unwrap(r)));
  }

  /**
   * `PATCH {id}` merges at the ENTITY level (TicketContext/Status preserved → the ticket is reused), but
   * `spec` is replaced WHOLESALE — always send the FULL spec. See reference/04-hooks.md.
   *
   * `password` is OPTIONAL and must be OMITTED (not sent as `''`) when the user didn't type a new one —
   * the backend hooks treat an absent/blank password as "keep what's stored", never "clear it"
   * (reference/21-secrets.md). The caller (the add/edit component) is responsible for leaving the key off
   * the object entirely rather than passing `password: ''`.
   */
  update(id: string, spec: { username: string; password?: string }): Observable<SecretFieldServiceAccount> {
    return this.http.patch(`${this.base()}/${id}`, { spec }).pipe(map((r: any) => this.unwrap(r)));
  }

  /**
   * Reveals the real, decrypted password — the one supported way to read it back, gated by the
   * `secretfield.secret.read` access-control action. See reference/21-secrets.md.
   */
  revealPassword(id: string): Observable<string> {
    return this.http.get(`${this.base()}/${id}/password`).pipe(map((r: any) => this.unwrap(r)?.value ?? ''));
  }

  /** Resolve the provisioning ticket (its `name` is the chat URL segment) via origin-context. */
  ticketName(id: string): Observable<string | null> {
    const url = `/v1/aiservicedesk/tickets/${this.workspaceId()}/origin-context`
      + `?type=${ORIGIN_TYPE}&id=${id}&subType=${SUB_TYPE}`;
    return this.http.get(url).pipe(map((r: any) => this.unwrap(r)?.name ?? null));
  }
}
