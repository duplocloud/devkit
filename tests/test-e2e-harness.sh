#!/usr/bin/env bash
# Contract tests for tests/e2e/cloud_onboarding_e2e.py against a scripted fake studio (real SSE framing,
# pending-approval round trips, persisted executed_cmds) and a fake container CLI. Nothing live is touched;
# these pin how the harness judges a run, not whether any stack works.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
echo "e2e harness contract:"
python3 -I -m py_compile tests/e2e/cloud_onboarding_e2e.py || exit 1
OUT="$(python3 -I tests/test_e2e_harness.py 2>&1)"
if printf '%s\n' "$OUT" | tail -1 | grep -q '^OK'; then
  printf '  tests/test_e2e_harness.py … ok (%s)\n' "$(printf '%s\n' "$OUT" | grep -E '^Ran ' | head -1)"
else
  echo "  tests/test_e2e_harness.py … FAIL"; printf '%s\n' "$OUT" | tail -30; exit 1
fi
