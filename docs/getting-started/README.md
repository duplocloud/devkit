# Getting started

Everything you need to go from an empty directory to a working DuploCloud extension. No prior
DuploCloud knowledge assumed, and nothing to read outside this repo.

**What you'll have at the end:** the DuploCloud AI Helpdesk platform running locally, connected to
your AWS account and to an EKS cluster, with your own extension loaded into it as a first-class
resource type — its own backend, its own UI, and its own provisioning.

> **In a hurry?** [../quickstart.md](../quickstart.md) is the short version: a running platform with
> AWS connected. No Kubernetes, no extension.

## The path

Work through these in order. Each page states what it needs from the one before it, and ends by
pointing at the next.

| # | Page | What you get |
| --- | --- | --- |
| 0 | [Prerequisites](prerequisites.md) | Confirmation that you have everything this kit needs |
| 0a | [Windows: set up WSL](windows-wsl.md) | *Windows only.* A WSL 2 Ubuntu shell with Docker and Compose v2 |
| 1 | [Install and sign in](install.md) | The platform running locally, and you signed in to it |
| 2 | [Connect AWS](connect-aws.md) | The agent answering questions about your AWS account |
| 3 | [Connect Kubernetes](connect-kubernetes.md) | The agent answering questions about your EKS cluster |
| 4 | [Build your first extension](build-your-first-extension.md) | An S3 security posture dashboard, loaded and live with no host restart |
| 5 | Use the Terraform extension — **coming soon** | A real shipping extension importing your own Terraform repo — then modified by you and redeployed |
| 6 | [Where to next](where-to-next.md) | The authoring manual, the samples, and going to production |

## How these pages are written

Every page has the same shape, so once you have read one you know where to look in the next:

- **what you'll do**, in one line
- **what you need first**, linking back to the page that produces it
- **copy-pasteable commands**, with `<angle-bracketed>` placeholders where you substitute your own
  values
- **the output you should see**
- **what's next**

When something goes wrong, [troubleshooting.md](../troubleshooting.md) is the single place to look.

## If you get stuck

- [troubleshooting.md](../troubleshooting.md) — symptoms, causes, and fixes
- [faq.md](../faq.md) — licensing, data, and platform support
- [SUPPORT.md](../../SUPPORT.md) — where to ask, and what to expect
