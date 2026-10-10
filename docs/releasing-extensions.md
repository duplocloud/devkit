# Releasing extensions

`.github/workflows/release.yml` runs on every push to `main` and on a manual dispatch. For each
`extensions/*/manifest.json`, plus the single-extension layouts `extension/manifest.json` and
`extension/*/manifest.json`, it builds the bundle and hands it to `scripts/release-extensions.sh`, which
publishes one GitHub Release per build. This page covers what that run does, in any organization, and the
extra steps that apply only inside DuploCloud's own organizations, `duplocloud` and `duplocloud-internal`.

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
moved, when a `skills/` folder has no matching `skills[].folder` entry in the manifest, and when a webpack
frontend bundle ships without the file that Native Federation hosts need.

In `duplocloud` and `duplocloud-internal`, the release also carries `extension.zip.sig`, and, for an id the
allowlist maps to this repository, the build is uploaded to the channels bucket and registered as a new,
unpublished version with the license server. A version stays unpublished, for a platform owner to publish
once the build has been verified, unless the extension opts in to publishing (see "Publishing on register").

Outside those two organizations, a release ships the zip alone. A customer's copy of this workflow holds no
DuploCloud signing credential, so it signs nothing, uploads nothing, and registers nothing.

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

## In DuploCloud's organizations

Signing is mandatory in `duplocloud` and `duplocloud-internal`. A repository there sets two secrets and two
organization variables:

| Name | Kind | Holds |
| --- | --- | --- |
| `CONSOLE_SIGNING_KEY` | Secret, granted per repository | The publisher's private key PEM |
| `CONSOLE_API_KEY` | Secret, granted per repository | The console API key used to register versions and artifacts |
| `CONSOLE_SIGNING_CERT` | Organization variable | The publisher's certificate. The same value for every repository |
| `EXTENSION_PUBLISHER_ROLE_ARN` | Organization variable | The AWS role the workflow assumes, by name, to write to the channels bucket |

The workflow maps `CONSOLE_SIGNING_KEY` onto `EXTENSION_SIGNING_KEY` and `CONSOLE_SIGNING_CERT` onto
`EXTENSION_SIGNING_CERT` before calling the signer. Each of the four fails the job before anything is
written. A missing signing key or certificate fails each extension before it is signed or released, rather
than shipping an unsigned build. An allowlisted extension with no `CONSOLE_API_KEY` fails the same way,
before it is signed or released, since that build could never be registered. A missing
`EXTENSION_PUBLISHER_ROLE_ARN` fails the credentials step, which runs before the publish step. Only
`CONSOLE_SIGNING_KEY` and `CONSOLE_SIGNING_CERT` matter to a repository the allowlist does not name.

The role is only assumed for a repository the allowlist names, through GitHub's OIDC token
(`permissions: id-token: write`), so a repository that does not publish never needs AWS credentials at all.

### One-time console setup

A platform owner sets up each of these once in the console. Each one then serves every release.

1. **The API key behind `CONSOLE_API_KEY`.** In the platform-owner team, create a custom role holding
   **View extension versions** and **Manage extension versions**, create a service account with that role,
   and store its API key as the organization secret. The release job reads and creates versions and artifacts,
   and publishes a version when opted in. Manage extension versions covers publishing, and the allowlist
   supplies each extension's uuid, so the key needs no other capability. The console's own guide covers the
   service-account workflow in `docs/platform_owner/extension-versions.md`.
2. **The signing key behind `CONSOLE_SIGNING_KEY` and `CONSOLE_SIGNING_CERT`.** The publishing team needs a
   namespace covering its manifest ids, and a signing key created under that team. The console returns the
   key's private PEM once, at creation, and that goes into the secret. The key's certificate goes into the
   organization variable.
3. **One extension record per extension.** Create it under the same publishing team, with a manifest id
   that equals the `id` in the extension's `manifest.json`. The console accepts a signed artifact only when
   the signature's manifest id matches the record and the signing key belongs to the record's team. The
   console's API only reads extension records, so this step happens in the console, and the record's uuid is
   what the allowlist entry names.

### Joining the allowlist

`.github/extension-publishers.json` ships empty in devkit. Each entry maps one manifest id to one
repository and one console extension, with an optional `"publish": true` (see "Publishing on register"):

```json
{
  "schemaVersion": 1,
  "publishers": [
    { "manifestId": "duplo.extensions.your-extension", "repository": "duplocloud/your-repo", "consoleExtension": "[console extension uuid]" }
  ]
}
```

