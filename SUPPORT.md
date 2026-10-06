# Support

**Where to ask:** [GitHub Issues](https://github.com/duplocloud/devkit/issues) on
this repository. Pick the form that fits — bug, feature request, or question.

**What to expect: best effort, and nothing more than that.** This dev kit is maintained by the
DuploCloud team alongside the product. There is no support contract attached to this repository and
no response-time commitment. Issues get read. Reproducible ones get fixed. Some will sit longer than
you'd like, and a few will be closed as out of scope.

If you need an answer you can rely on, you need a DuploCloud support agreement — that's a
conversation with **sales@duplocloud.net**, not an issue here.

## Before you open an issue

- **[docs/troubleshooting.md](docs/troubleshooting.md)** lists real failures by their exact error
  string, with the fix and how to confirm it worked.
- **[docs/faq.md](docs/faq.md)** answers the licensing, data, and platform-support questions.
- **[The documentation](docs/README.md)** covers the whole workflow: prerequisites and setup in
  [getting started](docs/getting-started/README.md), every `.env` variable in
  [configuration](docs/configuration.md), every script and flag in the
  [CLI reference](docs/cli-reference.md), and taking framework updates in
  [upgrading](docs/upgrading.md).
- **[CONTRIBUTING.md](CONTRIBUTING.md)** covers how to verify a change you've made to the framework.
- **The `/duplo-extension` skill and the reference docs under `.claude/`** answer most "how do I
  build X" questions — they are the same material the authoring agent reads.
- **The samples under `samples/`** are worked examples. If you're stuck on a pattern, one of them
  probably does it.

## What doesn't belong in an issue

| Situation | Where it goes |
| --- | --- |
| A security vulnerability in the dev kit | **Email `ai-reporting@duplocloud.net`.** Don't open an issue — see [SECURITY.md](SECURITY.md). |
| Production use, or licensing beyond local development | **sales@duplocloud.net** — the `quay.io/duplocloud/*` images are licensed for local development only ([TERMS.md](TERMS.md)). |
| A bug in the DuploCloud platform itself, or in the published images | Your normal DuploCloud support channel. Those images are built from the product, not from this repo. |
| A bug in an extension *you* wrote | Yours to debug. `./logs.sh` tails every service, and the samples show the working shape. |
| Third-party advisories in the sample frontends | Known. The samples pin Angular-era dependency trees on purpose and are tracked separately. |

## Filing an issue that gets answered

Include the ref from `.devkit-version` (or your commit SHA), your `DUPLO_TARGET`, the exact commands
you ran, and the real output. The bug form asks for all of it. A report without a reproduction is
usually a report nobody can act on.

Useful to attach, once redacted: `./logs.sh --no-follow` (or one service, e.g.
`./logs.sh --no-follow duplo-ai-studio`), `docker compose ps`, `docker compose version`, your OS and
architecture, and the `STUDIO_TAG` / `UI_TAG` / `AGENT_TAG` / `XTERM_TAG` / `INSTALLER_TAG` lines from `.env`.
Those tags are not secret and they pin down exactly which build you are on.

## Never paste

`.env`, admin tokens, LLM API keys, passwords, customer names, account IDs, or ticket contents.
`./run.sh` writes a long-lived Administrator token into `.env`; treat that file the way you'd treat
a production credential. Redact before you attach anything.
