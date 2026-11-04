# 21 — Secrets in Spec/Result fields (passwords, API tokens, keys)

A resource's `Spec`/`Result` is plain C# — nothing stops an extension author from adding
`public string? Password { get; set; }` the same way they'd add `public string? Region { get; set; }`.
Treated as an ordinary field, that value is: stored in Mongo in plaintext, echoed back in full on every
GET/List/Create/Update/PATCH response, **and** written in plaintext into `shared/<subtype>.json` — the
file the LLM provisioning agent `Read`s into its own conversation. The attributes and recipe below close
all three, plus the on-screen and ask-AI leaks that follow from them. Worked end-to-end:
[`samples/secret-field`](../../../../samples/secret-field).

## First question: does this even belong on your Spec?

| The secret is… | Use |
|---|---|
| Credentials for an **external system** your extension calls (a SaaS API, a cloud account) | A **Provider/Credential/Scope** ([07-scope-credentials](07-scope-credentials.md)) — `spec.ScopeIds`, not a raw field. Already encrypted at rest, already delivered to the ticket workdir per 07-scope-credentials (the exact on-disk location depends on provider category — `other_scopes/<name>.json` only for category `other`), already excluded from every response. Nothing further to do. |
| An **inherent attribute of the resource itself** — a password/token the user is choosing *for the thing you're creating* (a DB master password, a service-account token you mint) | There is no Scope for this — it's genuinely part of the resource's own Spec/Result. Use the `[SecretValue]`/`[AgentSecretValue]` pattern below. |

If you're unsure which one you have: would a different, unrelated resource in the same workspace ever
reuse this exact credential? If yes, it's a Scope. If the value only ever makes sense attached to this one
resource, it's a Spec/Result field.

## The four layers

