# Upgrading an extension's UI library: the vendored `@duplocloud-internal/ng-common-lib` tarball

For extensions built from this dev-kit (or from the `duplo-extension-dev` skill template) that vendor the UI
library as a tarball. The current line is 0.4.1 (Angular 22); the notes below contrast it with the 0.1.x line.
0.4.1 adds the `REMOTE_ExtensionAnalytics` host token (with the `ExtensionAnalytics` / `ExtensionTracker` types) that
an extension's `analytics.ts` imports — an extension that tracks page views and actions needs 0.4.1 or later
([`reference/21-analytics.md`](../.claude/skills/duplo-extension-dev/reference/21-analytics.md)).

> **This is not a drop-in upgrade.** 0.2.0 is compiled against **Angular 22** and ships as ESM
> (`fesm2022`, `"type": "module"`); its peer range is `@angular/core@^22.1.0`. It is meant to be consumed by
> a **Native Federation** remote that emits `remoteEntry.json`. An extension still on Angular-15 + Webpack
> Module Federation cannot use it by swapping the tarball — the install will not resolve, and even if forced
> it would still emit the Webpack-era `.js` remote entry, which the Angular 22 portal never loads.
>
> **Migrate the extension first**, then the tarball swap below is the last step of that migration:
> [`.claude/skills/duplo-extension-ng22-migration/`](../.claude/skills/duplo-extension-ng22-migration/).
> That skill converts one extension in place — deletes the Webpack layer and the dev shell, writes
> `federation.config.js` and the `@angular-architects/native-federation:build` target, bumps every
> dependency, and finishes with the gate `scripts/verify-remote-federation.js`.

If your extension is already an Angular 22 Native-Federation remote (it has `frontend/federation.config.js`
and no `frontend/webpack.config.js`), the steps below are all you need.

---

## What changed in 0.2.0

| | 0.1.5 | 0.2.0 |
|---|---|---|
| Peer dependencies | Angular-15 ecosystem | **Angular 22** — `@angular/{core,common,forms,router,platform-browser,cdk,material}@^22.1.0`, `rxjs@^7.8.0` |
| UI peers | Angular-15-era majors | `@ng-bootstrap/ng-bootstrap@^21`, `@ng-select/ng-select@^23.5.1`, `@swimlane/ngx-datatable@^25`, `@ngx-translate/core@^18`, `ngx-toastr@^20.0.5`, `ngx-markdown@^22`, `ngx-monaco-editor-v2@^22.0.4`, `ngx-echarts@^22`, `@ngbracket/ngx-layout@^22.0.1`, `angularx-flatpickr@^8.1.0` |
| Package format | — | ESM only: `fesm2022/`, `"type": "module"`, `exports` map |
| `ng-block-ui` | external dependency | **bundled inside the tarball** (`bundleDependencies`), so the tarball installs with no registry access |
| Shipped SCSS | `scss/` folder via the `./scss/*` subpath | unchanged |

The `scss/` folder, unchanged from 0.1.5:

| File | Import as | What it is |
|---|---|---|
| `_theme-vars.scss` | `@duplocloud-internal/ng-common-lib/scss/theme-vars` | `@mixin duplo-theme-css-vars` — emits the portal's themable CSS custom-property contract (`--primary`, `--white`, the `--primary-50…900` ramp, …) |
| `_variables.scss` | `.../scss/variables` | Bootstrap variable overrides |
| `_utils.scss` | `.../scss/utils` | `:root` aliases (`--duplo-light`, …) |
| `panel-form.scss` | `.../scss/panel-form` | `@mixin panel-form-accordion` |
| `modal-form.scss` | `.../scss/modal-form` | `.modal-form-v2` styles |
| `markdown.scss` | `.../scss/markdown` | `.markdown-box` styles |

Component styles are compiled and inlined into the package either way, so **you do not need to import any of
this**: a remote only ever mounts inside the portal, and the host already emits the custom properties the
components read.

---

## Steps

### 1. Get the tarball

Either pack it from the platform UI repo:

```bash
cd duplo-ui/portal && npm install && npm run pack:common-lib
# → duplocloud-internal-ng-common-lib-0.2.0.tgz
```

`pack:common-lib` builds both libraries, bundles the `ng-block-ui` fork into the package, and packs the
tarball in one step.

Or pull the published one from GitHub Packages (needs a `read:packages` token):

```bash
npm pack @duplocloud-internal/ng-common-lib@0.2.0
```

### 2. Swap the vendored tarball

**In this repo**, two vendoring schemes coexist — refresh both, or use
`./scripts/refresh-common-lib.sh /path/to/duplocloud-internal-ng-common-lib-0.2.0.tgz` to do it in one shot.
The script drops the tarball into both locations, deletes the old one from each, and rewrites the `file:`
dependency in every `package.json` that references it.

