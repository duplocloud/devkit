# Extension theming (light / dark) — design

## Intent

The DuploCloud portal now switches between **Light / Dark / System** (`<html data-theme="light|dark">`)
and exposes a theme-token contract (`--surface`, `--primary-text`, …) whose values change per mode and per
brand theme. Extensions render inside the portal's own DOM (Native Federation remotes, no iframe, no shadow
DOM), so the tokens and the `data-theme` attribute already reach them — but today's extensions are
light-only: they paint `var(--white)` / hex backgrounds and, worse, bundle a stale `ng-common-lib` (0.3.0 in
the issue reporter, 0.4.0 on devkit `dev`)
whose globally injected datatable styles repaint the portal's tables white in dark mode (see the
duploai-issue-reporter "Reported issues" page).

This change makes devkit produce extensions that follow the portal theme by default, and gives builders of
existing extensions a clear migration path.

## Goals

1. Every extension scaffolded from devkit follows Light/Dark with no extra work by its author.
2. Existing extensions can be migrated by following one skill/guide.
3. Extensions keep rendering as today on portals released **before** the dark theme (no dark tokens
   there), including the tables that the bundled ng-common-lib styles globally.
4. On a dark-capable portal, extensions match the portal in both modes (same tokens, same contrast).

## Non-goals

- Migrating extensions that live in other repos (e.g. duploai-issue-reporter). That follows later, using
  the migration skill this change adds.
- Per-extension brand themes or a theme switcher inside extensions.

## Anti-goals (a failure even if it "works")

- Any change on an older portal: there, every extension must look as it does today. (On a dark-capable
  portal in light mode, a few text spots become slightly darker because they now use the portal's own text
  tokens, e.g. `--warning-text`; that is intended — see decision 6.)
- Fallback values sprinkled through component styles (`var(--surface, #fff)` at each use). Fallbacks are
  defined **once**, in ng-common-lib.
- Token defaults that can win over the portal: anything with specificity above zero, or a global stylesheet
  in the remote. The only defaults allowed are the library's zero-specificity `:where(...)` block below.

## Constraints

