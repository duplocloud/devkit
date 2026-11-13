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

`ExtensionStudioLoader` **rejects** a bundle whose `manifest.sdkVersion` ≠ the host's running SDK version. The host
version is read from the running `Duplo.Ai.Model` assembly, and the SDK feed is packed at that same version, so
host runtime == feed == your extension's pin. A skew surfaces as `Could not load file or assembly
'Duplo.Ai.DataManagement, Version=…'`. Always set `manifest.sdkVersion` from `sdk-version`, and build against
the matching `sdk-bundle`.

## Building for more than one SDK version (package feed, no host)

The exactness rule means an extension meant for hosts at different SDK versions ships one bundle per version.
`scripts/build-extension.sh` does that from the package feed when `DUPLO_SDK_VERSIONS` names the versions,
comma-separated or one per line:

```bash
DUPLO_SDK_VERSIONS=1.0.6,1.0.7 ./scripts/build-extension.sh extensions/<name>
```

- Each version is restored as `Duplocloud.AiHelpdesk.Sdk` at exactly that version through the `nuget.org`
  source in `backend/nuget.config` (a feed build puts nothing in the local `./sdk-packages` source), so it must
  be a version the feed publishes. No `sdk-version` or `sdk-bundle` call is made, and no `.env`, `DUPLO_HOST` or
  `DUPLO_TOKEN` is needed to build.
- The frontend is built once; the backend is published once per version, with `-p:DuploSdkVersion=<v>`, and
  obfuscated when `ARMDOT_LICENSE_FILE_PATH` is set, as in a host build.
- Output is `dist/sdk-<v>/extension.zip` per version, each stamped `sdkVersion: <v>` and no `sdkDigest` (there
  is no host bundle to fingerprint). `dist/extension.zip` is not written, and a bundle for a version no longer
  listed is removed by the next build. Unset, the variable keeps the single host build at `dist/extension.zip`.
- The host credentials are for deploying only. `scripts/deploy-all.sh` reads the host's `sdk-version` and loads
  the one bundle stamped with it, failing when none matches; `scripts/deploy-extension.sh <zip>` loads the bundle
  you name, which the host rejects unless its `sdkVersion` is the host's.
- In CI, `.github/workflows/extension-ci.yml` and `release.yml` take the same list from the repository variable
  `DUPLO_SDK_VERSIONS`; the release action then cuts one release per bundle, tagged with its `sdkVersion`.

## Reloading changed code — bump `manifest.version`

Bump `manifest.version` on **every backend code change** before re-loading. A `load-bundle` of the **same**
version does not reliably pick up new code: the prior `AssemblyLoadContext` is only best-effort-unloaded (BSON
serializers and MVC caches pin it), and old MVC routes can linger (→ `AmbiguousMatchException`). A new version
stages a fresh `{id}/{version}/backend` dir and a fresh load context, so the new DLL actually runs. Frontend-asset
and skill-only changes reload fine at the same version. If you must reload the same backend version, restart the
studio.

## What a local run needs (checklist)
- Base URL + an Administrator bearer token.
- .NET 8 SDK + Node 22 (Angular 22 requires `^22.22.3 || ^24.15.0 || >=26.0.0`) + npm `>= 10.9.0` locally
  (or use the in-platform agent image, which has all of them).
- This skill dir (with `templates/helloworld/` + `reference/`).
- Network access to the platform for `sdk-version`/`sdk-bundle` and `load-bundle`.
