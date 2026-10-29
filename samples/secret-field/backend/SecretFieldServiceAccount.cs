using Duplo.Ai.Common.Attributes;
using Duplo.Ai.Common.Utilities;
using Duplo.Ai.DataManagement.Encryption;
using Duplo.Ai.DataManagement.Hooks;
using Duplo.Ai.DataManagement.Interfaces;
using Duplo.Ai.DataManagement.Services;
using Duplo.Ai.Model.Attributes;
using Duplo.Ai.Model.Interfaces;
using Duplo.Ai.Model.Resource;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using MongoDB.Bson.Serialization.Attributes;

namespace Duplo.Extension.SecretField;

// Worked reference for reference/21-secrets.md: a resource whose Spec carries a password the USER
// chooses for the external service account this resource represents — not a credential for THIS
// extension to call some other system (that would be a Scope/Credential, see
// reference/07-scope-credentials.md), but an inherent attribute of the resource itself, same category
// as an RDS master password or a VM admin password. This sample exercises, end to end, every layer
// reference/21-secrets.md describes:
//   1. [SecretValue(ExcludeFromResponse = true)] — dropped from every GET/List/Create/Update/PATCH response.
//   2. [AgentSecretValue]                        — dropped from shared/secret-field-service-account.json
//                                                   (what the agent Reads); the real value instead goes to
//                                                   the sibling .secrets.json, read only by provision.sh via jq.
//   3. IMongoEncryptionProvider                  — encrypted at the BSON boundary (this file's hooks class).
//   4. ISecretRedactionService                   — the plaintext is registered so it's scrubbed from any
//                                                   agent output that might otherwise echo it.
//   5. A reveal endpoint                         — SecretFieldServiceAccountsController.RevealPassword,
//                                                   gated by the separately-grantable secretfield.secret.read
//                                                   action — the only supported way to read the real value back.

/// <summary>User-supplied inputs for a Secret Field Service Account resource.</summary>
[BsonIgnoreExtraElements]
public class SecretFieldServiceAccountSpec : BaseSpec
{
    /// <summary>Not sensitive — identifies the account, doesn't authenticate it.</summary>
    public string? Username { get; set; }

    /// <summary>
    /// The account's password. Plaintext in C# memory; encrypted at the BSON boundary by
    /// <see cref="SecretFieldServiceAccountHooks"/> (mirrors the platform's own
    /// <c>AzureVirtualMachineHooks</c>/<c>AWSRdsInstanceHooks</c>).
    /// <para>
    /// <c>ExcludeFromResponse</c> keeps the real value out of every controller JSON response (GET, List,
    /// and the entity echoed by Create/Update/PATCH) — generic, wired once in the host's response
    /// serializer. <c>[AgentSecretValue]</c> keeps it out of
    /// <c>shared/secret-field-service-account.json</c> too (what the provisioning agent <c>Read</c>s);
    /// the real value is written instead to the sibling
    /// <c>shared/secret-field-service-account.secrets.json</c>, which <c>provision.sh</c> reads with
    /// <c>jq</c> — never with the Read tool. To retrieve the real value after creation, use
    /// <c>SecretFieldServiceAccountsController.RevealPassword</c> (<c>GET {id}/password</c>, gated by the
    /// separately-grantable <c>secretfield.secret.read</c> action) — never add a second, unguarded way to
    /// read this field back. See reference/21-secrets.md.
    /// </para>
    /// </summary>
    [SecretValue(ExcludeFromResponse = true)]
    [AgentSecretValue]
    public string? Password { get; set; }
}

/// <summary>Outputs the provisioning skill writes back.</summary>
[BsonIgnoreExtraElements]
public class SecretFieldServiceAccountResult : BaseResult
{
    /// <summary>The (fictitious) external system's id for the created account — an identifier, not a credential; not sensitive.</summary>
    public string? AccountId { get; set; }
}

/// <summary>
/// The entity. Its own Mongo collection; the ticket origin type/sub-type drive skill-mapping resolution
/// during provisioning.
/// </summary>
[BsonCollection("extension_secretfieldserviceaccounts")]
[BsonIgnoreExtraElements]
public class SecretFieldServiceAccount : ResourceBase<SecretFieldServiceAccountSpec, SecretFieldServiceAccountResult>
{
    public override string GetTicketOriginType() => "SecretFieldServiceAccount";
    public override string GetTicketOriginSubType() => "secret-field-service-account";
}

