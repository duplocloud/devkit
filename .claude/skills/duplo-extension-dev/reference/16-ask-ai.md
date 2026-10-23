# Ask AI sessions — on-demand chat tickets on a resource (OPT-IN)

**Ask AI is an OPT-IN feature. Never add it by default and never offer it proactively** — build it ONLY when
the user explicitly asks for it ("ask AI", "AI chat sessions on the resource", "on-demand tickets"). No
template ships this code; when requested, implement it from the recipe in §10.

When opted in, a resource offers **Ask AI**: user-initiated chat tickets attached to the resource, surfaced
as the **LAST tab INSIDE the Results tab strip** (e.g. Overview | Network | Logs | **Ask AI** — see §10c).
It is **never an entry in the header's Spec | Result switcher** (the `.seg` control) — that switcher
holds panels, not features. The typical flow is post-provisioning: once the resource is `Complete`, users
open the Ask AI tab to explore the created infra and debug random issues. The sessions are **not** the
provisioning ticket — a user can open as many as they want, in **every provisioning mode**. Worker /
Passthrough / No-provision resources have no provisioning ticket at all, yet can still get Ask AI sessions;
on those, Ask AI becomes the resource's only chat entry point (the Track-Provisioning UI is removed for
those modes regardless). Worked example: the Ask AI tab in
[`samples/network-stack`](../../../../samples/network-stack).

| | Provisioning ticket | Ask AI session |
|---|---|---|
| Created by | the platform, on resource create | the frontend, on user demand |
| Count per resource | ≤ 1 (Agent mode only) | 0..N, unlimited |
| Skill | auto-attached via manifest `skillMappings` | none auto-attached (optional per-ticket — §7) |
| `originContext.subType` | `<sub-type>` (e.g. `hello-world`) | `<sub-type>-askai` (e.g. `hello-world-askai`) |
| `originContext.metadata.purpose` | *(absent)* | `"ask-ai"` |
| First message | platform-generated provisioning message | extension-prefilled context + the user's question |

## 1. The discriminator — dedicated subType AND `purpose`

An Ask AI ticket keeps the resource's **originType** and **id**, but uses:
- **subType `<sub-type>-askai`** — a dedicated sub-type, because the platform keys **skill auto-resolution**
  and the single-ticket `origin-context` lookup on (type, subType). Reusing the provisioning subType would
  auto-attach the provisioning skill to every chat and make the Track-Provisioning lookup ambiguous.
  **Never reuse the provisioning subType.**
- **`metadata.purpose = "ask-ai"`** — the SDK's documented `OriginContext.Metadata` convention for
  distinguishing multiple tickets on one domain object. This is what tooling/queries filter on; the
  provisioning ticket carries no `purpose`. All metadata values must be **strings**.

Both parts are required: the subType does the mechanical isolation, `purpose` is the declared intent —
and `purpose` is LOAD-BEARING platform-side, not cosmetic: the platform stamps provisioning tickets with
`purpose = "{origintype}-baseline-setup"` and treats any ticket carrying that value as THE provisioning
ticket (undeletable, adoptable for pointer-healing). **Never use a purpose ending in `-baseline-setup`** for
Ask AI sessions.

## 2. API contract

All calls go to the **host's** tickets/user-data APIs (via the injected `REMOTE_DuploHttpClient`), not your
extension's own controller. `{ws}` = workspace id from `REMOTE_UserSession`.

