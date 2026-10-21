# Extension Theming (Light / Dark) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extensions built from devkit follow the portal's Light/Dark theme, stay unchanged on pre-dark-theme portals, and existing extensions get a migration path.

**Architecture:** ng-common-lib 0.5.1 ships one central, zero-specificity defaults block (`:where(:root)` light + `:where(:root[data-theme='dark'])` dark) injected once when the library loads, so the 20 tokens the dark theme added always resolve; portals that define them win. devkit vendors 0.5.1, names the tokens once in the `$g-*` partial, fixes the template and six samples, and documents building and migrating.

**Tech Stack:** Angular 22 Native Federation remotes, SCSS, ng-common-lib (duplo-ui `portal/common-lib`), Karma/Jasmine, `node --test`, Sass.

**Spec:** `docs/superpowers/specs/2026-10-19-extension-theming-design.md`

## Global Constraints

- The 20 tokens: `--backdrop --border-raised --code-surface --danger-text --dark-text --hover-bg --info-text --input-bg --input-disabled-bg --on-primary --primary-text --secondary-text --shadow-raised --shadow-selected --sidebar-text --success-text --surface --surface-raised --surface-subtle --warning-text`.
- Defaults selectors are exactly `:where(:root)` and `:where(:root[data-theme='dark'])` (zero specificity); nothing else in the remote may define tokens.
- Light defaults equal the portal light mixin (`duplo-ui/portal/common-lib/scss/_theme-vars.scss` `duplo-theme-css-vars`); dark defaults equal the dark mixin, with `dark-ramp-step(x, -N%)` written `color-mix(in srgb, var(--x) (100-N)%, #fff)`.
- Library version 0.5.1 (0.4.0 and 0.5.0 are already published; a version is never reused).
- devkit PR targets `dev`; branch `feature/extension-theming` (exists, off `origin/dev`). duplo-ui PR targets `master`; branch `chore/ng-common-lib-theme-defaults`.
- No commits or pushes until the requester reviews the staged changes; publishing 0.5.1 is triggered only on the requester's go-ahead.
- Code comments: one or two lines. No full portal build while a dev server runs; use targeted specs/tests.

## Review Focus

1. **The bundler drops the module-load call** (`common-lib/package.json` has `"sideEffects": false`) → defaults missing in an extension. Pinned by Task 4 Step 4 (built sample bundle must contain `duplo-theme-defaults`).
2. **Portal tokens defined before or after the defaults block** must win either way. Pinned by Task 1 spec `portal :root wins regardless of order`.
3. **Two copies inject** (host + remote, or two remotes on one page) → exactly one `<style id="duplo-theme-defaults">`. Pinned by Task 1 spec `is idempotent`.
4. **Partially updated portal** (`data-theme="dark"` but a token missing) → the dark default applies, not the light one. Pinned by Task 1 spec `dark defaults under data-theme dark`.
5. **Defaults drift** from `_theme-vars.scss` when the portal adds or changes a token. Pinned by Task 2 drift test.

---

## Part 1 — duplo-ui: ng-common-lib 0.5.1 (repo `duplo-ui/portal`, branch `chore/ng-common-lib-theme-defaults` off `origin/master`)

### Task 1: Central theme defaults in ng-common-lib

**Files:**
- Create: `common-lib/services/theme/theme-defaults.ts`
- Create: `common-lib/services/theme/theme-defaults.spec.ts`
- Modify: `common-lib/public-api.ts` (next to the other `services/theme/*` exports, ~line 209)

**Interfaces:**
- Produces: `export const THEME_DEFAULTS_STYLE_ID = 'duplo-theme-defaults'`, `export const THEME_DEFAULTS_CSS: string`, `export function ensureThemeDefaults(doc: Document): void` (appends one `<style id=THEME_DEFAULTS_STYLE_ID>` to `doc.head` if absent; never removes). Module bottom: `if (typeof document !== 'undefined') { ensureThemeDefaults(document); }`.

