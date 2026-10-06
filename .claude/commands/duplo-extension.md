---
description: Start authoring a DuploCloud extension — gather name + detailed requirements, list the platform's available scopes and pick which to test with, ask clarifying questions, then scaffold + build via the duplo-extension-dev skill.
---

You are kicking off authoring a new **DuploCloud platform extension** in this dev-kit repo.

## Run plan-first, approve once
Building an extension runs many commands (SDK fetch, `dotnet publish`, `npm` build, deploy curl, resource
creation) and writes many files — approving each one is tedious. To avoid a stream of permission prompts:

1. **Immediately enter plan mode** (`EnterPlanMode`) as your first action. Do all of **Steps 1–4 inside plan
   mode** — they are read-only (env probes, scope listing) plus questions to the user; **write no files and run no
   builds yet**.
2. Once the requirements are unambiguous, present **one consolidated implementation plan** and call
   **`ExitPlanMode`**. The plan must **always** lead with the resource shape — before any file list or commands:
   - **Spec** — a table of spec fields (name · type · required/optional) per resource.
   - **Result** — a table of result fields (name · type) per resource.
   - **User experience** — a short walkthrough: where it appears in the left-nav, the create/add form, the list
     view, the detail page (Spec | Result, the Result tabs, and the **lifecycle phases** this resource goes through —
     a small table of phase · driving status/result field; see `reference/19-detail-page.md`), and what
     provisioning does end-to-end.
   - **Access control** — where each resource sits in the permission tree (default: under the Workspace) and a
     table of any named actions (id · endpoint · why it needs an explicit grant), or "default: workspace-scoped
     CRUD, no named actions" (see `.claude/skills/duplo-extension-dev/reference/18-access-control.md`).

   Then list the files you'll create under `extensions/<name>/` and the exact build/deploy commands. In the
   `ExitPlanMode` call, declare the Bash permissions the build needs via `allowedPrompts` so the user approves the
   whole implementation **in a single step**, e.g.:
   - "run the dev-kit `scripts/` (build-extension, deploy-extension, register-agent)"
   - "run `dotnet publish` / `dotnet` for the extension backend"
   - "run `npm install` / `npm run build` for the extension frontend"
   - "curl the studio API (scope/provider/resource calls)"
3. **Only after the plan is approved**, execute Step 5 (scaffold → build → deploy → test). Stay within the
   approved plan; if the build needs something outside the declared permissions, ask.

Drive the intake below **in order**. Do NOT scaffold or write any code until the plan is approved.

## Step 1 — Preflight: choose the target platform (local or remote)
This session can build/deploy against the **local** dev-kit stack or an existing **remote** DuploCloud platform.
The target is the `DUPLO_TARGET` flag in `.env` (`local` | `remote`). Read it and probe both:

```bash
env() { grep -E "^$1=" .env 2>/dev/null | head -1 | cut -d= -f2-; }   # safe .env read (no sourcing)
TARGET=$(env DUPLO_TARGET); TARGET="${TARGET:-local}"
PORT=$(env STUDIO_PORT); PORT="${PORT:-60021}"
LBASE="http://localhost:$PORT"; LTOK=$(env DUPLO_ADMIN_TOKEN)
RBASE=$(env DUPLO_HOST); RTOK=$(env DUPLO_TOKEN)
echo "DUPLO_TARGET=$TARGET"
echo -n "local  ($LBASE): "; curl -fsS -o /dev/null -w "%{http_code}\n" -H "Authorization: Bearer $LTOK" \
  "$LBASE/v1/aiservicedesk/extensions/sdk-version" 2>/dev/null || echo "down"
if [ -n "$RBASE" ]; then echo -n "remote ($RBASE): "; curl -fsS -o /dev/null -w "%{http_code}\n" \
  -H "Authorization: Bearer $RTOK" "$RBASE/v1/aiservicedesk/extensions/sdk-version" 2>/dev/null || echo "unreachable"
fi
```

Decide the target with the user:
- **Local stack is DOWN (not 200):** offer two options and wait for the choice —
  1. **Start it locally** — run `./run.sh` (sets up the local platform), then re-run this preflight.
  2. **Use a remote platform** — set `DUPLO_TARGET=remote`, `DUPLO_HOST=<url>`, `DUPLO_TOKEN=<Administrator
     bearer token>` in `.env` (edit the file), then continue.
- **Local stack is UP (200):** ask *"Use the local dev-kit platform, or a remote one?"*
  - **Local** → ensure `DUPLO_TARGET=local` in `.env`; continue.
  - **Remote** → set `DUPLO_TARGET=remote` + `DUPLO_HOST`/`DUPLO_TOKEN` in `.env`; continue.