The `consoleExtension` uuid comes from the console's extensions page. Without an entry, or with one that
names a different repository, a build still signs and releases, since signing does not depend on the
allowlist, but the release job logs a notice and never uploads or registers it.

The allowlist alone is not the security boundary. The AWS role's trust policy, held in ai-release's
Terraform (`terraform/modules/release-channels`), names the same repositories, and that trust is what
actually lets a workflow run write to the bucket. A test in ai-release keeps the two lists equal against a
pinned devkit commit, so joining the allowlist takes a PR in both repositories: the entry here, and the
repository added to the role's trust list there. Either alone leaves the id unable to publish, refused by
AWS on one side or skipped by the allowlist check on the other.

Changes to this file, `release.yml`, `release-extensions.sh`, `_publish.sh`, `_publishers.sh` and the signer
are meant to take two approvals from the `devkit-maintainers` team, through a path-scoped rule in devkit's
ruleset. Together those files decide what gets signed, uploaded and registered.

## The channels bucket and the license server

A signed build uploads to `s3://duplo-helpdesk-channels/bundles/[id]/[version]/sdk-[sdkVersion]/` in
`us-west-2`, as two objects, `extension.zip` and `extension.zip.sig`. Both the bucket name and the console
URL can be overridden with the `BUNDLE_BUCKET` and `CONSOLE_URL` repository variables. Left unset, they
default to the production bucket and the production console.

A build that is already finished stops before any download of the zip or any S3 call. The script reads the
Release's digest for `extension.zip`, downloads only `extension.zip.sig`, and looks up the version and its
artifact for this SDK in the license server. An artifact whose path, hash and signature match is reported
as already published. Registration only ever follows both uploads, so a matching artifact means both objects
are already in the bucket. A failed lookup fails the job. Anything else takes the full path below.

Otherwise, before uploading, the script downloads both assets from the GitHub Release itself, never
rebuilding them, and recomputes the zip's sha256 locally. When the Release reports its own digest for that
asset, the script compares the two and fails the job on a mismatch, so a corrupted or substituted download
is never uploaded. The locally computed hash, not GitHub's, is what gets registered.

Every write from here on is create-only. The upload uses `aws s3api put-object --if-none-match '*'`, so it
never overwrites an existing key. When that fails with a 412, the script fetches what is already there and
compares bytes. Identical content counts as already uploaded and the run moves on. Different content fails
the job, since a published build is never replaced.

Registering the version with the license server follows the same shape. The script looks up the version by
its number before creating it, and an error saying the record already exists just means a concurrent run
created it first, so it looks up again rather than failing. It registers the artifact for this SDK the same
way, by looking it up before creating it. An existing artifact whose path, hash and signature all match
counts as already done. One that differs fails the job. Every version it creates starts unpublished.

### Publishing on register

Publishing a version is what ships its build to every entitled install, so it is opt-in, in either of two ways.

- **Per extension.** Set `"publish": true` on the extension's allowlist entry. A push to `main` then publishes a
  version when that run newly registers its build. A push that resumes a release an earlier run registered never
  publishes, so a version a platform owner unpublished stays unpublished.
- **Per run.** Start the Extension Release workflow by hand with its `publish` input checked. That run
  publishes every version it registers, and also a version an earlier run registered, since a person chose that
  run. It is also how to publish a version whose publish failed after registration.

Either way, the version is published only after its build is uploaded and its artifact is registered and
matches the release. A version that is already published is left alone. A repository builds against one SDK at
a time, so a version with builds for several SDKs is published once its first build is registered.

The release job reads the extension repository's own copy of the allowlist, so `"publish": true` is gated by
that repository's branch protection, not by devkit's review. Whoever can merge to the repository's `main` can turn
it on, much as they could change the release scripts the job runs. The console key that registers versions can
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

A tag that already has a release is never rebuilt, re-signed, or recreated. `release-extensions.sh` reads
that release's own assets and resumes from there, so a run that failed partway, during the upload or the
registration, can simply be re-run. Everything it already finished is a create-only no-op, and it picks up
where it stopped.

A release that was cut before its repository started signing, or outside DuploCloud's organizations, has no
`.sig` asset to resume from. It cannot gain one afterward. Once immutable releases are turned on for a
repository, which this workflow recommends, nothing can be added to a release after it is cut. That release
stays flagged with a warning and is skipped rather than retried. The only way forward is a new
`manifest.version`, which cuts a new tag and a new release that does get signed.