All four types below ship in the SDK feed today (`Duplo.Ai.Common`, `Duplo.Ai.DataManagement`), so you can
reference and compile against all of them with no SDK change. **Runtime is a different story for layers 3
and 4**: `IMongoEncryptionProvider` and `ISecretRedactionService` only resolve inside an extension's own DI
container if the host bridges them in (`HostServiceBridge.HostSingletons`, duplo-ai-helpdesk #734). On a
host build that predates that bridge, a resource whose hooks constructor requires either service fails to
load with:

    Unable to resolve service for type 'Duplo.Ai.DataManagement.Encryption.IMongoEncryptionProvider' while
    attempting to activate 'Duplo.Extension.<YourResource>Hooks'.

#734 shipped to the `dev`/`release/0.2.25` lines of duplo-ai-helpdesk but did not bump the SDK's `VERSION`
constant, so devkit's build-time SDK check cannot tell you whether your target host has it — the only way
to know is to check the host build, or load the extension and watch for the error above. The first two
layers are genuinely automatic the moment you add the attribute; the other two are a recipe you copy, but
only work once your host build includes #734.

| Layer | Attribute / type | What it does | Automatic? |
|---|---|---|---|
| 1. Response exclusion | `[SecretValue(ExcludeFromResponse = true)]` (`Duplo.Ai.Common.Attributes`) | Drops the property from **every** controller JSON response — GET, List, and the entity echoed by Create/Update/PATCH. Scoped to the response serializer only; model binding, BSON persistence, and the agent-spec serializer are untouched. | **Yes** — add the attribute, nothing else. |
| 2. Agent-spec exclusion | `[AgentSecretValue]` (`Duplo.Ai.Common.Attributes`) | Strips the property out of `shared/<subtype>.json` (what the agent `Read`s) and writes it instead to a sibling `shared/<subtype>.secrets.json`. That sibling file is permanently blocked from the ticket-files API (upload/download/list all refuse it) — the only way to it is your skill reading it directly on disk with `jq`. | **Spec only.** The host's redaction cache (`AgentSecretPropertyCache<TSpec>` in `ResourceProvisioningManager`) scans `TSpec` exclusively — it never looks at `TResult`. **A `[AgentSecretValue]` on a Result property is a silent no-op**: the agent-spec writer serializes `result` too, and that field goes into `shared/<subtype>.json` in plaintext regardless of the attribute. Don't put a secret on Result; if you must, protect it some other way (never store it there at all is simplest). |
| 3. At-rest encryption | `IMongoEncryptionProvider` (`Duplo.Ai.DataManagement.Encryption`) — `EncryptAsync`/`DecryptAsync`/`IsEncryptedAsync` | Encrypts the plaintext before it hits Mongo. | **No** — inject it into your own entity hooks and call it explicitly. Recipe below. |
| 4. Streamed-output backstop | `ISecretRedactionService` (`Duplo.Ai.Common.Utilities`) — `AddSecret(value)` | Once a plaintext value is registered, it's scrubbed to `[REDACTED]` everywhere it later appears in the agent's streamed ticket-chat output — a safety net if a skill ever echoes something it shouldn't. | **No** — call `AddSecret` yourself, right after you decrypt. **Silently does nothing for anything under 8 characters** (`SecretRedactionService.MinSecretLength`) — `AddSecret` just returns `false`, no exception, no log. A short password/token is never redacted from streamed output; enforce a minimum length on the field (`minlength="8"` client-side, and reject shorter values server-side) if this backstop matters to you. |

Plus a **reveal endpoint** (layer 5): nothing in the base `ResourcesController<T,TSpec,TResult>` exposes a
decrypted value back to a caller — every resource that needs one (a user reconnecting to a DB with its
original password, say) hand-writes a dedicated, separately-gated endpoint. No generic helper exists;
copy the recipe below.

**Default to marking a field with both `[SecretValue(ExcludeFromResponse = true)]` AND
`[AgentSecretValue]` together.** The only reason to omit `[AgentSecretValue]` is a skill that has a
specific, deliberate need to read the plaintext straight out of the main spec file — and if you do that,
say why in a comment next to the property, the same way you'd document any other deviation from the safe
default.

## The recipe (entity hooks)

There are two different first-party patterns for this, not one — pick one deliberately, don't mix them:

- **Azure VM shape** (`AzureVirtualMachineHooks`): never decrypts on read. The entity holds ciphertext in
  memory at all times; only the agent-spec override below and an explicit reveal-endpoint caller ever
  decrypt. Simpler — no per-row decrypt on every read, no risk of a blank edit copying a decrypted value.
- **RDS/ElastiCache shape** (`AWSRdsInstanceHooks`, `AWSRdsClusterHooks`, `AWSElastiCacheHooks`): decrypts
  in `OnPostReadAsync`, but then RESTORES the plaintext again in `OnPostCreateAsync`/`OnPostUpdateAsync` —
  so the entity the agent-spec serializer sees is already plaintext and needs no override at all.

The recipe below follows the **RDS/ElastiCache read side**, but — unlike RDS — does **not** restore
plaintext after a write, so its `GetExpandedSpecForAgentAsync` override (further down) still needs to
decrypt, guarded by `IsEncryptedAsync` since `OnPostReadAsync` may already have left the entity plaintext in
memory by the time that override runs. If you'd rather match the RDS shape exactly (and drop the override's
guard), restore plaintext in `OnPostCreateAsync`/`OnPostUpdateAsync` too; if you'd rather match the simpler
Azure VM shape, don't decrypt in `OnPostReadAsync` at all. On your entity's hooks class
(`ResourceHooksBase<TResource,TSpec,TResult>` or `DefaultEntityHooks<TResource>`):

