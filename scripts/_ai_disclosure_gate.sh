#!/usr/bin/env bash
# ISO 42001: an Agent-mode extension (non-empty manifest skillMappings) must render <app-ai-disclosure /> on its forms.
# Sourced by build-extension.sh and tests; defines ai_disclosure_gate <extension-dir>.

# Prints the extension's ng-common-lib X.Y.Z (lockfile first, then package.json); empty if unknown.
_ai_disclosure_lib_version() {
  local dir="$1" v=""
  if [ -f "$dir/frontend/package-lock.json" ]; then
    v=$(jq -r '.packages["node_modules/@duplocloud-internal/ng-common-lib"].version // empty' "$dir/frontend/package-lock.json" 2>/dev/null) || v=""
  fi
  if [ -z "$v" ] && [ -f "$dir/frontend/package.json" ]; then
    v=$(jq -r '(.dependencies // {})["@duplocloud-internal/ng-common-lib"] // (.devDependencies // {})["@duplocloud-internal/ng-common-lib"] // empty' "$dir/frontend/package.json" 2>/dev/null) || v=""
  fi
  printf '%s\n' "$v" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true
}

# True when X.Y.Z is below 0.4.0 (major, then minor).
_ai_disclosure_lt_040() {
  local major="${1%%.*}" rest="${1#*.}"
  local minor="${rest%%.*}"
  [ "$major" -lt 0 ] || { [ "$major" -eq 0 ] && [ "$minor" -lt 4 ]; }
}

ai_disclosure_gate() {
  local dir="$1"
  local mappings
  if ! mappings=$(jq -r '(.skillMappings // []) | length' "$dir/manifest.json" 2>/dev/null); then
    echo "  ✗ cannot read skillMappings from $dir/manifest.json (invalid JSON?)" >&2
    return 1
  fi
  [ "$mappings" -gt 0 ] || return 0
  # The copied wizard-stepper always contains the tag, so it does not count.
  if grep -rqs --include='*.ts' --include='*.html' --exclude='wizard-stepper.component.ts' '<app-ai-disclosure' "$dir/frontend/src"; then
    return 0
  fi
  if grep -rqsF --include='*.ts' --include='*.html' '[aiDisclosure]="true"' "$dir/frontend/src"; then
    return 0
  fi
  local ver
  ver=$(_ai_disclosure_lib_version "$dir")
  if [ -n "$ver" ] && _ai_disclosure_lt_040 "$ver"; then
    echo "  ! Agent-mode extension on ng-common-lib $ver renders no <app-ai-disclosure /> — upgrade to >= 0.4.0 and add it (docs/UPGRADING-ng-common-lib.md); not enforced below 0.4.0" >&2
    return 0
  fi
  echo "  ✗ Agent-mode extension (manifest skillMappings) renders no <app-ai-disclosure /> under frontend/src — add it to every Add/Edit form (reference/14-forms-and-wizards.md, \"AI-use disclosure\")" >&2
  return 1
}
