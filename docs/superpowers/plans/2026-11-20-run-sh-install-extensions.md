# run.sh: Auto-install Default Extensions — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **Revised 2026-11-24** to match what shipped. The first draft listed `<id[@version]>` arguments, picked the semver-highest catalog version, checked `…/extensions/{id}/versions`, skipped `…/catalog/refresh` and treated a 2xx install as done. The ticket's traced install flow (Andy Boutte's comment) replaced all of that: manifest ids only, refresh first, install the build the installer offers, wait for the installer.

**Goal:** `./run.sh` installs a fixed list of extensions (starting with Cloud Setup, `com.duplocloud.cloud-setup`, the agent the ticket calls the Cloud Deployment Agent) after the platform is set up and before it prints the "open the portal" finish.

**Architecture:** `scripts/install-extensions.sh <manifest-id>…` (same shape as `register-persona.sh` / `register-qdrant.sh`: sources `_target.sh`, idempotent, talks only to the studio admin API) does the work. It refreshes the registry catalog once and uses that reply as the catalog. Per manifest id it decides from the catalog row, the installer's mark and its requests whether to skip, leave alone or install. It installs the offered build with `pin:false`, then polls the catalog's `requests[]` until the installer reports the request `done`, `failed` or `backed-out`. `run.sh` owns the list (`DEVKIT_EXTENSIONS`) and calls the script non-fatally after the Qdrant KB step, before the "where to open the portal" section, adding a line to the "Platform ready" banner.

**Tech Stack:** bash (`set -euo pipefail`, bash 3.2-safe), curl, python3 stdlib for JSON — same as every other `scripts/*.sh`.

