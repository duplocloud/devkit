# Architecture

How the pieces fit. Orientation, not a specification — for the authoring detail, see the reference guides
in [`.claude/skills/duplo-extension-dev/reference/`](../.claude/skills/duplo-extension-dev/reference).

## The stack

Nothing here builds from source. Every service pulls a published image pinned by a tag in `.env`.

| Service | Image | Port | Role |
| --- | --- | --- | --- |
| `duplo-ai-studio` | `quay.io/duplocloud/backend` | 60031 | The platform API, serving `/v1/aiservicedesk`. Owns extensions, workspaces, resources, and tickets, and enforces the license in `Licensing__Token`. |
| `duplo-ui` | `quay.io/duplocloud/duplo-ai-helpdesk-ui` | 4210 | The Angular portal. The image serves the SPA only; the mounted `nginx/default.conf` proxies API prefixes to the studio, so the browser sees one origin and there is no CORS. |
| `claude-code-agent` | `quay.io/duplocloud/duplo-agent` | 8010 | The LLM agent that executes provisioning tickets. Calls back to the studio at `http://duplo-ai-studio:60021`. |
| `dind` | `docker:27-dind` | — | Docker-in-Docker daemon for the agent, mirroring the helpdesk-helm chart's sidecar. Shares `claude-code-agent`'s network namespace and listens on its loopback only (`DOCKER_HOST=tcp://127.0.0.1:2375`), so the agent can run containers and nothing else can reach the daemon. Mounts the same `/data` so bind-mount paths match. Runs privileged. |
| `mongo` | `mongo:7.0.14` | 27018 | All platform state, including the `loaded_extensions` records. Matches the version pinned in the helpdesk-helm chart. |
| `qdrant` | `qdrant/qdrant:v1.18.2` | 6333 | The vector database behind the Knowledge Base. The studio reaches it in-network at `http://qdrant:6333`; the host port is published so its dashboard is available for debugging. Runs with RBAC on, so the studio can mint read-only per-collection tokens instead of sharing the master key. |
| `xterm` | `quay.io/duplocloud/duplo-xterm` | 6061 | In-browser terminal. The browser reaches it on the published host port, so `AIStudio__XtermHost` must be host-reachable. |
| `init-perms` | `busybox:1.36` | — | One-shot. Chowns the shared named volumes to uid 1001 so the non-root studio and agent can write them. Named volumes are created root-owned, so this runs on every startup. |

Ports shown are the dev kit's `.env.example` defaults, mostly offset from the platform's standard ports so
this stack can run alongside a full local platform. See [configuration.md](configuration.md#host-ports).

Qdrant is the one service the platform reaches only through its own records: the studio has no connection
to it until a provider and a collection exist. `run.sh` therefore runs
[`scripts/register-qdrant.sh`](cli-reference.md#platform-registration), which registers Qdrant as a
`vectorDatabase` provider, wraps it in a `qdrant` scope so the provider is selectable in the ticket scope
picker, and creates an empty `devkit-docs` collection owned by the `extension-dev` workspace. That
collection's read access is *not* that scope — about a minute after it is created, the reconcile worker
mints a read-only token scoped to the one collection, wraps it in a `kb-devkit-docs-readonly` scope, and
attaches it to the owning workspace by itself.

Ingesting documents into that collection is a separate matter, and needs AWS Bedrock. The embedding model
the studio seeds is Bedrock's `cohere.embed-v4`, and the agent refuses every other provider, so uploading
a document needs Bedrock credentials that can invoke it. The registration above runs unconditionally
regardless: on the direct-Anthropic path the collection still provisions to Ready and can be browsed from
the UI, but each upload fails. See [configuration.md](configuration.md#knowledge-base).

## Volumes

| Volume | Mounted by | Holds |
| --- | --- | --- |
| `mongo_data` | mongo | The database, including `loaded_extensions`. |
| `platform_data` | studio, agent | The shared `/data` file store — skills and loaded-extension skill files. Shared so the agent can read the skills the studio seeded. |
| `extension_studio_data` | studio | Unpacked hot-loaded extension bundles. |
| `claude_sessions` | agent | Agent sessions, under its real home (`/home/appuser/.claude`). |
| `qdrant_data` | qdrant | Knowledge Base vectors and their payloads. |

Because extensions live in a named volume **and** are recorded in Mongo, they survive a container
recreate: `ExtensionReplayHostedService` re-registers the active records on boot. That is why
`./stop.sh && ./run.sh` keeps your extensions, and `./stop.sh --wipe` does not.

## What an extension is

One extension is a single deployable unit that becomes a **first-class resource type** in the platform:

| Part | What it is |
| --- | --- |
| Backend | A C# resources controller, service, and entity, compiled against the host SDK. |
| Frontend | An Angular 22 Native-Federation remote — list, add, and view components — loaded into the portal at runtime by its `remoteEntry.json` URL. |
| Provisioning skill | The instructions the agent follows when a resource of this type is created. |
| `manifest.json` | Id, version, REST segments, routes, and menus. |

It is packaged as a single `extension.zip`.

## The build and hot-load loop

```
  scripts/build-extension.sh                       scripts/deploy-extension.sh
            │                                                │
            │  GET  /v1/aiservicedesk/admin/extensions/      │  POST /v1/aiservicedesk/admin/
            │         sdk-version                            │        extensions/load-bundle
            │  GET  …/sdk-bundle                             │
            ▼                                                ▼
      compile against the        ──►  extension.zip  ──►  studio unpacks, registers,
      RUNNING platform's SDK                               and serves the new type
                                                                  │
                                                                  ▼
                                                      live in the UI, no restart
```

1. **Build.** `build-extension.sh` validates naming, reads the host's SDK version, downloads the SDK
   bundle, runs `dotnet publish` and the frontend build, then excludes every assembly the host already
   provides and zips what is left.
2. **Deploy.** `deploy-extension.sh` POSTs the bundle to `load-bundle`.
3. **Live.** The new resource type appears with no host restart. Creating one in the UI fires a
   provisioning ticket.
4. **Provision.** The ticket is assigned from the workspace's agent list — which is why a workspace needs
   an agent attached before anything provisions, and why `run.sh` runs `register-agent.sh`.

Because the build compiles against the SDK of the *running* platform, upgrading the studio image can mean
a new SDK — rebuild and redeploy after an upgrade.

## Local versus remote

The same scripts drive either target. `scripts/_target.sh` resolves the base URL and token from
`DUPLO_TARGET`:

- **`local`** — this stack at `http://localhost:$STUDIO_PORT`, authenticated with `DUPLO_ADMIN_TOKEN`.
- **`remote`** — an existing DuploCloud platform at `DUPLO_HOST`, authenticated with `DUPLO_TOKEN`.

Real environment variables override the file, so CI can supply both as secrets with no `.env` at all.

## Access model

The UI's accessible-workspace list is permission-set based, with no superuser bypass. An admin token can
hit every API while the portal still shows no workspaces. `run.sh` therefore creates three things beyond
the `extension-dev` workspace: a permission set granting it, a permission-set group assigning your user,
and the workspace itself. Without them, login lands on `/app/auth/no-tenant-access`.
