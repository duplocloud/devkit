# shellcheck shell=bash
# Sourced by scripts/build-extension.sh — fingerprints the SDK feed a bundle was compiled against.
#
# sdkVersion alone does not identify an SDK: the host's SDK surface and dependency floors can move under an
# unchanged version, so a bundle that fails at run time could be a broken extension or one built against a drifted
# SDK. build-extension.sh stamps this digest beside sdkVersion so the two can be told apart by recomputing it over
# the host's own sdk-bundle.
#
# Definition (anything recomputing it must match this exactly): for every file in the extracted SDK bundle, the line
# "<sha256 hex>  <path relative to the bundle root>\n"; the lines sorted bytewise by path; sdkDigest is the lowercase
# sha256 hex of their concatenation. That is `sha256sum` output over the sorted file list, hashed once more.

# _sdk_sha256 [file] -> lowercase sha256 hex of the file (or stdin). sha256sum on Linux, shasum on macOS.
_sdk_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@" | cut -d' ' -f1
  else shasum -a 256 "$@" | cut -d' ' -f1; fi
}

# sdk_digest <extracted-sdk-bundle-dir> -> sdkDigest on stdout. Fails on a directory with no files.
sdk_digest() {
  local root="${1:?usage: sdk_digest <dir>}" files
  files="$(cd "$root" && find . -type f | sed 's|^\./||' | LC_ALL=C sort)"
  [ -n "$files" ] || { echo "ERROR: no files under $root to digest" >&2; return 1; }
  local f
  while IFS= read -r f; do
    printf '%s  %s\n' "$(_sdk_sha256 "$root/$f")" "$f"
  done <<<"$files" | _sdk_sha256
}