/// <summary>
/// Encrypts/decrypts <see cref="SecretFieldServiceAccountSpec.Password"/> at the BSON boundary and
/// registers the plaintext with <see cref="ISecretRedactionService"/> whenever it's in hand — the exact
/// recipe the platform's own password-bearing resources use (Azure VM, Azure Postgres Flexible Server,
/// AWS RDS). See reference/21-secrets.md for why each call below is where it is.
/// </summary>
public class SecretFieldServiceAccountHooks
    : ResourceHooksBase<SecretFieldServiceAccount, SecretFieldServiceAccountSpec, SecretFieldServiceAccountResult>
{
    private readonly IMongoEncryptionProvider _encryption;
    private readonly ISecretRedactionService _redaction;

    public SecretFieldServiceAccountHooks(
        ILogger<SecretFieldServiceAccountHooks> logger,
        IServiceProvider serviceProvider,
        IMongoEncryptionProvider encryption,
        ISecretRedactionService redaction)
        : base(logger, serviceProvider)
    {
        _encryption = encryption;
        _redaction = redaction;
    }

    public override async Task OnPreCreateAsync(SecretFieldServiceAccount entity, CancellationToken cancellationToken)
    {
        await base.OnPreCreateAsync(entity, cancellationToken);
        await EncryptPasswordAsync(entity, existing: null, cancellationToken);
    }

    public override async Task OnPreUpdateAsync(
        SecretFieldServiceAccount existing, SecretFieldServiceAccount updated, CancellationToken cancellationToken)
    {
        await base.OnPreUpdateAsync(existing, updated, cancellationToken);
        await EncryptPasswordAsync(updated, existing, cancellationToken);
    }

    public override async Task OnPostReadAsync(SecretFieldServiceAccount entity, CancellationToken cancellationToken)
    {
        await base.OnPostReadAsync(entity, cancellationToken);
        var stored = entity.Spec?.Password;
        if (string.IsNullOrEmpty(stored))
            return;

        if (await _encryption.IsEncryptedAsync(stored, cancellationToken))
        {
            try
            {
                var plaintext = await _encryption.DecryptAsync(stored, cancellationToken);
                entity.Spec!.Password = plaintext;
                _redaction.AddSecret(plaintext); // re-register on every read — the registry is in-memory only
            }
            catch (Exception ex)
            {
                // A value that still looks encrypted after a failed decrypt is left as ciphertext rather
                // than thrown here — [SecretValue(ExcludeFromResponse=true)] already keeps it out of every
                // response either way, so a GET/List never 500s over it. RevealPasswordAsync (service,
                // below) is where a decrypt failure is surfaced explicitly to a caller who needs the real
                // value. This catch is what actually delivers that; without it the exception would
                // propagate straight through GetByIdAsync and pre-empt RevealPasswordAsync's own check.
                Logger.LogError(ex,
                    "OnPostReadAsync: failed to decrypt stored password for SecretFieldServiceAccount {Id}", entity.Id);
            }
        }
    }

    /// <summary>
    /// PATCH semantics (reference/04-hooks.md: spec is replaced wholesale, reference/21-secrets.md: don't
    /// let an edit silently wipe the secret) — a blank/absent password in the incoming spec means "keep
    /// what's stored", never "clear it". Only a genuinely new, non-empty PLAINTEXT value is registered
    /// for redaction and encrypted.
    /// <para>
    /// <b>Why the <c>IsEncryptedAsync</c> check is required, not optional:</b> <c>OnPreUpdateAsync</c>
    /// fires on every update that round-trips the full entity — not only a user's PATCH, but also
    /// internal platform updates such as stamping <c>TicketContext</c> once the provisioning ticket
    /// exists. Those carry the password exactly as last persisted, i.e. already ciphertext. Without
    /// this check, a non-empty-but-already-encrypted value would be fed back into <c>EncryptAsync</c>
    /// and encrypted a SECOND time — and again on every subsequent internal update — silently
    /// corrupting the stored value past what a single <c>DecryptAsync</c> call can recover. Confirmed
    /// live: the ticket's shared/*.secrets.json value differed from the freshly-inserted Mongo value
    /// because the TicketContext-stamping update (which fires ~1 write after create) re-encrypted it.
    /// </para>
    /// </summary>
    private async Task EncryptPasswordAsync(
        SecretFieldServiceAccount entity, SecretFieldServiceAccount? existing, CancellationToken cancellationToken)
    {
        var incoming = entity.Spec?.Password;
        if (string.IsNullOrEmpty(incoming))
        {
            if (entity.Spec != null)
                entity.Spec.Password = existing?.Spec?.Password; // keep existing ciphertext
            return;
        }

        if (await _encryption.IsEncryptedAsync(incoming, cancellationToken))
            return; // already ciphertext (an internal update replayed it) — leave it untouched

        _redaction.AddSecret(incoming); // genuinely new plaintext — register before encrypting
        entity.Spec!.Password = await _encryption.EncryptAsync(incoming, cancellationToken);
    }
}

