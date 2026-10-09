---
name: duplo-extension-ng22-migration
description: Migrate an existing DuploCloud platform extension's frontend from Angular 15 + Webpack Module Federation to Angular 22 + Native Federation. Use when an extension built from an older dev-kit no longer loads in the Angular 22 portal, when its frontend/ still has webpack.config.js / webpack-shared-lib.js / ngx-build-plus and @angular/core 15, or when asked to upgrade, migrate or port an extension remote to Angular 22 / Native Federation / remoteEntry.json.
---

# Migrate an extension frontend to Angular 22 + Native Federation

An extension built from the pre-Angular-22 dev-kit is a **Webpack Module Federation** remote: it emits
`remoteEntry.js`, shares Angular 15 singletons, and carries a standalone dev shell. The Angular 22
portal is a **Native Federation** host: it loads `remoteEntry.json` and negotiates Angular 22
singletons. The two do not interoperate at all — an unmigrated extension does not degrade, it simply
never mounts.

This skill converts one extension in place. The reference shape is **`samples/helloworld/frontend/`**
in this dev-kit; diff against it whenever a step is ambiguous. It is the only copy that has been built
and gate-verified end to end.

Throughout, `<devkit>` is a checkout of `duplo-ai-extension-devkit` and `<portal>` is a checkout of
`duplo-ui/portal`. You need the dev-kit for the reference files and the gate script; you need the
portal only for the gate's optional host-entry argument and the host-requirement check.

