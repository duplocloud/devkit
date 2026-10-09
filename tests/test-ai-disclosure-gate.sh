#!/usr/bin/env bash
# Tests for scripts/_ai_disclosure_gate.sh — Agent-mode extensions must render <app-ai-disclosure>.
# Builds throwaway extension dirs; never touches samples. Usage: ./tests/test-ai-disclosure-gate.sh
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1

PASS=0; FAIL=0
t()   { printf '  %s … ' "$1"; }
ok()  { echo "ok"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

. ./scripts/_ai_disclosure_gate.sh || { echo "scripts/_ai_disclosure_gate.sh not found"; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkext() {  # mkext <name> <manifest-json> [file-with-tag]
  local d="$WORK/$1"; mkdir -p "$d/frontend/src/app"
  printf '%s' "$2" > "$d/manifest.json"
  echo "export class X {}" > "$d/frontend/src/app/x.component.ts"
  [ -z "${3-}" ] || echo '<app-ai-disclosure />' > "$d/frontend/src/app/$3"
  echo "$d"
}

echo "ai disclosure gate:"

t "fails an Agent-mode extension without the tag"
d=$(mkext agent-missing '{"skillMappings":[{"originType":"X","skillNames":["s"]}]}')
if ai_disclosure_gate "$d" 2>/dev/null; then bad "returned 0"; else ok; fi

t "passes an Agent-mode extension with the tag in a .ts template"
d=$(mkext agent-ts '{"skillMappings":[{"originType":"X","skillNames":["s"]}]}' add.component.ts)
if ai_disclosure_gate "$d" 2>/dev/null; then ok; else bad "returned 1"; fi

t "passes an Agent-mode extension with the tag in a .html template"
d=$(mkext agent-html '{"skillMappings":[{"originType":"X","skillNames":["s"]}]}' add.component.html)
if ai_disclosure_gate "$d" 2>/dev/null; then ok; else bad "returned 1"; fi

t "passes a Worker extension (no skillMappings) without the tag"
d=$(mkext worker '{"resources":[]}')
if ai_disclosure_gate "$d" 2>/dev/null; then ok; else bad "returned 1"; fi

t "treats an empty skillMappings array as non-Agent"
d=$(mkext empty '{"skillMappings":[]}')
if ai_disclosure_gate "$d" 2>/dev/null; then ok; else bad "returned 1"; fi

t "fails closed on an unreadable manifest"
d=$(mkext broken '{"skillMappings": [')
if ai_disclosure_gate "$d" 2>/dev/null; then bad "returned 0"; else ok; fi

t "names the fix in its error"
d=$(mkext agent-msg '{"skillMappings":[{"originType":"X","skillNames":["s"]}]}')
msg=$(ai_disclosure_gate "$d" 2>&1 >/dev/null || true)
case "$msg" in *app-ai-disclosure*14-forms-and-wizards*) ok ;; *) bad "$msg" ;; esac

AG='{"skillMappings":[{"originType":"X","skillNames":["s"]}]}'
lock() {  # lock <dir> <version>
  printf '{"packages":{"node_modules/@duplocloud-internal/ng-common-lib":{"version":"%s"}}}' "$2" > "$1/frontend/package-lock.json"
}

t "warns (returns 0) below ng-common-lib 0.4.0"
d=$(mkext old-lib "$AG"); lock "$d" 0.3.0
msg=$(ai_disclosure_gate "$d" 2>&1 >/dev/null) && rc=0 || rc=$?
case "$rc:$msg" in 0:*"not enforced below 0.4.0"*) ok ;; *) bad "rc=$rc $msg" ;; esac

t "enforces at ng-common-lib 0.4.0"
d=$(mkext new-lib "$AG"); lock "$d" 0.4.0
if ai_disclosure_gate "$d" 2>/dev/null; then bad "returned 0"; else ok; fi

t "does not count the copied wizard-stepper tag"
d=$(mkext wiz-only "$AG" wizard-stepper.component.ts)
if ai_disclosure_gate "$d" 2>/dev/null; then bad "returned 0"; else ok; fi

t "passes when a wizard sets [aiDisclosure]=\"true\""
d=$(mkext wiz-flag "$AG" wizard-stepper.component.ts)
echo '<wizard-stepper [aiDisclosure]="true"></wizard-stepper>' > "$d/frontend/src/app/wiz.component.html"
if ai_disclosure_gate "$d" 2>/dev/null; then ok; else bad "returned 1"; fi

echo; echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