```csharp
public class MyResourceHooks : ResourceHooksBase<MyResource, MyResourceSpec, MyResourceResult>
{
    private readonly IMongoEncryptionProvider _encryption;
    private readonly ISecretRedactionService _redaction;

    public MyResourceHooks(ILogger<MyResourceHooks> logger, IServiceProvider serviceProvider,
        IMongoEncryptionProvider encryption, ISecretRedactionService redaction)
        : base(logger, serviceProvider)
    {
        _encryption = encryption;
        _redaction = redaction;
    }

    public override async Task OnPreCreateAsync(MyResource entity, CancellationToken ct)
    {
        await base.OnPreCreateAsync(entity, ct);
        await EncryptPasswordAsync(entity, existing: null, ct);
    }

    public override async Task OnPreUpdateAsync(MyResource existing, MyResource updated, CancellationToken ct)
    {
        await base.OnPreUpdateAsync(existing, updated, ct);
        await EncryptPasswordAsync(updated, existing, ct);
    }

    // PATCH semantics (see below): absent/null in the incoming spec means "keep what's stored" —
    // never persist null over a real value. Only a genuinely new, non-empty PLAINTEXT value is encrypted.
    private async Task EncryptPasswordAsync(MyResource entity, MyResource? existing, CancellationToken ct)
    {
        var incoming = entity.Spec?.Password;
        if (string.IsNullOrEmpty(incoming))
        {
            // DO NOT just copy-and-return here: `existing` reaches this hook already decrypted —
            // MongoRepository.UpdateAsync re-fetches the current row via GetByIdAsync, which runs
            // OnPostReadAsync (below) before OnPreUpdateAsync ever sees it. So existing.Spec.Password is
            // PLAINTEXT at this point, despite what its name suggests. Returning right after copying it
            // persists that plaintext to Mongo on every edit that leaves the field blank — a real bug a
            // copy of this exact recipe shipped with. Instead, feed the copied value back into `incoming`
            // so it falls through to the same IsEncryptedAsync/EncryptAsync path below, the same shape
            // AWSRdsInstanceHooks.OnPreUpdateAsync already uses for this exact situation (no early return).
            incoming = existing?.Spec?.Password;
            if (string.IsNullOrEmpty(incoming) || entity.Spec is null) return;
            entity.Spec.Password = incoming;
        }
        // REQUIRED, not optional: OnPreUpdateAsync fires on every update that round-trips the full
        // entity — not only a user's PATCH, but also internal platform updates such as stamping
        // TicketContext once the provisioning ticket exists. Those carry the password exactly as last
        // persisted, i.e. already ciphertext. Skipping this check re-encrypts already-encrypted
        // ciphertext as if it were new plaintext — and again on every subsequent internal update —
        // silently corrupting the value past what one DecryptAsync call can recover. This is not a
        // hypothetical: it happened on the very first resource built from an earlier draft of this
        // recipe that omitted the check.
        if (await _encryption.IsEncryptedAsync(incoming, ct))
            return;
        _redaction.AddSecret(incoming);                 // plaintext still in hand — register before encrypting
        entity.Spec!.Password = await _encryption.EncryptAsync(incoming, ct);
    }

    public override async Task OnPostReadAsync(MyResource entity, CancellationToken ct)
    {
        await base.OnPostReadAsync(entity, ct);
        var stored = entity.Spec?.Password;
        if (string.IsNullOrEmpty(stored)) return;
        if (await _encryption.IsEncryptedAsync(stored, ct))
        {
            try
            {
                var plaintext = await _encryption.DecryptAsync(stored, ct);
                entity.Spec!.Password = plaintext;
                _redaction.AddSecret(plaintext);         // re-register on every read — the registry is in-memory
            }
            catch (Exception ex)
            {
                // DecryptAsync fails CLOSED by default on this platform version — it throws rather than
                // silently returning the ciphertext unchanged, unless an operator has opted into
                // Encryption:AllowUnencryptedFallback (off by default). Without this catch, that exception
                // propagates straight through GetByIdAsync and 500s every GET/List over this entity, and
                // pre-empts the reveal endpoint's own explicit "failed to decrypt" error below. Leave the
                // value as ciphertext instead — [SecretValue(ExcludeFromResponse=true)] already keeps it
                // out of the response either way, so there's nothing unsafe about leaving it.
                Logger.LogError(ex, "OnPostReadAsync: failed to decrypt stored password for {Id}", entity.Id);
            }
        }
    }
}
```

`entity.Spec.Password` always carries the real ciphertext (or plaintext, mid-request) in C# memory — this
hooks class never blanks it. Keeping it out of responses is handled once, generically, by
`[SecretValue(ExcludeFromResponse = true)]` at the serialization boundary; keeping it out of the agent is
handled once, generically, by `[AgentSecretValue]`. Nothing in your controller or service needs to scrub
anything.

## The agent-spec serializer override — REQUIRED if you combine `[AgentSecretValue]` with at-rest encryption

This step is easy to skip because nothing fails loudly without it — the build succeeds, the agent still
never sees the password, and the sibling `shared/<subtype>.secrets.json` file still gets created. It just
contains a value no skill can actually use.

Here's why: `[AgentSecretValue]`'s host-side redaction (`ResourceProvisioningManager.RedactAgentSpecSecrets`)
only **moves** whatever value is already in the agent-spec JSON into the sibling file — it has no concept
of decryption. That JSON comes from `GetExpandedSpecForAgentAsync`, whose **default implementation
serializes the entity exactly as handed in**. Right after `OnPreCreateAsync`, that's ciphertext — nothing
has decrypted it yet. So without an override, the sibling file ends up holding the same ciphertext Mongo
has — useless to a skill that needs the real password to actually authenticate somewhere. (This is not
hypothetical: it's the exact gap that let `samples/secret-field` ship with this bug the first time — the
sample's own `provision.sh` never surfaced it because it only checks whether the field is *present*, never
tries to use the value for anything real.)

