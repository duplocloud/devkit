---
name: duplo-extension-theme-migration
description: Migrate an existing DuploCloud platform extension's frontend to the portal's Light/Dark theme tokens. Use when an extension shows white panels, unreadable text or white tables in the portal's dark mode, when its frontend vendors @duplocloud-internal/ng-common-lib below 0.5.1, when its styles use var(--white), hex colours or $g-white, or when asked to make an extension support dark mode / theme variables / ng-common-lib 0.5.
---

# Migrate an extension to the portal's theme tokens

The portal switches **Light / Dark / System** by setting `<html data-theme>` and changing the values of its
theme tokens. An extension renders in the portal's DOM, so it follows the switch for free — **except** where it
paints a literal colour (hex, `var(--white)`, `$g-white`), or bundles an older ng-common-lib. Below 0.5.0 the
library is light-only, and its globally injected datatable styles repaint the portal's tables white while the
extension's page is open. 0.5.0 follows dark mode but lacks the token defaults, so on a portal without the dark
theme its components lose their backgrounds.

The rules for writing theme-aware styles are in
[duplo-extension-dev/reference/21-theming.md](../duplo-extension-dev/reference/21-theming.md). This skill is the
upgrade path for an extension that predates them. Work in the extension's `frontend/`.

## 1. Vendor ng-common-lib ≥ 0.5.1

0.5.1 carries the dark-theme components **and** zero-specificity token defaults, so the migrated extension also
keeps its look on portals that predate the dark theme.

- Get the tarball: `npm pack @duplocloud-internal/ng-common-lib@0.5.2` (GitHub Packages; needs a token with
  `read:packages` in `~/.npmrc`), or copy it from this repo's `packages/`.
- Inside devkit, `scripts/refresh-common-lib.sh <tgz>` does the next two steps for every frontend.
- Move it into `frontend/vendor/`, delete the old `duplocloud-internal-ng-common-lib-*.tgz` there, and point the
  dependency at it: `"@duplocloud-internal/ng-common-lib": "file:vendor/duplocloud-internal-ng-common-lib-0.5.2.tgz"`.
- `npm install` to refresh the lockfile.

## 2. Bring in the `$g-*` theme names

Copy the template's `src/app/shared/_g-structure.scss` over the extension's copy (or add the "Theme tokens" block
and remove `$g-white` if the extension changed the file). Components keep `@use`-ing it.

## 3. Find the light-only colours

```bash
grep -rnoE '\$g-white|background[a-z-]*: *(var\(--(white|light)\)|white\b)|rgba?\([^)]*\)|(^|[^-])color: *(\$g-|var\(--)(primary|info|warning|danger|success|secondary|dark)([;) }]|$)|#[0-9a-fA-F]{3,8}\b' \
  src --include='*.scss' --include='*.ts' --include='*.html' \
  | grep -v _g-structure.scss | grep -vE ':rgba?\( *(0, *0, *0|255, *255, *255) *,'
```

It prints each match, not each line, so one line can appear several times. The last filter drops black/white
with alpha (shadows, overlays), which may stay. Everything else it lists — hex, `rgb()`/`rgba()` of a colour,
white/light backgrounds, fill colours used as text — needs a token.

## 4. Map each hit

| Found | Replace with |
|---|---|
| `background: $g-white` / `#fff` / `var(--white)` | `$g-surface` (menus/modals `$g-surface-raised`; inline TS `var(--surface)`) |
| `color: $g-primary` (text, icon) | `$g-primary-text` |
| `color: $g-warning` / `$g-danger` / `$g-success` (text, icon) | `$g-warning-text` / `$g-danger-text` / `$g-success-text` |
| `color: $g-secondary` (text) | `$g-secondary-text` |
| `color: $g-white` / `#fff` on an accent fill | `$g-on-primary` |
| `#ebe9f1` (line) / `#d8d6de` (control edge) | `$g-border` / `var(--control-border)` |
| `#b9b9c3` / `#6e6b7b` / `#5e5873` (text) | `$g-muted` / `$g-body` / `$g-headings` |
| `#7367f0` / `#28c76f` / `#ff9f43` / `#ea5455` fill | `$g-primary` / `$g-success` / `$g-warning` / `$g-danger` |
| Console / terminal ground (`#161d31`, …) | `$g-code-surface`, text `color-mix(in srgb, var(--white) 85%, transparent)` |
| Card shadow `0 4px 24px rgba(…)` | `$g-shadow-raised` |
| `rgba(<accent>, .08)` tint | `color-mix(in srgb, $g-primary 8%, transparent)` |

Keep fills and borders on the fill names (`border-color: $g-success` stays). A colour no token covers keeps its
light value plus `:host-context(html[data-theme='dark']) .x { … }`; body-appended modals and dropdowns use
`::ng-deep html[data-theme='dark'] .x { … }`. Monaco options go through `withMonacoTheme(...)`, never a fixed
`theme: 'vs-dark'`.

Re-run the step 3 grep until it is empty (third-party brand colours excepted).

## 5. Build and check the defaults shipped

```bash
npm run build && grep -rl duplo-theme-defaults dist
```

At least one file must match: that is ng-common-lib's token-defaults block, which keeps the extension looking as
before on older portals. Then, from the repository root, run `node scripts/verify-remote-federation.js
extensions/<name>` as usual.

## 6. Verify in the portal

Hot-load the extension and switch **user menu → Dark**, then **Light**: no white panels, readable text, and the
portal's own tables unchanged while the extension's page is open. On a portal without the dark theme, the
extension should look exactly as it did before the migration.