| Purpose | Call |
|---|---|
| Create session | `POST /v1/aiservicedesk/tickets/{ws}` → response `.name` (the chat URL segment) |
| List sessions | `GET /v1/aiservicedesk/tickets/{ws}/origin-context/list?type=<OriginType>&id=<resourceId>&subType=<sub>-askai` |
| Provisioning ticket (agent-id source) | `GET /v1/aiservicedesk/tickets/{ws}/origin-context?type=<OriginType>&id=<resourceId>&subType=<sub>` → bare Ticket (`.aiAgentId` / `.name`) or **204 No Content** when none (never 404); also supports `&metadata[purpose]=…` filtering |
| Fallback agent | `GET /v1/aiservicedesk/user/data/models/allowed?workspaceId={ws}` → **DOUBLE-wrapped** `ApiResponse<PagedResponse<…>>`: models at `.data.items` → first model's `agentIds[0]` |
| Workspace scopes | `GET /v1/aiservicedesk/user/data/workspaces/{ws}/scopes` → `[{id, name, …}]` |
| Workspace skills (optional, §7) | `GET /v1/aiservicedesk/user/data/workspaces/{ws}/skills` → match by `name` → `.id` — the list is PERSONA-derived: a skill not on the workspace's persona won't appear |
| Close session | `PUT /v1/aiservicedesk/tickets/{ws}/{ticketName}/status` body `{ "status": "closed", "disposition": "resolved" }` — path takes the ticket NAME; status ∈ `open\|inProgress\|waitingForUserInput\|waitingForUserAgent\|closed`; with `closed`, disposition must be `resolved` or `unResolved` (capital R) |
| Open chat | route `/ai/service-desk/{ws}/tickets/chat/{ticketName}` |

**Agent id resolution:** read `aiAgentId` off the resource's provisioning ticket when one exists (Agent mode),
else fall back to the first allowed model's `agentIds[0]`. Worker / Passthrough / No-provision resources skip
the origin-context lookup entirely and go straight to the fallback.

## 3. Create payload

```json
{
  "title": "Ask AI — my-hello",
  "aiAgentId": "<resolved agent id>",
  "workspaceId": "<ws>",
  "ticketContextForAgent": { "scopeIds": ["<scope-id>", "…"] },
  "originContext": {
    "type": "HelloWorld",
    "id": "<resourceId>",
    "subType": "hello-world-askai",
    "metadata": { "purpose": "ask-ai" }
  }
}
```

- `ticketContextForAgent` also accepts `memoryEnabled` (default `true`) — set `false` to opt the session
  out of workspace memory. Bad `scopeIds` are REJECTED by scope-access validation, not ignored.
- `metadata` may carry extra **string** facts about the resource (name, status, …) — useful for rendering the
  session list without re-fetching the resource. `purpose` is mandatory.
- **Zero manifest changes are needed** — the `-askai` subType appears in no `resources[]` or `skillMappings[]`
  entry, which is exactly what keeps the provisioning skill off these tickets.
- A custom `originContext.type` renders as a raw (unlabelled) string in the studio's Linked-tickets column —
  cosmetic only; keep your own type.

## 4. Initial context + first message

The initial context is **set by the extension** and **editable by the user**:
1. The extension prefills a context block in the dialog — the usual source is the resource's `spec` + `result`
   (name, status, key fields, live-state URLs), but there is **no hard rule**: each extension writes its own
   `buildAskAiContext()` with whatever the agent needs. A `[SecretValue(ExcludeFromResponse = true)]`-marked
   field ([21-secrets](21-secrets.md)) is safe to reference here without special-casing it — the frontend's
   `item.spec` was populated from the same GET response every other view uses, which never carried the real
   value to begin with, so `buildAskAiContext()` gets `undefined`/absent, not a leak.
2. The user edits/extends that context and types their question. Both land in the ticket's **first chat
   message** — not in any ticket field.
3. Delivery: set the platform's chat-seed key, **then** navigate — the chat view reads it on init (and
   removes it immediately) and auto-sends it **only when the ticket has ZERO messages**. Sibling keys give
   escape hatches: `ai-redirect-prefill-only` = `'true'` prefills the composer instead of sending;
   `ai-redirect-prefill-always` = `'true'` bypasses the zero-message gate; `ai-redirect-new-file-paths`
   (JSON array) attaches files:
   ```ts
   sessionStorage.setItem('ai-redirect-new-query-message', `${context}\n\nUser Question:\n${question}`);
   this.router.navigateByUrl(`/ai/service-desk/${ws}/tickets/chat/${name}`);
   ```

Tip: when the session is investigative, end the context with an explicit guardrail line, e.g.
`IMPORTANT: perform READ-ONLY investigation only — do not modify any infrastructure.`

## 5. Scopes