**Spec:** ClickUp [Update DevKit to auto-install the Cloud Deployment Agent](https://app.clickup.com/t/17twvjwz78f) (DUPLOAI-4813): Sum Yip's comments (endpoints, the live refresh response) and Andy Boutte's traced install flow — manifest id as `extensionId`, refresh first, the offered version from `marks[]`, `POST /install`, poll until installed.

## Global Constraints

- Extension list lives in `run.sh` as `DEVKIT_EXTENSIONS=( … )`; first and only entry for now: `com.duplocloud.cloud-setup`. The ticket's agent id `99104691-58dc-4178-8860-f69b5ac5a727` is that row's `uuid`.
- Entries are **manifest ids** — the license catalog's `manifest_id`, which the installer keys every entry on. Never the agent UUID (matches no entry; the install fails `not-entitled`) and never the catalog's display `id` (renameable). No `@version`: without a pin the installer only takes the version it offers (otherwise 409 `version-not-offered`).
- Endpoints (Administrator bearer token; base URL = `BASE_URL` from `scripts/_target.sh`, prefix `/v1/aiservicedesk/admin`):
  - `POST /extension-registry/catalog/refresh` → the full ExtensionLibrary document (same shape as `GET /extension-registry/catalog`). Called **once** per run and used as the catalog. A non-2xx refresh only warns, then falls back to one `GET /extension-registry/catalog`.
  - `POST /extension-registry/install` body exactly `{"extensionId": "<manifest-id>", "version": "<offered>", "pin": false}` → 202 (or 200 when a request is already pending) with `requestId` and `state`.
  - `GET /extension-registry/catalog` → polled while waiting for the installer.
  - No `…/extensions/{id}/versions` call: the catalog row's `installed` / `installedVersion` already say what is current.
- Catalog fields used: `libraryState`; `extensions[]` (`manifestId`, `licensed`, `installed`, `installedVersion`); `marks[]` (`id`, `version`, `reason`, `pinnedVersion`); `requests[]` (`requestId`, `id`, `version`, `state`, `reason`, `detail`).
- Never fatal to `run.sh`: a failed install prints a re-run hint and the platform still comes up.
- Idempotent: a re-run must not re-POST an install for the version already installed.
- JSON is built and parsed with `python3` only (no `jq`).
- Ids are validated against `^[A-Za-z0-9][A-Za-z0-9._-]*$` before use; `@` is rejected.
- `EXT_INSTALL_TIMEOUT` (default 300) bounds the wait per extension; `EXT_INSTALL_POLL` (default 5) sets the interval, both in seconds.

## Review Focus

1. **Wrong install key:** a UUID or display id in `DEVKIT_EXTENSIONS` installs nothing. → `list_defined` rejects UUID-shaped entries; `matches_manifest_id`.
2. **Re-running `./run.sh`:** the second run reports "already installed" and sends no install POST. → `current_version_skipped`.
3. **Don't fight an admin or the installer:** a pinned extension, one mid-install, or one the installer refuses (mark `reason`) is left alone or reported, never re-installed. → `pinned_left_alone`, `in_progress_skipped`, `mark_blocked`.
4. **Install is asynchronous:** a 202/200 is not success; only a `done` request is. A `failed` / `backed-out` request or a timeout is a failure with the installer's reason. → `install_202_polled_to_done`, `install_failed_reason`, `install_backed_out`, `install_timeout`.
5. **Non-JSON error bodies** (nginx 502 HTML, empty body) from install: the HTTP code and raw text reach the user, with no Python traceback. → `install_non_json_error`.

---

### Task 1: `scripts/install-extensions.sh`

**Files:**
- Create: `scripts/install-extensions.sh` (executable)
- Create: `tests/test-install-extensions.sh` (executable)

**Interfaces:**
- Consumes: `scripts/_target.sh` → `BASE_URL`, `TOKEN`.
- Produces: CLI `./scripts/install-extensions.sh <manifest-id> [...]`
  - no args → usage on stderr, exit 2
  - exit 0 ⇒ every id is installed, already current, or skipped. exit 1 ⇒ at least one id failed or timed out (every other id is still processed), or there is no token, or the catalog can't be read / its `libraryState` isn't `ok`.
  - stdout lines:
    - `    ✔ <id> <ver> — already installed`
    - `    ✔ <id> <ver> — installed`
    - `    ↷ <id> — not in the extension catalog, skipped`
    - `    ↷ <id> — not licensed for this install, skipped`
    - `    ↷ <id> — the installer offers no version (does the license list it?), skipped`
    - `    ↷ <id> — pinned at <ver>, left alone`
    - `    ↷ <id> — an install is already in progress (<state>)`
  - stderr lines:
    - `    ! could not refresh the extension catalog: HTTP <code>: <…> — using the cached one`
    - `    ✗ could not read the extension catalog: HTTP <code>: <…>` / `library state "<state>" (<why>)`
    - `    ✗ <id> — the installer can't install it here: <reason>`
    - `    ✗ <id> <ver> — install failed: HTTP <code>: <…>`
    - `    ✗ <id> <ver> — install failed: <failed|backed-out> (<reason>)`
    - `    ✗ <id> <ver> — still <state> after <n>s (EXT_INSTALL_TIMEOUT); check the Extension Library page`
    - `    ✗ '<arg>' — invalid extension id`

Per-id decision, in order, over the catalog row matched on `manifestId`, the mark matched on `id`, and any request for that id not yet `done`/`failed`/`backed-out`:

```
no row                          → missing     (skip)
licensed == false               → unlicensed  (skip)
mark.pinnedVersion              → pinned      (leave alone)
an unfinished request           → busy        (leave alone)
mark.version, installed at it   → current     (already installed)
mark.version                    → install mark.version
mark.reason                     → blocked     (error)
otherwise                       → nooffer     (skip)
```

- [x] **Step 1: Write the test harness and failing tests**

`tests/test-install-extensions.sh` uses a temp kit copy, a `.env` with `DUPLO_ADMIN_TOKEN=fixture`, and a stub `curl` first on `PATH` that logs `"<METHOD> <URL> <BODY>"`. It serves `$STUB/catalog.json` from both refresh and GET (`refresh.code` makes the refresh fail). It answers install with `install.code` / `install.body` (default 202 `{"requestId":"r1","state":"accepted"}`). After a 2xx install, later catalog reads carry a request `r1` whose state is popped from `$STUB/states` (default `done`). `run` sets `EXT_INSTALL_POLL=0`.

Tests: `offered_version_installed`, `pin_is_json_false`, `call_sequence` (refresh, install, GET poll — never `/versions`), `mark_version_wins`, `catalog_read_once`, `refresh_failure_warns`, `current_version_skipped`, `no_versions_call`, `older_current_upgraded`, `unknown_id_skipped`, `no_offer_skipped`, `catalog_unreachable`, `install_http_error_message`, `install_non_json_error`, `invalid_id_rejected` (incl. `@`), `no_args_usage`, `matches_manifest_id`, `library_state_not_ok`, `unlicensed_skipped`, `mark_blocked`, `pinned_left_alone`, `in_progress_skipped`, `finished_request_ignored`, `installer_reason_shown`, `install_202_polled_to_done`, `install_200_is_pending`, `install_failed_reason`, `install_backed_out`, `install_timeout`, `poll_without_request_id`.

- [x] **Step 2: Run tests, verify they fail**

Run: `bash tests/test-install-extensions.sh`

- [x] **Step 3: Implement `scripts/install-extensions.sh`** per the constraints and decision table above. `api METHOD URL [BODY]` prints the body then the HTTP code (`000` on a transport failure; never `curl -f`). `err_msg` turns a JSON error body into `message` + `errors` + ` (code)`, else the raw text, else `<empty body>`.

- [x] **Step 4: Run tests, verify they pass**

Run: `bash tests/test-install-extensions.sh`
Expected: every line `ok`, final `30 passed, 0 failed`.

---

### Task 2: Wire it into `run.sh`

**Files:**
- Modify: `run.sh` — header "On completion it has: …"; new block between the Qdrant KB `esac` and `# ── where to open the portal`; banner line.
- Modify: `docs/architecture.md`, `docs/cli-reference.md`.
- Create: `tests/test-run-install-extensions.sh`

**Interfaces:**
- Consumes: Task 1's CLI and exit codes.
- Produces: `DEVKIT_EXTENSIONS` array and `EXT_LINE` banner fragment in `run.sh`.

- [x] **Step 1: Write the wiring test** (static checks; nothing starts the stack)

| test | assert |
|---|---|
| `syntax` | `bash -n run.sh` |
| `list_defined` | `DEVKIT_EXTENSIONS` contains `com.duplocloud.cloud-setup`; every entry matches `^[A-Za-z0-9][A-Za-z0-9._-]*$` and none is UUID-shaped |
| `call_is_non_fatal` | the install runs as an `if`/`elif` condition |
| `empty_list_guarded` | an empty `DEVKIT_EXTENSIONS` is checked just before it is expanded (bash 3.2 + `set -u`) |
| `placed_after_kb_before_portal` | the call sits after `register-qdrant.sh` and before `portal_url() {` |
| `banner_shows_extensions` | the banner line with `$KB_LINE` also has `$EXT_LINE` |
| `portal_message_still_last` | `tests/test-run-portal-message.sh` still passes |

- [x] **Step 2: Add the block to `run.sh`**, with a comment giving the ticket, the manifest-id rule, the refresh / offered build / wait flow and why it is non-fatal.

- [x] **Step 3: Run the wiring tests and the existing run.sh tests**

Run: `for f in tests/test-run-*.sh tests/test-install-extensions.sh; do bash "$f" || echo "FAILED: $f"; done`
Expected: no `FAILED:` lines.

- [ ] **Step 4: Live check against the local stack** (needs Docker and a licensed `.env`; not runnable in CI)

1. `POST …/extension-registry/catalog/refresh` with the admin token: `com.duplocloud.cloud-setup` is listed, licensed, and has a mark with a `version`.
2. `./scripts/install-extensions.sh com.duplocloud.cloud-setup` → `✔ … installed`; the catalog row now shows `installed: true` at that version.
3. Run it again → `already installed`, with no install POST.
4. `./run.sh` (no flags) → the `==> Installing default extensions…` block prints before the portal step, and the banner shows the `Extension` line.

## Open questions

- **Empty `marks[]`:** the live refresh response in the ticket has `marks: []` although the installer is ready and Cloud Setup is licensed with version `0.1.22`. With no mark the script skips the id as "offers no version". If that is the normal state on a fresh stack, fall back to the newest `versions[]` entry and retry once with a 409's `offeredVersion`.
- **Agent attachment:** this installs the extension only. Attaching the agent to the `extension-dev` workspace (as `register-agent.sh` does for the default agent), if needed, is a follow-up.
