# secret-field — a password-bearing resource

Worked reference for **[reference/21-secrets.md](../../.claude/skills/duplo-extension-dev/reference/21-secrets.md)**:
a `SecretFieldServiceAccount` resource whose Spec carries a `Password` the user chooses — an inherent
attribute of the resource itself, not a credential for calling some other system (that's a
Scope/Credential, [07-scope-credentials.md](../../.claude/skills/duplo-extension-dev/reference/07-scope-credentials.md)).
Built from `templates/helloworld`; every change beyond the rename is secrets-related.

## Host prerequisite

This sample's hooks require `IMongoEncryptionProvider` and `ISecretRedactionService` to be resolvable
inside the extension's own DI container — only true on a host build that includes duplo-ai-helpdesk #734
(`HostServiceBridge.HostSingletons`). That change didn't bump the SDK's `VERSION`, so the build-time SDK
check can't detect a host that's missing it. On such a host, loading this extension fails with:

    Unable to resolve service for type 'Duplo.Ai.DataManagement.Encryption.IMongoEncryptionProvider' while
    attempting to activate 'Duplo.Extension.SecretField.SecretFieldServiceAccountHooks'.

If you hit that error, the fix is a host build that includes #734 — not a devkit-side change.

## What it demonstrates, end to end

| Layer | Where |
|---|---|
| `[SecretValue(ExcludeFromResponse = true)]` — dropped from every GET/List/Create/Update/PATCH response | `backend/SecretFieldServiceAccount.cs` (`SecretFieldServiceAccountSpec.Password`) |
| `[AgentSecretValue]` — dropped from `shared/secret-field-service-account.json`, split into the sibling `.secrets.json` | same property; consumed by `skills/provision-secret-field-service-account/provision.sh` via `jq` |
| At-rest encryption (`IMongoEncryptionProvider`) | `SecretFieldServiceAccountHooks.OnPreCreateAsync`/`OnPreUpdateAsync`/`OnPostReadAsync` |
| Streamed-output backstop (`ISecretRedactionService.AddSecret`) | same hooks, right after every encrypt/decrypt |
| Reveal endpoint, gated by a named action | `SecretFieldServiceAccountsController.RevealPassword` (`GET {id}/password`, `secretfield.secret.read`) |
| Write-only edit form (PATCH keep/clear/replace convention) | `frontend/src/app/add/add-secret-field-service-account.component.ts` |
| On-demand reveal from the UI | `frontend/src/app/view/view-secret-field-service-account.component.ts` (eye icon on the Password tile) |
| Skill-side discipline: `jq`, never `Read`, never cached across steps | `skills/provision-secret-field-service-account/SKILL.md` + `provision.sh` |

## Provisioning mode

Agent mode (same as `samples/helloworld`) — deliberately, because the agent-visibility problem
(`[AgentSecretValue]` / the sibling `.secrets.json`) only exists for agent-provisioned resources. The
skill simulates creating the account (no real external system) and derives a fake `accountId` from the
username; a real extension would call its target system's API here, authenticating with the password
read from the secrets file.

## Build
```bash
# The scripts read the target platform from .env (scripts/_target.sh).
./scripts/build-extension.sh  samples/secret-field
./scripts/deploy-extension.sh samples/secret-field/dist/extension.zip
```

## Try it

1. Create a resource with a username + password.
2. `GET` it — confirm the response has no `password` key at all.
3. Watch the ticket — the agent's `Read` of `shared/secret-field-service-account.json` shows
   `"password": null`; the real value only ever touched `provision.sh`'s `jq` extraction.
4. On the detail page's Password tile, click the eye icon — confirms the real value is still retrievable,
   on demand, through the one gated endpoint.
5. Edit the resource leaving Password blank, re-reveal it — then also check the Mongo document directly.
   The reveal endpoint alone can't tell a correctly-kept password apart from one that got silently
   persisted as plaintext; only looking at the stored document can.