- **Samples** share one copy at the repo-root `packages/` (they never leave this repo, so a shared relative
  path is safe):

  ```bash
  cp /path/to/duplocloud-internal-ng-common-lib-0.2.0.tgz packages/
  rm packages/duplocloud-internal-ng-common-lib-<old-ver>.tgz
  ```

  then point the dependency at the new file in `frontend/package.json` for any affected samples:

  ```diff
  -    "@duplocloud-internal/ng-common-lib": "file:../../../packages/duplocloud-internal-ng-common-lib-<old-ver>.tgz",
  +    "@duplocloud-internal/ng-common-lib": "file:../../../packages/duplocloud-internal-ng-common-lib-0.2.0.tgz",
  ```

- **The `duplo-extension-dev` skill template** keeps its own copy at
  `.claude/skills/duplo-extension-dev/templates/helloworld/frontend/vendor/` — it gets `cp -r`'d out to
  `extensions/<name>/` or a provisioning-ticket workdir, so it can't reach back to repo-root `packages/` and
  must stay self-contained:

  ```bash
  cp /path/to/duplocloud-internal-ng-common-lib-0.2.0.tgz \
    .claude/skills/duplo-extension-dev/templates/helloworld/frontend/vendor/
  rm .claude/skills/duplo-extension-dev/templates/helloworld/frontend/vendor/duplocloud-internal-ng-common-lib-<old-ver>.tgz
  ```

  `frontend/package.json` there keeps `"file:vendor/duplocloud-internal-ng-common-lib-<ver>.tgz"` — bump just
  the version in the filename.

### 3. Regenerate the lockfile

`package-lock.json` pins the old filename **and its integrity hash**, so it must be regenerated — hand-editing
the version string leaves a stale `integrity` and the install fails.

```bash
cd frontend
npm install --package-lock-only
```

Confirm it took:

```bash
grep -n "ng-common-lib" package-lock.json
```

Both the `dependencies` entry and the `node_modules/@duplocloud-internal/ng-common-lib` entry should read
`file:../../../packages/duplocloud-internal-ng-common-lib-0.2.0.tgz`, with `"version": "0.2.0"` and integrity
`sha512-/69ZgZvvSNMoGO2GQnySpW7Upfd9zVmtNqFWTa/2oQHWcIIJ+M8JdBiv3jfeyk3kG6SfZHvdPD8OylfFLnjRng==`. The entry
also carries `"bundleDependencies": ["ng-block-ui"]`.

### 4. Install and build

Installs are strict — run a plain install, with no extra flags. Never pass `--legacy-peer-deps`: it
silently hides a real peer conflict, and the Angular 22 dependency set does not need it. The one genuine
conflict (`ngx-toastr` has no Angular 22 release) is resolved by the `overrides` block already present in
every frontend's `package.json`:

```json
"overrides": {
  "ngx-toastr": {
    "@angular/common": "$@angular/common",
    "@angular/core": "$@angular/core"
  }
}
```

```bash
npm install
npm run build
```

`npm run build` writes `dist/remoteEntry.json` plus sibling ESM chunks. There is no `dist/browser/`
subdirectory and no `index.html` — the remote has no standalone dev server; it is only ever loaded by the
portal.

If you have a stale `node_modules`, npm can keep serving the old unpacked copy. Force it:

```bash
rm -rf node_modules/@duplocloud-internal && npm install
```

### 5. Verify the built remote

```bash
node scripts/verify-remote-federation.js <extension-dir>
```

This checks that `frontend/dist/remoteEntry.json` exists, that `frontend/dist/browser/` does **not**, that the
container name matches `manifest.json`'s `frontend.remote.remoteName`, that the manifest's `remoteEntry` URL
ends in `remoteEntry.json`, and that the exposed module is present. Pass the host's `remoteEntry.json` as a
second argument to also check every shared package against the host at the same major version.

---

## What this upgrade does *not* change

- **The vendoring model.** The library is consumed as a committed `file:` tarball, so no `.npmrc` and no
  auth token are needed for a fresh clone to install.
- **The detail shell.** The shared `_g-structure.scss` / `detail-page.scss` / lifecycle rail are copied per
  extension (the lib does not export them), so a tarball bump never touches them.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `EINTEGRITY` / `checksum mismatch` on install | lockfile still holds the 0.1.5 hash | redo step 3 |
| `ERESOLVE` naming `@angular/core@15` peers | the extension has not been migrated to Angular 22 | run the [migration skill](../.claude/skills/duplo-extension-ng22-migration/) first — do **not** reach for `--legacy-peer-deps` |
| `ERESOLVE` naming `ngx-toastr` | the `overrides` block is missing from `package.json` | add it (step 4) |
| Build resolves the old version | stale unpacked copy in `node_modules` | `rm -rf node_modules/@duplocloud-internal` and reinstall |
| Build emits `dist/browser/` instead of `dist/remoteEntry.json` at the top level | `angular.json`'s esbuild `outputPath` is missing `"browser": ""` | set `"outputPath": { "base": "dist", "browser": "" }` — `build-extension.sh` copies `frontend/dist/.` straight into the bundle's `fe/` |