/// <summary>
/// Resource service deriving from <see cref="ResourceServiceBase{TResource,TSpec,TResult}"/>. Adds one
/// method beyond standard CRUD: <see cref="RevealPasswordAsync"/>, backing the controller's reveal
/// endpoint.
/// </summary>
public class SecretFieldServiceAccountService
    : ResourceServiceBase<SecretFieldServiceAccount, SecretFieldServiceAccountSpec, SecretFieldServiceAccountResult>
{
    private readonly IMongoEncryptionProvider _encryption;

    public SecretFieldServiceAccountService(
        IRepository<SecretFieldServiceAccount> repository,
        ILogger<SecretFieldServiceAccountService> logger,
        IServiceScopeFactory scopeFactory,
        IHttpContextAccessor httpContextAccessor,
        IMongoEncryptionProvider encryption)
        : base(repository, logger, scopeFactory, httpContextAccessor)
    {
        _encryption = encryption;
    }

    /// <summary>
    /// The base implementation serializes <paramref name="resource"/> exactly as handed in — still
    /// ciphertext, since nothing decrypts it between <c>OnPreCreateAsync</c> and this call. The host's
    /// generic <c>[AgentSecretValue]</c> redaction (<c>ResourceProvisioningManager.RedactAgentSpecSecrets</c>)
    /// only MOVES whatever value is already in the JSON into the sibling <c>.secrets.json</c> file — it
    /// has no idea how to decrypt anything. Without this override, that sibling file ends up holding the
    /// same useless ciphertext as the main file would have, instead of the real password a skill needs to
    /// actually use. Mirrors <c>AzureVirtualMachineService.GetExpandedSpecForAgentAsync</c> exactly:
    /// decrypt, serialize, then restore the ciphertext on the entity so nothing else downstream — the
    /// in-memory object this same request might still use afterward — ever sees the plaintext.
    /// </summary>
    public override async Task<string> GetExpandedSpecForAgentAsync(
        SecretFieldServiceAccount resource, CancellationToken ct = default)
    {
        var cipher = resource.Spec?.Password;
        // The IsEncryptedAsync check matters here as much as it does in OnPostReadAsync/EncryptPasswordAsync:
        // if this resource was already read through the normal entity pipeline before reaching this call
        // (OnPostReadAsync decrypts Spec.Password in place), `cipher` is already plaintext here. Decrypting
        // it a second time would either throw or hand the agent a corrupted value — the decrypt-side mirror
        // of the double-encryption bug fixed above. Skip straight to the base serializer in that case.
        if (string.IsNullOrWhiteSpace(cipher) || resource.Spec is null
            || !await _encryption.IsEncryptedAsync(cipher, ct))
            return await base.GetExpandedSpecForAgentAsync(resource, ct);

        var plaintext = await _encryption.DecryptAsync(cipher, ct);
        resource.Spec.Password = plaintext;
        try
        {
            return await base.GetExpandedSpecForAgentAsync(resource, ct);
        }
        finally
        {
            resource.Spec.Password = cipher;
        }
    }

    /// <summary>
    /// Decrypts and returns the real password for <paramref name="id"/> — the one supported way to read
    /// this field back, since <see cref="SecretFieldServiceAccountSpec.Password"/> is
    /// <c>[SecretValue(ExcludeFromResponse = true)]</c> and never appears in any other response. Backs
    /// <c>SecretFieldServiceAccountsController.RevealPassword</c>, gated by the
    /// <c>secretfield.secret.read</c> access-control action. See reference/21-secrets.md.
    /// </summary>
    /// <exception cref="KeyNotFoundException">No account with this id.</exception>
    /// <exception cref="InvalidOperationException">No password is stored, or it failed to decrypt.</exception>
    public async Task<string> RevealPasswordAsync(string id, CancellationToken cancellationToken = default)
    {
        var entity = await Repository.GetByIdAsync(id, cancellationToken)
            ?? throw new KeyNotFoundException($"SecretFieldServiceAccount '{id}' not found");

        var pw = entity.Spec?.Password;
        if (string.IsNullOrEmpty(pw))
            throw new InvalidOperationException("No password is stored for this service account.");

        // OnPostReadAsync (via GetByIdAsync's entity hooks, just above) already attempted decryption; a
        // value that still looks encrypted means that attempt failed — surface that explicitly instead
        // of handing back ciphertext as if it were the real password.
        if (await _encryption.IsEncryptedAsync(pw, cancellationToken))
        {
            Logger.LogError(
                "RevealPasswordAsync: stored password for SecretFieldServiceAccount {Id} failed to decrypt", id);
            throw new InvalidOperationException("Unable to decrypt the stored password. Contact support.");
        }

        return pw;
    }
}