Mirror the platform's own fix for this (`AzureVirtualMachineService.GetExpandedSpecForAgentAsync`) on your
resource's service class — decrypt, let the base method serialize, then restore the ciphertext so nothing
downstream that reuses this same in-memory entity ever sees the plaintext. **The `IsEncryptedAsync` guard
below matters, not just the null check**: if this same resource was already read through the normal entity
pipeline before reaching this call (`OnPostReadAsync`, above, already decrypted `Spec.Password` in place —
which can happen any time the host re-fetches the resource to regenerate its ticket files, not only right
after create), `cipher` is already plaintext here. Decrypting it a second time would either throw or hand
the agent a corrupted value — the decrypt-side mirror of the double-encryption bug the recipe's
`EncryptPasswordAsync` guards against above:

```csharp
public override async Task<string> GetExpandedSpecForAgentAsync(MyResource resource, CancellationToken ct = default)
{
    var cipher = resource.Spec?.Password;
    if (string.IsNullOrWhiteSpace(cipher) || resource.Spec is null
        || !await _encryption.IsEncryptedAsync(cipher, ct))
        return await base.GetExpandedSpecForAgentAsync(resource, ct);

    var plaintext = await _encryption.DecryptAsync(cipher, ct);
    resource.Spec.Password = plaintext;
    try
    {
        return await base.GetExpandedSpecForAgentAsync(resource, ct);   // bakes plaintext into the JSON string
    }
    finally
    {
        resource.Spec.Password = cipher;                                // never skip this, even on an exception path
    }
}
```

**This override is only required if your hooks leave ciphertext in memory** — either the Azure VM shape
(never decrypts on read) or, like the recipe above, the RDS read-side without the RDS write-side restore.
If your hooks instead restore plaintext in `OnPostCreateAsync`/`OnPostUpdateAsync` (the full RDS shape),
the entity the agent-spec serializer sees is already plaintext and this override is redundant — such a
resource needs a `// agent-secret-spec-exception: <reason>` comment to get past the lint below instead.

`scripts/build-extension.sh`'s build gate fails your build if it finds `[AgentSecretValue]` plus your own
`EncryptAsync` call with no override like this anywhere in the backend — but that check can only confirm
an override **exists**, not that it's correct (e.g. that you actually restore the ciphertext in `finally`).
Treat the lint as a floor, not a substitute for the verification checklist at the end of this doc.

## The reveal endpoint

Only needed when some caller legitimately has to retrieve the real value later (a user reconnecting to a
database with its original password). Gate it with a **named action** ([18-access-control](18-access-control.md)),
never plain CRUD access — revealing a secret is a materially bigger grant than "can read this resource":

```csharp
// duplo-review-exception: secret-returned-to-client
// reason: the user who owns this resource needs the real password to connect to it, and there is no
//   other way to retrieve it. Scoped to this one explicit, separately-permissioned action — never
//   returned from any other endpoint.
[HttpGet("{id}/password")]
[AccessControl(Action = "myresource.secret.read",
    ActionName = "Reveal password", Destructive = true,
    Description = "Decrypts and returns the real password. A materially bigger grant than ordinary read access.")]
public async Task<IActionResult> RevealPassword(string id, CancellationToken ct)
{
    var value = await _service.RevealPasswordAsync(id, ct);   // decrypts; throws KeyNotFoundException / InvalidOperationException
    return Ok(ApiResponse<object>.SuccessResult(new { value }, "Password retrieved"));
}
```

The service method re-reads the entity, checks `IsEncryptedAsync` to detect a stored value that failed to
decrypt (surface that as an explicit error — never hand back ciphertext as if it were real), and returns
the plaintext. See `samples/secret-field` for the full method.

## The skill side — reading the sibling `.secrets.json`

`[AgentSecretValue]` only protects the field if the skill actually reads it from the sibling file instead
of the main one. In your `provision.sh` (or equivalent), extract it with `jq` **immediately before its one
use** — never with the Read tool, never `echo`/`cat` to stdout, never cached across steps:

```bash
if [ -f ./shared/my-resource.secrets.json ]; then
  PASSWORD=$(jq -r '.password // empty' ./shared/my-resource.secrets.json)
else
  PASSWORD=""
fi
[ -z "$PASSWORD" ] && PASSWORD=$(jq -r '.spec.password // empty' ./shared/my-resource.json)  # fallback: unset/cleared
```

