# run.sh: Auto-install Default Extensions — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `./run.sh` installs a fixed list of extensions (starting with the Cloud Deployment Agent) after the platform is set up and before it prints the "open the portal" finish.

**Architecture:** A new `scripts/install-extensions.sh <id[@version]>…` (same shape as `register-persona.sh` / `register-qdrant.sh`: sources `_target.sh`, idempotent, talks only to the studio API) does the work. It reads the registry catalog once. Per id: if the id is not in the catalog it is skipped. Otherwise it picks the version from the catalog entry, then checks `/admin/extensions/{id}/versions` and skips if that version is already current; if not, it POSTs the install with `pin:false`. `run.sh` owns the list (`DEVKIT_EXTENSIONS`) and calls the script non-fatally after the Qdrant KB step, before the `where to open the portal` section, adding a line to the "Platform ready" banner.

**Tech Stack:** bash (`set -euo pipefail`), curl, python3 stdlib for JSON — same as every other `scripts/*.sh`.

**Spec:** ClickUp [Update DevKit to auto-install the Cloud Deployment Agent](https://app.clickup.com/t/17twvjwz78f) (DUPLOAI-4813), with Sum Yip's comments giving the endpoints below, plus this request: (1) retrieve the catalog and check each extension in a fixed list of ids in `./run.sh` exists, skipping ids that don't; (2) identify the version from that JSON; (3) POST the install with `pin:false`. `/versions` is used to tell whether that version is already installed.

## Global Constraints

- Extension list lives in `run.sh` as `DEVKIT_EXTENSIONS=( … )`; first and only entry for now: `com.duplocloud.demo-cloud-deployment` (the ticket's "Manifest ID").
- Exactly three endpoints (Administrator bearer token; base URL = `BASE_URL` from `scripts/_target.sh`):
  - `GET  /v1/aiservicedesk/admin/extension-registry/catalog` → `{"extensions":[{"id":…,"versions":[{"version":"1.4.2","name":…,"description":…,"changelog":…,"createdAt":…,"updatedAt":…}]}],"marks":[…]}`. Called **once** per script run. **An id that is absent, or present with `versions: []`, doesn't exist ⇒ skip (not an error).**
  - `GET  /v1/aiservicedesk/admin/extensions/{extensionId}/versions` → `[{"version":…,"status":…,"isCurrent":bool,…}]`, the locally stored installed versions. **404 or `[]` ⇒ not installed yet ⇒ install.**
  - `POST /v1/aiservicedesk/admin/extension-registry/install` body exactly `{"extensionId": "<id>", "version": "<ver>", "pin": false}`
- No call to `…/catalog/refresh` (see Open questions).
- Never fatal to `run.sh`: a failed install prints a re-run hint and the platform still comes up (same rule as the agent/LLM/KB steps).
- Idempotent: a re-run of `./run.sh` must not re-POST an install for a version that is already current.
- JSON is built and parsed with `python3` only (no `jq` — not a dev-kit prerequisite).
- Extension ids are validated against `^[A-Za-z0-9._-]+$` before being put in a URL path.

## Review Focus

1. **Unordered / multi-digit versions:** the catalog's `versions` array has no guaranteed order, and `"1.10.0"` sorts below `"1.9.3"` as a string. Expect the semver-highest. → Task 1 test `picks_semver_highest`.
2. **Pre-releases:** a catalog holding `2.0.0-rc.1` next to `1.10.0` must not auto-install the rc. A catalog with *only* pre-releases installs the highest one. → Task 1 tests `stable_beats_prerelease`, `prerelease_only`.
3. **Re-running `./run.sh`:** the second run must report "already installed" and send no install POST. → Task 1 test `current_version_skipped`.
4. **"Doesn't exist" vs "server broken":** an id missing from the catalog skips quietly, and a `/versions` 404 means install. A catalog or `/versions` 500 is an error the user must see, never a silent skip or a blind install. → Task 1 tests `unknown_id_skipped`, `empty_versions_skipped`, `catalog_unreachable`, `versions_http_error`.
5. **Non-JSON error bodies** (nginx 502 HTML, empty body) from install: the HTTP code and the raw text reach the user, with no Python traceback. → Task 1 test `install_non_json_error`.

---

### Task 1: `scripts/install-extensions.sh`

**Files:**
- Create: `scripts/install-extensions.sh` (executable)
- Create: `tests/test-install-extensions.sh` (executable)

**Interfaces:**
- Consumes: `scripts/_target.sh` → `BASE_URL`, `TOKEN`.
- Produces: CLI `./scripts/install-extensions.sh <extension-id>[@<version>] [...]`
  - no args → usage on stderr, exit 2
  - exit 0 ⇒ every id is installed, already current, or skipped as not in the catalog. exit 1 ⇒ at least one id failed (every other id is still processed), or there is no token, or the catalog can't be read.
  - stdout lines (exact prefixes, tests match on them):
    - `    ✔ <id> <ver> — already installed`
    - `    ✔ <id> <ver> — installed`
    - `    ↷ <id> — not in the extension catalog, skipped`
  - stderr lines:
    - `    ✗ could not read the extension catalog: HTTP <code>: <server message or raw body>`
    - `    ✗ <id>@<ver> — version not in the catalog (available: <v1>, <v2>…)`
    - `    ✗ <id> — could not read installed versions: HTTP <code>: <…>`
    - `    ✗ <id> <ver> — install failed: HTTP <code>: <…>`
    - `    ✗ '<arg>' — invalid extension id`

- [ ] **Step 1: Write the test harness and failing tests**

`tests/test-install-extensions.sh` follows `tests/test-deploy-extension.sh`. It uses a temp kit copy (`scripts/install-extensions.sh`, `scripts/_target.sh`), a `.env` with `DUPLO_ADMIN_TOKEN=fixture`, and a stub `curl` first on `PATH`. A `run ARGS…` helper captures `$OUT`/`$RC` with `env -u DUPLO_TARGET -u DUPLO_HOST -u DUPLO_TOKEN -u DUPLO_BASE -u DUPLO_ADMIN_TOKEN -u DUPLO_ENV_FILE`.

Stub `curl` contract. The script must call curl so this works: `-X <METHOD>` is always present, the URL is the one arg starting with `http`, the body comes after `--data`, and `-w '\n%{http_code}'` makes the status the last line.
- Appends `"<METHOD> <URL> <BODY>"` to `$STUB/curl.log`.
- `*/extension-registry/catalog` → `$STUB/catalog.json` with 200. File absent → `oops` with 500.
- `*/admin/extensions/<id>/versions` → `$STUB/versions-<id>.json` with code `$(cat $STUB/versions-<id>.code 2>/dev/null || echo 200)`. File absent → `{"message":"not found"}` with 404.
- `*/extension-registry/install` → `$STUB/install.body` (default `{}`), with code `$STUB/install.code` (default 200).
- Helper `installs()` prints the logged install bodies. Tests compare them parsed with `python3 -c 'json.loads'`.

Tests (name → setup → assertions). `X=com.example.x`, `Y=com.example.y`. Unless stated, the catalog has X with versions `1.2.0, 1.10.0, 1.9.3` (that order) and there is no `versions-X.json` (→ 404, not installed).

| test | setup | assert |
|---|---|---|
| `picks_semver_highest` | default | rc 0; exactly one install body == `{"extensionId":"com.example.x","version":"1.10.0","pin":false}`; stdout `✔ com.example.x 1.10.0 — installed` |
| `pin_is_json_false` | default | raw logged body contains `"pin": false` (boolean, not `"false"`) |
| `call_sequence` | default | log is exactly: `GET …/extension-registry/catalog`, `GET …/admin/extensions/com.example.x/versions`, `POST …/extension-registry/install`; `! grep -q refresh curl.log` |
| `catalog_read_once` | `run X Y`, catalog has X and Y | exactly one `extension-registry/catalog` line in the log |
| `current_version_skipped` | `versions-X.json` = `[{"version":"1.10.0","isCurrent":true}]` | rc 0; no install line; stdout `✔ com.example.x 1.10.0 — already installed` |
| `older_current_upgraded` | `versions-X.json` = `[{"version":"1.9.3","isCurrent":true}]` | install body version `1.10.0` |
| `stable_beats_prerelease` | catalog X `2.0.0-rc.1, 1.10.0` | installs `1.10.0` |
| `prerelease_only` | catalog X `2.0.0-rc.1, 2.0.0-rc.2` | installs `2.0.0-rc.2` |
| `pinned_version_present` | `run X@1.2.0` | installs `1.2.0` |
| `pinned_version_absent` | `run X@9.9.9` | rc 1; stderr `version not in the catalog (available: 1.10.0, 1.9.3, 1.2.0)` (highest first); no `/versions` call, no install |
| `unknown_id_skipped` | `run Y X`, catalog has only X | rc 0; stdout `↷ com.example.y — not in the extension catalog, skipped`; X still installed; no `/versions` call or install body for Y |
| `empty_versions_skipped` | catalog X `versions: []` | rc 0; `↷ com.example.x — not in the extension catalog, skipped`; no install; no `Traceback` |
| `catalog_unreachable` | no catalog.json | rc 1; stderr `could not read the extension catalog: HTTP 500: oops`; log has only the catalog GET |
| `versions_http_error` | `versions-X.code` = 500, `versions-X.json` = `oops` | rc 1; stderr `could not read installed versions: HTTP 500: oops`; no install |
| `install_http_error_message` | install.code 400, install.body `{"message":"license has expired","code":"license_limit_exceeded"}` | rc 1; stderr has `HTTP 400`, `license has expired`, `(license_limit_exceeded)` |
| `install_non_json_error` | install.code 502, install.body `<html>Bad Gateway</html>` | rc 1; stderr has `HTTP 502` and `Bad Gateway`; no `Traceback` |
| `invalid_id_rejected` | `run '../etc'` | rc 1; `invalid extension id`; nothing logged for it |
| `no_args_usage` | `run` | rc 2; stderr starts with `Usage:` |

- [ ] **Step 2: Run tests, verify they fail**

Run: `bash tests/test-install-extensions.sh`
Expected: FAIL on every case (script does not exist).

- [ ] **Step 3: Implement `scripts/install-extensions.sh`**

Header comment in the house style (WHY + idempotency + usage), `set -euo pipefail`, `cd "$(dirname "$0")/.."`, `source scripts/_target.sh`, token check copied from `register-persona.sh`.

- `api METHOD URL [BODY]` → prints response body, then a final line with the HTTP code. Calls `curl -sS --max-time 30 -w '\n%{http_code}' -X "$METHOD" "$URL" -H "Authorization: Bearer $TOKEN" [-H "Content-Type: application/json" --data "$BODY"]`. A curl transport failure (no response at all) prints code `000`. Never `-f`: the error body is what the user needs (see `_studio_api.sh` WHY).
- `err_msg`: a python3 snippet reused for every non-2xx. It returns `message` + `errors` + ` (code)` when the body is JSON, else the stripped raw body, else `<empty body>`. It's the same logic as `studio_create_id` in `scripts/_studio_api.sh`. Copy it rather than sourcing that file, because that file needs `TOK` and only does create-and-return-id.
- Flow:
  1. Validate all args (bad ones → `✗ … invalid extension id`, mark failure, drop).
  2. `GET …/extension-registry/catalog` once. A non-2xx, or a body without an `extensions` list, prints `✗ could not read the extension catalog` and exits 1.
  3. Per id, one python3 call over the catalog JSON (args: id, optional wanted version) prints the chosen version, or an error kind (`missing` / `no-version`) plus the available list for bash to format. `missing` and an empty `versions` print `↷ skipped`.

```python
def key(v):  # semver-ish: numeric core, stable > prerelease, prerelease compared by dot parts
    core, _, pre = v.partition("-")
    nums = tuple(int(p) if p.isdigit() else 0 for p in core.split("."))
    pre_key = tuple((0, int(p)) if p.isdigit() else (1, p) for p in pre.split(".")) if pre else ()
    return (nums, 1 if not pre else 0, pre_key)
# entry = next(e for e in catalog["extensions"] if e.get("id") == id)  → absent ⇒ "missing"
# vs = [v["version"] for v in entry.get("versions") or []]             → empty  ⇒ "missing"
# wanted given → must be in vs exactly; else stable = [v for v in vs if "-" not in v] → max(stable or vs, key=key)
```

  4. `GET …/admin/extensions/<id>/versions`. A 404 or `[]` means not installed. A 2xx with an entry where `isCurrent` is true and `version == chosen` prints `✔ already installed`. Any other non-2xx prints `✗ could not read installed versions` and the install is not attempted.
  5. Otherwise POST the install with a body built by `json.dumps({"extensionId": id, "version": ver, "pin": False})`. A 2xx prints `✔ installed`; anything else prints `✗ install failed`.

- [ ] **Step 4: Run tests, verify they pass**

Run: `bash tests/test-install-extensions.sh`
Expected: every line `ok`, final `PASS=18 FAIL=0` (use the same summary/exit convention as `tests/test-deploy-extension.sh`).

- [ ] **Step 5: Commit**

```bash
git add scripts/install-extensions.sh tests/test-install-extensions.sh
git commit -m "DUPLOAI-4813 - add scripts/install-extensions.sh: install catalog extensions by id[@version]"
```

---

### Task 2: Wire it into `run.sh`

**Files:**
- Modify: `run.sh` — header comment "On completion it has: …" (~line 46-48); new block between the Qdrant KB `esac` (~line 1408) and `# ── where to open the portal` (~line 1410); banner line (~line 1465).
- Modify: `docs/architecture.md` — one sentence after the "Access model" paragraph naming the auto-installed extensions and `scripts/install-extensions.sh`.
- Create: `tests/test-run-install-extensions.sh`

**Interfaces:**
- Consumes: Task 1's CLI and exit codes.
- Produces: `DEVKIT_EXTENSIONS` array and `EXT_LINE` banner fragment in `run.sh`.

- [ ] **Step 1: Write the failing wiring test** (static checks, like `tests/test-run-portal-message.sh`; nothing starts the stack)

| test | assert |
|---|---|
| `syntax` | `bash -n run.sh` |
| `list_defined` | `awk '/^DEVKIT_EXTENSIONS=\(/,/^\)/' run.sh` evals to an array that contains `com.duplocloud.demo-cloud-deployment`, and every entry matches `^[A-Za-z0-9._-]+(@[A-Za-z0-9._+-]+)?$` |
| `call_is_non_fatal` | a line matches `^if ./scripts/install-extensions.sh "\$\{DEVKIT_EXTENSIONS\[@\]\}"; then` |
| `placed_after_kb_before_portal` | line no. of that call > line of `./scripts/register-qdrant.sh "$WS"` and < line of `^portal_url() {` |
| `banner_shows_extensions` | the banner line containing `$KB_LINE` also contains `$EXT_LINE` |
| `portal_message_still_last` | `bash tests/test-run-portal-message.sh` still passes |

- [ ] **Step 2: Run it, verify it fails**

Run: `bash tests/test-run-install-extensions.sh`
Expected: FAIL on `list_defined`, `call_is_non_fatal`, `placed_after_kb_before_portal` and `banner_shows_extensions`.

- [ ] **Step 3: Add the block to `run.sh`**

Section header `# ── install the dev-kit's default extensions (idempotent, never fatal) ──`. Add a comment saying why: the ticket; the list is the one place to add more; entries are `id` (latest stable in the catalog) or `id@version`; ids not in the catalog are skipped; and it is non-fatal for the same reason as the KB step. Then:

- `DEVKIT_EXTENSIONS=(` one id per line with a trailing `# Cloud Deployment Agent` comment `)`
- `EXT_LINE=""`, `echo "==> Installing default extensions…"`
- `if ./scripts/install-extensions.sh "${DEVKIT_EXTENSIONS[@]}"; then EXT_LINE="` newline `  Extension ${DEVKIT_EXTENSIONS[*]} → installed or skipped (see output above)"`, so the label pads to 10 columns like `Persona   `
- `else echo "    (extension install incomplete — re-run ./scripts/install-extensions.sh ${DEVKIT_EXTENSIONS[*]})"; fi`

Append `$EXT_LINE` to the banner line after `$KB_LINE`. Add "installed the default extensions (DEVKIT_EXTENSIONS)" to the header's "On completion it has:" sentence. Add the sentence to `docs/architecture.md`.

- [ ] **Step 4: Run the wiring tests and the existing run.sh tests**

Run: `for f in tests/test-run-*.sh tests/test-install-extensions.sh; do bash "$f" || echo "FAILED: $f"; done`
Expected: no `FAILED:` lines.

- [ ] **Step 5: Commit**

```bash
git add run.sh docs/architecture.md tests/test-run-install-extensions.sh
git commit -m "DUPLOAI-4813 - run.sh: auto-install DEVKIT_EXTENSIONS (Cloud Deployment Agent) before the portal step"
```

- [ ] **Step 6: Live check against the local stack** (needs Docker and a licensed `.env`; not runnable in CI)

1. On a **fresh** stack (`./run.sh --reset`), `GET …/extension-registry/catalog` with the admin token and confirm `com.duplocloud.demo-cloud-deployment` is listed with at least one version. If it isn't, see the first open question before going further.
2. `./scripts/install-extensions.sh com.duplocloud.demo-cloud-deployment` → `✔ … installed`; `/versions` now shows it `isCurrent`.
3. Run it again → `already installed`, with no install POST.
4. `./run.sh` (no flags) → the `==> Installing default extensions…` block prints before `==> Waiting for the portal`, and the banner shows the `Extension` line.

Record the output in the PR description.

---

## Open questions (confirm with the ticket owner before or during Task 2 Step 6)

- **Is the catalog populated on a fresh stack without a refresh?** Sum's comments also list `POST …/extension-registry/catalog/refresh`, which this plan does not call. If step 6.1 shows an empty or stale catalog, add a single non-fatal refresh before the catalog GET, plus a test asserting it comes first and that a refresh failure doesn't stop the run.
- **Is install synchronous?** The plan treats a 2xx from `/install` as done. If it only queues the install, the script should poll `/versions` until `isCurrent` matches.
- **Agent ID `99104691-58dc-4178-8860-f69b5ac5a727`:** the ticket title says "auto-install the Cloud Deployment *Agent*". This plan installs the extension only. If the agent also has to be attached to the `extension-dev` workspace (as `register-agent.sh` does for the default agent), that is a follow-up task.
