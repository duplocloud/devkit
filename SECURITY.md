# Security Policy

## Reporting a vulnerability

**Please do not open a public issue for security problems.**

Email **ai-reporting@duplocloud.net** with the details, and we'll take it from there.

Helpful things to include:

- The affected file, script, sample, or workflow
- The commit SHA or dev-kit version you were running
- Steps to reproduce, and what an attacker gains
- Any logs or output — with tokens, keys, and customer identifiers redacted

Maintainers will acknowledge the report, work the fix privately, and coordinate disclosure with you
before anything is published.

## Scope

**In scope** — the dev kit itself:

- `run.sh`, `stop.sh`, `logs.sh`, and everything under `scripts/`
- `docker-compose.yml` and the `nginx/` configuration
- The reference agents under `samples/`
- The authoring skill and reference docs under `.claude/`
- The GitHub Actions workflows under `.github/workflows/`

**Out of scope here** — please route these elsewhere:

- **Vulnerabilities in the published platform images** (`quay.io/duplocloud/*`). These are built from the
  DuploCloud product, not from this repo. Report them through your normal DuploCloud support channel.
- **Third-party dependency advisories in the sample frontends.** The samples pin Angular-era dependency
  trees for reference purposes and are tracked separately; a plain issue is fine for those.
- Issues that only occur in a deployment of your *own* agent code rather than in dev-kit framework code.

## Supported versions

Fixes land on `main`. There are no maintenance backports — pick up security fixes with:

```bash
./scripts/upgrade_dev_kit.sh
```

That refreshes the framework while leaving your `extensions/` and `.env` untouched.

## Handling credentials when you use this kit

This dev kit runs a full platform stack locally, so a working checkout legitimately holds real credentials.
A few things worth knowing:

- **`.env` is secret and is git-ignored.** `.gitignore` excludes `.env*` while allowing `.env.example`.
  Never commit `.env`, and never paste it into an issue or a PR.
- **`./run.sh` mints a long-lived Administrator token into `.env`.** Treat that file the way you would treat
  a production credential. If it leaks, rotate the token on the platform it points at.
- **LLM provider keys live in `.env` too** (Anthropic, Azure Foundry, or AWS Bedrock).
- **`DUPLO_TARGET=remote` points the build at a real platform** using `DUPLO_HOST` + `DUPLO_TOKEN`. In CI those
  come from repository secrets — keep them as secrets, never inline them into a workflow file.
- **The agent sends your prompts and skill content to your configured LLM provider.** Don't paste production
  secrets, customer names, or ticket contents into agent prompts, provisioning skills, or `PROMPT.md` files.
- **Agents run with platform privileges.** A provisioning skill is executable logic, not documentation —
  review a skill from an untrusted source before you load it, exactly as you would review code.

## Not hardened for production

This kit exists for local agent development. The stack binds development ports on your machine and is not
configured, patched, or reviewed for use as a production control plane. Don't expose it to the public internet.