The fallback exists so a ticket written by an older build of your extension (before you added
`[AgentSecretValue]`), or a resource with no password set, still resolves correctly either way.

## PATCH semantics — don't let an edit silently wipe the secret

[04-hooks](04-hooks.md) already establishes that `PATCH {id}` replaces `spec` wholesale, so an edit form
must send the **full** spec. For a secret field that's excluded from GET, the edit form has no value to
echo back — so the convention has to be explicit:

- **Key absent, or value `null`/empty** in the incoming spec → keep the currently-stored value unchanged.
- **A non-empty string** → treat it as a real replacement; encrypt and persist it.

There is no way to distinguish "user left it blank because they didn't change it" from "user wants to
clear it" with a bare string, so if your resource genuinely needs a clear action, give it one explicitly
(a checkbox, a separate `ClearPassword: true` flag) rather than overloading empty string.

## Frontend — write-only, never redisplay

`<password-field>` ([14-forms-and-wizards](14-forms-and-wizards.md)) masks the *display*; it does not stop
a naive edit form from re-submitting whatever the GET response contained. Since the field is now excluded
from every GET, there is nothing to pre-populate — build the edit form accordingly:
- **Add form**: an ordinary `<password-field>`, required.
- **Edit form**: show a placeholder (`"•••• — leave blank to keep"`), start the model field `undefined`,
  and only include the key in the PATCH body when the user actually typed something.

## Hard rules

- **Never put a secret in `AdditionalCustomSpec` or `ExtraConfigs`.** These are untyped `BsonDocument` bags
  — attribute-based protection is structurally impossible on a dynamic key, so anything placed there is
  permanently unprotected by every layer above.
- **The frontend's `buildAskAiContext()` ([16-ask-ai](16-ask-ai.md)) is safe by construction** — it reads
  `item.spec`/`item.result` as populated from the same GET response every other view uses, which already
  never carried the real value. The actual risk is the **backend**-created-ticket alternative (16-ask-ai
  §9): a hand-written `GetTicketMetadata()`/`GetTicketTitle()`/`GetProvisioningMessage()` override runs
  server-side with the real, decrypted `entity.Spec`/`entity.Result` in hand — `ExcludeFromResponse` only
  strips a field from HTTP responses, and these methods don't produce one. Never interpolate a marked field
  into any string one of them builds.
- **Worker mode is not exempt** — `entity.Result` written via `SaveProgressAsync` goes through the same
  response serializer, so layer 1 already covers it; just don't log the plaintext in `Logger.Log*` calls
  along the way.

## Verification checklist — run this for real, every time

`scripts/build-extension.sh`'s lint catches the common mistake (a field with no attribute at all, or
`[AgentSecretValue]` + your own encryption with no decrypting override). It cannot catch whether your
override is semantically correct, whether your encryption logic is idempotent across repeated updates, or
whether the target platform actually has `IMongoEncryptionProvider`/`ISecretRedactionService` bridged into
extension DI containers at all (a host capability, not a devkit one — see your platform's release notes).
Both real bugs this doc now warns about were found by *running* the extension, not by reading the code —
do the same before calling this done:

1. Create a resource with the secret field set. Confirm the GET response has no value for it at all.
2. Open its provisioning ticket's workdir. Confirm `shared/<subtype>.json` has the field as `null`, and
   `shared/<subtype>.secrets.json` exists.
3. **Confirm the sibling file's value is genuinely usable** — not another ciphertext blob. If you have
   nothing else to compare it against, this is what the `GetExpandedSpecForAgentAsync` override above is
   for; skipping it is invisible until a skill actually tries to use the value.
4. Trigger at least one more update to the resource after creation (an edit, or just let the platform
   stamp `TicketContext` on it, which happens automatically once the ticket exists). Reveal the password
   again — it must still be the original value. This is the one step that catches double-encryption; it
   will not show up after a single create.
5. Reveal the password through your endpoint and confirm it matches what you originally typed.
6. **Edit the resource leaving the secret field blank, then inspect the Mongo document directly** (not
   just the reveal endpoint — a plaintext value and a correctly-decrypted reveal look identical from the
   API). This is the one step that catches a blank edit silently storing plaintext at rest; the reveal
   endpoint alone cannot distinguish the two cases.
