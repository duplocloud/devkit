# Plain-Language Extension Intake Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The agent that designs an extension asks only plain questions, states its technical choices as plain defaults, and gets the user's approval of a plain summary before it writes code, in Studio and in `/duplo-extension`.

**Architecture:** Phase 1 of `duplo-extension-dev/SKILL.md` gains one "Talking to the user" subsection that owns the question table, the four-pattern table, the summary shape and the in-product "Build this?" pause. The command points to it instead of keeping its own list. A static bash check pins the wording rules and the reference fixes; live runs on both paths check behaviour.

**Tech Stack:** Markdown agent instructions (Claude Code skill + command), bash test in the repo's `tests/test-*.sh` style.

**Spec:** `docs/superpowers/specs/2026-11-16-plain-language-intake-design.md`

## Global Constraints

- Branch `DUPLOAI-5468-approachable-intake` off `origin/dev`; the PR targets `dev`.
- Terms that never appear in a user-facing question or in the four-pattern "says" column (case-insensitive, whole word): `spec`, `result`, `resource`, `scope`, `provider`, `provisioning`, `mode`, `CRUD`, `endpoint`, `controller`, `FE`, `section id`, `originType`, `remote`.
- The four plain names, verbatim: Worker → **Background job**, Agent → **AI agent**, Passthrough → **Instant**, No-provision → **Read-only**.
- Pause: one `ask_human` `yes_no` ending "Build this?"; no model-added options. `blockedReason`: `Review what I'll build`.
- Phase 1's technical settle-list and its existing mode-selection rules stay as they are. The `reference/` guides are untouched.
- No push until the requester says so. Task 6's in-product run needs the branch on GitHub, so it waits for that go-ahead.

## Review Focus

1. **A fully filled template** → the batch still confirms Name, Spec fields, Result fields as guesses; no other row is asked. Pinned by Task 6 run A.
2. **A change request contradicting an earlier answer** → the summary is revised and asked again; no code is written in between. Pinned by Task 6 run B.
3. **Empty Scopes field and an outside system in the product** → the summary states it builds without testing against that system; the agent never calls a scopes listing (403 on the ticket token). Pinned by Task 6 run B.
4. **"Only admins should manage this"** → admin derived and stated; the workspace-or-admin question is not asked. Pinned by Task 6 run C.
5. **Two related things in one requirement** → the "Does one X hold many Ys?" question appears; with one thing it does not. Pinned by Task 6 runs A and C.

---

### Task 1: Static intake check

**Files:**
- Create: `tests/test-intake-plain-language.sh`

**Interfaces:**
- Produces: the subsection heading `### Talking to the user` inside Phase 1, and the column headers `Ask the user` (question table) and `What the agent says` (four-pattern table), which Task 2 must use.

- [ ] **Step 1: Write the check** in the style of `tests/test-strip-term-noise.sh` (`t`/`ok`/`bad`, PASS/FAIL counts, exit 1 on any FAIL). Cases:
  - `SKILL.md` has `### Talking to the user` between `## Phase 1` and `## Phase 2`.
  - Every table row in that subsection: the `Ask the user` and `What the agent says` cells contain none of the Global Constraints terms.
  - The four plain names appear in that subsection.
  - `SKILL.md` contains `Build this?`, `before every ask` and `Review what I'll build`, no `Change something`, and no `section id /` question.
  - `SKILL.md` contains no `dirname "$0"`, no `PRIVATE`, no `22-admin-resources`.
  - The command contains `Talking to the user`, and none of `ParentRefSpec`, `consumed by the FE`, `named action`.
  - The command has no bare relative link: `grep -nE '(^|[ (\x60])reference/[0-9]'` is empty.
  - `docs/quickstart.md` and `docs/getting-started/build-your-first-extension.md` do not contain `with **Other**`.
- [ ] **Step 2: Run it and confirm it fails** — `bash tests/test-intake-plain-language.sh` → FAIL on the subsection, pause, `$0`, `PRIVATE`, command and docs cases.
- [ ] **Step 3: Commit** — `git add tests/test-intake-plain-language.sh && git commit -m "test: pin the plain-language intake rules"`

### Task 2: "Talking to the user" in Phase 1

**Files:**
- Modify: `.claude/skills/duplo-extension-dev/SKILL.md` (Phase 1: the "Present the settled shape" paragraph and "Where the answers come from / how to ask")

**Interfaces:**
- Consumes: the headings and column names from Task 1.
- Produces: the subsection the command links to as `.claude/skills/duplo-extension-dev/SKILL.md#talking-to-the-user`.

- [ ] **Step 1: Add the subsection** after the settle-list, holding:
  - the asking rule from the spec ("one batch: Name, Spec fields, Result fields as guesses, plus any row the requirement points two ways; every other row a stated default");
  - the question table (columns: Decision · Ask the user · Default), rows and defaults from the spec's before/after table, including the product note on the Scopes field;
  - the four-pattern table (Mode · Plain name · What the agent says);
  - one line on UX patterns: describe the chosen form shape in plain words in the summary.
