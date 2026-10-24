# 21 — Theming: Light / Dark and brand themes

The portal switches between **Light / Dark / System** from the user menu and recolours per deployment (brand
themes). An extension follows both automatically **if every colour it paints comes from a theme token**.

## How the theme reaches a remote

- The remote renders in the portal's own DOM (no iframe, no shadow DOM), so the portal's tokens on `:root` and
  `<html data-theme="light|dark">` already apply to its elements. The remote ships no global stylesheet of its
  own; only ng-common-lib injects a few global styles (below).
- Tokens change value per mode: `--surface` is white in light and near-black in dark. Paint with tokens and the
  extension switches with the portal; paint with a literal and it doesn't.
- **ng-common-lib ≥ 0.5.1** injects zero-specificity defaults for the tokens the dark theme added
  (`:where(:root)` light, `:where(:root[data-theme='dark'])` dark). A portal that defines a token always wins;
  on a portal that predates the dark theme the defaults fill the gap, so the extension still looks as before.
  They load with the library, so the library must be imported in code that loads with the extension's pages (the
  scaffold does). On 0.5.1 that import must use an export: a bare `import '@duplocloud-internal/ng-common-lib'`
  is tree-shaken away. 0.5.2 keeps it.
- Every extension bundles its **own** copy of ng-common-lib, and some of its components inject global CSS.
  **Rebuild against the portal's current ng-common-lib**: a stale bundled copy repaints the portal's own tables
  in old (light-only) colours while the extension's page is open.

## Use the `$g-*` names

Component styles `@use` the scaffold's `shared/_g-structure.scss` and use only its names — never a raw `var()`
with a fallback, never a hex value.

| Need | Use | Token |
|---|---|---|
| Card / page background | `$g-surface` | `--surface` |
| Menu, popover, modal background | `$g-surface-raised` | `--surface-raised` |
| Pale panel | `$g-surface-subtle` | `--surface-subtle` |
| Input background | `$g-input-bg` | `--input-bg` |
| Body / heading / muted text | `$g-body` / `$g-headings` / `$g-muted` | `--body-color` / `--headings-color` / `--text-muted` |
| Grey secondary text | `$g-secondary-text` | `--secondary-text` |
| Accent text (links, active labels, icons) | `$g-primary-text` / `$g-info-text` | `--primary-text` / `--info-text` |
| Status text and icons | `$g-success-text` / `$g-warning-text` / `$g-danger-text` | `--success-text` / … |
| Accent / status **fills and borders** | `$g-primary` / `$g-success` / `$g-warning` / `$g-danger` / `$g-secondary` | `--primary` / … |
| Text on an accent fill | `$g-on-primary` | `--on-primary` |
| Hairline divider / outline | `$g-border` | `--border-color` |
| Popover edge / elevation | `$g-border-raised` / `$g-shadow-raised` | `--border-raised` / `--shadow-raised` |
| Terminal / console ground | `$g-code-surface` | `--code-surface` |
| Tinted surface or hover | `color-mix(in srgb, $g-primary 8%, transparent)` | — |

Inline `styles: [...]` in a `.ts` file can't `@use` Sass: write the token directly, `var(--surface)`.

## Rules

- **Backgrounds** use `$g-surface*` — never `var(--white)` / `#fff`, which stay white in dark.
- **Text** uses a text token. A fill colour (`$g-primary`, `$g-warning`, `$g-secondary`) is for fills and
  borders; as text it is 2–3.5:1 in dark.
- **No hex, `rgb()` or Vuexy literals** (`#7367f0`, `#ebe9f1`, …) in component styles. Black/white with alpha is
  fine for shadows and overlays (`rgba(0, 0, 0, .08)`), not for hairline borders — those vanish in dark.
- **Never define tokens** (`:root { --surface: … }`) in an extension: it would beat the portal's values.
- **A colour no token covers** keeps its light value and gets a dark override:
  `:host-context(html[data-theme='dark']) .x { color: $g-body; }`.
- **Content appended to `<body>`** (an `NgbModal` opened from an `ng-template`, a `container="body"` dropdown
  styled through `::ng-deep`) is outside the host element: `::ng-deep html[data-theme='dark'] .x { … }`.

## Editors and charts

They paint through JavaScript, so tokens alone don't reach them. Use ng-common-lib's adapters
([20-ui-library](20-ui-library.md)):

- Monaco: `editorOptions = withMonacoTheme({ language: 'yaml' })` — never a fixed `theme: 'vs-dark'`.
- CodeMirror: `CodeMirrorThemeService`; ECharts: `EchartsThemeService`; xterm: `xtermTheme(mode, theme)`.

## Check it

1. `npm run build`, then `grep -rl duplo-theme-defaults dist` — at least one file (the library defaults shipped).
2. Load the extension in the portal and switch **user menu → Dark**, then **Light**: no white panels, no
   unreadable text, tables match the portal's.

Existing extension still light-only? Use the `duplo-extension-theme-migration` skill.
