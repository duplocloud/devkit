# Plain-language extension intake: design

ClickUp: DUPLOAI-5468 "Make devkit skill more approachable".

## Intent

Someone who has never read the devkit docs can answer every question the agent asks while it designs
their extension. Today the agent asks in the platform's own vocabulary: spec and result fields with
types, an "extension scope" and separate "Provider scopes", a provisioning mode, named actions, a menu
section id. Those are the agent's decisions to make. The user knows their problem: what people type in,
what they want to see afterwards, who should manage it, which outside system it talks to.

The agent derives the technical shape from that, states each choice as a plain default, and asks only
what it cannot derive.

## Who meets the intake

| Entry point | Who | Where the questions come from |
|---|---|---|
| Studio → Add extension (in the product) | A portal admin, often on the free tier, with no devkit checkout | `duplo-extension-ticket` (helpdesk) clones devkit and hands off to `duplo-extension-dev` Phase 1 |
| `/duplo-extension` in Claude Code | A developer with devkit cloned | `.claude/commands/duplo-extension.md` Steps 2–4, then `duplo-extension-dev` Phase 1 |

Both reach Phase 1 of `.claude/skills/duplo-extension-dev/SKILL.md`. The in-product path never sees the
command; the ticket links only `.claude/skills/*`.

## Goals

1. Every question put to the user uses words from the user's problem domain. Platform terms (spec,
   result, resource, scope, provider, provisioning, mode, CRUD, endpoint, controller, FE, section id,
   originType, remote) do not appear in a question.
2. The agent decides the technical shape itself and states each decision as a plain sentence the user
   can override. It asks only when the requirement leaves a decision open and a wrong guess changes what
   gets built.
3. The four provisioning modes are explained to the user in plain words, once, when the agent states
   which one it picked (table below).
4. The approval summary opens with what the user will get, in plain words. The Spec / Result / mode /
   access tables follow under a "Technical details" heading for reviewers and builders.
5. One question list. Phase 1 owns it, and the command points to it. The command keeps only what is
   local-only: the target platform (Step 1), the requirement template (Step 2), choosing the workspace and
   running the scope-listing script (Step 3), plan mode, and the test choice (Step 6).
6. One way to ask in the product: the bootstrap's `ask_human` protocol (one call, options where there
   are alternatives, `blockedReason` one short line). Phase 1 defers to it.

## Non-goals

- The Studio create form (duplo-ui, helpdesk). Its template is already plain.
- The detail page's own labels (Spec | Result toggle, lifecycle rail). Platform UI, separate change.
- What gets built. The same decisions are settled; only who settles them and how they are worded changes.
- The reference guides under `reference/`. They are for the agent and stay technical.

## Anti-goals

- A build that is wrong because the agent stopped asking. The Phase 1 gate stays: every decision is
  settled before scaffolding, by derivation, a stated default, or an answer.
- A glossary the user has to read before answering.
- Asking the user to choose "Worker / Agent / Passthrough / No-provision" by name.
- Dropping the technical tables. Reviewers and the build rely on them; they move below the plain summary.

## The questions: before and after

The agent asks once, in one batch. The batch always holds the Name, Spec fields and Result fields rows,
each as a guess to confirm, and any other row where the requirement points two ways. Every other row is
stated as a default in the approval summary, and the user approves the summary before anything is
built. A stated default the user approves is a decision, so menu placement no longer needs its own
question.

| Decision | Asked today | Asked instead | Default when the requirement is silent |
|---|---|---|---|
| Name | confirm the extension id, resource type(s) and Native Federation remote name | "I'll call it **Jenkins Jobs**. Keep that name?" (ids derived silently) | derived from the requirement |
| Extension scope | workspace or admin (`AdminResourcesController`, Admin Workspace) | "Who manages these: people in a workspace, or only platform admins?" | people in a workspace |
| Provider scopes for testing | which Provider scope(s) / `scopeId` to use; create a provider `type: other` + scope | "To test this I need to reach Jenkins. Which saved connection should I use?" (list by name, plus "it doesn't need one"). In the product the create form's Scopes field answers this. The ticket cannot list connections, so when that field is empty and the work needs one, the summary states: "No Jenkins connection was picked, so I'll build it without testing against Jenkins." | none, when the work touches no outside system |
| Spec fields | spec fields with name · type · required/optional | "When someone adds one, what do they fill in? My guess: job name (required), branch (default main)." | the template's Inputs section |
| Result fields | result fields with name · type | "When it's done, what should the page show? My guess: build number, status, duration, a link to the log." | the template's Result section |
| Provisioning mode (the four patterns) | "confirm if unsure" among Worker / Agent / Passthrough / No-provision | stated, with the plain name below: "This is a fixed set of steps, so it runs as a **background job** with no AI. Tell me if it needs AI judgement." | derived; never asked by name |
| Custom endpoints | custom actions / extra controller endpoints consumed by the FE | "Besides add, edit and delete, does it need any buttons? For example **Run now** or **View logs**." | none |
| Access control | permission-tree position; named actions vs plain CRUD | only when a button does something sensitive: "Can anyone in the workspace press **Restart**, or only people you allow?" | anyone in the workspace |
| One or many resources | flat vs parent → child (`ParentRefSpec`) | only with more than one resource: "Does one **Pipeline** hold many **Jobs**?" | flat |
| Menu placement | section id / "top-level" / none | "Where in the left menu: its own **Jenkins** group, or under **DevOps**?" | its own group |
| Teardown | deprovision, retain vs hard delete (`AutoDeleteOnDeProvision`), cascade guard | "When someone deletes one here, should the Jenkins job be deleted too?" | delete what provisioning created |
| Outside auth | auth style basic / bearer | "How does Jenkins sign in: username and API token, or a single token?" | from the chosen connection |
| Target platform (local only) | "Use the local dev-kit platform, or a remote one?" | "Build against the DuploCloud running on this machine, or one hosted elsewhere?" | this machine when it is up |