The dialog shows a **scope multi-select** (checkbox list from the workspace-scopes endpoint), **pre-checked
from `spec.scopeIds`** — the user can add or drop scopes per session. The picked ids go into
`ticketContextForAgent.scopeIds`; the platform materializes their credentials into the ticket exactly as for
provisioning (see [07-scope-credentials](07-scope-credentials.md)). If an expected scope is missing from the
workspace, degrade gracefully: start the session without it and tell the user in the dialog.

## 6. Worker / Passthrough / No-provision resources

These modes create **no provisioning ticket** ([19](19-detail-page.md#ladders-by-provisioning-mode--and-the-ticket-ui-that-goes-with-them)),
but Ask AI sessions are user-created and never depend on one — so a requested Ask AI tab is the resource's chat
entry point on those modes. The one difference: `resolveAgentId()` goes straight to `/models/allowed` (no
origin-context call).

## 7. Optional: attach a skill per session

To make Ask AI sessions run a specific skill (e.g. a triage skill) without auto-attaching it anywhere:
- Register the skill in manifest `skills[]` but give it **no `skillMappings` entry** — it installs as a
  workspace skill, auto-attached to nothing.
- At create time, resolve its id by `name` from the workspace-skills endpoint and pass
  `ticketContextForAgent.skillIds: [id]` (plus the deprecated top-level `skillIds` for belt-and-braces).
- If the id can't be resolved, still instruct the agent **by skill name** inside the seeded first message and
  warn the user in the dialog ("skill not found in this workspace — the agent will be instructed instead").

## 8. Pitfalls

- **The seed key is an undocumented host contract.** `'ai-redirect-new-query-message'` must be set immediately
  before navigating and used for nothing else; don't rely on it surviving anything but that one navigation.
- **`origin-context/list` items have no `currentStatus`** — derive the badge from the LAST
  `history.statuses[]` entry, defaulting to `'open'`.
- **Surface real errors.** Propagate the create error and show `e?.error?.message` inside the dialog — never a
  bare `alert()` or a swallowed `catchError(() => of(null))`.
- **Filter client-side on `purpose` too.** When listing, keep only items with
  `metadata?.purpose === 'ask-ai'` (tolerating absent metadata on old tickets) — forward-compatible if other
  ticket flavors ever share the subType.
- **No pagination on the list** — sort client-side by `createdAt || updatedAt`, tolerating absent fields.
- **Navigation fallback** — host routes can no-op from a remote; use `router.navigateByUrl(url)` and fall back
  to `window.location.assign(url)` when it resolves false/throws.

## 9. Backend-created alternative (not the default)

A backend can create these tickets instead: a custom controller action that calls the SDK's
`CreateTicketAsync` (the `POST {id}/ticket` row in [03-base-classes](03-base-classes.md)), with
`GetTicketMetadata()` snapshotting per-ticket metadata (incl. `purpose`), `GetTicketTitle()` naming it,
`GetProvisioningMessage()` or `suppressInitialMessage` controlling the first message (suppression still creates the ticket and writes
`shared/<subtype>.json`, and mints no scoped token), and — for N tickets per
resource — nulling `entity.TicketContext` before each create to defeat the one-ticket idempotency gate. Use it
when the initial context needs server-side data the frontend can't see; otherwise prefer the frontend path
above (simpler, mode-independent, zero backend changes).

**This is the one path where a secret can genuinely leak into an Ask AI session.** Unlike the frontend path,
these overrides run server-side with the real, decrypted `entity.Spec`/`entity.Result` in hand —
`[SecretValue(ExcludeFromResponse = true)]` only strips a field from HTTP *responses*, and a hand-written
`GetTicketMetadata()`/`GetTicketTitle()`/`GetProvisioningMessage()` is not one. Never interpolate a
`[SecretValue]`/`[AgentSecretValue]`-marked field into any string these methods produce
([21-secrets](21-secrets.md)).

> If you add such a controller action, decide its access policy: opening an AI session against a resource
> is usually more than a "can edit" grant should imply, so give it a named action —
> `[AccessControl(Action = "<feature>.ask-ai", ActionName = …, Description = …)]`. The inherited
> `POST {id}/ticket` is covered by the base's PUT verb override ([18-access-control](18-access-control.md)).

The inherited endpoint's shape:

```bash
# Force ticket creation for one resource, regardless of skill-mapping routing; then poll its status.
POST …/user/data/workspaces/{ws}/environment/<restSegment>/{id}/ticket
GET  …/user/data/workspaces/{ws}/environment/<restSegment>/{id}/ticket-status
```

## 10. Implementation recipe (frontend path — the code to write on opt-in)

Written for helloworld names — substitute your extension's `ORIGIN_TYPE`/`SUB_TYPE`/service/entity names.
**`samples/network-stack`'s implementation is canonical — if this recipe and the sample ever drift, follow the
sample.** Three parts: service additions, a self-contained panel component, and the view wiring.

### 10a. Service additions (`<name>.service.ts`)

Add the consts next to the existing `ORIGIN_TYPE`/`SUB_TYPE`, the interface next to the entity interface, and
the methods inside the service class. Requires `switchMap` in the `rxjs/operators` import and `scopeIds?:
string[]` on the entity's `spec`.

```ts
// Ask AI sessions use a DEDICATED subType (never the provisioning one — skill auto-resolution and the
// origin-context lookup key on type+subType) plus metadata.purpose as the declared discriminator. See 16-ask-ai.
const ASKAI_SUB = 'hello-world-askai';
const ASKAI_PURPOSE = 'ask-ai';

/** An Ask AI chat session on a resource, as returned by the tickets origin-context/list endpoint. */
export interface AskAiTicket {
  id?: string;
  name: string;
  title?: string;
  createdBy?: string;
  createdAt?: string;
  updatedAt?: string;
  originContext?: { type?: string; id?: string; subType?: string; metadata?: Record<string, string> };
  history?: { statuses?: { status?: string }[] };
}
```

```ts
  // ── Ask AI sessions (see reference/16-ask-ai.md) ─────────────────────────────────────────────────
  // User-created chat tickets on this resource — unlimited, mode-independent, distinct from the
  // provisioning ticket by ASKAI_SUB + metadata.purpose. All calls hit the HOST tickets/user-data APIs.

  private ticketsBase(): string {
    return `/v1/aiservicedesk/tickets/${this.workspaceId()}`;
  }

  /** All Ask AI sessions for one resource, newest first. */
  listAskAiTickets(id: string): Observable<AskAiTicket[]> {
    const url = `${this.ticketsBase()}/origin-context/list`
      + `?type=${ORIGIN_TYPE}&id=${id}&subType=${ASKAI_SUB}`;
    return this.http.get(url).pipe(
      map((r: any) => {
        const items = (this.unwrap(r) ?? []) as AskAiTicket[];
        return items
          // Keep the purpose filter even though the subType already isolates — forward-compatible, and
          // tolerant of old tickets created without metadata.
          .filter(t => (t.originContext?.metadata?.['purpose'] ?? ASKAI_PURPOSE) === ASKAI_PURPOSE)
          .sort((a, b) => (b.createdAt || b.updatedAt || '').localeCompare(a.createdAt || a.updatedAt || ''));
      }),
      catchError(() => of([])),
    );
  }

  /**
   * Agent for a new session: the provisioning ticket's aiAgentId when one exists, else the first allowed
   * model's agent. Worker/Passthrough/No-provision resources have NO provisioning ticket — drop the
   * origin-context call there and go straight to the /models/allowed fallback.
   */
  resolveAgentId(id: string): Observable<string | null> {
    const url = `${this.ticketsBase()}/origin-context?type=${ORIGIN_TYPE}&id=${id}&subType=${SUB_TYPE}`;
    return this.http.get(url).pipe(
      map((r: any) => this.unwrap(r)?.aiAgentId ?? null),
      catchError(() => of(null)),
      switchMap((agentId: string | null) => agentId ? of(agentId) : this.fallbackAgentId()),
    );
  }

  private fallbackAgentId(): Observable<string | null> {
    const url = `/v1/aiservicedesk/user/data/models/allowed?workspaceId=${this.workspaceId()}`;
    return this.http.get(url).pipe(
      map((r: any) => {
        // DOUBLE-wrapped: ApiResponse<PagedResponse<LlmModel>> — models live at .data.items.
        const models = (this.unwrap(r)?.items ?? []) as any[];
        return models.find(m => m?.agentIds?.length)?.agentIds[0] ?? null;
      }),
      catchError(() => of(null)),
    );
  }

  /** Workspace scopes for the dialog's multi-select (pre-check the ones already on spec.scopeIds). */
  listScopes(): Observable<{ id: string; name: string }[]> {
    const url = `/v1/aiservicedesk/user/data/workspaces/${this.workspaceId()}/scopes`;
    return this.http.get(url).pipe(
      map((r: any) => ((this.unwrap(r) ?? []) as any[]).map(s => ({ id: s.id, name: s.name }))),
      catchError(() => of([])),
    );
  }

  /** Create an Ask AI session; resolves to the ticket `name` (the chat URL segment). Errors propagate. */
  createAskAiTicket(item: HelloWorld, agentId: string, scopeIds: string[]): Observable<string> {
    const body = {
      title: `Ask AI — ${item.name}`,
      aiAgentId: agentId,
      workspaceId: this.workspaceId(),
      ticketContextForAgent: { scopeIds },
      originContext: {
        type: ORIGIN_TYPE,
        id: item.id,
        subType: ASKAI_SUB,
        metadata: { purpose: ASKAI_PURPOSE },  // all metadata values must be strings
      },
    };
    return this.http.post(this.ticketsBase(), body).pipe(map((r: any) => this.unwrap(r)?.name));
  }

  closeAskAiTicket(name: string): Observable<any> {
    return this.http.put(`${this.ticketsBase()}/${name}/status`, { status: 'closed', disposition: 'resolved' });
  }

  /**
   * Default prefill for the Ask AI dialog's context box — the resource "sets" the initial context here.
   * Each extension rewrites this from its OWN spec/result (there is no hard rule on what goes in); the
   * user can edit the block freely before starting the session.
   */
  buildAskAiContext(item: HelloWorld): string {
    return [
      'Context:',
      `- Resource: HelloWorld "${item.name}" (id ${item.id})`,
      `- Status: ${item.status}${item.subStatus ? ` — ${item.subStatus}` : ''}`,
      `- Spec: firstName=${item.spec?.firstName ?? '—'}, lastName=${item.spec?.lastName ?? '—'}`,
      item.result?.fullName ? `- Result: fullName=${item.result.fullName}` : null,
    ].filter(Boolean).join('\n');
  }
```

### 10b. The panel component (`shared/ask-ai-panel.component.ts`)

Standalone + signals + `@if/@for`, hand-rolled overlay (no NgbModal), `FormsModule` only for `[(ngModel)]`.
Rendered as the **Ask AI tab's content** (an `ngbNavContent` template inside the Results tab strip), so it
wraps in a plain `<div>` — not its own card.

```ts
import { Component, OnInit, inject, input, signal } from '@angular/core';
import { Router } from '@angular/router';
import { FormsModule } from '@angular/forms';
import { CommonLibComponentsModule } from '@duplocloud-internal/ng-common-lib';
import { AskAiTicket, HelloService, HelloWorld } from '../hello.service';
import { StatusBadgeComponent } from './status-badge.component';

// Ask AI panel (see reference/16-ask-ai.md): the sessions list + the "start a session" dialog. Rendered as
// the LAST tab of the Results tab strip — the intended use is post-provisioning, to explore the created
// infra and debug issues. Self-contained and mode-independent: it never needs the provisioning ticket
// (works on Worker/Passthrough/No-provision resources that have none).
@Component({
  selector: 'hw-ask-ai-panel',
  imports: [CommonLibComponentsModule, FormsModule, StatusBadgeComponent],
  styles: [`
    .askai-backdrop { position: fixed; inset: 0; background: rgba(0,0,0,.4); z-index: 1050; }
    .askai-dialog { position: fixed; top: 10%; left: 50%; transform: translateX(-50%); width: min(640px, 92vw);
      max-height: 80vh; overflow-y: auto; z-index: 1051; }
  `],
  template: `
    <div class="p-1">
      <div class="d-flex align-items-center">
        <h5 class="mb-0 mr-auto">AI Sessions</h5>
        <button class="btn btn-primary btn-sm" (click)="openDialog()">
          <i data-feather="message-circle" class="mr-50"></i> Ask AI
        </button>
      </div>

      @if (sessions().length) {
        <div class="list-group list-group-flush mt-50">
          @for (t of sessions(); track t.name) {
            <div class="list-group-item d-flex align-items-center px-0">
              <app-status-badge [status]="statusOf(t)"></app-status-badge>
              <a class="ml-75 mr-auto text-truncate" href="javascript:void(0)" (click)="openChat(t)">
                <span class="font-weight-bold">{{ t.name }}</span>
                @if (t.title) { <span class="text-muted ml-50">{{ t.title }}</span> }
              </a>
              @if (t.createdBy) { <small class="text-muted mr-1">{{ t.createdBy }}</small> }
              @if (statusOf(t) !== 'closed') {
                <button class="btn btn-outline-secondary btn-sm" (click)="close(t)">Close</button>
              }
            </div>
          }
        </div>
      } @else {
        <p class="text-muted font-small-3 mt-50 mb-50">No AI sessions yet — start one to explore or debug this resource.</p>
      }
    </div>

    @if (dialogOpen()) {
      <div class="askai-backdrop" (click)="dialogOpen.set(false)"></div>
      <div class="card askai-dialog p-2">
        <h4>Ask AI about {{ resource().name }}</h4>
        <p class="text-muted font-small-3">
          Starts a new AI chat session on this resource. The context below was prefilled from the resource —
          edit it as you like; the selected scopes' credentials are attached to the session.
        </p>

        <label class="form-label">Context</label>
        <textarea class="form-control" rows="6" [(ngModel)]="contextText" name="askAiContext"></textarea>

        <label class="form-label mt-75">Your question</label>
        <textarea class="form-control" rows="3" [(ngModel)]="questionText" name="askAiQuestion"
                  placeholder="What do you want to know or do?"></textarea>

        @if (scopes().length) {
          <label class="form-label mt-75">Scopes</label>
          @for (s of scopes(); track s.id) {
            <div class="custom-control custom-checkbox">
              <input type="checkbox" class="custom-control-input" [id]="'askai-scope-' + s.id"
                     [checked]="selectedScopeIds().has(s.id)" (change)="toggleScope(s.id)">
              <label class="custom-control-label" [for]="'askai-scope-' + s.id">{{ s.name }}</label>
            </div>
          }
        }

        @if (error(); as err) {
          <div class="alert alert-danger p-75 mt-1 mb-0">{{ err }}</div>
        }

        <div class="d-flex justify-content-end mt-1">
          <button class="btn btn-outline-secondary mr-75" (click)="dialogOpen.set(false)" [disabled]="busy()">Cancel</button>
          <button class="btn btn-primary" (click)="start()" [disabled]="busy() || !questionText.trim()">
            {{ busy() ? 'Starting…' : 'Start session' }}
          </button>
        </div>
      </div>
    }
  `,
})
export class AskAiPanelComponent implements OnInit {
  private readonly svc = inject(HelloService);
  private readonly router = inject(Router);

  readonly resource = input.required<HelloWorld>();

  protected readonly sessions = signal<AskAiTicket[]>([]);
  protected readonly scopes = signal<{ id: string; name: string }[]>([]);
  protected readonly selectedScopeIds = signal<Set<string>>(new Set());
  protected readonly dialogOpen = signal(false);
  protected readonly busy = signal(false);
  protected readonly error = signal<string | null>(null);
  protected contextText = '';
  protected questionText = '';

  ngOnInit(): void {
    this.reload();
  }

  private reload(): void {
    this.svc.listAskAiTickets(this.resource().id).subscribe(t => this.sessions.set(t));
  }

  openDialog(): void {
    const it = this.resource();
    this.contextText = this.svc.buildAskAiContext(it);
    this.error.set(null);
    this.svc.listScopes().subscribe(scopes => {
      this.scopes.set(scopes);
      // Pre-check the scopes the resource was provisioned with; the user can add/drop per session.
      const preset = new Set((it.spec?.scopeIds ?? []).filter(id => scopes.some(s => s.id === id)));
      this.selectedScopeIds.set(preset);
    });
    this.dialogOpen.set(true);
  }

  protected toggleScope(id: string): void {
    const next = new Set(this.selectedScopeIds());
    next.has(id) ? next.delete(id) : next.add(id);
    this.selectedScopeIds.set(next);
  }

  protected start(): void {
    const it = this.resource();
    this.busy.set(true);
    this.error.set(null);
    this.svc.resolveAgentId(it.id).subscribe({
      next: agentId => {
        if (!agentId) {
          this.busy.set(false);
          this.error.set('No AI agent is available in this workspace.');
          return;
        }
        this.svc.createAskAiTicket(it, agentId, [...this.selectedScopeIds()]).subscribe({
          next: name => {
            this.busy.set(false);
            if (!name) {
              this.error.set('Ticket was created but no name came back.');
              return;
            }
            this.dialogOpen.set(false);
            this.gotoChat(name, `${this.contextText}\n\nUser Question:\n${this.questionText.trim()}`);
          },
          // Surface the API's real message (15-error-handling) — never a bare alert().
          error: e => { this.busy.set(false); this.error.set(e?.error?.message || 'Failed to start the session.'); },
        });
      },
      error: () => { this.busy.set(false); this.error.set('Could not resolve an AI agent.'); },
    });
  }

  protected openChat(t: AskAiTicket): void {
    this.gotoChat(t.name);
  }

  protected close(t: AskAiTicket): void {
    this.svc.closeAskAiTicket(t.name).subscribe({ next: () => this.reload(), error: () => this.reload() });
  }

  /** list items carry no currentStatus — derive from the LAST history entry, default 'open'. */
  protected statusOf(t: AskAiTicket): string {
    const st = t.history?.statuses;
    return st?.length ? (st[st.length - 1]?.status || 'open') : 'open';
  }

  private gotoChat(name: string, seedMessage?: string): void {
    if (seedMessage) {
      // Platform contract: the chat view reads this key on init and auto-sends it into the empty ticket.
      // Set it immediately before navigating; use it for nothing else.
      sessionStorage.setItem('ai-redirect-new-query-message', seedMessage);
    }
    const url = `/ai/service-desk/${this.svc.workspaceId()}/tickets/chat/${name}`;
    this.router.navigateByUrl(url).then(ok => { if (!ok) window.location.assign(url); })
      .catch(() => window.location.assign(url));
  }
}
```

### 10c. Wiring into the view component — the LAST tab of the Results tab strip

Ask AI is an `ngbNav` tab **inside the main card's Result strip**, appended **last**. Never add it to the
header's Spec | Result switcher (that `.seg` control stays Spec | Result). People reach it after
provisioning is `Complete`, to learn more about the created infra and debug random issues.

Every detail view already has the strip ([17-custom-result-views](17-custom-result-views.md) ·
[19-detail-page](19-detail-page.md)) — a one-tab `Overview` strip at minimum — so opting in is appending
one item AFTER every other tab:

```html
<!-- inside the Result strip's <ul ngbNav …> — AFTER every other tab: -->
<li [ngbNavItem]="'ask-ai'">
  <a ngbNavLink>Ask AI</a>
  <ng-template ngbNavContent>
    <hw-ask-ai-panel [resource]="it" />
  </ng-template>
</li>
```

```ts
import { AskAiPanelComponent } from '../shared/ask-ai-panel.component';
// @Component imports: [...existing, AskAiPanelComponent]
```

(`activeTab = 'overview'` is a plain field — ngbNav two-way binds it from a template event; don't use a
signal. `ngbNav` ships with `CommonLibComponentsModule`.)

For Worker/Passthrough/No-provision resources, additionally drop the origin-context call in
`resolveAgentId()` (go straight to `fallbackAgentId()`), since no provisioning ticket exists.
