---
name: provision-secret-field-service-account
description: Provisions a Secret Field Service Account resource — the canonical AGENT-BASED provisioning loop for a resource whose spec carries a password. Reads the non-secret spec from shared/secret-field-service-account.json and the password from the sibling secrets.json, "creates" the account (simulated — no real external system), and writes the result back via the resource's own status/results APIs.
---

# provision-secret-field-service-account — agent-based provisioning with a secret spec field

You are the **provisioning agent** for a **Secret Field Service Account** resource (origin
`SecretFieldServiceAccount`, subType `secret-field-service-account`). This is the worked reference for
[reference/21-secrets.md](../../../../.claude/skills/duplo-extension-dev/reference/21-secrets.md): a
resource whose Spec carries a password, and the one thing that differs from the plain
`provision-helloworld` pattern is **where the password lives and how you read it**.

The pattern (same shape as any agent-based resource):

```
read non-secret spec  ->  POST status Processing (+ progressive subStatus)
                      ->  read the password from the SIBLING secrets file, immediately before use
                      ->  do the work  ->  POST results (the outputs)  ->  POST status Complete
                      (on error at any point: POST status Failed + faults, then stop)
```

## Inputs the platform gives you

- `$DUPLO_BASE` (fall back to `$DUPLO_HOST`) + `$DUPLO_TOKEN` — base URL + a **resource-scoped** token
  valid only for THIS resource's `…/{id}/status` and `…/{id}/results`.
- `shared/secret-field-service-account.json` — the resource's expanded spec. Read `spec.username`,
  `id`, `ownerWorkspaceId` from here. **`spec.password` is always `null` in this file** — the backend
  strips any `[AgentSecretValue]` property before writing it, specifically because you `Read` this file
  into your own conversation context. This is safe to `Read` with the Read tool.
- `shared/secret-field-service-account.secrets.json` — present **only** when a password is currently
  stored. Contains `{"password": "<the real value>"}`. **Never open this file with the Read tool.**
  Extract the one field you need with `jq`, in a bash block, immediately before the one place you use it
  — never cache it to a variable that survives across steps, never `echo`/`cat` it, never put it in a
  bash command's `description`. If you need it more than once, re-run the `jq` extraction each time
  rather than reusing an earlier value.

Write-back base: `RES=${DUPLO_BASE:-$DUPLO_HOST}/v1/aiservicedesk/user/data/workspaces/<ownerWorkspaceId>/environment/extensions/secret-field-service-accounts/<id>`.

## Steps

1. **Report progress.** `POST $RES/status {"status":"Processing","subStatus":"Creating service account"}`.
2. **Do the work.** A real skill would call the target system's API here, authenticating with the
   password extracted from the secrets file (see `provision.sh`'s pattern). This sample simulates it —
   it derives a deterministic fake `accountId` and never calls out anywhere.
3. **Write the result** (a SEPARATE api from status, and `accountId` is NOT sensitive — don't confuse an
   identifier with a credential): `POST $RES/results {"accountId":"<...>"}`.
4. **Complete.** `POST $RES/status {"status":"Complete","subStatus":"Service account created"}`.
   On any failure: `POST $RES/status {"status":"Failed","faults":["<message>"]}` and stop.

### Deterministic helper
`provision.sh` (next to this SKILL.md) runs steps 1–4 verbatim. Invoke it by its full mounted path from
the ticket workdir:
```bash
bash .claude/skills/provision-secret-field-service-account/provision.sh
```

## The one rule this skill exists to demonstrate

**Never let the password reach your own context window or any output you produce.** Concretely:
- Don't `Read` `shared/secret-field-service-account.secrets.json` — only `jq` it from inside a bash block.
- Don't assign the extracted value to a variable any earlier than the one bash block that uses it, and
  don't reuse that variable in a later, separate tool call — re-extract instead.
- Don't put the value in a bash command's human-readable `description`, in a status/result message, or in
  any text you write back to the ticket.
- If the account creation fails, report the failure reason — never the password you tried.

## Notes

- **Status and results are two separate APIs** — never fold the result into a status payload (see
  [reference/04-hooks.md](../../../../.claude/skills/duplo-extension-dev/reference/04-hooks.md)).
- The backend C# (`backend/SecretFieldServiceAccount.cs`) defines the typed `spec`/`result` shape, the
  `[SecretValue]`/`[AgentSecretValue]` attributes that make this skill's secrets-file handling necessary,
  and the reveal endpoint a human uses to get the password back later. This skill only fills the
  status/results endpoints `ResourcesController` already provides.
