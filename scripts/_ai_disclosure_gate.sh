#!/usr/bin/env bash
# ISO 42001: an Agent-mode extension (non-empty manifest skillMappings) must render <app-ai-disclosure /> on its forms.
# Sourced by build-extension.sh and tests; defines ai_disclosure_gate <extension-dir>.

ai_disclosure_gate() {
  local dir="$1"
  local mappings
  if ! mappings=$(jq -r '(.skillMappings // []) | length' "$dir/manifest.json" 2>/dev/null); then
    echo "  ✗ cannot read skillMappings from $dir/manifest.json (invalid JSON?)" >&2
    return 1
  fi
  [ "$mappings" -gt 0 ] || return 0
  if grep -rqs --include='*.ts' --include='*.html' 'app-ai-disclosure' "$dir/frontend/src"; then
    return 0
  fi
  echo "  ✗ Agent-mode extension (manifest skillMappings) renders no <app-ai-disclosure /> under frontend/src — add it to every Add/Edit form (reference/14-forms-and-wizards.md, \"AI-use disclosure\")" >&2
  return 1
}
