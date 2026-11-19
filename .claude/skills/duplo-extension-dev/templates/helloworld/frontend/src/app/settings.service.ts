import { Injectable, inject } from '@angular/core';
import { Observable, of, throwError } from 'rxjs';
import { catchError, map } from 'rxjs/operators';
import { REMOTE_DuploHttpClient } from './hello.service';

// Sample admin settings endpoint. A real agent replaces it with its own admin settings endpoint.
const SETTINGS_URL = '/v1/aiservicedesk/admin/extensions/helloworld/settings';
// Used only while SETTINGS_URL returns 404; rename it to '<idName>.settings' (reference/02 rename table).
const FALLBACK_KEY = 'helloworld.settings';

export interface HelloSettings {
  scopeId?: string;
}

/** `local` is true when the settings came from (or went to) this browser instead of the endpoint. */
export interface SettingsResult {
  settings: HelloSettings;
  local: boolean;
}

@Injectable({ providedIn: 'root' })
export class SettingsService {
  private readonly http = inject<any>(REMOTE_DuploHttpClient as any);

  // Same envelope rule as HelloService: some endpoints wrap the body in {data: …}.
  private unwrap = (r: any) => (r && r.data !== undefined ? r.data : r);

  load(): Observable<SettingsResult> {
    return this.http.get(SETTINGS_URL).pipe(
      map((r: any) => ({ settings: (this.unwrap(r) ?? {}) as HelloSettings, local: false })),
      catchError(err => isNotFound(err) ? of({ settings: readLocal(), local: true }) : throwError(() => err)),
    );
  }

  save(settings: HelloSettings): Observable<SettingsResult> {
    return this.http.put(SETTINGS_URL, settings).pipe(
      map(() => ({ settings, local: false })),
      catchError(err => {
        if (!isNotFound(err)) {
          return throwError(() => err);
        }
        writeLocal(settings);
        return of({ settings, local: true });
      }),
    );
  }
}

function isNotFound(err: any): boolean {
  return err?.status === 404;
}

// localStorage can throw (private mode, blocked storage); read that as "nothing saved".
function readLocal(): HelloSettings {
  try {
    return JSON.parse(localStorage.getItem(FALLBACK_KEY) ?? '{}') ?? {};
  } catch {
    return {};
  }
}

// A throw here surfaces as the save's error, so the page never claims a save that did not happen.
function writeLocal(settings: HelloSettings): void {
  localStorage.setItem(FALLBACK_KEY, JSON.stringify(settings));
}
