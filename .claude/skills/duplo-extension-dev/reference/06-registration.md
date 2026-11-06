# Registration — In-Platform vs Local, and SDK Versioning

An extension bundle (`{manifest.json, backend/, fe/, skills/}` zip) is registered by **loading** it into a
running studio. There are two ways in, and they differ only in the endpoint + token.

## Mode A — In-platform (Extension resource provisioning ticket)

A user creates a **Extension resource** in Extension Studio; the standard provisioning lifecycle runs this
skill in a ticket. The platform (`ResourceProvisioningManager`,
`Duplo.Ai.DataManagement/.../Services/ResourceProvisioningManager.cs`) hands the agent everything:

- **Inputs:** the spec is written to `shared/<subtype>.json` in the ticket workdir
  (`extension.json` for the Extension resource). The skill template is seeded into
  `.claude/skills/duplo-extension-dev/` (templates + reference included).
- **`platform_context`:** `duplo_base_url` and a **resource-scoped JWT** (`duplo_token`), plus any
  selected scope's **cloud credentials** under `platform_context.scopes`.
- **Token scopes (48h):** the scoped JWT authorizes only this resource's
  `…/{id}/status`, `…/{id}/results`, `…/{id}/load-bundle`, plus the always-granted agent-callback path.
  (`{id}/load` is NOT granted — workdir-staged load stays Administrator break-glass.)
- **Env the platform sets:** `DUPLO_HOST` and `DUPLO_TOKEN` (a skill must NEVER overwrite either).
  `DUPLO_BASE` is a local-only override — scripts read `${DUPLO_BASE:-$DUPLO_HOST}`.

Load endpoint (resource-scoped, on the Extension resource):
```
POST {DUPLO_HOST}/v1/aiservicedesk/user/data/workspaces/{ws}/environment/extension-studio/{id}/load-bundle
Authorization: Bearer {DUPLO_TOKEN}        # the scoped token
Content-Type: application/zip
<bundle.zip>
```
Then mark the Extension resource done with `POST …/environment/extension-studio/{id}/status {"status":"Complete"}`.

## Mode B — Local developer (Claude on your machine)

Run this skill locally. It cannot rely on an injected token, so **you provide**:
- the platform **base URL** (e.g. `https://<tenant>.duplocloud.net`, or the dev-kit stack at
  `http://localhost:60031`), and
- an **admin bearer token** (a user with the `Administrator` role).

Build the bundle the same way, then register via the **admin** endpoint:
```
POST {BASE}/v1/aiservicedesk/admin/extensions/load-bundle      # [Authorize(Roles="Administrator")]
Authorization: Bearer {ADMIN_TOKEN}
Content-Type: application/zip
<bundle.zip>
```
Admin extension management (`Duplo.Ai.Studio.ExtensionStudio/Controllers/Admin/ExtensionsController.cs`):
| Verb · Route | Purpose |
|---|---|
| `POST /v1/aiservicedesk/admin/extensions/load-bundle` | Load/upgrade from a zip body (unpacks + hot-loads). |
| `POST /v1/aiservicedesk/admin/extensions/load` | Load from a `manifest` (DLL already staged on the extensions volume). |
| `GET /v1/aiservicedesk/admin/extensions/{id}/versions` | List loaded versions (rollback candidates). |
| `POST /v1/aiservicedesk/admin/extensions/{id}/activate/{version}` | Activate a previously loaded version (rollback). |
| `GET  /v1/aiservicedesk/admin/extensions` · `GET {id}` | List / inspect loaded extensions. |
| `POST /v1/aiservicedesk/admin/extensions/{id}/disable` | Unregister (unload, withdraw routes). |
| `DELETE /v1/aiservicedesk/admin/extensions/{id}` | Disable + purge the record. |
| `GET /v1/aiservicedesk/extensions/sdk-version` | Host SDK version (authenticated — send the bearer token). |
| `GET /v1/aiservicedesk/extensions/sdk-bundle` | SDK NuGet feed as a zip (authenticated — send the bearer token). |

The skill **auto-detects** the mode: if `$DUPLO_TOKEN` + `$DUPLO_BASE`/`$DUPLO_HOST` are present →
Mode A (in-ticket); otherwise → Mode B (ask for base URL + admin token).

## Getting the SDK to compile against (both modes)

The host serves its own SDK as a NuGet feed:
1. `GET …/extensions/sdk-version` → e.g. `{"version":"1.0.2"}` — pin this.
2. `GET …/extensions/sdk-bundle` → zip of `.nupkg`s; unzip into `backend/sdk-packages/`.
3. `backend/nuget.config` points at `./sdk-packages`; the `.csproj` references
   `Duplocloud.AiHelpdesk.Sdk` `Version="[$(DuploSdkVersion)]" ExcludeAssets="runtime"` (compile-only).
4. `dotnet publish backend -p:DuploSdkVersion=<version>` → ships only your DLL (SDK assemblies are NOT
   bundled; the host's Default ALC provides them at load → shared type identity).

## SDK version pinning — why exactness matters

For new builds, always set `manifest.sdkVersion` from `sdk-version` and compile against the matching
`sdk-bundle`. The .NET 10 host also accepts older compiled bundles within its supported SDK range
(same SDK major, at least the minimum supported version, and no newer than the host), subject to its
referenced-API compatibility checks. An older manifest does not need an artificial version bump solely
because the host runtime changed. Test existing bundles on the upgraded host before release.

New `net10.0` builds require a .NET 10 host. In-platform builds also require an agent with SDK 10.

## Reloading changed code — bump `manifest.version`

Bump `manifest.version` on **every backend code change** before re-loading. A `load-bundle` of the **same**
version does not reliably pick up new code: the prior `AssemblyLoadContext` is only best-effort-unloaded (BSON
serializers and MVC caches pin it), and old MVC routes can linger (→ `AmbiguousMatchException`). A new version
stages a fresh `{id}/{version}/backend` dir and a fresh load context, so the new DLL actually runs. Frontend-asset
and skill-only changes reload fine at the same version. If you must reload the same backend version, restart the
studio.

## What a local run needs (checklist)
- Base URL + an Administrator bearer token.
- .NET 10 SDK + Node 22 (Angular 22 requires `^22.22.3 || ^24.15.0 || >=26.0.0`) + npm `>= 10.9.0` locally
  (or use the in-platform agent image, which has all of them).
- This skill dir (with `templates/helloworld/` + `reference/`).
- Network access to the platform for `sdk-version`/`sdk-bundle` and `load-bundle`.