- [ ] **Step 1: Write the failing spec** (`theme-defaults.spec.ts`). Each test renders into a fresh `<iframe>` so the host's global tokens don't interfere; read values with `getComputedStyle(frameDoc.documentElement).getPropertyValue('--x').trim()`.
  - `fills light defaults`: after `ensureThemeDefaults(frameDoc)` → `--surface` = `#fff`, `--input-disabled-bg` = `#efefef`, `--surface-subtle` = `#f6f6f6`, `--shadow-selected` = `1px 1px 5px 0 #afbbe3`.
  - `dark defaults under data-theme dark`: set `data-theme="dark"` → `--surface` = `#171719`, `--surface-raised` = `#232327`, `--input-disabled-bg` = `#212124`, `--border-raised` = `#4a4a53`.
  - `portal :root wins regardless of order`: append `<style>:root{--surface:#123456}</style>` before, then (in a second frame) after `ensureThemeDefaults` → `--surface` = `#123456` both times; with `data-theme="dark"` and `:root[data-theme='dark']{--surface:#0a0b0c}` → `#0a0b0c`.
  - `is idempotent`: call twice → `frameDoc.querySelectorAll('#duplo-theme-defaults').length` = 1.
  - `covers all 20 tokens in light; 18 in dark`: parse `THEME_DEFAULTS_CSS` into the two blocks; light names = the 20; dark names = the 20 minus `--hover-bg`, `--on-primary` (the dark mixin does not redefine those two).

- [ ] **Step 2: Run it to verify it fails**
  Run: `npx ng test duplo-portal --include='../common-lib/services/theme/theme-defaults.spec.ts' --watch=false` (no dev server running)
  Expected: FAIL — cannot resolve `./theme-defaults`.

- [ ] **Step 3: Implement `theme-defaults.ts`** with these exact values.
  Light block `:where(:root)`: `--backdrop: rgba(34, 41, 47, 0.5); --border-raised: rgba(34, 41, 47, 0.05); --code-surface: var(--primary-900); --danger-text: var(--danger-darken-10); --dark-text: var(--dark); --hover-bg: color-mix(in srgb, var(--headings-color) 4%, transparent); --info-text: var(--info); --input-bg: #fff; --input-disabled-bg: #efefef; --on-primary: var(--white); --primary-text: var(--primary); --secondary-text: var(--secondary); --shadow-raised: 0 5px 25px rgba(34, 41, 47, 0.1); --shadow-selected: 1px 1px 5px 0 #afbbe3; --sidebar-text: var(--sidebar); --success-text: var(--success-darken-10); --surface: #fff; --surface-raised: #fff; --surface-subtle: #f6f6f6; --warning-text: var(--warning-darken-15);`
  Dark block `:where(:root[data-theme='dark'])`: `--backdrop: rgba(0, 0, 0, 1); --border-raised: #4a4a53; --code-surface: color-mix(in srgb, var(--primary) 14%, var(--surface)); --danger-text: color-mix(in srgb, var(--danger) 55%, #fff); --dark-text: var(--body-color); --info-text: color-mix(in srgb, var(--info) 55%, #fff); --input-bg: #171719; --input-disabled-bg: #212124; --primary-text: color-mix(in srgb, var(--primary) 55%, #fff); --secondary-text: color-mix(in srgb, var(--secondary) 70%, #fff); --shadow-raised: 0 8px 24px rgba(0, 0, 0, 0.7), 0 0 0 1px rgba(255, 255, 255, 0.08); --shadow-selected: 0 0 4px 0 rgba(175, 187, 227, 0.35); --sidebar-text: color-mix(in srgb, var(--sidebar) 55%, #fff); --success-text: color-mix(in srgb, var(--success) 55%, #fff); --surface: #171719; --surface-raised: #232327; --surface-subtle: var(--neutral-50); --warning-text: color-mix(in srgb, var(--warning) 55%, #fff);`
  Add the `public-api.ts` export. One-line comment on the file: why `:where()` (portal always wins).

- [ ] **Step 4: Run the spec** — same command. Expected: PASS (5 tests). Also run the existing theme specs: `npx ng test duplo-portal --include='../common-lib/services/theme/**/*.spec.ts' --watch=false` → all pass.

- [ ] **Step 5: Stage for review** — `git add` the three files; do not commit.

### Task 2: Drift test against `_theme-vars.scss`

**Files:**
- Create: `scripts/theme-defaults/theme-defaults.test.mjs`
- Modify: `package.json` (add `"theme:defaults:test": "node --test scripts/theme-defaults/theme-defaults.test.mjs"`)

**Interfaces:**
- Consumes: `THEME_DEFAULTS_CSS` text from Task 1 (read the `.ts` file and extract the two blocks with a regex — no TS import); `compileThemeCss` and `parseColour` from `scripts/generate-theme/generate-theme.mjs`.

