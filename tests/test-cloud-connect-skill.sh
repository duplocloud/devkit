#!/usr/bin/env bash
# Structural checks for the /duplo-cloud-connect skill rename, plus EXECUTED checks that run.sh's opt-in
# onboarding prompt and the wizard it runs (scripts/cloud-connect-wizard.sh) never prompt or hang off a
# terminal, and the wizard's full mocked flow suite (tests/test_cloud_connect_wizard.py: fake connector,
# fake aws/gcloud, run.sh's block on a pty). No Docker, no credentials, no network.
# (Skill wording is deliberately not grepped: prose assertions are brittle.)
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
PASS=0; FAIL=0
t()   { printf '  %s … ' "$1"; }
ok()  { echo "ok"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

NEW=.claude/skills/duplo-cloud-connect/SKILL.md
DOC=docs/skills/duplo-cloud-connect/SKILL.md

echo "duplo-cloud-connect skill (structure):"

t "new skill dir exists; old installed skill and docs copy are gone"
if [ -f "$NEW" ] && [ -f "$DOC" ] && [ ! -e .claude/skills/duplo-connect-cloud ] && [ ! -e docs/skills/duplo-connect-cloud ]; then ok; else bad "stale or missing skill dir"; fi

t "frontmatter name matches the directory"
if [ "$(sed -n 's/^name: //p' "$NEW" | head -1)" = duplo-cloud-connect ]; then ok; else bad "name mismatch"; fi

t "no reference to the old name remains (except this file's own mentions)"
if grep -rIl 'duplo-connect-cloud' . --exclude-dir=.git --exclude-dir=node_modules --exclude=test-cloud-connect-skill.sh | grep -q .; then bad "stale references"; else ok; fi

t "internal scripts/connect-cloud.sh keeps its name"
if [ -f scripts/connect-cloud.sh ]; then ok; else bad "script missing"; fi

t "docs copy is identical to the installed skill"
if diff -q "$NEW" "$DOC" >/dev/null; then ok; else bad "copies differ"; fi

t ".agents/skills resolves to the installed skill"
if [ -f .agents/skills/duplo-cloud-connect/SKILL.md ]; then ok; else bad "symlink broken"; fi

echo "run.sh onboarding prompt (executed guards):"

BLOCK="$(sed -n '/^# ── optional cloud onboarding/,$p' run.sh)"

t "run.sh parses and the prompt block was found"
if bash -n run.sh && [ -n "$BLOCK" ]; then ok; else bad "syntax or block missing"; fi

# Each case runs the real block with a hard timeout (a prompt that waited would be killed, rc 124).
run_block() { # env-assignments... ; stdin is always /dev/null, stdout a pipe
  ( env "$@" bash -c "$BLOCK" </dev/null 2>&1 ) &
  local pid=$! n=0
  while kill -0 "$pid" 2>/dev/null; do
    n=$((n+1)); [ "$n" -gt 100 ] && { kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; echo "HUNG"; return; }
    sleep 0.1
  done
  wait "$pid" 2>/dev/null
}

t "no TTY (stdin/stdout not terminals): silent, returns immediately"
OUT="$(run_block NONINTERACTIVE=0 CI=)"; if [ -z "$OUT" ]; then ok; else bad "output: $OUT"; fi

t "--non-interactive: silent"
OUT="$(run_block NONINTERACTIVE=1 CI=)"; if [ -z "$OUT" ]; then ok; else bad "output: $OUT"; fi

t "CI set: silent"
OUT="$(run_block NONINTERACTIVE=0 CI=true)"; if [ -z "$OUT" ]; then ok; else bad "output: $OUT"; fi

t "the block runs the wizard (not a manual hand-off) and survives its failure"
if printf '%s' "$BLOCK" | grep -q './scripts/cloud-connect-wizard.sh --yes || CONNECT_RC=' && ! printf '%s' "$BLOCK" | grep -q 'start Claude Code'; then ok; else bad "wizard call missing"; fi

echo "cloud-connect wizard:"

t "wizard scripts are executable and syntactically valid"
if [ -x scripts/cloud-connect-wizard.sh ] && bash -n scripts/cloud-connect-wizard.sh \
   && python3 -I -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' scripts/cloud_connect_wizard.py; then ok; else bad "syntax or mode"; fi

# The REAL wrapper, off a terminal: it must refuse (rc 2) before asking or running anything — it is killed
# and reported as HUNG if it waits. Answers are offered on stdin to prove they are not consumed as consent.
run_wizard_notty() {
  ( printf 'y\n1\n2\n1\n' | env -u CLOUD_CONNECT_WIZARD_ALLOW_NO_TTY "$@" ./scripts/cloud-connect-wizard.sh 2>&1; echo "rc=$?" ) &
  local pid=$! n=0
  while kill -0 "$pid" 2>/dev/null; do
    n=$((n+1)); [ "$n" -gt 100 ] && { kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; echo "HUNG"; return; }
    sleep 0.1
  done
  wait "$pid" 2>/dev/null
}

t "wizard without a terminal: refuses with rc 2, asks nothing"
OUT="$(run_wizard_notty)"
case "$OUT" in *"needs a terminal"*"rc=2") case "$OUT" in *"Which cloud"*|*HUNG*) bad "prompted: $OUT" ;; *) ok ;; esac ;; *) bad "output: $OUT" ;; esac

t "wizard --help exits 0 and says Azure is not supported"
OUT="$(./scripts/cloud-connect-wizard.sh --help 2>&1)"; RC=$?
if [ "$RC" = 0 ] && printf '%s' "$OUT" | grep -q 'Azure is not supported'; then ok; else bad "rc=$RC: $OUT"; fi

t "mocked wizard flows (tests/test_cloud_connect_wizard.py)"
if OUT="$(PYTHONDONTWRITEBYTECODE=1 python3 tests/test_cloud_connect_wizard.py 2>&1)"; then ok; else bad "$(printf '%s' "$OUT" | tail -15)"; fi

echo; echo "cloud-connect skill: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
