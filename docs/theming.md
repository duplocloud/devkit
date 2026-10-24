# Theming: Light / Dark in extensions

The DuploCloud portal has a **Light / Dark / System** switch in the user menu, and deployments can ship their own
brand colours. Extensions render inside the portal, so they follow both — as long as their styles use the
portal's theme tokens instead of fixed colours.

## What you get from devkit

- **The scaffold and samples are theme-aware.** Their styles use the `$g-*` names in
  `src/app/shared/_g-structure.scss` (`$g-surface`, `$g-primary-text`, `$g-border`, …), which map to the
  portal's tokens and change with the mode.
- **ng-common-lib 0.5.2** (vendored in `packages/` and the template's `vendor/`) has the dark-theme versions of
  its components, plus token defaults so an extension built with it still looks as before on a portal that
  predates the dark theme. The portal's own values always take precedence.

## Writing styles

Use the `$g-*` names for every colour: `$g-surface` for backgrounds, `$g-primary-text` for accent text,
`$g-border` for lines. No hex values, no `var(--white)` backgrounds. The full table, the rules for dark-only
overrides and modals, and the editor/chart adapters are in
[reference/21-theming.md](../.claude/skills/duplo-extension-dev/reference/21-theming.md); the `/duplo-extension`
command follows it.

## Migrating an older extension

An extension built before this change shows white panels or white tables in dark mode. The
[`duplo-extension-theme-migration`](../.claude/skills/duplo-extension-theme-migration/SKILL.md) skill walks
through it: vendor ng-common-lib 0.5.2, bring in the `$g-*` names, replace the fixed colours, rebuild, and check
both modes.

## Checking

Build, then open the extension in the portal and switch **user menu → Dark** and back to **Light**: panels follow
the mode, text stays readable, and the portal's tables look the same as on its own pages.
