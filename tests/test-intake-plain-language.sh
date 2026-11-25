#!/usr/bin/env bash
# Checks the extension intake that /duplo-extension and the in-product Extension ticket both run:
# the questions put to the user are in plain words, the command takes its questions from the skill,
# and the skill's file references point at real paths.
#
# The plain-words rule is checked on two table columns inside SKILL.md's "Talking to the user"
# subsection: "Ask the user" (the question table) and "What the agent says" (the four patterns).
# Those cells are what the agent reads out; the rest of SKILL.md is the agent's own checklist and
# keeps its technical names.
#
# Static only: reads markdown, starts nothing.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
PASS=0; FAIL=0
t()   { printf '  %s … ' "$1"; }
ok()  { echo "ok"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

SKILL=.claude/skills/duplo-extension-dev/SKILL.md
CMD=.claude/commands/duplo-extension.md
DOCS=(docs/quickstart.md docs/getting-started/build-your-first-extension.md)
# Platform words a first-time user cannot be expected to know. Plurals included.
BANNED='\b(specs?|results?|resources?|scopes?|providers?|provisioning|modes?|crud|endpoints?|controllers?|fe|section ids?|origintypes?|remotes?)\b'

# The "Talking to the user" subsection: from its heading to the next ## or ### heading.
# `|| true`: under pipefail, `talking | grep -q` would otherwise fail whenever grep exits on its first match while
# awk is still writing (SIGPIPE), which made these checks pass or fail by timing.
talking() { awk '/^### Talking to the user/{on=1; print; next} on && /^##+ /{exit} on' "$SKILL" || true; }

# Prints the cells of every table column whose header is exactly "$1", one per line.
column_cells() {
  talking | awk -F'|' -v want="$1" '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    /^\|/ {
      if (!intable) { intable=1; col=0; for (i=2; i<NF; i++) if (trim($i)==want) col=i; next }
      if ($0 ~ /^\|[ \t:|-]+\|[ \t]*$/) next
      if (col) print trim($col)
      next
    }
    { intable=0; col=0 }'
}

t "SKILL.md has a 'Talking to the user' subsection inside Phase 1"
if awk '/^## Phase 1/{p=1} /^## Phase 2/{p=0} p && /^### Talking to the user/{f=1} END{exit !f}' "$SKILL"; then ok
else bad "no '### Talking to the user' between '## Phase 1' and '## Phase 2'"; fi

for col in "Ask the user" "What the agent says"; do
  t "the '$col' column exists and holds no platform words"
  cells=$(column_cells "$col")
  if [ -z "$cells" ]; then bad "no '$col' column in the subsection"
  elif hits=$(printf '%s\n' "$cells" | grep -inE "$BANNED"); then bad "platform words in: $hits"
  else ok; fi
done

t "the four patterns carry their plain names"
missing=""
for name in "Background job" "AI agent" "Instant" "Read-only"; do talking | grep -q "$name" || missing+=" '$name'"; done
[ -z "$missing" ] && ok || bad "missing:$missing"

t "the in-product pause is one yes_no ask, re-posted as Blocked before every ask"
if ! grep -q "Review what I'll build" "$SKILL" || ! grep -q "Build this?" "$SKILL" || ! grep -q "before every ask" "$SKILL"; then
  bad "pause wording missing from $SKILL"
elif grep -q "Change something" "$SKILL"; then
  bad "'Change something' duplicates the platform's own 'Chat about this' row"
else ok; fi

t "the four always-ask guesses ride the pause when they are all the batch holds, and the summary names it"
if talking | grep -q "ride the pause" && talking | grep -qi "its name"; then ok
else bad "no 'ride the pause' exception or no name in What you'll get"; fi

t "Agent is always asked, offers a position, and a new section always gets an order"
if talking | grep -q 'Always ask:\*\* the Name, Agent,' \
   && talking | grep '^| Agent |' | grep -q 'just above \*\*Settings\*\*' \
   && grep -q 'always\*\* the object form with an order' "$SKILL"; then ok