- [ ] **Step 1: Write the test** `defaults match the stock theme`: compile `compileThemeCss("@import '../styles';\n")`, take the stock `:root` and `:root[data-theme=dark]` blocks; assert (a) every one of the 20 tokens the stock light block defines is in the light defaults and vice versa; same for dark (18); (b) for tokens whose stock value is a literal colour/shadow (`--surface`, `--surface-raised`, `--input-bg`, `--input-disabled-bg`, `--surface-subtle`, `--backdrop`, `--border-raised`, `--shadow-raised`, `--shadow-selected` in both modes) the default equals the stock value after `parseColour`/whitespace normalisation; (c) for `var(...)`-valued light tokens the text is identical.
- [ ] **Step 2: Run** `npm run -s theme:defaults:test` → PASS. Then temporarily change one default in a scratch copy (or assert the test reads the live file) to confirm it fails on drift → FAIL; revert.
- [ ] **Step 3: Stage for review.**

### Task 3: Version 0.5.1, PR, publish

**Files:** Modify `common-lib/package.json` (`"version": "0.5.1"`).

- [ ] **Step 1:** Bump the version.
- [ ] **Step 2:** `npm run pack:common-lib` → `duplocloud-internal-ng-common-lib-0.5.1.tgz`; `tar -xzf … && grep -c duplo-theme-defaults package/fesm2022/*.mjs` → ≥ 1.
- [ ] **Step 3:** Requester reviews; then commit, push, `gh pr create --base master` (no AI attribution).
- [ ] **Step 4:** On the requester's go-ahead: `gh workflow run publish-ng-common-lib.yml --ref chore/ng-common-lib-theme-defaults`; wait for success. Download with `npm pack @duplocloud-internal/ng-common-lib@0.5.1` (requester's `~/.npmrc` token) into `~/Downloads`.

---

## Part 2 — devkit (branch `feature/extension-theming`, PR against `dev`)

### Task 4: Vendor 0.5.1 and prove the defaults ship

**Files:** `packages/duplocloud-internal-ng-common-lib-0.5.1.tgz`, `.claude/skills/duplo-extension-dev/templates/helloworld/frontend/vendor/…-0.5.1.tgz` (old 0.4.0 removed); `package.json` + `package-lock.json` in the template frontend and the 6 `samples/*/frontend`.

- [ ] **Step 1:** `./scripts/refresh-common-lib.sh ~/Downloads/duplocloud-internal-ng-common-lib-0.5.1.tgz` → "Refreshed 7 frontend(s)".
- [ ] **Step 2:** `npm install` in each of the 7 frontends (lockfiles refresh).
- [ ] **Step 3:** `npm run build` in each → all succeed.
- [ ] **Step 4:** In each built output, `grep -rl duplo-theme-defaults dist` → at least one file. If none: the bundler dropped the call — stop, go back to Part 1 and add the library file to `common-lib/package.json` `"sideEffects"`, republish 0.5.2.
- [ ] **Step 5:** Stage for review.

### Task 5: `$g-*` tokens and template/sample style fixes

**Files:**
- Modify (template, then copy byte-identical to the 6 samples): `src/app/shared/_g-structure.scss`, `src/app/shared/detail-page.scss`, `src/app/shared/lifecycle-rail.component.scss`.
- Modify inline styles: template `add/add-hello.component.ts:22`; samples' `add/*.component.ts` (helloworld `add-hello`, passthrough-configmap `add-configmap`, worker-appstack `add-appstack`, worker-compute `add-calculator`, parent-child `parents/add-parent` + `children/add-child`); network-stack `wizard/wizard-stepper.component.ts:32-50`, `shared/logs-panel.component.ts:18-22`.

**Interfaces:**
- Produces in `_g-structure.scss` (plain `var()`, no fallback): `$g-surface`, `$g-surface-raised`, `$g-surface-subtle`, `$g-input-bg`, `$g-primary-text`, `$g-info-text`, `$g-success-text`, `$g-warning-text`, `$g-danger-text`, `$g-secondary-text`, `$g-on-primary`, `$g-border-raised`, `$g-shadow-raised`, `$g-code-surface`. Remove `$g-white`. Update the partial's header comment (defaults come from ng-common-lib 0.5.1).

