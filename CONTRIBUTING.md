# Contributing

There are two quite different things you might be doing with this repo. Only one of them involves sending a
pull request here.

## 1. Building your own agents — you don't need a PR

The dev kit is free to build on, subject to the terms described in the [README](README.md). You
clone it, make it your own repo, and your agents live in `extensions/<name>/`:

```bash
git clone https://github.com/duplocloud/devkit my-agent && cd my-agent
./scripts/init-project.sh git@github.com:me/my-agent.git
```

Your `extensions/` directory is yours and is never touched by `./scripts/upgrade_dev_kit.sh`. Nothing in it
belongs upstream — please don't open PRs adding agents to this repository. See the
[README](README.md) for the full workflow.

## 2. Improving the dev kit itself — PRs welcome

Changes to the *framework* are what we take upstream:

- `run.sh`, `stop.sh`, `logs.sh`, and `scripts/`
- `docker-compose.yml`, `nginx/`, and the build toolchain image in `build/`
- The reference agents in `samples/`
- The authoring command and skill under `.claude/`
- `.github/workflows/`
- Documentation

## Getting set up

You need two things:

- **Docker** with Compose v2, and access to `quay.io/duplocloud/*` (`docker login quay.io` if needed)
- **An LLM key for the agent** — an Anthropic key is simplest; Azure Foundry and AWS Bedrock also work

```bash
cp .env.example .env
./run.sh
```

## Verifying a change

There is no unit test suite; verification means exercising the real stack. Match the effort to what you touched:

| You changed | Verify by |
|---|---|
| `scripts/`, `run.sh`, `stop.sh` | `./run.sh --reset`, then build **and** deploy a sample end to end |
| `samples/<name>/` | `./scripts/build-extension.sh` on that sample, then deploy and create one in the UI |
| A sample frontend | `npm ci && npm run build` in that `frontend/` directory |
| `.claude/` skill or reference docs | Run `/duplo-extension` and confirm the guidance still matches reality |
| `docker-compose.yml`, `nginx/` | `./stop.sh --wipe && ./run.sh` from a clean slate |

To exercise a framework change against a sample, copy it into `extensions/` and build there:

```bash
cp -R samples/helloworld extensions/helloworld
./scripts/build-extension.sh  extensions/helloworld
./scripts/deploy-extension.sh extensions/helloworld/dist/agent.zip
./logs.sh                     # tail everything, or one service
```

**Note that CI will not catch sample regressions for you.** `.github/workflows/extension-ci.yml` only builds
`extensions/*/manifest.json`, and this repo ships no `extensions/` directory — so on a PR here the build step
is skipped entirely. Verify `samples/` locally.

## Commit messages

Conventional commits, imperative mood, under 72 characters, no trailing period:

```
fix(run.sh): require terms acceptance before requesting a license
docs: record the terms-acceptance requirement in the design
chore(compose): pull the studio from the devkit image repo
```

Types in use: `feat`, `fix`, `docs`, `test`, `refactor`, `chore`. Scope in parentheses is optional and is
usually the script or component touched. Keep commits focused — one logical change each.

## Please never commit

- **`.env`** or any real credential — admin tokens, LLM keys, `DUPLO_TOKEN`, passwords
- **Customer identifiers** — real customer names, domains, account IDs, support ticket IDs, or verbatim
  customer quotes, including inside agent briefs and prompts
- **Build output** — `dist/`, `node_modules/`, `**/bin/`, `**/obj/`, `backend/sdk-packages/`

`.gitignore` covers the build output and `.env`. One deliberate exception: the vendored library tarball is
committed, because the samples resolve the platform UI library from it — once at the repo-root `packages/`
for every sample, plus a self-contained copy under the skill template's `frontend/vendor/`.

**That tarball is proprietary.** `@duplocloud-internal/ng-common-lib` is the compiled DuploCloud platform
UI library — DuploCloud IP, **not open source**, and **not covered by the Apache License** that governs the
rest of this repository. It is licensed separately as the "Licensed Library" under
[TERMS.md](TERMS.md), which permits building agents against it and shipping the parts your build
bundles into a compiled agent, and nothing else. Do not republish it to any package registry,
unpack or repackage it, copy it into another repository, or remove the `NOTICE` file that sits beside
each committed copy. If you add or bump a vendored copy, copy that `NOTICE` alongside it — nothing
does this for you, and an unmarked tarball ships as if it were Apache-licensed.

## Opening a pull request

By submitting a pull request, you agree to license your contribution under the Apache License,
Version 2.0, and you confirm that you have all necessary rights and permissions to do so.

- One logical change per PR; say what it does and why
- State how you verified it — which samples you built, whether you did a full `--reset` run
- **Call it out prominently if you change `.env.example`**, especially image tags or ports. Those defaults get
  adopted into every user's `.env` on their next `./run.sh` after an upgrade, so a change there reaches everyone.
