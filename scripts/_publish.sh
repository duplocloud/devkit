# shellcheck shell=bash
# Sourced by scripts/release-extensions.sh. Signing is mandatory in Duplo's two organizations and skipped anywhere
# else, so a customer copy of the release workflow behaves as before with no Duplo credential. Upload and registration
# run only in Duplo's organizations, for a manifest id the allowlist maps to this repository. A registered version
# stays unpublished unless the caller sets publish_version (scripts/release-extensions.sh, from the allowlist entry's
# "publish" or a manual run's publish input).

# duplo_org: exit 0 when this run belongs to one of Duplo's organizations.
duplo_org() { case "${GITHUB_REPOSITORY_OWNER:-}" in duplocloud|duplocloud-internal) return 0 ;; *) return 1 ;; esac; }

bundle_bucket="${BUNDLE_BUCKET:-duplo-helpdesk-channels}"
console_url="${CONSOLE_URL:-https://console.duplocloud.com}"

# s3_put_once <file> <key>: create-only upload. A 412 compares bytes, identical counting as already uploaded.
s3_put_once() {
  local file=$1 key=$2 out have
  if out="$(aws s3api put-object --bucket "$bundle_bucket" --key "$key" --body "$file" --if-none-match '*' 2>&1)"; then
    echo "==> uploaded s3://$bundle_bucket/$key"; return 0
  fi
  if ! grep -qE 'PreconditionFailed|\(412\)' <<<"$out"; then echo "::error::upload of $key failed: $out"; return 1; fi
  have="$(mktemp)"
  aws s3api get-object --bucket "$bundle_bucket" --key "$key" "$have" >/dev/null || { rm -f "$have"; return 1; }
  if cmp -s "$file" "$have"; then rm -f "$have"; echo "==> $key already uploaded, identical bytes"; return 0; fi
  rm -f "$have"; echo "::error::s3://$bundle_bucket/$key already holds different bytes. A published build is never replaced."
  return 1
}

# console <method> <path> [json]: one console API call. The key reaches curl through a header file, never argv.
console() {
  local hdr body
  hdr="$(mktemp)"; chmod 600 "$hdr"; printf 'Authorization: Api-Key %s\n' "$CONSOLE_API_KEY" > "$hdr"
  if [ -n "${3:-}" ]; then
    body="$(curl -sS --fail-with-body -X "$1" -H @"$hdr" -H 'Content-Type: application/json' --data "$3" "$console_url$2")"
  else
    body="$(curl -sS --fail-with-body -X "$1" -H @"$hdr" "$console_url$2")"
  fi
  local rc=$?; rm -f "$hdr"; printf '%s' "$body"; return $rc
}

# artifact_body <key> <sdk> <sha> <sigfile>: the artifact record publish_build registers, and compares an existing one to.
artifact_body() {
  jq -n --arg p "s3://$bundle_bucket/$1" --arg s "$2" --arg h "$3" --rawfile g "$4" \
    '{sdk_version: $s, s3_path: $p, sha256: $h, signature: $g}'
}

# artifact_matches <lookup> <artifact>: exit 0 when the lookup's first artifact has the same path, hash and signature.
artifact_matches() {
  jq -e --argjson a "$2" '.[0] | .s3_path == $a.s3_path and (.sha256 | ascii_downcase) == $a.sha256 and .signature == $a.signature' \
    <<<"$1" >/dev/null
}

# maybe_publish <tag> <version uuid> <new|existing>: mark the version published when publish_version allows it and it
# is not already. publish_version=new publishes only a build this call newly registered, so a push that resumes an
# existing tag never publishes and a deliberate unpublish sticks. publish_version=any, a manual run's choice, also
# publishes a build an earlier run registered. Runs only after the build's artifact is registered and matches the
# release, so a version is never published ahead of the build it ships.
maybe_publish() {
  case "${publish_version:-}" in
    any) ;;
    new) [ "$3" = new ] || return 0 ;;
    *) return 0 ;;
  esac
  local tag=$1 vuuid=$2 out
  out="$(console GET "/api/extensions/$uuid/versions/$vuuid/")" \
    || { echo "::error::$tag — console lookup of the version to publish failed: $out"; return 1; }
  if jq -e '.is_published == true' <<<"$out" >/dev/null; then echo "==> $tag's version is already published"; return 0; fi
  out="$(console PATCH "/api/extensions/$uuid/versions/$vuuid/" '{"is_published": true}')" \
    || { echo "::error::$tag — console refused to publish the version: $out"; return 1; }
  echo "==> published $tag in the license server"
}

