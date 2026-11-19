# 13 — The logged-in user (frontend, backend, agent skill)

Get the current user's identity in each of the three places an extension runs.

> In this platform the **login username IS the email** — the JWT carries the email in both the `email` and
> `duplocloud.net/auth/username` claims. So backend/agent see the email; on the frontend `username` is the display
> name and may differ from `email`.

## Frontend (Angular remote)
Inject the host-shared `REMOTE_UserSession` string token — no HTTP call, already available to the federated
remote. The token constant is the one your service already declares (`export const REMOTE_UserSession =
'REMOTE_UserSession'` in `<name>.service.ts`); a bare string needs the cast because `inject()` is typed for
`ProviderToken` ([use-ng22](../../use-ng22/SKILL.md)):
```ts
import { Component, computed, inject } from '@angular/core';
import { REMOTE_UserSession } from '../hello.service';

@Component({ /* … */ })
export class MyExtComponent {
  private readonly session = inject<any>(REMOTE_UserSession as any);
  protected readonly email = computed(() => this.session?.user?.email ?? '');        // the logged-in user's email
  protected readonly username = computed(() => this.session?.user?.username ?? '');  // display name (may differ from email for OIDC/Okta)
  // roles: this.session?.user?.roles;  tenant: this.session?.tenant?.AccountName / TenantId
}
```
Reactive (recompute on user/tenant change): `toSignal(this.session.currentUser)` and read `.email` off it.
Fallback (rarely needed): `GET /admin/GetUserRoleInfo` via `REMOTE_DuploHttpClient` returns `{ Username, Roles }`.

**Refresh timers** (`UserSession` in the common lib, `models/authnz.model.ts`) drive a list's re-fetch:

| Method | Emits | Use for |
|---|---|---|
| `getTenantRefreshTimer(immediate?, frequency?)` | `[tenant, tenantChanged]` on first load (if `immediate`), every poll tick and every workspace switch | a **workspace** resource's list ([02](02-authoring-guide.md#frontend)) |
| `getRefreshTimer(immediate?, frequency?)` | a tick number on first load (if `immediate`) and every poll tick — no workspace | an **admin** resource's list: it has no workspace to switch ([21](21-admin-resources.md), `samples/admin-settings`) |

`getTenantRefreshTimer` is built on `getRefreshTimer`.
Pipe either through `takeUntilDestroyed(this.destroyRef)`.

## Backend (typed extension — inject `ICurrentUser`)
The SDK exposes `ICurrentUser` (a host singleton, so it injects into hot-loaded extensions). Read it inside a
request-scoped call (controller action, hook, `EnrichResultAsync`):
```csharp
using Duplo.Ai.Studio.Extensibility.Infra;

public sealed class MyResourceService : ResourceServiceBase<MyResource, MySpec, MyResult>
{
    private readonly ICurrentUser _user;
    public MyResourceService(ICurrentUser user /*, … other host services */) => _user = user;

    protected override async Task OnBeforeCreateAsync(MyResource r, CancellationToken ct)
    {
        if (_user.IsAuthenticated)
            r.Spec.CreatedBy = _user.Email;   // == _user.Username here
        // _user.OnBehalfOf, _user.Roles also available
        await base.OnBeforeCreateAsync(r, ct);
    }
}
```
`ICurrentUser`: `Email`, `Username` (== Email), `OnBehalfOf`, `Roles`, `IsAuthenticated`. Outside an HTTP request
(e.g. a worker) there's no user → strings are empty and `IsAuthenticated` is false. Do NOT define your own
current-user service — only host-registered SDK services inject on hot-load.

## Agent (provisioning skill)
When the agent processes a message, the sender's identity is exported as environment variables the skill can read:
```bash
echo "$DUPLO_USER_EMAIL"   # the logged-in user's email
echo "$DUPLO_USERNAME"     # same value
```
Set only when the message carries an identity — treat them as optional in scripts. Available alongside `DUPLO_HOST`,
`DUPLO_TOKEN`, and `DUPLO_SECRET_<NAME>`.