> **Before you start, read the [host requirement](#host-requirement--read-this-before-you-debug-anything).**
> A perfectly migrated extension still hangs forever on a portal that predates the
> `REMOTE_LoadRemoteModule` fix, with no error to point at. Confirm the portal first, or you will spend
> hours debugging a correct extension.

---

## 0. Preconditions and inventory

Run from the extension's root (the directory holding `manifest.json` and `frontend/`).

```bash
EXT=/abs/path/to/extension            # the dir containing manifest.json + frontend/
FE="$EXT/frontend"
ls "$FE"/webpack.config.js "$FE"/webpack-shared-lib.js 2>/dev/null
node -e "console.log(require('$FE/package.json').dependencies['@angular/core'])"
```

Migrate only if `webpack.config.js` exists **and** `@angular/core` resolves to a 15.x range. If
`federation.config.js` exists *and* `webpack.config.js` does not, the extension is already migrated —
run the [gate](reference/verification.md) instead and stop. If **both** exist, a previous migration was
abandoned half-way; delete `federation.config.js` and start clean rather than trusting it.

Capture the four values that must survive the migration. Every later step reuses them:

```bash
REMOTE_NAME=$(jq -r '.frontend.remote.remoteName' "$EXT/manifest.json")
PKG_NAME=$(jq -r '.name'        "$FE/package.json")
PKG_DESC=$(jq -r '.description' "$FE/package.json")
PROJECT_KEY=$(jq -r '.projects | keys[0]' "$FE/angular.json")
PREFIX=$(jq -r --arg k "$PROJECT_KEY" '.projects[$k].prefix' "$FE/angular.json")
echo "remote=$REMOTE_NAME pkg=$PKG_NAME project=$PROJECT_KEY prefix=$PREFIX"
```

Read `REMOTE_NAME` from the **manifest**, not from `webpack.config.js`. The manifest is what the host
resolves the container by; if the two ever disagreed, the manifest is the one that matters. If
`.frontend.remote.remoteName` is null, stop and ask — there is nothing to name the container.

`REMOTE_NAME` must also be **unique across every extension installed on the same portal**. Two
extensions sharing a container name alias to each other at runtime and the first one loaded wins, so
the wrong extension's pages render. If the extension was copied from a sample or template and still
carries a default like `duploExtensionHelloworld`, rename it now — in both `manifest.json` and (in
step 2) `federation.config.js`.

**Also inventory what you are about to delete.** Step 1 deletes `src/app/app.module.ts` and
`src/app/app.component.ts` on the assumption they are the dev shell the old template shipped. In a real
extension somebody may have put production code there. Read both files first; if either declares
anything the exposed `Extension` module needs, move that code into `src/app/` proper before deleting.

---

## 1. Delete the Webpack layer and the dev shell

```bash
rm -f "$FE/webpack.config.js" "$FE/webpack-shared-lib.js" \
      "$FE/src/index.html" "$FE/src/polyfills.ts" "$FE/src/bootstrap.ts" \
      "$FE/src/app/app.module.ts" "$FE/src/app/app.component.ts"
rm -rf "$FE/node_modules" "$FE/package-lock.json" "$FE/dist" "$FE/.angular"
```

Why each one goes:

| File | Replaced by |
|---|---|
| `webpack.config.js` | `federation.config.js` (step 2) |
| `webpack-shared-lib.js` | the inline `shared` block in `federation.config.js` |
| `src/index.html` | `"index": false` in `angular.json` — a remote has no page of its own |
| `src/polyfills.ts` | `"polyfills": ["zone.js"]` in `angular.json` |
| `src/bootstrap.ts` | nothing — the remote is never bootstrapped standalone |
| `src/app/app.module.ts`, `app.component.ts` | nothing — the dev shell is gone |

The `serve` architect target goes too; step 3 rewrites `angular.json` without it. `ng serve` for a
federated remote required `ngx-build-plus:dev-server`, which does not exist in Angular 22. Develop
against a running portal instead: build, `scripts/build-extension.sh`, and hot-load.

The lockfile must go as well. It is an npm-v2 lockfile pinning the whole Angular 15 tree; there is no
in-place upgrade for it, and every attempt to keep it needs `--force` or the legacy peer-deps flag,
both of which are barred here.

---

## 2. Add `federation.config.js`

Copy the reference verbatim, then change exactly two things — the container name, and the exposed
module:

```bash
cp <devkit>/samples/helloworld/frontend/federation.config.js "$FE/federation.config.js"
perl -pi -e "s/duploExtensionHelloworld/$REMOTE_NAME/g" "$FE/federation.config.js"
perl -pi -e "s{'\./Extension': '\./src/app/extension\.routes\.ts'}{'./Extension': './src/app/extension.module.ts'}" \
  "$FE/federation.config.js"
```

The second edit matters because helloworld has since been modernized to standalone components, so its
config exposes `./src/app/extension.routes.ts`. This migration keeps the extension's
`src/app/extension.module.ts` ([step 5](#5-rewrite-the-tsconfig-pair-and-srcmaints)), and an extension
coming off Angular 15 has no `extension.routes.ts` — the build dies at config load with
`FsPath: …/src/app/extension.routes.ts does not exist`. Point `exposes` at the NgModule; the modernization
pass that later adds `extension.routes.ts` moves it back.

Read the file's comment block — it documents the aliasing hazard, the subset rule and the skip list,
all of which are covered in [Traps](#traps) below.

The `shared` block you just copied lists 18 packages. It must end up a *subset* of the host's list,
matching what **this** extension declares: `requiredVersion: 'auto'` makes `share()` call
`lookupVersion()`, which **throws at config load** for any package missing from this `package.json`.

**Leave the block alone for now.** Trimming it needs the final `package.json`, which step 4 writes —
the trim is the last action of [step 4](#4-rewrite-packagejson). Doing it here, against the Angular 15
`package.json`, produces a list that step 4 then invalidates.

Do **not** add anything the reference does not list — in particular do not copy extra entries out of
the portal's `federation.shared.js`. The host shares utilities (`yaml`, …) an extension has no
dependency on; adding one throws at config load, and the gate enforces remote ⊆ host anyway.

`@duplocloud-internal/ng-common-lib` itself is deliberately **not** shared — the host compiles its own
copy under a different specifier, so it is bundled into the remote.

---

## 3. Rewrite `angular.json`

Two architect targets replace the single `ngx-build-plus:browser` one: `build` runs the Native
Federation wrapper, which delegates to an `esbuild` target running `@angular/build:application`.
Keep the extension's own `PROJECT_KEY` and `prefix`; both `target` strings must reference it.

```json
{
  "$schema": "./node_modules/@angular/cli/lib/config/schema.json",
  "version": 1,
  "newProjectRoot": "projects",
  "projects": {
    "<PROJECT_KEY>": {
      "projectType": "application",
      "root": "",
      "sourceRoot": "src",
      "prefix": "<PREFIX>",
      "architect": {
        "build": {
          "builder": "@angular-architects/native-federation:build",
          "options": { "target": "<PROJECT_KEY>:esbuild" },
          "configurations": {
            "production": { "target": "<PROJECT_KEY>:esbuild:production" }
          },
          "defaultConfiguration": "production"
        },
        "esbuild": {
          "builder": "@angular/build:application",
          "options": {
            "outputPath": { "base": "dist", "browser": "" },
            "index": false,
            "browser": "src/main.ts",
            "polyfills": ["zone.js"],
            "tsConfig": "tsconfig.app.json",
            "inlineStyleLanguage": "scss",
            "assets": [],
            "styles": [],
            "scripts": []
          },
          "configurations": {
            "production": {
              "optimization": true,
              "outputHashing": "none",
              "sourceMap": false,
              "namedChunks": false,
              "budgets": [
                { "type": "initial", "maximumWarning": "5mb", "maximumError": "10mb" }
              ]
            }
          },
          "defaultConfiguration": "production"
        }
      }
    }
  }
}
```

`outputPath: { "base": "dist", "browser": "" }` is load-bearing — see the last trap. Keep the
extension's own `assets`/`styles` entries if it had non-empty ones (the samples ship none: Bootstrap 4
and the Vuexy theme are served globally by the host).

---

## 4. Rewrite `package.json`

Start from `samples/helloworld/frontend/package.json`, restore `name` and `description`, then reconcile
the dependency list with what this extension actually imports.

```bash
cp <devkit>/samples/helloworld/frontend/package.json "$FE/package.json.new"
jq --arg n "$PKG_NAME" --arg d "$PKG_DESC" '.name = $n | .description = $d' \
  "$FE/package.json.new" > "$FE/package.json" && rm "$FE/package.json.new"
```

Then, against the pre-migration `package.json` (recover it with
`git show HEAD:frontend/package.json` if you already overwrote it):

- **Add back** any dependency the extension has that helloworld does not (its own libraries). Pick an
  Angular-22-compatible version; if none exists, see the `overrides` note below.
- **Drop** `@angular/animations` and `@angular/platform-browser-dynamic` — the host ships neither. If
  the source imports `BrowserAnimationsModule` / `provideAnimations`, remove those imports.
- **Drop** the build-time Webpack stack: `@angular-architects/module-federation`, `ngx-build-plus`,
  `@angular-devkit/build-angular`, and the `start` script.
- **Repoint** `@duplocloud-internal/ng-common-lib` at a **0.2.0-or-later** tarball (Angular 22 peers).
  The 0.1.x tarballs carry Angular 15 peers and will fail a strict install. Use **0.4.1 or later** (the
  dev-kit's current tarball): the analytics retrofit in [step 9](#9-analytics-retrofit) imports a token that
  0.4.0 and earlier do not export.

  Careful here: the `cp` above brought helloworld's own `file:../../../packages/...` path with it, which
  is correct **only** for something living at `samples/<name>/frontend/`. A self-contained extension
  vendors its copy at `frontend/vendor/` and wants `file:vendor/duplocloud-internal-ng-common-lib-0.2.0.tgz`.
  Restore the extension's own path style and then prove the file is actually there — a wrong `file:`
  path fails at install with a bare `ENOENT`/`Could not resolve dependency` that names the tarball, not
  the mistake:

  ```bash
  node -e '
  const p = require("'"$FE"'/package.json").dependencies["@duplocloud-internal/ng-common-lib"];
  const f = require("path").resolve("'"$FE"'", p.replace(/^file:/, ""));
  console.log(p, "->", require("fs").existsSync(f) ? "OK" : "MISSING");'
  ```

Two rules about the ranges, both deliberate departures from the portal's own `package.json`:

1. **Caret the whole runtime `@angular/*` set and `@angular/compiler-cli`.** Angular's framework
   packages pin their own peers *exactly*, so a caret on `core` beside a pin on `router` becomes an
   `ERESOLVE` the day the next minor publishes. `@angular/build` and `@angular/cli` stay pinned
   (`22.0.9`) — their peers are `^22.0.0` ranges, so the tooling pair carries no such trap.
2. **`@angular-architects/native-federation` is a runtime `dependency`, not a devDependency.**
   `src/main.ts` imports it, so `npm install --omit=dev` in a hardened CI would otherwise break the
   build.

The `overrides` block is how you handle a dependency with no Angular 22 release. `ngx-toastr` is the
current example:

```json
"overrides": {
  "ngx-toastr": { "@angular/common": "$@angular/common", "@angular/core": "$@angular/core" }
}
```

If a new conflict appears at install time, add another entry here. Never restore the legacy peer-deps
flag — it hides real incompatibilities across the whole tree instead of recording one known-safe
exception.

### Last action of this step: trim the shared list

Now that `package.json` is final, reconcile step 2's `shared` block against it. Run this against the
**final** `package.json` — the one you just finished writing, never the pre-migration one:

```bash
node -e '
const deps = Object.keys(require(process.argv[1]).dependencies || {});
const ref = ["@angular/core","@angular/common","@angular/forms","@angular/router",
  "@angular/platform-browser","@angular/cdk","@angular/material","rxjs",
  "@ng-bootstrap/ng-bootstrap","@ngx-translate/core","ngx-toastr","@ng-select/ng-select",
  "@swimlane/ngx-datatable","ngx-markdown","ngx-monaco-editor-v2",
  "@ngbracket/ngx-layout","ngx-echarts","angularx-flatpickr"];
console.log("KEEP:", ref.filter(p => deps.includes(p)).join(" "));
console.log("DROP:", ref.filter(p => !deps.includes(p)).join(" ") || "(none)");
' "$FE/package.json"
```

Delete every `DROP` line from `federation.config.js`.

`DROP` is normally `(none)`: you started this step from helloworld's `package.json`, which declares all
18 as **direct dependencies**, and nothing above tells you to remove any of them. A non-empty `DROP`
therefore means you pruned something — so check *why* before obeying it:

> **If `DROP` names `@ngbracket/ngx-layout`, `ngx-echarts` or `angularx-flatpickr`, do not obey it.**
> Re-add the dependency to `package.json` instead, then re-run. Those three are
> `@duplocloud-internal/ng-common-lib` peers that carry DI tokens, and the lib reaches them from code
> the extension never imports directly — so they look unused right up until a page renders a chart or a
> date picker and throws `NG0201`. See the [DI-carrying peer trap](#a-di-carrying-peer-left-unshared).

Being an installed peer is **not** enough to keep an entry in the shared list. npm auto-installs peers
into `node_modules`, but it never writes them into your `package.json` — and `lookupVersion` reads the
`package.json` dependency maps, not `node_modules`. A package present only as an auto-installed peer
still throws at config load. Only a direct dependency counts.

---

## 5. Rewrite the tsconfig pair and `src/main.ts`

Copy all three from helloworld unchanged; nothing in them is per-extension.

```bash
for f in tsconfig.json tsconfig.app.json src/main.ts; do
  cp "<devkit>/samples/helloworld/frontend/$f" "$FE/$f"
done
```

What changed from the Angular 15 versions, in case the extension customised them:

- `tsconfig.json`: `"module": "ES2022"`, `"moduleResolution": "bundler"`, `"lib": ["ES2022","dom"]`,
  plus `"skipLibCheck": true`, `"strict": false` and `"useDefineForClassFields": false`. `baseUrl` is
  gone (bundler resolution does not want it). If the extension had `paths` entries, re-add them.
- `tsconfig.app.json`: `"files": ["src/main.ts"]` only — `src/polyfills.ts` is gone.
- `src/main.ts`: a one-liner that calls `initFederation()` instead of `import('./bootstrap')`:

```ts
import { initFederation } from '@angular-architects/native-federation';

initFederation().catch(err => console.error(err));
```

The remote is never bootstrapped. `initFederation()` only initialises the shared scope so the build
graph is federation-aware; the host lazy-loads the exposed `./Extension` module by remoteEntry URL.

Leave `src/app/extension.module.ts` alone. The exported class must still be named `Extension` and the
module must still use `RouterModule.forChild(...)` — the host's `extension-route-registrar.ts`
resolves `m.Extension`.

> Keeping the NgModule is the right call **for a migration** — getting to Angular 22 and restructuring to
> standalone are separate jobs, and doing both at once makes a failure hard to attribute. Once the
> migration is verified at runtime, modernize in a second pass using the
> [`use-ng22`](../use-ng22/SKILL.md) skill: standalone components plus `export const Extension: Routes`
> from `extension.routes.ts` (`loadChildren` accepts either, so the host needs no change). The
> `helloworld` template in `duplo-extension-dev` is the worked reference.

---

## 6. `standalone: false` on every decorator

Angular 19 flipped the default of `standalone` from `false` to `true` for `@Component`, `@Directive`
**and** `@Pipe`. An Angular 15 extension declares all of them in an NgModule, so every one needs the
flag written out explicitly.

**Count them; do not assume a number.** Helloworld has 7 components; other samples and real extensions each
have their own number.

```bash
grep -rnE "@(Component|Directive|Pipe)\(" "$FE/src" --include='*.ts' | wc -l
```

Add `standalone: false` as a property of each decorator's object literal, e.g.

```ts
@Component({
  selector: 'app-status-badge',
  template: `...`,
  standalone: false
})
```

Then verify none was missed — this check is per-file, so a file with two decorators and one flag still
reports:

```bash
grep -rlE "@(Component|Directive|Pipe)\(" "$FE/src" --include='*.ts' | while read -r f; do
  n=$(grep -cE "@(Component|Directive|Pipe)\(" "$f")
  s=$(grep -c "standalone: false" "$f")
  [ "$n" = "$s" ] || echo "MISSING: $f — $n decorator(s), $s flag(s)"
done
```

Expect no output. Skipping one produces **NG6008 — "Component X is standalone, and cannot be declared
in an NgModule"** at build time, which is at least loud; the file-level count above is what catches the
second decorator in a file that already looks handled.

### 6b. The other flipped default: change detection — and this one is silent

`standalone` is not the only `@Component` default Angular moved. In Angular 22 the strategy enum is
`OnPush = 0`, `Eager = 1` (`Eager` is the old `Default`), and **a component with no `changeDetection`
property now defaults to `OnPush`**, not to eager checking.

Unlike NG6008 this produces **no error at all**. The build passes, unit tests pass, the page renders its
static shell — and then any field assigned from an async callback (`subscribe`, `setTimeout`, a promise)
never repaints. A list sits empty forever while the network tab shows the data arrived. Do not trust a
green build here; it is only visible at runtime.

Pick one of two fixes — do not leave the property absent while assigning plain fields:

- **Shim (bulk migrations):** add `changeDetection: ChangeDetectionStrategy.Eager` to every component and
  import the enum. This is what `duplo-ui/portal` did for 898 of its 904 components — retrofitting them to
  signals was not feasible.
- **Preferred for an extension's handful of components:** hold async state in `signal()` and leave the
  property off, so the component keeps the modern OnPush default. A signal write marks the view dirty, so
  the repaint happens with no `markForCheck` anywhere. See the helloworld template for the worked shape.

Audit which components still assign plain fields while declaring no strategy:

```bash
grep -rlE "@Component\(" "$FE/src" --include='*.ts' | while read -r f; do
  grep -q "changeDetection:" "$f" && continue
  grep -q "this\.[A-Za-z_]* = " "$f" && echo "CHECK: $f — no strategy, assigns plain fields"
done
```

Then confirm at runtime, not at build: load the page in the host and watch a list actually populate after
its request resolves.

---

## 7. Flip the manifest to `remoteEntry.json`

Native Federation publishes a JSON descriptor, not a JS container. One line changes:

```bash
perl -pi -e 's{/remoteEntry\.js(\?[^"]*)?"}{/remoteEntry.json"}' "$EXT/manifest.json"
grep -n '"remoteEntry"' "$EXT/manifest.json"   # must now end in /remoteEntry.json"
```

The optional group drops a cache-busting query such as `remoteEntry.js?v=0.6.118`, which some Webpack-era
manifests carry. Drop it rather than carrying it over: the [gate](reference/verification.md) requires
`remoteEntry` to end in `/remoteEntry.json`, and the migrated samples carry no query. A substitution
written for the bare `remoteEntry.js"` form matches nothing on such a manifest and leaves it on the Webpack
entry, so check the `grep` output rather than assuming the edit landed.

Keep `remoteName`, `exposedModule` and `type: "module"` exactly as they were.

Use a **targeted substitution, not a `jq` round-trip**. `jq`'s pretty-printer reflows the whole
document — compact one-line records get exploded, deliberate blank-line grouping is stripped — and
these manifests are hand-authored files people read and diff. Exactly one line should change.

---

## 8. Install strictly, build, gate

```bash
cd "$FE" && npm install && npm run build
```

`npm install`, with **no** `--legacy-peer-deps` and no `--force`. An `ERESOLVE` here is a real
incompatibility: read which package conflicts and add an `overrides` entry (step 4).

Then run the gate — the full command and how to read each failure are in
**[reference/verification.md](reference/verification.md)**:

```bash
node <devkit>/scripts/verify-remote-federation.js "$EXT" \
  <portal>/ai-studio/ai-suite-dist/remoteEntry.json
```

Expect `OK: <dir> is a loadable Native Federation remote`.

Across the dev-kit's samples, **no source change beyond `standalone: false` was required**. A
richer extension may still hit API drift in the jumped major versions — `@ng-bootstrap/ng-bootstrap`
13→21, `@swimlane/ngx-datatable` 20→25, `@ngx-translate/core` 14→18, RxJS 6→7. Those surface as
ordinary compile errors; fix them against each library's changelog.

---

## 9. Analytics retrofit

Once the frontend builds and passes the gate, run the **analytics retrofit** on it — always, even though the
request was "migrate". The single owner is
[`duplo-extension-dev/reference/21-analytics.md`](../duplo-extension-dev/reference/21-analytics.md#analytics-retrofit-existing-extensions);
in short:

1. Add `frontend/src/app/analytics.ts` from the dev-kit scaffold
   (`.claude/skills/duplo-extension-dev/templates/helloworld/frontend/src/app/analytics.ts`), class renamed to
   `<Name>Analytics`, `EXTENSION_ID` set to the manifest `id`. It is an `@Injectable({ providedIn: 'root' })`
   service, so it works unchanged in a migrated `standalone: false` NgModule extension.
2. Add `pageView('<page>')` to `ngOnInit` of every routed page and `action('<verb>-<object>')` to the success
   callback of every create / update / delete / deprovision / custom action.
3. **No properties** — not in the calls, not in the manifest (⛔ hard rule in 21-analytics).
4. Rebuild with `scripts/build-extension.sh`: it also checks the manifest `id` format (lowercase reverse-DNS,
   ≥ 3 segments) and that `EXTENSION_ID` equals it. If an old extension's `id` fails the format check, tell the
   user instead of renaming it yourself.
5. Tell the user which page views and actions you added, alongside the migration summary.

---

## Host requirement — read this before you debug anything

**A correctly migrated extension still will not load on a portal that predates the
`REMOTE_LoadRemoteModule` fix.**

**Symptom.** You navigate to the extension's page and nothing happens. The route does not render. There
is **no network request** for `remoteEntry.json`, **no console error**, **no rejected promise, and no
timeout** — the navigation simply never completes. Nothing in the browser points at a cause, and every
instinct says the extension is broken.

**Cause.** It is not the extension. AI Studio is itself a federated remote, and it bundles its own copy
of the Native Federation wrapper. That copy's module-level `federationPromise` is only resolved by
`initFederation()`, which runs in the **host's** `main.ts`, never in AI Studio's copy. So AI Studio's
`loadRemoteModule` awaits a promise that never settles.

**Fix — platform side, not yours.** The portal provides its own already-initialised `loadRemoteModule`
through the `REMOTE_LoadRemoteModule` DI token; AI Studio's `remote.module.ts` injects it and installs
it via `setRemoteModuleLoader()` before any extension route is built. Nothing in the extension can
substitute for this. Confirm the portal has it:

```bash
grep -rn "REMOTE_LoadRemoteModule" <portal>/src/app/app.module.ts \
                                   <portal>/ai-studio/src/app/remote.module.ts
```

Four hits (two imports, one `provide:`, one `@Inject`) means the portal is new enough. Zero hits means
**upgrade the portal** — do not touch the extension.

---

## Traps

Every one of these passes a build, or fails pointing at the wrong cause. Symptom first.

### A hoisted `const S = {...}` reused across shared entries

**Symptom.** The build succeeds. `dist/remoteEntry.json` looks plausible. At runtime the host either
loads a second copy of a package it thought it was sharing, or a version-mismatch warning names a
version the extension does not have installed. With `strictVersion: false` — which every entry uses —
there is no hard failure to trace, just wrong behaviour.

**Cause.** The Angular 15 `webpack-shared-lib.js` template did exactly this:

```js
const S = { singleton: true, strictVersion: false, requiredVersion: 'auto' };
module.exports = { '@angular/core': S, '@angular/common': S, /* … */ };
```

Native Federation's `share()` shallow-copies the map and then **mutates each value in place**: it sets
`requiredVersion` and `version`, and deletes `includeSecondaries`. With one shared object, the first
key resolves its version and stamps it onto `S`. Every later key then sees `requiredVersion !== 'auto'`,
skips its own lookup, and ships `@angular/core`'s metadata under its own name.

Reproduce it in ten seconds from the extension's `frontend/`:

```bash
node -e "
const { share } = require('@angular-architects/native-federation/config');
const S = { singleton: true, strictVersion: false, requiredVersion: 'auto' };
console.log(share({ '@angular/core': S, 'rxjs': S })['rxjs']);"
```

Prints `{ requiredVersion: '^22.1.0', version: '22.1.0' }` for **rxjs** — Angular's version, on RxJS.
`S` itself comes back mutated. Nothing warns.

**Fix.** One fresh object literal per entry, exactly as `samples/helloworld/frontend/federation.config.js`
and the portal's `federation.shared.js` write them. Never `const S`, never a spread of a shared base.

### Sharing a package the extension does not declare

**Symptom.** The build dies before compiling anything, at config load:

```
Shared Dependency yaml has requiredVersion:'auto'. However, this dependency is not found in your package.json
```

It reads like a broken install, so the reflex is `rm -rf node_modules && npm install` — which does not
help, because the package was never supposed to be installed here in the first place.

**Cause.** `requiredVersion: 'auto'` makes `share()` call `lookupVersion()`, which resolves the package
from **this** `package.json` and throws if it is absent. This bites whenever someone "syncs" the shared
list by copying the portal's `federation.shared.js`: the host shares things an extension has no
dependency on (`yaml`, for one).

**Fix.** The shared list is a **subset** of the host's, never a mirror. Run the KEEP/DROP snippet at the
end of step 4 — against the final `package.json` — and delete every entry the extension does not
declare as a direct dependency. The gate independently enforces remote ⊆ host, so a subset always
passes and a remote-only package always fails.

### A DI-carrying peer left unshared

**Symptom.** Build is clean, remote loads, and then the page throws at runtime:
**`NG0201: No provider for <Something>`** — e.g. `NG0201: No provider for FlexLayoutServerLoaded`, or a
`NullInjectorError` for `TranslateService`, `NGX_ECHARTS_CONFIG` or `FlatpickrDefaults`. The provider
demonstrably exists: the host calls the matching `forRoot()`/`withConfig()` at startup, and the same
component works fine inside the portal.

**Cause.** Two copies of the package, therefore two different class identities for the same token. The
host's `forRoot()` provider is keyed on *its* class; the remote's privately bundled copy asks for a
different one, and the injector correctly reports no provider. Nothing about this is visible to the
compiler.

**Fix.** Any package with `forRoot()` providers, DI tokens or module-level state must resolve to **one**
instance across host and remote — list it in `shared`. The three that are easy to miss, because they
arrive transitively as `@duplocloud-internal/ng-common-lib` peers rather than from the extension's own
imports:

- `@ngbracket/ngx-layout` — `CoreCommonModule` imports plain `FlexLayoutModule`, whose `SERVER_TOKEN`
  only `.withConfig()` provides. The host does that; a private copy here fails with
  `NG0201 FlexLayoutServerLoaded`.
- `ngx-echarts` — `NGX_ECHARTS_CONFIG`.
- `angularx-flatpickr` — `FlatpickrDefaults`.

### Adding a package with a Node-only secondary entry point

**Symptom.** The browser build fails on a package you never import directly, complaining about a
missing module such as `@angular/platform-server`, or about Node built-ins (`fs`, `path`,
`child_process`) in the bundle. The error names a `/server` or `/schematics` path.

**Cause.** Native Federation expands a shared package's **secondary entry points** from its `exports`
map and pre-bundles them all for the browser. Node-only entry points get dragged in and cannot survive
browser bundling.

**Fix.** Check the package's `exports` map before adding it to `shared`, and add a `skip` entry for any
Node-only path. The reference config already skips the two known cases:

```js
skip: [
  ...NG_SKIP_LIST,
  /\/schematics(\/|$)/,            // @angular/cdk's Node-only ./schematics entry point
  '@ngbracket/ngx-layout/server',  // imports @angular/platform-server
],
```

And note the sub-trap: **`skip` REPLACES the built-in list rather than extending it.** `NG_SKIP_LIST`
must be spread in explicitly. Writing `skip: ['@ngbracket/ngx-layout/server']` silently un-skips
`es-module-shims`, `zone.js` and `@softarc/native-federation*`.

### Mixing exact pins and carets inside `@angular/*`

**Symptom.** `npm install` worked on the machine that did the migration and fails with `ERESOLVE` for
everybody else, or in CI, or "suddenly" weeks later with no change to the extension. The conflict names
two `@angular/*` packages at adjacent patch versions.

**Cause.** Angular's framework packages pin their own peers **exactly**: `@angular/router@22.1.0`
declares `"@angular/core": "22.1.0"`, and `@angular/compiler-cli@22.1.0` declares
`"@angular/compiler": "22.1.0"`. A caret on `core` beside a pin on `router` is fine until 22.2.0
publishes — then a lockfile-free install resolves `core` to 22.2.0 against a pinned `router@22.1.0` and
dies. The portal can pin because it maintains a committed lockfile; an extension that is copied and
then edited cannot.

**Fix.** Caret the entire runtime `@angular/*` set **and** `@angular/compiler-cli`. Leave
`@angular/build` and `@angular/cli` pinned. Nothing is lost — the gate compares resolved-version
**majors**, never `requiredVersion` strings.

### Missing `outputPath: { "base": "dist", "browser": "" }`

**Symptom.** The build succeeds and `frontend/dist/` looks fine locally, but the packaged extension
ships broken: the host requests `fe/remoteEntry.json` and gets a 404, so the route fails to load. The
bundle contains `fe/browser/remoteEntry.json` instead. Nothing in the build output hints at this.

**Cause.** Angular 17+ emits into `dist/browser/` by default. `scripts/build-extension.sh` copies
`frontend/dist/.` straight into the bundle's `fe/`, so the extra directory level is preserved verbatim
into the published layout.

**Fix.** The flattening `outputPath` in step 3. The gate catches it directly — check 2 fails with
`.../dist/browser/ exists`.

---

## Related

- `scripts/migrate-sample-to-ng22.sh` — the in-repo projection this skill generalises. It handles
  steps 1–5 and 7 for a **dev-kit sample**, deriving the Angular project key from the npm package name.
  It deletes `src/app/app.module.ts` and `app.component.ts` unconditionally, so do not point it at an
  extension whose `app.module.ts` holds production code.
- `.claude/skills/use-ng22/` — **the Angular 22 patterns to modernize toward once this migration passes
  its runtime gate**: standalone components, signals, the OnPush-by-default trap (step 6b), `inject()`,
  `@if`/`@for`, a `Routes` export. Its
  [`reference/patterns.md`](../use-ng22/reference/patterns.md) is the exhaustive per-API catalogue,
  including which Angular 22 APIs are unusable inside a federated remote (zoneless, signal forms,
  `httpResource`).
- `.claude/skills/duplo-extension-dev/` — authoring a new extension (already Angular 22).
- `reference/verification.md` — the gate, check by check.