- Remotes ship no global CSS; component SCSS only (`styleUrl`), host provides Bootstrap 4 + Vuexy + tokens.
- Token names and semantics come from the portal contract (`duplo-ui/portal/common-lib/scss/_theme-vars.scss`,
  rules in duplo-ui's `.claude/skills/duplo-theme-colors/SKILL.md`): backgrounds `--surface*`, accent text
  `--primary-text`/`--info-text`, status text `--success|warning|danger-text`, grey text `--secondary-text`,
  hairlines `--border-color`, never `--white`/`--light` as a background, never a fill colour (`--primary`,
  `--secondary`) as text. Dark-only literals use `:host-context(html[data-theme='dark'])`; content appended to
  `<body>` (NgbModal from a template, `container="body"` dropdowns) uses `::ng-deep html[data-theme='dark'] …`.
- Monaco / CodeMirror / ECharts / xterm follow the theme only through ng-common-lib's exported adapters
  (`withMonacoTheme`, `CodeMirrorThemeService`, `EchartsThemeService`, `xtermTheme`).
- Everything (docs, plans, skills) lives in devkit. One PR against `dev`.

## Decisions (made with the requester)

1. **Library:** vendor `@duplocloud-internal/ng-common-lib` **0.5.1** in place of 0.4.0 (devkit `dev`
   today), via `scripts/refresh-common-lib.sh`, then `npm install` per frontend to refresh lockfiles.
   **Prerequisite (separate duplo-ui PR, approach "A′ central defaults"):** 0.5.0 uses the 20 tokens the
   dark theme added (`--backdrop --border-raised --code-surface --danger-text --dark-text --hover-bg
   --info-text --input-bg --input-disabled-bg --on-primary --primary-text --secondary-text --shadow-raised
   --shadow-selected --sidebar-text --success-text --surface --surface-raised --surface-subtle
   --warning-text`) about 113 times in ~40 files without a fallback; portals before the dark theme
   (release/0.2.24) define none of them, so library components inside extensions — and the globally styled
   datatables, which also restyle the host's tables — would lose backgrounds and text colours there.
   0.5.1 adds **one central defaults file**: when the library module loads it appends a single
   `<style id="duplo-theme-defaults">` to `<head>` (once, never removed) with
   `:where(:root) { …20 light defaults… }` and `:where(:root[data-theme='dark']) { …20 dark defaults… }`.
   `:where()` has zero specificity, so any portal that defines the tokens (`:root`, `:root[data-theme=dark]`,
   theme bundles) always wins regardless of load order; on older portals the defaults fill the gap, and on a
   partially updated portal a missing token gets a sensible value for the active mode. Because it is tied to
   the library loading (not to a route), it covers routed pages, exposed widgets (e.g. the navbar issue
   reporter) and modals that outlive a route. Light defaults equal the portal's light mixin, which equals
   what 0.4.0 rendered (the dark theme kept light pixel-identical). Every extension bundles its own copy
   (not shared via federation), so one extension build meets portals of different ages.
2. **Token names in devkit:** extend the existing `$g-*` partial (`shared/_g-structure.scss`) with the theme
   tokens as plain `var(--token)` (no per-token fallback; the library supplies the defaults). Component
   styles use only `$g-*` names. The light-only `$g-white` card background becomes `$g-surface`. Existing
   `$g-*` entries keep their current fallbacks.
3. **Where guidance lives (follows devkit's own pattern):**
   - New extensions: `.claude/skills/duplo-extension-dev/reference/21-theming.md`, linked from the
     authoring guide (`02`), the UI-library reference (`20`) and the skill's index.
   - Existing extensions: a separate skill `.claude/skills/duplo-extension-theme-migration/` mirroring
     `duplo-extension-ng22-migration` (bump lib → add/refresh `$g-*` partial → find light-only colours →
     map → rebuild → verify both modes).
   - People: `docs/theming.md` (linked from `docs/README.md`), and a 0.5.1 section in
     `docs/UPGRADING-ng-common-lib.md` (which today says the host emits `--white` and nothing about dark).
4. **Scope of code changes:** the helloworld template and all six samples (`helloworld`, `network-stack`,
   `parent-child`, `passthrough-configmap`, `worker-appstack`, `worker-compute`).
5. Docs and plans live under `docs/superpowers/` in devkit.
6. **Light rule = match the portal.** Map to the portal's tokens in both modes (`color: $g-warning` text →
   `$g-warning-text`, console ground → `$g-code-surface`, card shadow → `$g-shadow-raised`), not to
   light-only dark overrides. Older portals keep today's look through the fallbacks.

## What changes, concretely

- **Library (duplo-ui, `common-lib`):** new `services/theme/theme-defaults.ts` (the defaults CSS and an
  idempotent `ensureThemeDefaults()` called at module load), exported from `public-api.ts`; a spec; a node
  test that fails if the defaults drift from `_theme-vars.scss`; version 0.5.1. `package.json` has
  `"sideEffects": false`, so the build must prove the module-load call survives in an extension bundle; if
  not, list the file under `sideEffects`.
- **Token partial** (template + each sample's identical `shared/_g-structure.scss`): add `$g-surface`,
  `$g-surface-raised`, `$g-surface-subtle`, `$g-input-bg`, `$g-primary-text`, `$g-info-text`,
  `$g-success-text`, `$g-warning-text`, `$g-danger-text`, `$g-secondary-text`, `$g-on-primary`,
  `$g-border-raised`, `$g-shadow-raised`, `$g-code-surface` (exact set is the builder's call). Keep existing
  names that are still valid (`$g-border`, `$g-headings`, …).
- **Misuses to fix** in template/samples: `$g-white` backgrounds → `$g-surface`; `$g-primary` / `$g-warning`
  used as **text** → `$g-primary-text` / `$g-warning-text`; `$g-white` text on a fill → `$g-on-primary`.
- **Inline component styles** (`styles: [...]` in `.ts`, e.g. network-stack `wizard-stepper`, `logs-panel`)
  hold raw hex and can't `@use` Sass: move them to a `.scss` file using `$g-*`, or (builder's call) keep them
  inline with `var(--token, fallback)` as the documented exception. A console/terminal ground uses
  `$g-code-surface`.
- **Guidance content:** token table (name → meaning → light fallback), do/don't rules, dark overrides,
  body-appended content, editors/charts adapters, the "rebuild against the portal's current ng-common-lib"
  rule (stale bundled copies of `ViewEncapsulation.None` components override the host), a grep recipe to
  find light-only colours, and a manual check list (toggle in the user menu, both modes).

## Success

- `npm run build` passes for the template and every sample with 0.5.1, and each built bundle contains the
  `duplo-theme-defaults` injection.
- On a page with no portal tokens, the defaults supply all 20 light values; with `data-theme="dark"` the 20
  dark values; with the portal's own `:root` tokens present, the portal's values win.
- No `var(--white)` / `var(--light)` background and no raw hex left in template/sample component styles
  (except documented exceptions: third-party brand colours, JS-consumed colours).
- Library components look as in 0.4.0 on an older portal; a sample extension loaded in a dark-theme
  portal shows dark surfaces and readable text.

## Left to the builder

- Exact `$g-*` additions and naming beyond those listed; wording and structure of the docs and skills.
- Whether network-stack's inline styles move to `.scss` or keep the `var()` exception.
- How to verify in a portal (local AI Studio with a sample hot-loaded, or build-only plus code review).

## Calls I made (requester to confirm while reading)

- Dark defaults follow the brand where the portal derives them from it: `dark-ramp-step(x, -45%)` (45% white
  into x) is written `color-mix(in srgb, var(--x) 55%, #fff)` for `--primary-text`, `--info-text`,
  `--sidebar-text` and the status texts, `--secondary-text` uses 70%; the rest are the stock dark literals.
- Three sample spots whose current light value differs from the portal's light token (network-stack console
  `#161d31` vs `--code-surface`, wizard card shadow vs `--shadow-raised`, warning text vs `--warning-text`)
  follow the portal token everywhere, including older portals (small, intentional change). With central
  defaults the token is always defined, so "today's literal on old portals, token on new" cannot be
  expressed without per-use code.
- The migration skill is new and separate rather than a section of `duplo-extension-dev`.