- [ ] **Step 2: Rewrite "Present the settled shape"** so the summary opens with **What you'll get** (five to eight plain lines), then the unconfirmed defaults one per line, then **Technical details** holding the existing tables unchanged.
- [ ] **Step 3: Rewrite the in-platform "how to ask"**: defer to the bootstrap's `ask_human` protocol by name (`duplo-extension-ticket`, "Questions — ask in chat, never park"); replace the example `blockedReason` with one plain line; add the pause exactly as the spec's "The approval summary" section words it.
- [ ] **Step 4: Run the check** — Task 1's subsection, pause and `section id` cases PASS.
- [ ] **Step 5: Commit** — `git commit -am "feat(skill): ask plain questions and confirm a plain summary before building"`

### Task 3: The command defers to Phase 1

**Files:**
- Modify: `.claude/commands/duplo-extension.md` (the plan-shape list near the top, Steps 1–4, Step 6)

- [ ] **Step 1:** Step 2 keeps the template; replace its name proposal with a pointer to Phase 1's Name row.
- [ ] **Step 2:** Step 3: remove the workspace-or-admin block (Phase 1 owns it); keep choosing the workspace and the scope-listing script, and word the question toward the user as the spec's Provider-scopes row.
- [ ] **Step 3:** Step 4: replace the bullet list with "Ask the batch from Talking to the user" plus the link, and keep the gate sentence.
- [ ] **Step 4:** The plan-shape list at the top: open with **What you'll get**, then the existing items under **Technical details**.
- [ ] **Step 5:** Steps 1 and 6: reword the questions to the user per the spec's Target platform row and in plain words for the A/B test choice.
- [ ] **Step 6:** Rewrite every bare `reference/…` link to `.claude/skills/duplo-extension-dev/reference/…`.
- [ ] **Step 7: Run the check** — the command cases PASS.
- [ ] **Step 8: Commit** — `git commit -am "feat(command): take the intake questions from the skill"`

### Task 4: Reference fixes in SKILL.md

**Files:**
- Modify: `.claude/skills/duplo-extension-dev/SKILL.md` (reference index, "Getting the working copy", Phase 2 scaffold copy)

- [ ] **Step 1:** The scaffold copy uses `.claude/skills/duplo-extension-dev/templates/helloworld` (repo root as the working directory, as the scripts already assume).
- [ ] **Step 2:** "Getting the working copy": the devkit repo is public; a plain `git clone` works. Keep `gh` for the user's own repo.
- [ ] **Step 3:** Reference index label `22-admin-resources` → `21-admin-resources`.
- [ ] **Step 4: Run the check** — the `$0`, `PRIVATE` and label cases PASS.
- [ ] **Step 5: Commit** — `git commit -am "fix(skill): template path, public clone, admin-resources label"`

### Task 5: Docs describe the intake as it runs

**Files:**
- Modify: `docs/quickstart.md` (section "b."/"c." around the `/duplo-extension` walkthrough), `docs/getting-started/build-your-first-extension.md` (the walkthrough after line 55)

- [ ] **Step 1:** Describe: the requirement template, one batch of plain questions, the **What you'll get** summary to approve. Quote two questions from the table as examples. Remove "with **Other**".
- [ ] **Step 2: Run the check** — all cases PASS.
- [ ] **Step 3: Commit** — `git commit -am "docs: describe the plain-language intake"`

### Task 6: Live runs

**Files:**
- Create: `tests/fixtures/intake/a-jenkins-full.md` (the template filled for one Jenkins Job resource), `b-jenkins-no-connection.md` (same, outside system named, no connection), `c-admin-two-things.md` ("only admins manage a VPN server; workspaces pick one for their apps")

- [ ] **Step 1: Run A, local** — `/duplo-extension` against the local stack with fixture A. Pass: one batch with Name, inputs and outputs as guesses, no parent/child question; the plan opens with **What you'll get** and names the plain pattern.
- [ ] **Step 2: Run C, local** — fixture C. Pass: admin stated, never asked; the "hold many" question appears.
- [ ] **Step 3: Push the branch** (requester's go-ahead) and set the local studio's system settings `extension-devkit-repo` = `duplocloud/devkit`, `extension-devkit-branch` = `DUPLOAI-5468-approachable-intake`.
- [ ] **Step 4: Run B, product** — Studio → Add extension, fixture B, Scopes empty. Pass: one `ask_human` batch; the summary says it builds without testing against Jenkins; status `Blocked` / `Review what I'll build`; answer through "Chat about this" with a contradicting edit → `Blocked` re-posted, revised summary asked again, no `Authoring code` beat in between; then **Yes** → `Authoring code`.
- [ ] **Step 5:** Record the questions and summaries from each run in the PR description. Reset `extension-devkit-branch` afterwards.