Then **confirm the chosen target is reachable** (200 from `<base>/v1/aiservicedesk/extensions/sdk-version`
with its token) before proceeding. For the rest of this command resolve `BASE`/`TOKEN` the way `scripts/_target.sh`
does: local → `http://localhost:$STUDIO_PORT` + `DUPLO_ADMIN_TOKEN`; remote → `DUPLO_HOST` + `DUPLO_TOKEN`. The
`scripts/` read the same flag, so they target whatever you set here.

## Step 2 — Requirement first, then suggest a name
Lead with the requirement and **listen** — do not interrogate with a checklist yet:
- **Ask for the requirement with this template** (ask this first). Give the user the copy-paste template below and ask
  them to fill it in — replace the sample lines with their own (a line or two per section is plenty; rough is fine,
  you'll firm it up in Step 4). It is plain markdown so they can copy, edit, and paste it back. Capture the answers.

  ```
  ## What you want to build
  A Jenkins Job resource — trigger a Jenkins build from DuploCloud and track its outcome.

  ## Inputs (what the user fills in when creating one)
  - job name (required)
  - branch (default: main)
  - build parameters (optional, key-value)

  ## What should happen (what provisioning does with the inputs)
  Call Jenkins to start the build, poll until it finishes, capture the build number and result.

  ## Result to show
  - build number
  - status (SUCCESS / FAILED)
  - duration
  - link to the console log
  ```
- **Enumerate what already exists.** Before proposing anything, `ls extensions/*/manifest.json`. If extensions
  already live here (a shared repo — other developers' work), let the requirement decide: MODIFY an existing
  `extensions/<name>/` or scaffold a NEW `extensions/<name2>/`; ask when it's ambiguous. Before scaffolding new,
  read a sibling extension to match its conventions.
- **Then suggest a name.** From that description, propose a short, lowercase extension name (e.g. `widgets`,
  `reports`) and say what it drives — the extension id, the resource type(s), and the Native Federation remote name. Ask the user
  to confirm or change it; do not ask for a name cold before hearing the requirement. In a shared repo the name —
  and the frontend's federation remote `name` — must collide with no sibling extension.

## Step 3 — List the target's scopes, ask which to test with
A scope carries the credentials the agent will use during provisioning. First settle the **workspace** to author
against, then list its scopes and ask which one(s) this extension needs **for testing**:
- **Local** → workspace is `EXTENSION_DEV_WORKSPACE_ID` (from `.env`).
- **Remote** → use `DUPLO_WORKSPACE_ID` if set in `.env`; otherwise `GET <base>/v1/aiservicedesk/admin/data/workspaces`,
  show the list, ask the user to pick one, and offer to save it to `.env` as `DUPLO_WORKSPACE_ID`.

Resolve `BASE`/`TOKEN`/`WS` per the chosen target, then list (replace the placeholders with the resolved values):

```bash
env() { grep -E "^$1=" .env 2>/dev/null | head -1 | cut -d= -f2-; }
TARGET=$(env DUPLO_TARGET); TARGET="${TARGET:-local}"
if [ "$TARGET" = remote ]; then
  BASE=$(env DUPLO_HOST); TOK=$(env DUPLO_TOKEN); WS=$(env DUPLO_WORKSPACE_ID)
else
  PORT=$(env STUDIO_PORT); BASE="http://localhost:${PORT:-60021}"; TOK=$(env DUPLO_ADMIN_TOKEN); WS=$(env EXTENSION_DEV_WORKSPACE_ID)
fi
python3 - "$TOK" "$WS" "$BASE" <<'PY'
import sys,json,urllib.request,urllib.error
tok,ws,base=sys.argv[1:4]
B=f"{base}/v1/aiservicedesk"
def get(p):
    r=urllib.request.Request(f"{B}{p}",headers={"Authorization":f"Bearer {tok}"})
    d=json.load(urllib.request.urlopen(r,timeout=15)); d=d.get("data",d)
    return d.get("items",d) if isinstance(d,dict) else d
try:
    scopes=get(f"/user/data/workspaces/{ws}/scopes")
    provs={p.get("id"):(p.get("type"),p.get("name")) for p in (get('/admin/data/providers') or [])}
    if not scopes:
        print("No scopes registered. Register a provider + scope (admin providers/scopes API) and attach it to "
              "the workspace, or proceed with none if the extension needs no external creds.")
    for s in scopes:
        t,pn=provs.get(s.get("providerId"),("?","?"))
        print(f"- {s.get('name')}  ·  provider: {t} ({pn})  ·  scopeId: {s.get('id')}")
except urllib.error.HTTPError as e:
    print("Could not list scopes:", e.code, e.read().decode()[:200])
PY
```
Show the list, then ask the user **which scope(s)** to use for testing. Record the chosen `scopeId`(s) — they
become the resource spec's `ScopeIds` when you create a test resource, and the provisioning skill reads that
scope's credentials from `other_scopes/<name>.json` (see
`.claude/skills/duplo-extension-dev/reference/07-scope-credentials.md`). If the target system isn't registered
yet, help the user create a provider (`type: "other"`, `category: other`) + scope first.

## Step 4 — Clarifying questions (gate)
Now that you've heard the requirement, turn the template answers into a precise shape: **section 2 → the exact Spec
field table, section 4 → the exact Result field table, section 3 → the provisioning mode** (derive per SKILL Phase 1;
don't default to agent). Ask any remaining questions you need to build correctly. **Archetype is always typed (C#
backend + Angular remote + provisioning skill) — never ask the user to choose an archetype.** Remaining questions, e.g.:
- exact **spec fields** and **result fields** per resource (name · type · required/optional);
- **only if the requirement describes more than one related resource:** is it a flat set or a
  **parent → child** hierarchy? (drives `ParentRefSpec`/`ChildResourceController` + nested menu — see reference/08);
- **custom actions / extra controller endpoints** consumed by the FE (logs, trigger, etc.);
- **access control**: is "anyone granted the workspace may manage it" right (the default), or does the resource
  sit under a parent / an extension category? Should any endpoint require an **explicitly granted named action**
  rather than plain CRUD (restart, console/exec, credential-minting shapes — see reference/18-access-control.md)?
- **menu** placement (a top-level `collapsible-section` with `item` children renders nested correctly);
- **agent** — which agent (DevOps / Compliance / Observability / Release Management / custom) this
  extension files under; omit the field if the author doesn't pick one;
- **Ask AI** is opt-in: scaffold it ONLY if the user's requirement explicitly asks for AI chat sessions on the
  resource — never offer it or add it unprompted (see skill reference 16-ask-ai);
- for an external system: **auth** style (basic/bearer) and which API calls provisioning makes (a custom
  external HTTP API, etc.).

**Do not write code until these are unambiguous.**

## Step 5 — Scaffold + build (hand off to the skill)
Now follow the `duplo-extension-dev` skill — read `.claude/skills/duplo-extension-dev/SKILL.md` and its
`reference/` docs, then:
- scaffold into **`extensions/<name>/`** (one dir per extension under `extensions/` — copy the skill's
  `templates/helloworld`, or adapt what `scripts/init-project.sh` already seeded there). Reference examples live in `samples/`.
- set a **unique** `REMOTE_NAME` in `frontend/federation.config.js` (used as the federation `name` and it must
  match `manifest.json`'s `frontend.remote.remoteName` — two extensions sharing it collide),
- author backend + frontend + provision skill(s) + `manifest.json` to match the agreed requirements. **Rename every
  `HelloWorld`/`HelloService`/`hw-` identifier (backend AND frontend) to your resource, and set the FE service's
  `REST_SEGMENT` to the full `extensions/<…>` path — the build fails otherwise.**
- build + deploy (the scripts resolve the target from `.env`/env via `scripts/_target.sh`):
  ```bash
  ./scripts/build-extension.sh  extensions/<name>
  ./scripts/deploy-extension.sh extensions/<name>/dist/extension.zip
  ```

## Step 6 — Verify provisioning (ask the user which way)
Once the extension is deployed and the new resource type is live, **ask the user how they want to test it** and
proceed with their choice:

- **A) User creates it in the UI; the agent watches.** The user opens the UI, navigates to the new resource type,
  and creates one (selecting the chosen scope). You **watch the provisioning** — tail the agent
  (`./logs.sh claude-code-agent`) and poll the resource's status/result
  (`GET …/environment/<restSegment>/{id}`) until it reaches `Complete`/`Failed`, then report what happened.
- **B) The agent creates it via API and self-watches.** You create the resource yourself — `POST
  …/user/data/workspaces/<ws>/environment/<restSegment>` with the spec (including the chosen `ScopeIds`) — then
  poll its status/result (and, if useful, `./logs.sh claude-code-agent`) until `Complete`/`Failed` and report.

Either way, the chosen `scopeId`(s) become the resource spec's `ScopeIds`, and the provisioning skill reads that
scope's credentials from `other_scopes/<name>.json`. See the skill's
[07-scope-credentials](../skills/duplo-extension-dev/reference/07-scope-credentials.md) and the **Verify** section
of `SKILL.md` for the exact endpoints per mode (in-platform vs local/admin).
