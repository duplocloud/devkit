# Releasing extensions

`.github/workflows/release.yml` runs on every push to `main` and on a manual dispatch. It calls
[duplocloud/actions/release-extension](https://github.com/duplocloud/actions/tree/main/release-extension), which
builds every `extensions/*/manifest.json`, plus the single-extension layouts `extension/manifest.json` and
`extension/*/manifest.json`, with `scripts/build-all.sh`, then signs each bundle, publishes one GitHub Release
per build, uploads it and registers it with the console in one run. The action's README has its inputs and
the rules it enforces. This page covers what that run does, in any organization, and the extra steps that
apply only inside DuploCloud's own organizations, `duplocloud` and `duplocloud-internal`.

Only one release run executes for a repository at a time. A run that starts while another is still in
flight queues behind it rather than overlapping or being canceled mid-write.

## What a release produces

A build is tagged `<slug>-v<version>-sdk-<sdkVersion>`, where `<slug>` is the extension directory's name
and `<sdkVersion>` comes from the built bundle's own `manifest.json` (stamped by `build-extension.sh` from
the host SDK it built against). The release is cut at the built commit with `extension.zip` attached. A
version already released, under this tag shape or the older `<slug>-v<version>` one, is skipped if the
extension is unchanged since, and fails the run if it changed, since bumping `manifest.version` is the only
way to tell two different bundles apart.

Two checks run before any of that, for every build in every organization. A manifest with no `resources`
entry is refused, since the host would refuse the bundle anyway, and so is a zip over 268435456 bytes (256
MiB). A pull request that touches an extension sees the same checks ahead of time, as a warning rather than
a failure, from `scripts/check-extension-pr.sh`. That script also warns when `manifest.version` has not
moved, when a `skills/` folder has no matching `skills[].folder` entry in the manifest, when a webpack
frontend bundle ships without the file that Native Federation hosts need, and when the frontend uses an
ng-common-lib older than 0.5.1 (see the `duplo-extension-theme-migration` skill).

