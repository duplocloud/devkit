# Hello World — canonical typed agent

This is the **worked reference** the `duplo-extension-dev` skill copies and adapts. It is the smallest
complete, buildable, loadable DuploCloud agent that behaves as a **first-class resource**: a real C#
`ResourcesController` + service + entity (its own Mongo collection + REST route), an Angular 22
Native-Federation remote (list/add/view), and a provisioning skill. The upload endpoint compiles
nothing — it loads the **pre-built DLL** into a collectible AssemblyLoadContext + per-agent DI child
container and registers the new controller's routes **live** (no host restart), exactly like a
built-in resource (Namespace, NetworkBaseline).

```
backend/    typed C# — Spec/Result/Resource/Hooks/Service (SDK base classes) + ResourcesController
frontend/   Angular 22 Native-Federation remote (list/add/view) using the platform UI lib @duplocloud-internal/ng-common-lib
skills/     provision-helloworld — reads firstName+lastName, writes fullName back as the result
manifest.json  ties it together: backend block + typed resource + skill + frontend remote/menu/route
```

The detail page is the platform's detail shell (reference/19-detail-page.md): a card-less header, a Spec | Result
switcher, the main card, and a lifecycle rail whose phase timeline is derived from the resource's status + result.
The Result content is hand-written (reference/17-custom-result-views.md).

The example resource takes `firstName` + `lastName` and produces `fullName`, persisted in its own
`extension_helloworlds` collection and served at `…/environment/extensions/helloworlds`.

## What it demonstrates

- A resource type contributed by a hot-loaded agent DLL with **no host changes**: its own controller
  becomes routable at `…/environment/extensions/helloworlds`, its service runs the standard provisioning
  lifecycle, and FaultDetection reconciles it — identical to a first-party resource.
- The skill → **status** → **result** loop (the two write-back APIs are separate), posted to the
  resource's OWN route. Spec fields are typed properties under `spec`; the result is the typed result
  object.
- A per-agent Native-Federation remote that shares the host's Angular 22 / RxJS singletons, reaches
  host services via the `REMOTE_DuploHttpClient` + `REMOTE_UserSession` string DI tokens, and builds its
  UI from the platform library `@duplocloud-internal/ng-common-lib` (searchable-datatable, forms, ngbNav) plus
  the detail shell in `frontend/src/app/shared/`, so it looks native.

## Build + package + load

```bash
# 1. SDK feed — pin the agent to the host's exact SDK version
SDK_VER=$(curl -fsS -H "Authorization: Bearer $TOKEN" "$DUPLO_BASE/v1/aiservicedesk/extensions/sdk-version" | jq -r .version)
curl -fsS -H "Authorization: Bearer $TOKEN" "$DUPLO_BASE/v1/aiservicedesk/extensions/sdk-bundle" -o /tmp/sdk.zip
unzip -o /tmp/sdk.zip -d backend/sdk-packages

# 2. Backend DLL. The SDK is compile-only, but publish still copies its whole transitive closure
#    (Mongo/AWS/AspNetCore + native runtimes/) into dist/backend — the host already has all of it, so only
#    this agent's own dll belongs in the bundle (step 4). Or just run ../../scripts/build-extension.sh,
#    which trims automatically.
( cd backend && dotnet publish Duplo.Extension.HelloWorld.csproj -c Release -o ../dist/backend -p:DuploSdkVersion="$SDK_VER" )

# 3. Frontend remote — uses the platform UI lib @duplocloud-internal/ng-common-lib from the shared
#    tarball (packages/*.tgz, referenced via file: in package.json), so NO token is needed.
#    Plain `npm install` — the one Angular 22 peer conflict (ngx-toastr) is resolved by the "overrides"
#    block in package.json, so the `--legacy-peer-deps` escape hatch is neither needed nor allowed.
#    The build writes frontend/dist/remoteEntry.json + sibling ESM chunks (no dist/browser/, no index.html).
( cd frontend && npm install && npm run build )

# 4. Assemble the bundle: manifest.json + backend/ (your DLL only) + fe/ + skills/, then zip
rm -rf pkg; mkdir -p pkg/backend pkg/fe pkg/skills
cp manifest.json pkg/ ; cp dist/backend/Duplo.Extension.*.dll pkg/backend/ ; cp -r frontend/dist/* pkg/fe/ ; cp -r skills/* pkg/skills/
rm -f agent.zip   # zip updates in place — drop the stale archive first so the bundle shrinks
( cd pkg && zip -r ../agent.zip . )

# 5. Upload the bundle — the studio unpacks + hot-loads the DLL
curl -fsS -X POST "$DUPLO_BASE/v1/aiservicedesk/user/data/workspaces/$WS/environment/extension-studio/$ID/load-bundle" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/zip" --data-binary @agent.zip
```

See the skill entry point `../../.claude/skills/duplo-extension-dev/SKILL.md` for the full build+load
flow (in-platform and local), and the framework docs in `../../.claude/skills/duplo-extension-dev/reference/` — `01-architecture.md`, `02-authoring-guide.md`, `03-base-classes.md`,
`04-hooks.md`, `05-custom-actions.md`, `06-registration.md`.

## Load the frontend into a local portal without uploading a bundle

Serve the built remote yourself and have the portal read it from there — useful for iterating on the UI
against a backend that already has the agent installed.

```bash
( cd frontend && npm run build )                       # writes frontend/dist/remoteEntry.json
npx http-server frontend/dist -p 4401 --cors -c-1      # -c-1: no caching, so a rebuild is picked up
```

Then point the portal at it: in `duplo-ui/portal/src/app/services/extension-manifest.store.ts`, put this
sample's `manifest.json` `frontend` blob into `mockLocalExt` with
`remote.remoteEntry: 'http://localhost:4401/remoteEntry.json'` (absolute — a relative path would resolve
against the API host). Run the portal (`npm run run:all`) and open **AI Suite → DevOps → Hello World**.

## Adapt for a new resource

Rename `HelloWorld*` → your resource across `backend/` (classes, `[BsonCollection]`, controller
`[Route]`, `GetTicketOriginType`/`SubType`), edit the spec/result fields, update the FE service
(`SUB_TYPE`, REST segment, origin-context `type=`), the skill, and `manifest.json` (ids, type names,
`backend.entryAssembly`, originType/subType, restSegment, menu, route). Keep `archetype: "typed"` so the loader
takes the DLL path.
