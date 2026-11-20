# Privacy

The dev kit's UI can send product usage metrics to DuploCloud via Mixpanel. This page says exactly
what that means.

## Opting in

Usage metrics are controlled inside the portal UI itself — the product asks for your consent there.
The dev kit does not prompt for it, has no `.env` setting for it, and does not modify the served UI
bundle: the nginx config in `nginx/default.conf` is a plain same-origin proxy to the studio.

## What is collected

**Who you are.** Metrics are tied to the email you sign in with — which is the same email the dev
kit's license is issued to. Your username, your assigned roles, and your email's domain (as a
company grouping) are sent with it. This is not anonymous, and we do not describe it as such.

**What you do.** Product events naming the feature used and the objects involved:

- Chat and tickets — `ticket_created`, `ticket_form_opened`, `ticket_status_changed`,
  `chat_message_sent`, `chat_action_sent`, `ticket_feedback_submitted`,
  `message_feedback_submitted`, `ticket_scopes_updated`, `ticket_command_permissions_updated`,
  `prompt_suggestion_clicked`, `prompt_template_clicked`
- Admin pages viewed — `admin_workspaces_viewed`, `admin_agents_viewed`, `admin_personas_viewed`,
  `admin_providers_viewed`, `admin_scopes_viewed`, `admin_skills_viewed`, `admin_users_viewed`,
  `admin_api_tokens_viewed`, `admin_permission_sets_viewed`, `admin_permission_set_groups_viewed`,
  `admin_command_policy_definitions_viewed`, `admin_command_policy_mappings_viewed`,
  `admin_quota_definitions_viewed`, `admin_quota_mappings_viewed`, `persona_viewed`
- Admin objects created or updated — workspaces, personas, providers, credentials, scopes, skills,
  MCP servers, users, permission sets and groups, command policies, quotas

**The properties attached to them.** Names of the objects you create or edit — the ticket key
(e.g. `DEVKIT-42`, not anything you typed), workspace, agent, provider, scope, credential, MCP
server, permission set and group, command policy, quota, and their mappings. Object ids
(workspace, provider, persona, ticket, instance). Counts and booleans (`scope_count`,
`custom_field_count`, `message_length`, `has_files`, `has_commands`, `has_prompt`, and similar).
Persona and skill *names* are not sent — those events carry only counts and type flags.

**Two properties carry free text**, both of them content your workspace admin configured rather
than anything you typed:

- `suggestion_text` on `prompt_suggestion_clicked` — the full text of the prompt suggestion you
  clicked, which is also the message that then gets sent to the agent.
- `template_description` on `prompt_template_clicked` — the template's description. The template
  *body* is not sent.

**Automatically, from your browser.** Mixpanel's library attaches to every event: your browser and
version, OS, device type, screen size, the referrer, and the current page URL (which contains
ticket keys, never message text). Mixpanel also derives an approximate city and region from your
IP address.

## What is *not* collected

- **The chat messages you type.** `chat_message_sent` carries `message_length` — a number — not the
  message. The one exception is above: clicking a prompt *suggestion* sends that suggestion's text.
- **The commands or tool calls themselves.** No command text, tool names, or arguments —
  `chat_action_sent` carries `has_commands` / `has_tools` flags alongside the ticket key. Command
  policy events send the policy's name, never its regex patterns.
- **Credential values, API keys, or tokens.** Credential events carry the credential's *name* and
  a *count* of its custom fields, never the values.
- **Your files, or the contents of files you attach.** Only `has_files`.
- **Anything from the code you write, or from the agent's output.** Skill events carry only the
  skill's type and format — not its name, source, or body. Agent prompts are reduced to a
  `has_prompt` flag, and free-text feedback to a `has_text` flag.
- **Anything from the studio backend.** These metrics come from the UI only; the studio has no
  analytics integration.

## How it is used

DuploCloud uses these metrics **internally only** — to understand which parts of the product get
used and where people get stuck. They are **never sold**, and never shared with anyone outside
DuploCloud, with one unavoidable exception: Mixpanel itself, which stores and processes the data
on our behalf as our analytics provider. No advertisers, no data brokers, no other third parties.

## Third party

Mixpanel is the only analytics processor the UI integrates. If you do not opt in, their library is
never initialized in your browser, so no request is made to them at all.

The UI bundle also contains a Userflow integration, but the dev kit never supplies it a key, so it
never activates.

Questions: **ai-reporting@duplocloud.net**.