In every organization the build is uploaded and registered with the console as a new, unpublished version
of the record whose manifest id equals the bundle's. A version stays unpublished, for a platform owner to
publish once the build has been verified, unless the run was dispatched with `publish` (see "Publishing on
register"). In `duplocloud` and `duplocloud-internal` the release also carries `extension.zip.sig`, the
bundle is obfuscated, and the upload goes to the channels bucket through the publisher role. Elsewhere the
bundle is plain, signed only when the repository supplies its own key and certificate, and the upload goes
through a URL the console issues for the console key, so a customer's repository needs nothing from
DuploCloud beyond that key.

## Signing a build

Any repository, not only DuploCloud's own, can sign a build with `.github/actions/extension-sign`, a
composite action that wraps `scripts/extension-sign.py sign`. It takes three inputs:

- `bundle`, the path to the built `extension.zip`
- `signing-key`, the publisher's private key PEM, from a secret
- `signing-cert`, the publisher's certificate, a compact JWS from the console

It returns `signature-path`, the path of the `.sig` it wrote. The key and certificate reach the script
through the `EXTENSION_SIGNING_KEY` and `EXTENSION_SIGNING_CERT` environment variables, never as a command
argument, so neither shows up in a process listing.

`sign` writes one compact ES256 JWS next to the zip, built from the zip's own manifest rather than the
source one, since `sdkVersion` only exists in the built copy. Its claims are the manifest's `id`, `version`
and `sdk_version`, the zip's own sha256, and the time it was signed. It refuses, writing nothing, when the
signing key's public half does not match the certificate, when the manifest id falls outside every
namespace the certificate covers, when the certificate has expired, or when `sdkVersion` is missing, still
carries its placeholder value, or either `version` or `sdkVersion` is not strict semver
(`MAJOR.MINOR.PATCH[-pre]`, no build metadata). It warns, but still signs, when the certificate expires
within 30 days.

`verify [zip] [sig]` checks a signature the way the console does: the certificate's chain to a published
root key, the certificate's own validity window, the signature's claims against the zip and its manifest,
and the namespace. By default it fetches root keys from the console's public `root-keys` endpoint, which
needs no credential. A `--root-key` flag substitutes a local key for testing and says so in its output, so
that run is never mistaken for a check against the console's real roots.

## Obfuscating a build

DuploCloud's own extensions ship with their backend assembly obfuscated by ArmDot, the same protection the
platform's assemblies carry. Only the extension's own assembly is processed. The SDK assemblies the host
provides never ship in the bundle, so they are never touched. ArmDot runs with control-flow obfuscation and
code virtualization only. Renaming and string hiding stay off, because both break the reflection the host
uses to load an extension.

Obfuscation runs when `ARMDOT_LICENSE_FILE_PATH` names an ArmDot license file, and only for Release builds.
`build-extension.sh` passes the license into the builder container and drops a temporary
`Directory.Build.targets` beside the extension's csproj, so the extension's own project file never changes. An
extension that already has its own `Directory.Build.targets` in its `backend/` directory is refused, since the
build would overwrite it. A relative license path is taken relative to the directory you run the script from.

A license problem fails the build rather than ship an unprotected or expiring assembly. A path that does not name
a non-empty file is refused before anything compiles. A license file ArmDot rejects fails the build too.

An obfuscated bundle's `manifest.json` carries `"obfuscation": {"tool": "armdot", "version": "<engine
version>"}`, and a plain bundle carries no `obfuscation` key, so a release step can tell the two apart. The
release action refuses a bundle from a DuploCloud organization that carries no `obfuscation` key, so every
DuploCloud release ships obfuscated. The license is DuploCloud's, so a customer's build is plain and needs nothing.

## In DuploCloud's organizations

Signing is mandatory in `duplocloud` and `duplocloud-internal`. A repository there sets these secrets and
organization variables:

| Name | Kind | Holds |
| --- | --- | --- |
| `CONSOLE_SIGNING_KEY` | Secret, granted per repository | The publisher's private key PEM |
| `CONSOLE_API_KEY` | Secret, granted per repository | The console API key used to register versions and artifacts |
| `CONSOLE_SIGNING_CERT` | Organization variable | The publisher's certificate. The same value for every repository |
| `EXTENSION_PUBLISHER_ROLE_ARN` | Organization variable | The AWS role the workflow assumes, by name, to write to the channels bucket |
| `ARMDOT_LICENSE_KEY` | Organization secret | Base64 of DuploCloud's ArmDot license file. The reusable release action decodes it to the file `build-extension.sh` reads, so every build it runs obfuscates |

`release.yml` hands all five to the action. In these organizations the action fails the job before the build
when the signing key, the certificate, the ArmDot license or the console key is missing, rather than ship an
unsigned, unprotected or unregistered build. `EXTENSION_PUBLISHER_ROLE_ARN` is assumed through GitHub's OIDC
token (`permissions: id-token: write`) before the action runs, and only a repository the role's trust list
names can assume it, so a repository outside that list fails at the credentials step, before anything is built.

### One-time console setup

A platform owner sets up each of these once in the console. Each one then serves every release.

1. **The API key behind `CONSOLE_API_KEY`.** In the platform-owner team, create a custom role holding
   **View agent versions**, **Manage agent versions** and `view_agents`, create a service account
   with that role, and store its API key as the organization secret. The action looks the extension up by
   manifest id on the console's staff routes, which is what `view_agents` covers, then reads and creates
   versions and artifacts, and publishes a version when the run asks for it. Manage agent versions covers
   publishing. The console's own guide covers the service-account workflow in
   `docs/platform_owner/agent-versions.md`.
2. **The signing key behind `CONSOLE_SIGNING_KEY` and `CONSOLE_SIGNING_CERT`.** The publishing team needs a
   namespace covering its manifest ids, and a signing key created under that team. The console returns the
   key's private PEM once, at creation, and that goes into the secret. The key's certificate goes into the
   organization variable.
3. **One extension record per extension.** Create it under the same publishing team, with a manifest id
   that equals the `id` in the extension's `manifest.json`. The action finds the record by that id and fails
   the job when none exists, and the console accepts a signed artifact only when the signature's manifest id
   matches the record and the signing key belongs to the record's team. The console's API only reads
   extension records, so this step happens in the console.

### The role trust

The AWS role's trust policy, held in ai-release's Terraform (`terraform/modules/release-channels`), names
the repositories whose `main` may assume the publisher role, and that trust is what lets a workflow run write
to the bucket. A DuploCloud repository joins it through an ai-release PR that adds the repository, with its
GitHub OIDC subject prefix, to `extension_publisher_repositories` in `terraform/prod/main.tf`, and an
ai-release maintainer applies it. Until then its release fails at the credentials step.

Changes to `release.yml`, the signer and its `extension-sign.requirements.txt` are meant to take two
approvals from the `devkit-maintainers` team, through a path-scoped rule in devkit's ruleset. `release.yml`
pins the release action to a commit, so a move to a newer action is an edit that rule covers. The signer and
its requirements file here serve the composite `extension-sign` action only. A release signs with the
action's own copy of `extension-sign.py` and its own pinned requirements, which live in `duplocloud/actions`,
under that repository's review.

## The channels bucket and the license server

In DuploCloud's organizations a signed build uploads to
`s3://duplo-helpdesk-channels/bundles/[id]/[version]/sdk-[sdkVersion]/` in `us-west-2`, as two objects,
`extension.zip` and `extension.zip.sig`, with the assumed role. Both the bucket name and the console URL can be
overridden with the `BUNDLE_BUCKET` and `CONSOLE_URL` repository variables. Left unset, they default to the
production bucket and the production console. Elsewhere the action asks the console for an upload URL with the
console key and uploads through that, so the bucket is never named.

Every write is create-only, and the action's README under "Re-runs" has the resume rules: a release at an
existing tag is read back rather than rebuilt or re-signed, an artifact whose path, hash and signature match is
reported as already registered, and a run that stopped between any two steps finishes on the next run. A
registered artifact that differs from the release fails the job, since a published build is never replaced.
Every version it creates starts unpublished.

### Publishing on register

Publishing a version is what ships its build to every entitled install, so it is opt-in. Start the Extension
Release workflow by hand with its `publish` input checked. That run publishes every version it registers a
first build for, after the build is uploaded and its artifact is registered and matches the release. A version
that is already published is left alone, and so is one an earlier run registered or a platform owner
unpublished, so a platform owner publishes those in the console. The console key that registers versions can
also publish them, since one capability covers both.

## Certificate reissue and key rotation

Reissuing the certificate alone, which a platform owner does as it nears expiry, changes only the
`CONSOLE_SIGNING_CERT` organization variable, to the new certificate from the console's signing-keys page.
`CONSOLE_SIGNING_KEY` does not change, since the underlying key is the same one the new certificate still
certifies.

Rotating the key changes both. A new key needs a new certificate that names its public half, so
`CONSOLE_SIGNING_KEY` and `CONSOLE_SIGNING_CERT` have to move together. The signer checks that the key's
public half matches the certificate's before it signs anything, so updating one without the other fails
every release in DuploCloud's organizations until both are in place.

## Re-running a release

A tag that already has a release is never rebuilt, re-signed, or recreated. The action reads that release's own
assets and resumes from there, so a run that failed partway, during the upload or the registration, can simply
be re-run. Everything it already finished is a create-only no-op, and it picks up where it stopped.

A release that was cut before its repository started signing has no `.sig` asset, and it cannot gain one
afterward. Once immutable releases are turned on for a repository, which this workflow recommends, nothing
can be added to a release after it is cut. The action does not skip that release. It reads back the
`extension.zip` alone and registers the build with an empty signature, as it does for any unsigned build.
Outside DuploCloud's organizations it then uploads through the console-issued URL and the run ends clean. In
DuploCloud's organizations the upload writes two objects through the publisher role, so the run fails at the
`.sig` upload, after the unsigned build is registered. The way to a signed build is a new `manifest.version`,
which cuts a new tag and a new release that does get signed.
