# Documentation

Everything beyond the [README](../README.md). Start at the top and work down — the order is the path a new
reader takes.

| Page | What it covers |
| --- | --- |
| [quickstart.md](quickstart.md) | The fast path: a running platform with AWS connected |
| [getting-started/](getting-started/README.md) | The full guided path — prerequisites, install, AWS, Kubernetes, and your first extension |
| [architecture.md](architecture.md) | How the studio, agent, UI, xterm, and Mongo fit together, and how the hot-load loop works |
| [configuration.md](configuration.md) | Every `.env` variable — default, effect, and which are managed for you |
| [cli-reference.md](cli-reference.md) | `run.sh`, `stop.sh`, `logs.sh`, and every script in `scripts/` — flags and behavior |
| [releasing-extensions.md](releasing-extensions.md) | What `release.yml` publishes, signing, and the extra steps inside DuploCloud's own organizations |
| [upgrading.md](upgrading.md) | Taking framework updates, and how image-tag pinning works |
| [troubleshooting.md](troubleshooting.md) | Symptoms, causes, fixes |
| [faq.md](faq.md) | Licensing, data, platform support, and what happens on upgrade |
| [UPGRADING-ng-common-lib.md](UPGRADING-ng-common-lib.md) | Refreshing the vendored `@duplocloud-internal/ng-common-lib` tarball |

## Writing extensions

The authoring manual is the 20 numbered guides in
[`.claude/skills/duplo-extension-dev/reference/`](../.claude/skills/duplo-extension-dev/reference) —
naming, architecture, the authoring path, base classes, hooks, custom actions, registration, scope
credentials, parent/child and menus, the SDK API, deprovisioning, enrichment and live state, current user,
forms and wizards, error handling, opt-in Ask AI sessions, the hand-written result content, access control,
and the detail-page shell. They are the source of truth, and the `/duplo-extension` authoring command reads
them directly.

Worked examples live in [`samples/`](../samples) — start with
[`samples/helloworld`](../samples/helloworld), the reference sample.

## Policies

| Document | What it covers |
| --- | --- |
| [LICENSE](../LICENSE) | Apache-2.0, covering the dev-kit source |
| [NOTICE](../NOTICE) | The boundary: what Apache-2.0 covers and what it does not |
| [TERMS.md](../TERMS.md) | The proprietary container images and vendored library — local development only |
| [SECURITY.md](../SECURITY.md) | Reporting a vulnerability |
| [PRIVACY.md](../PRIVACY.md) | The usage metrics the UI sends if you opt in, and what is collected |
| [CONTRIBUTING.md](../CONTRIBUTING.md) | Framework PRs welcome; your extensions stay in your repo |
| [CODE_OF_CONDUCT.md](../CODE_OF_CONDUCT.md) | Contributor Covenant 2.1 — expected behaviour in issues and PRs |
| [SUPPORT.md](../SUPPORT.md) | Where to get help and what to expect: GitHub Issues, best effort, no SLA |
