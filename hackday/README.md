# DuploCloud @ AI Conference Hack Day

Everything you need to build an agent on the DuploCloud platform — **September 29th**.

**📺 Watch first:** [Hack Day walkthrough (15 min)](https://vimeo.com/1228174847) — the problem, the
platform, and a live demo of building an agent end to end.

---

## Start here

**[Installing DevKit.md](<Installing DevKit.md>)** — **Do this before you arrive.** Get the whole
platform running on your laptop via Docker: prerequisites, install, and the checks that prove it worked.
20–40 minutes, mostly image pulls, so do it on home wifi. Also covers how you'll be judged.

**[Sponsor Integrations.md](<Sponsor Integrations.md>)** — Wire a sponsor tool into your agent.
Step-by-step for **Neo4j**, **Crusoe**, **Nebius**, and **Vultr**, plus the general pattern for any
sponsor not listed. 10–15 minutes each, and it counts toward one of the two prizes.

**[Getting Support.md](<Getting Support.md>)** — Slack invite, email, the sponsor desk, and what to
include when you ask so you get a fast answer.

---

## Configuring the platform

These five are the building blocks of an agent. They have a **dependency order** — follow it top to
bottom the first time.

| | Page | What it covers |
| --- | --- | --- |
| **1** | [Adding Providers.md](<Adding Providers.md>) | Connect your systems — cloud accounts, Kubernetes, Git, incident tools. Provider → Credential → **Scope**, and nothing reaches an agent without a Scope. |
| **2** | [Adding MCP Servers.md](<Adding MCP Servers.md>) | *Optional.* Give the agent external tools via MCP. Two config types: HTTP/SSE for remote endpoints, Raw for command-based servers. Needs a Provider from step 1. |
| **3** | [Adding Skills.md](<Adding Skills.md>) | Teach the agent tasks. A `SKILL.md` pasted in, uploaded as a zip, pulled from a private Git repo, or taken from a vendor. |
| **4** | [Adding Personas.md](<Adding Personas.md>) | Group Skills by role — SRE, Provisioning, Security — with shared system prompts. |
| **5** | [Adding Workspaces.md](<Adding Workspaces.md>) | Where it comes together: attach Scopes and Personas, invite users, set a system prompt. |

```
Provider → Credential → Scope ─┐
                               ├─→ WORKSPACE → file a ticket here
Skills → Persona ──────────────┘
```

---

## Quick answers

| I want to… | Go to |
| --- | --- |
| Get the platform running | [Installing DevKit.md](<Installing DevKit.md>) |
| Fix an install error | [Installing DevKit.md § 6](<Installing DevKit.md>) → [docs/troubleshooting.md](../docs/troubleshooting.md) |
| Build my first agent | [Installing DevKit.md § 4](<Installing DevKit.md>), then [docs/quickstart.md § 6](../docs/quickstart.md#6-build-your-first-ai-app) |
| Connect an AWS or Kubernetes account | [Adding Providers.md](<Adding Providers.md>) |
| Use a sponsor tool | [Sponsor Integrations.md](<Sponsor Integrations.md>) |
| Understand why my Scope isn't showing on a ticket | [Adding Workspaces.md](<Adding Workspaces.md>) — attaching makes it available, not active |
| Know how the prizes work | [Installing DevKit.md § 7](<Installing DevKit.md>) |
| Ask a human | [Getting Support.md](<Getting Support.md>) |

---

## Before the day

- [ ] Watched the [walkthrough](https://vimeo.com/1228174847)
- [ ] Platform installed and running — [Installing DevKit.md](<Installing DevKit.md>)
- [ ] Signed in at <http://localhost:4210>
- [ ] Joined the [Hack Day Slack](https://join.slack.com/t/hackday-brv1895/shared_invite/zt-4ar74ve28-YSK96VM1ERprQXoTIbTGBA)
- [ ] *(Optional but recommended)* Built one throwaway agent, so you know the loop

You have six hours on the day. Spend them on the ambitious version of your idea, not the plumbing.

---

## Beyond this folder

The full dev kit documentation lives in [`../docs/`](../docs/README.md) — architecture, every `.env`
variable, the CLI reference, and the agent-authoring guides. These Hack Day pages are the short
path; that's the complete one.

**Questions?** hackday@duplocloud.net · [Slack](https://join.slack.com/t/hackday-brv1895/shared_invite/zt-4ar74ve28-YSK96VM1ERprQXoTIbTGBA) · sponsor desk on the day
