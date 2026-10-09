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

**What you do.** Product events naming the feature used and the objects involved. Every event name
is namespaced: `com.duplocloud.armor.<event>` for the studio UI, `com.duplocloud.devops.<event>` for
the AI DevOps > DevOps pages, and `<extension-id>.<event>` for extensions (see below).

- Chat and tickets — `com.duplocloud.armor.` followed by `create-ticket`, `ticket-form.viewed`,
  `change-ticket-status`, `send-chat-message`, `send-chat-action`, `submit-ticket-feedback`,
  `submit-message-feedback`, `update-ticket-scopes`, `update-ticket-mcp-permissions`,
  `update-ticket-command-permissions`, `apply-prompt-suggestion`, `apply-prompt-template`
- Admin pages viewed — `com.duplocloud.armor.` followed by `workspace-list.viewed`,
  `workspace-agent-list.viewed`, `persona-list.viewed`, `persona-detail.viewed`,
  `provider-list.viewed`, `scope-list.viewed`, `skill-list.viewed`, `user-list.viewed`,
  `api-token-list.viewed`, `permission-set-list.viewed`, `permission-set-group-list.viewed`,
  `command-policy-list.viewed`, `command-policy-mapping-list.viewed`, `quota-list.viewed`,
  `quota-mapping-list.viewed`
- Admin objects created or updated — `create-<object>` / `update-<object>` for workspaces,
  personas, providers, credentials, scopes, skills, MCP servers, users, permission sets and groups,
  command policies and their mappings, quotas and their mappings
- Knowledge bases and extensions — `create-kb`, `delete-kb`, `delete-kb-document`, `share-kb`,
  `unshare-kb`, `remove-kb-from-workspace`, `kb-add-documents-form.viewed`,
  `register-extension-bundle`, `reject-extension-bundle`, `extension-detail.viewed`,
  `extension-register-form.viewed`
- AI DevOps > DevOps — `com.duplocloud.devops.` followed by page views (`network-list.viewed`,
  `cluster-detail.viewed`, `environment-list.viewed`, `tf-deployment-detail.viewed`,
  `resource-detail.viewed`, and similar), `create-` / `update-` / `delete-` / `deprovision-` actions
  on networks, plans, clusters, environments, resource groups and Terraform deployments and
  environments, Terraform runs (`tf-plan`, `tf-apply`, `tf-destroy`, `tf-resync`,
  `tf-commit-push`), and `ask-agent`, `track-provisioning`, `download-kubeconfig`, `show-kubectl`,
  `open-workstation`
- Extensions — page views and actions named `<extension-id>.<event>` (see the properties below)

**The properties attached to them.** Names of the objects you create or edit — workspace, agent,
provider, scope, credential, MCP server, permission set and group, command policy, quota, and their
mappings. Object ids (workspace, provider, persona, ticket, instance); tickets are identified by
`ticket_id` only — the ticket key (e.g. `DEVKIT-42`) is not sent. Counts and booleans
(`scope_count`, `custom_field_count`, `message_length`, `has_files`, `has_commands`, `has_prompt`,
and similar). Persona and skill *names* are not sent — those events carry only counts and type
flags. AI DevOps events carry only `resource_type`, `cloud` and `mode` — no resource names or ids.

**No free-text properties are sent.** Nothing a person typed, and nothing an admin configured as
text (such as prompt suggestion or template text), is attached to any event.

**From extensions.** Each extension event carries `extension_id` and `extension_version`, plus only
the properties the extension's author explicitly allowlisted in the manifest
(`frontend.analytics.properties`). The portal strips everything else before sending.

**Automatically, from your browser.** Mixpanel's library attaches to every event: your browser and
version, OS, device type, screen size, the referrer, and the current page URL (which contains
ticket keys, never message text). Mixpanel also derives an approximate city and region from your
IP address.

## What is *not* collected

- **The chat messages you type.** `send-chat-message` carries `message_length` — a number — not the
  message. No free text is sent at all.
- **The commands or tool calls themselves.** No command text, tool names, or arguments —
  `send-chat-action` carries `has_commands` / `has_tools` flags alongside the ticket id. Command
  policy events send the policy's name, never its regex patterns.
- **Credential values, API keys, or tokens.** Credential events carry the credential's *name* and
  a *count* of its custom fields, never the values.
- **Your files, or the contents of files you attach.** Only `has_files`.
- **Anything from your extensions' code beyond what the author allowlisted.** Extensions send page
  views and actions named `<extension-id>.<event>` with `extension_id` and `extension_version`, plus
  only the properties the author explicitly allowlisted in the manifest
  (`frontend.analytics.properties`); the portal strips everything else. Nothing from the agent's
  output is sent.
- **Skill, agent prompt and feedback content.** Skill events carry only the skill's type and
  format — not its name, source, or body. Agent prompts are reduced to a `has_prompt` flag, and
  free-text feedback to a `has_text` flag.
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