- [ ] **Step 1: Write the check** (a repo script is overkill; use this grep as the test): `grep -rnE '\$g-white|var\(--white|color: *\$g-(primary|warning|danger|success|secondary)\b|#[0-9a-fA-F]{3,8}\b' <template-src> samples/*/frontend/src --include='*.scss' --include='*.ts' | grep -v _g-structure.scss` → today: non-empty.
- [ ] **Step 2: Apply the mapping** — backgrounds `$g-white`/`#fff` → `$g-surface` (inline TS: `var(--surface)`); `color: $g-primary` → `$g-primary-text`; `color: $g-warning` → `$g-warning-text`; `color: $g-white` on a fill → `$g-on-primary`; network-stack wizard/logs hex → tokens (`#fff` → `var(--surface)`, `#ebe9f1` → `var(--border-color)`, `#d8d6de` → `var(--control-border)`, `#b9b9c3` → `var(--text-muted)`, `#6e6b7b` → `var(--body-color)`, `#7367f0` fill → `var(--primary)` / as text `var(--primary-text)`, `#28c76f` fill → `var(--success)`, card shadow → `var(--shadow-raised)`, console `#161d31` → `var(--code-surface)`, console text `#d0d2d6` → `var(--body-color)` only if it reads on `--code-surface` in light, else keep and add a dark rule). Borders/dots keep fills (`$g-primary`, `$g-success`, …).
- [ ] **Step 3: Re-run the check** → empty, except third-party brand colours (none expected).
- [ ] **Step 4:** `diff` the three shared files of each sample against the template → identical. `npm run build` in all 7 → pass.
- [ ] **Step 5:** Stage for review.

### Task 6: Guidance for new extensions — `reference/21-theming.md`

**Files:** Create `.claude/skills/duplo-extension-dev/reference/21-theming.md`; modify `.claude/skills/duplo-extension-dev/SKILL.md` (reference index), `reference/02-authoring-guide.md` (styling section, ~lines 213 and 367), `reference/20-ui-library.md` (theme adapters), `.claude/commands/duplo-extension.md` (mention theming).

- [ ] **Step 1:** Write `21-theming.md`: how theming reaches a remote (same DOM, `data-theme`, host tokens, library defaults); `$g-*` table (name → token → use); rules (backgrounds `$g-surface*`, accent text `$g-primary-text`, status text `$g-*-text`, grey text `$g-secondary-text`, fills only for fills/borders, no hex, no `var(--white)` background, no `:root` definitions); dark-only literals via `:host-context(html[data-theme='dark'])`; body-appended content via `::ng-deep html[data-theme='dark'] …`; editors/charts via `withMonacoTheme`, `CodeMirrorThemeService`, `EchartsThemeService`, `xtermTheme`; "rebuild against the current ng-common-lib" (stale `ViewEncapsulation.None` copies override the host); manual check (user menu → Dark/Light).
- [ ] **Step 2:** Add the links in the four files.
- [ ] **Step 3:** Check every relative link resolves: `grep -o '](\.\{0,2\}/[^)]*)' <files>` and test each path exists.
- [ ] **Step 4:** Stage for review.

### Task 7: Migration skill — `duplo-extension-theme-migration`

**Files:** Create `.claude/skills/duplo-extension-theme-migration/SKILL.md` (frontmatter `name`, `description` triggering on "migrate extension to dark mode / theme variables / ng-common-lib 0.5"), modelled on `duplo-extension-ng22-migration/SKILL.md`.

- [ ] **Step 1:** Steps: (1) vendor ng-common-lib ≥ 0.5.1 (refresh script or manual `file:` swap) and `npm install`; (2) copy the template `_g-structure.scss`; (3) find light-only colours with the Task 5 grep; (4) mapping table (old → new, as in Task 5 Step 2); (5) inline TS styles → `var(--token)`; (6) `npm run build`, confirm `duplo-theme-defaults` in `dist`; (7) verify in a portal in Light and Dark, and on an older portal if available.
- [ ] **Step 2:** Link it from `docs/README.md` "Writing extensions" and from `21-theming.md`.
- [ ] **Step 3:** Stage for review.

### Task 8: Human docs and PR

**Files:** Create `docs/theming.md`; modify `docs/README.md` (index row), `docs/UPGRADING-ng-common-lib.md` (0.5.1 section: what changed, defaults block, `$g-*` names, link to the migration skill; correct the "host emits `--white`" text).

- [ ] **Step 1:** Write `docs/theming.md` (short: what the user sees, how extensions follow it, links to `21-theming.md` and the migration skill).
- [ ] **Step 2:** Update the two docs; check links as in Task 6 Step 3.
- [ ] **Step 3:** Final check: `git status`, all 7 builds green (Task 4/5), grep check empty (Task 5).
- [ ] **Step 4:** Requester reviews the full diff; then commit (one commit per task), push, `gh pr create --base dev` (no AI attribution), including the spec and this plan.
