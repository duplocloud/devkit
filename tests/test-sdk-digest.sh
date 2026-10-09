#!/usr/bin/env bash
# Tests for scripts/_sdk_digest.sh — the sdkDigest build-extension.sh stamps into a bundle's manifest.
# Usage: ./tests/test-sdk-digest.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

PASS=0; FAIL=0
t()   { printf '  %s … ' "$1"; }
ok()  { echo "ok"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
. ./scripts/_sdk_digest.sh || { echo "scripts/_sdk_digest.sh not found"; exit 1; }

# The definition, computed independently: sha256 over "<sha256>  <path>\n" per file, sorted by path bytewise.
expected() {
  python3 - "$1" <<'PY'
import hashlib, os, sys
root = sys.argv[1]; lines = []
for d, _, fs in os.walk(root):
    for f in fs:
        p = os.path.join(d, f); rel = os.path.relpath(p, root)
        lines.append((rel.encode(), hashlib.sha256(open(p, "rb").read()).hexdigest()))
lines.sort()
print(hashlib.sha256(b"".join(h.encode() + b"  " + r + b"\n" for r, h in lines)).hexdigest())
PY
}

mkfeed() {
  FEED="$TMP/feed.$RANDOM"; mkdir -p "$FEED/sub"
  echo a > "$FEED/Duplocloud.AiHelpdesk.Sdk.1.0.6.nupkg"; echo b > "$FEED/B.nupkg"; echo c > "$FEED/sub/c.nupkg"
}

echo "sdk digest:"

t "matches the definition: sha256 of sorted '<sha256>  <path>' lines"
mkfeed
if [ "$(sdk_digest "$FEED")" = "$(expected "$FEED")" ]; then ok; else bad "$(sdk_digest "$FEED") != $(expected "$FEED")"; fi

t "changes when one package's bytes change"
mkfeed; before="$(sdk_digest "$FEED")"; echo changed > "$FEED/B.nupkg"
if [ "$(sdk_digest "$FEED")" != "$before" ]; then ok; else bad "unchanged: $before"; fi

t "changes when a package is added"
mkfeed; before="$(sdk_digest "$FEED")"; echo d > "$FEED/D.nupkg"
if [ "$(sdk_digest "$FEED")" != "$before" ]; then ok; else bad "unchanged: $before"; fi

t "does not depend on where the feed sits or the caller's cwd"
mkfeed; a="$(sdk_digest "$FEED")"; cp -R "$FEED" "$TMP/moved"; b="$( cd / && sdk_digest "$TMP/moved" )"
if [ "$a" = "$b" ]; then ok; else bad "$a != $b"; fi

t "fails on an empty feed rather than stamping the digest of nothing"
mkdir -p "$TMP/empty"
if ! sdk_digest "$TMP/empty" >/dev/null 2>&1; then ok; else bad "returned $(sdk_digest "$TMP/empty")"; fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