else bad "Agent not always asked, no position offered, or a new section may omit its order"; fi

t "Technical details is the one place checklist terms reach the user"
talking | grep -q 'except under \*\*Technical details\*\*' && ok || bad "never-say rule has no Technical details exception"

t "the one-or-many question skips a thing that only uses another"
talking | grep "^| One or many" | grep -q "only uses" && ok || bad "one-or-many row fires on the admin + consumer shape"

t "SKILL.md no longer asks for a menu 'section id'"
grep -qi "section id /" "$SKILL" && bad "the 'section id / top-level / none' question is still in $SKILL" || ok

t "SKILL.md copies the scaffold from the repo root, wherever the shell is"
if grep -q 'dirname "\$0"' "$SKILL"; then bad "\$(dirname \"\$0\") resolves to the shell in Claude's Bash"
elif ! grep -B2 'templates/helloworld" "extensions/<name>"' "$SKILL" | grep -q 'git rev-parse --show-toplevel'; then
  bad "the template copy is not anchored to the repo root"
elif grep -q "scaffold into the ticket workdir instead" "$SKILL"; then
  bad "SKILL.md still sends the in-platform scaffold to the ticket workdir, where the template is absent"
else ok; fi

t "SKILL.md does not call the public devkit repo private"
grep -q "PRIVATE" "$SKILL" && bad "'PRIVATE' still in $SKILL" || ok

t "SKILL.md's reference index labels the admin-resources guide by its file number"
grep -q "22-admin-resources" "$SKILL" && bad "'22-admin-resources' label still present" || ok

t "the command takes its questions from the skill"
if ! grep -q "Talking to the user" "$CMD"; then bad "no pointer to 'Talking to the user' in $CMD"
elif hits=$(grep -nE "ParentRefSpec|consumed by the FE|named action" "$CMD"); then bad "own question list still in $CMD: $hits"
else ok; fi

step() { awk -v h="## Step $1" 'index($0,h)==1{on=1; next} on && /^## /{exit} on' "$CMD" || true; }
t "the command asks once: no separate name or connection round before Step 4"
if step 2 | grep -q "for the user to"; then bad "Step 2 still asks the user to confirm the name"
elif step 3 | grep -q "Which saved connection should I use"; then bad "Step 3 still asks for the connection"
elif ! step 4 | grep -qi "saved connection"; then bad "Step 4's batch does not carry the connection question"
elif grep -q "ask which one(s) to use" "$CMD"; then bad "admin path still asks which scope(s) in jargon"
else ok; fi

t "the admin Workspace attach is Step 5's first action, after the plan is approved"
if step 3 | grep -q "PUT"; then bad "Step 3 still writes the Admin Workspace during read-only planning"
elif ! step 5 | grep -q "PUT"; then bad "Step 5 does not own the Admin Workspace attach"
else ok; fi

t "the first-extension guide walks the one-batch intake"
g=docs/getting-started/build-your-first-extension.md
sec=$(awk '/^## 4\.5/{on=1} on && /^## 4\.6/{exit} on' "$g")
if printf '%s\n' "$sec" | grep -q "It confirms the scope"; then bad "4.5 still has a separate scope step"
elif ! printf '%s\n' "$sec" | grep -q "What you'll get"; then bad "4.5 does not describe the What you'll get summary"
else ok; fi

t "the command links reference guides by repo path"
hits=$(grep -nE '(^|[ (`])reference/[0-9]' "$CMD")
[ -z "$hits" ] && ok || bad "bare reference/ links: $hits"

t "the docs no longer promise options with 'Other'"
hits=$(grep -n 'with \*\*Other\*\*' "${DOCS[@]}")
[ -z "$hits" ] && ok || bad "$hits"

echo
echo "intake plain-language: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
