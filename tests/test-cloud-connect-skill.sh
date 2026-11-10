#!/usr/bin/env bash
# Structural checks for the /duplo-cloud-connect skill rename, plus EXECUTED checks that run.sh's opt-in
# onboarding prompt never prompts or hangs off a terminal. No Docker, no credentials, no network.
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

BLOCK="$(sed -n '/optional cloud onboarding hint/,$p' run.sh)"

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

echo; echo "cloud-connect skill: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