### The four patterns, as the user hears them

| Mode | Plain name | One line the agent says |
|---|---|---|
| Worker | Background job | Runs a fixed set of steps in the background and retries until done. No AI. |
| Agent | AI agent | An AI works out the steps each time. For open-ended work. |
| Passthrough | Instant | Creates one thing the moment you save. |
| No-provision | Read-only | Shows information; creates nothing. |

The agent still picks by the existing rules in Phase 1 (never default to Agent). The table changes only
how the choice is reported.

### UX patterns

The form-shape index in Phase 1 (simple form, step-by-step wizard, repeatable rows, parent → child,
tabbed results) is the agent's choice. The summary describes the chosen shape in plain words ("a
three-step setup: Connection, Job, Schedule") and the user can ask for a different one.

## The approval summary

Opens with **What you'll get**, five to eight plain lines: where it appears in the menu, what someone
fills in, what happens after they save (naming the pattern by its plain name), what the page shows,
what delete does. Then each stated default the user did not confirm, one line each, so they can
object. Then **Technical details**: the existing Spec / Result / extension scope / mode / lifecycle /
access tables, unchanged.

The user approves the summary before any code is written, on both paths:

- **Local:** the summary is the plan approved through `ExitPlanMode`, as today.
- **Product:** after the batch of answers, the agent posts `Blocked` with `subStatus` `Needs more details`
  and a one-line `blockedReason` ("Review what I'll build"), then one `ask_human` `yes_no` question: the
  summary, ending "Build this?". **Yes** → post `Processing` / `Authoring code` and continue. Any other
  reply (the platform's own "Chat about this" row included) is the change request: the agent revises the
  summary and repeats the pause, `Blocked` POST first. The agent adds no options of its own, as the
  bootstrap requires. The shape matches the bootstrap's load approval, so the pause is a devkit change.
- **Product, three guesses only:** when the batch would hold only the Name, Spec fields and Result fields
  guesses, it is skipped and they ride the pause; the summary names the extension.

## Where it lives

- `duplo-extension-dev/SKILL.md` Phase 1 gains a **Talking to the user** subsection holding the
  question table, the four-pattern table and the summary shape. The settle-list above it keeps its
  technical wording; it is the agent's checklist.
- Phase 1's in-platform "how to ask" defers to the bootstrap's `ask_human` protocol, its example
  `blockedReason` becomes one plain line, and it adds the "Build this?" pause above.
- `.claude/commands/duplo-extension.md`: Step 2 keeps the requirement template; its name proposal moves
  to Phase 1's Name row. Step 3's workspace-or-admin question moves to Phase 1; Step 3 keeps choosing
  the workspace and the scope-listing script. Step 4's list is replaced by a pointer to the subsection.
  Steps 1 and 6 keep their mechanics with the plain wording above.
- `docs/quickstart.md` and `docs/getting-started/build-your-first-extension.md` describe the intake as
  it runs: the requirement template, then one batch of plain questions, then the summary to approve.
  Both currently say the command asks "as a set of options with Other", which it does not.

## Fixed in the same change

These are reference errors found while reading the intake:

- `SKILL.md` Phase 2 copies the scaffold from `$(dirname "$0")/templates/helloworld`. In Claude's Bash
  `$0` is the shell, so the path resolves to nothing. Use the repo path
  `.claude/skills/duplo-extension-dev/templates/helloworld`.
- `SKILL.md` "Getting the working copy" calls the devkit repo private and requires `gh`. It is public;
  the bootstrap clones it with plain `git clone`.
- The command links `reference/…` with paths that resolve only from the skill's directory. Use the
  repo-rooted form the command uses elsewhere.
- `SKILL.md`'s reference index labels the admin-resources guide `22-admin-resources` and links
  `21-admin-resources.md`.

## Left to the builder

- Exact wording of each question and of the summary, within the rules above.
- Whether the local path asks through Claude Code's `AskUserQuestion` or in chat.

## Open questions for the requester

1. Which entry point was used when the questions felt unclear: Studio in the product, or
   `/duplo-extension` in Claude Code? Both are covered; the answer sets which one is tested first.
2. Is "the 4 patterns of agent development" the four provisioning modes above?
3. Is "UX patterns" the form-shape choice above, or something the user should be shown before the
   build (a picture of the screens)?
