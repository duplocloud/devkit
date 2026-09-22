# 2. Connect AWS

**What you'll do:** give the agent read-only access to your AWS account, then prove it works by asking
it a question and getting a real answer back.

**What you need first:** [1. Install and sign in](install.md) — the platform running locally and you
signed in to the portal. You also need an AWS account you can create an IAM user in.

---

## Why an access key, and not a role

The published DuploCloud material leads with an IAM role. That works when a *hosted* HelpDesk
deployment is doing the connecting: the deployment runs inside AWS with an identity of its own, and it
assumes your role from that identity.

This dev kit is Docker Compose on your laptop. It has no AWS identity, so there is nothing for a role
to be assumed *from*. An access key is self-contained — it carries its own identity — so that is what
this page uses. The production alternative is named at the [end of the page](#a-note-on-iam-roles).

## 2.1 Create an IAM user and access key

1. In the AWS console, go to **IAM** → **Users** → **Create user**.

2. Set **User name** to `duplocloud-devkit`.

3. Leave **Provide user access to the AWS Management Console** *unchecked*. This user only ever
   authenticates through the API — it has no reason to be able to sign in to the console.

4. Click **Next** → **Attach policies directly**, then search for and tick **`ReadOnlyAccess`**.

   Read-only is deliberate, not a placeholder to loosen later. Nothing in this guide writes to your
   AWS account, and a getting-started credential should not be able to.

5. Click **Next** → **Create user**.

6. Open the user you just created → **Security credentials** tab → **Access keys** → **Create access
   key**.

7. Choose **Third-party service** as the use case, tick the confirmation checkbox, then **Next** →
   **Create access key**.

8. Copy both values before you leave the page:

   | Value | Where it goes |
   | --- | --- |
   | **Access key** | the **Access Key ID** field in [2.3](#23-add-the-credential) |
   | **Secret access key** | the **Password** field in [2.3](#23-add-the-credential) |

   **The secret is shown once.** If you navigate away without it, delete the key and create another —
   it cannot be retrieved.

## 2.2 Add the provider

A **provider** is the account you are connecting — here, one AWS account.

Provider, credential and scope are **one wizard**, not three separate visits. Clicking **Add** opens a
page headed **Add Provider** with a progress rail down the right-hand side listing three steps:
**Provider Details**, **Credentials**, **Scope**. You move between them with **Next**. Sections 2.2,
2.3 and 2.4 below are those three steps, in order — do not leave the wizard between them.

1. Providers lives in **AI Admin**, not in AI DevOps. Click the app switcher at the top left — the
   button reading **AI DevOps** — and choose **AI Admin**.

   The sidebar changes to: Workspaces, Memories, Personas, Skills, MCP Servers, Providers,
   Notifications, Extensions, Resources, LLMs, Analytics, Security, Access Control, Settings.

2. Click **Providers** in that sidebar, then **IT**. (**GTM** is the other category; cloud accounts
   are IT.)

3. Tabs run across the top: **Cloud**, **Kubernetes**, Observability, Incident Management, Source
   Control, GRC, Notifications, Other. Stay on **Cloud** — that is where AWS lives.

4. Click **Add** (top right). The **Add Provider** page opens on step 1, **Provider Details** —
   *"Enter basic provider details and account information."*

5. Fill in:

   | Field | Value |
   | --- | --- |
   | **Name** | `aws` |
   | **Description** (Optional) | leave empty |
   | **Type** | `AWS` — the choices are AWS, Azure, GCP and DuploCloud |
   | **Account ID** | `<your 12-digit AWS account ID>` |
   | **Metadata** (Optional) | leave empty |

   ![Step 1 of the Add Provider wizard, Provider Details, with Type set to AWS](../images/devkit-provider-details.png)

6. Click **Next**.

   The step also offers **Create**. That saves the provider on its own and closes the wizard, leaving
   you with no credential and no scope. Use **Next**.

## 2.3 Add the credential

You are now on step 2 of the same wizard, **Credentials** — *"Configure authentication credentials for
this provider."* The provider says *which* account. The credential says *how to authenticate to it*.

1. Fill in:

   | Field | Value |
   | --- | --- |
   | **Name** | `aws-devkit-key` |
   | **Credential Type** | `Access Key` |
   | **Access Key ID** | `<your AWS access key ID>` — from [2.1](#21-create-an-iam-user-and-access-key) |
   | **Password** | `<your AWS secret access key>` — from [2.1](#21-create-an-iam-user-and-access-key) |
   | **Credential Fields** | leave empty — the `+ Add Credential Field` button is for credential types that need extras |
   | **Metadata** (Optional) | leave empty |

   The secret really does go in the field labelled **Password**. That is the generic label the form
   uses for the secret half of any credential type.

   ![Step 2 of the Add Provider wizard, Credentials, with Credential Type set to Access Key](../images/devkit-provider-credential.png)

2. Click **Next**.

   The other buttons on this step: **Back** returns to Provider Details, **Skip** moves on without a
   credential, and **Create** saves and closes here. You want **Next**.

## 2.4 Add a scope

The last step of the wizard is **Scope**.

A **scope** is the boundary of what the agent may touch. Both HelpDesk tickets and extensions target a
scope — a ticket runs against the scope you pick on it, and an extension's resource spec carries the
scope IDs it was given.

When a ticket runs, the platform expands the scope into its provider and credential and hands them to
the agent, which writes them into the ticket's working directory — for AWS, as a named profile in
`.aws/credentials` that the AWS CLI then uses. Nothing outside the scope is materialized, so nothing
outside it is reachable.

1. Give the scope a **Name** of `aws-readonly`. A **Description** is available if you want one, along
   with an MCP Server selection you can leave alone.

2. Click **Create** to finish the wizard.

   This does not close on its own — creating the scope raises one more dialog, which is 2.5.

## 2.5 Attach the scope to the workspace

Creating a scope does not make it usable. A ticket can only select scopes attached to the workspace it
is filed in. The wizard offers this straight away, so there is nothing extra to go and find.

1. Creating the scope pops up **Attach Scope to Workspaces** — *"Select the workspaces to attach scope
   `aws-readonly` to."*

2. Open the **Workspaces** control and pick **extension-dev**. You can attach to more than one.

3. Click **Attach**.

   ![The Attach Scope to Workspaces dialog with extension-dev selected](../images/devkit-attach-scope-to-workspaces.png)

   The dialog also offers **Skip**. Take it only if you meant to attach the scope later — skipping
   leaves the scope created but invisible to every ticket, which looks exactly like the scope having
   failed to save.

The wizard closes. The provider, its credential and its scope are saved together, and the provider is
now listed on the **Cloud** tab. You can confirm the scope attached from the **Scopes** page in the
sidebar, which lists what the current workspace can use.

## 2.6 Prove it works

Connecting AWS is not done until the agent has actually answered a question about your account.

Switch back to **AI DevOps** with the app switcher at the top left before you start.

1. Go to **HelpDesk** → **Add Ticket**. The page is headed *Create a new ticket*, subtitled *With
   DuploCloud AI DevOps*.

2. In the large text box — placeholder *"Enter your ticket description for the LLM to help you solve
   it"* — type your question:

   ```
   List all S3 buckets in this account.
   ```

3. Leave the model selector at the bottom right of that box alone. It is already set, and reads your
   model followed by `(Direct Anthropic)` with a sub-line of `SDK: local-agent` — for example
   `claude-sonnet-5 (Direct Anthropic)` (with `claude-opus-5` also offered). There is no separate agent to choose.

4. Open **Select Scopes** and pick **`aws-readonly`**. Each entry shows the scope name with a small
   type badge beside it — `aws` for this one.

   This is the step everything else has been building toward, and it is **required** — **Create
   Ticket** stays disabled until the box has both text and a scope. Picking the scope is what causes
   the platform to expand it into its provider and credential and hand them to the agent. Without it
   the agent has no AWS credentials at all.

   ![The ticket form with the AWS scope selected and Create Ticket enabled](../images/devkit-ticket-scope-selected.png)

5. Click **Create Ticket**.

6. **Approve the command.** The ticket opens, the agent thinks for a moment, and then it stops and
   asks permission before running anything. You get a *Thought* line, a *Running tool: Bash* line, the
   sentence *"I would like to execute the following commands and request your approval to proceed :"*,
   and a black code block holding the command it wants to run — an `aws` CLI call against the profile
   your scope produced.

   Below that: **Approve** / **Reject** / **Ignore** with **Approve** already selected, a **Remember
   for this ticket** checkbox, and a **Submit** button. Nothing runs until you click **Submit**.

   Tick **Remember for this ticket** first if you would rather not be asked again for the rest of this
   ticket, then click **Submit**.

   ![The agent asking for approval to run an AWS CLI command, with Approve selected](../images/devkit-command-approval.png)

**What success looks like:** the command runs and the agent replies in the thread with a rendered
table of your buckets — Bucket Name and Created, named, not described in the abstract:

![The agent's reply: a table of the account's S3 buckets](../images/devkit-ticket-answer-aws.png)

Recognize those names and AWS is connected: real credentials, reaching a real account, through the
scope. The rail on the right records what ran it — **STATUS**, **LLM**, **TOTAL COST**, **SCOPES** (a
chip carrying your scope's name), **PERSONAS**, **PRIORITY** and **TICKET ID**.

An empty list is only a pass if you genuinely have no buckets. If you expected buckets and got none,
the credential is the place to look — recheck the **Access Key ID** and **Password** you entered in
[2.3](#23-add-the-credential). See [troubleshooting.md](../troubleshooting.md#providers-aws-and-kubernetes)
for the rest.

## A note on IAM roles

> **IAM Role is the production path, and it does not apply here.** A DuploCloud deployment running
> inside AWS authenticates as itself and assumes a role in your account, so no long-lived key is ever
> stored. That requires an AWS identity to assume the role *from* — which Docker Compose on a laptop
> does not have, which is why this page uses an access key instead. When you move to a hosted
> deployment, the same provider takes a credential of type **IAM Role** with the role's ARN, and the
> scope above is unchanged. Nothing in this guide needs to be redone.

**Next:** [3. Connect Kubernetes](connect-kubernetes.md)