# publish_build <tag> <id> <version> <sdk> <dir>: upload the Release's zip and .sig, then register both. Reads the
# assets from the Release so a re-run reuses the bytes already signed and released, with no rebuild.
#
# A finished build stops early. Registration runs only after both uploads, so a registered artifact matching the
# Release's digest and .sig means both objects are already in the bucket, and the run needs neither the zip nor S3.
publish_build() {
  local tag=$1 id=$2 version=$3 sdk=$4 v dl localsha sha key vuuid out art
  for v in "$id" "$version" "$sdk"; do
    [[ "$v" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo "::error::$tag — $v cannot form a bucket key."; return 1; }
  done
  key="bundles/$id/$version/sdk-$sdk/extension.zip"
  sha="$(gh api "repos/{owner}/{repo}/releases/tags/$tag" --jq '.assets[] | select(.name == "extension.zip") | .digest // empty')" \
    || { echo "::error::$tag — cannot read its release digest."; return 1; }
  sha="${sha#sha256:}"
  dl="$(mktemp -d)"
  gh release download "$tag" -p extension.zip.sig -D "$dl" \
    || { echo "::error::$tag — cannot download its signature."; rm -rf "$dl"; return 1; }

  # Without a digest there is no hash to compare before the zip is downloaded, so the full path below runs.
  if [ -n "$sha" ]; then
    out="$(console GET "/api/extensions/$uuid/versions/?version=$version")" \
      || { echo "::error::$tag — console lookup of the version failed: $out"; rm -rf "$dl"; return 1; }
    vuuid="$(jq -r '.[0].uuid // empty' <<<"$out")"
    if [ -n "$vuuid" ]; then
      out="$(console GET "/api/extensions/$uuid/versions/$vuuid/artifacts/?sdk_version=$sdk")" \
        || { echo "::error::$tag — console lookup of the artifact failed: $out"; rm -rf "$dl"; return 1; }
      if artifact_matches "$out" "$(artifact_body "$key" "$sdk" "$sha" "$dl/extension.zip.sig")"; then
        echo "==> $tag already uploaded and registered"; rm -rf "$dl"; maybe_publish "$tag" "$vuuid" existing; return
      fi
    fi
  fi

  gh release download "$tag" -p extension.zip -D "$dl" \
    || { echo "::error::$tag — cannot download its assets."; rm -rf "$dl"; return 1; }
  # The local hash is always computed and is what gets registered. GitHub's own digest, when the release carries
  # one, only confirms the download matches what was actually released, before anything is uploaded or registered.
  localsha="$(shasum -a 256 "$dl/extension.zip" | cut -d' ' -f1)"
  if [ -n "$sha" ]; then
    [ "$sha" = "$localsha" ] \
      || { echo "::error::$tag — release digest $sha does not match downloaded extension.zip hash $localsha."; rm -rf "$dl"; return 1; }
  else
    sha="$localsha"
  fi
  s3_put_once "$dl/extension.zip" "$key" && s3_put_once "$dl/extension.zip.sig" "$key.sig" || { rm -rf "$dl"; return 1; }

  out="$(console GET "/api/extensions/$uuid/versions/?version=$version")" \
    || { echo "::error::$tag — console lookup of the version failed: $out"; rm -rf "$dl"; return 1; }
  vuuid="$(jq -r '.[0].uuid // empty' <<<"$out")"
  if [ -z "$vuuid" ]; then
    out="$(console POST "/api/extensions/$uuid/versions/" "$(jq -n --arg v "$version" --arg n "$id $version" '{version: $v, name: $n}')")" \
      || grep -q "already exists" <<<"$out" || { echo "::error::$tag — console refused the version: $out"; rm -rf "$dl"; return 1; }
    out="$(console GET "/api/extensions/$uuid/versions/?version=$version")" \
      || { echo "::error::$tag — console lookup of the version failed: $out"; rm -rf "$dl"; return 1; }
    vuuid="$(jq -r '.[0].uuid // empty' <<<"$out")"
  fi
  [ -n "$vuuid" ] || { echo "::error::$tag — the console has no version uuid for $version after creating it."; rm -rf "$dl"; return 1; }
  art="$(artifact_body "$key" "$sdk" "$sha" "$dl/extension.zip.sig")"
  out="$(console GET "/api/extensions/$uuid/versions/$vuuid/artifacts/?sdk_version=$sdk")" \
    || { echo "::error::$tag — console lookup of the artifact failed: $out"; rm -rf "$dl"; return 1; }
  if [ "$(jq 'length' <<<"$out")" -gt 0 ]; then
    if artifact_matches "$out" "$art"; then
      echo "==> $tag already registered"; rm -rf "$dl"; maybe_publish "$tag" "$vuuid" existing; return
    fi
    echo "::error::$tag — the console already holds a build for SDK $sdk that differs from this release."; rm -rf "$dl"; return 1
  fi
  out="$(console POST "/api/extensions/$uuid/versions/$vuuid/artifacts/" "$art")" \
    || { echo "::error::$tag — console refused the artifact: $out"; rm -rf "$dl"; return 1; }
  echo "==> registered $tag in the license server"; rm -rf "$dl"
  maybe_publish "$tag" "$vuuid" new
}
