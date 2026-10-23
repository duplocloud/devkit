using Duplo.Ai.DataManagement.AccessControl;
using Duplo.Ai.DataManagement.Controllers.User.Resource;
using Duplo.Ai.DataManagement.Models;
using Duplo.Ai.Model;
using Duplo.Ai.Model.Interfaces;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.Logging;

namespace Duplo.Extension.SecretField;

/// <summary>
/// The extension's own workspace-scoped REST controller. Inheriting
/// <see cref="ResourcesController{T,TSpec,TResult}"/> provides the full CRUD surface plus
/// <c>POST {id}/results</c>, <c>POST {id}/status</c> and the deprovision lifecycle. The one addition
/// beyond a plain scaffold is <see cref="RevealPassword"/> — see reference/21-secrets.md.
/// </summary>
[ApiController]
[Route("v1/aiservicedesk/user/data/workspaces/{workspaceId}/environment/extensions/secret-field-service-accounts")]
// Access-node declaration: places this resource in the permission tree under its workspace. See
// reference/18-access-control.md.
[AccessControl(Parent = typeof(Workspace), ParentIdProperty = "OwnerWorkspaceId")]
public class SecretFieldServiceAccountsController
    : ResourcesController<SecretFieldServiceAccount, SecretFieldServiceAccountSpec, SecretFieldServiceAccountResult>
{
    private readonly SecretFieldServiceAccountService _service;

    public SecretFieldServiceAccountsController(
        IEntityService<SecretFieldServiceAccount> service,
        SecretFieldServiceAccountService serviceAccountService,
        ILogger<SecretFieldServiceAccountsController> logger)
        : base(service, logger)
    {
        _service = serviceAccountService;
    }

    // ─────────────────────────── Secret reveal ───────────────────────────
    //
    // duplo-review-exception: secret-returned-to-client
    // reason: the user who owns this service account needs the real password to actually use it, and
    //   there is no other way to retrieve it. Scoped to this one explicit, separately-permissioned
    //   action — gated apart from ordinary resource-read access via secretfield.secret.read. Never
    //   returned from any other endpoint. See reference/21-secrets.md.

    /// <summary>
    /// Reveals the real, decrypted password. <see cref="SecretFieldServiceAccountSpec.Password"/> is
    /// <c>[SecretValue(ExcludeFromResponse = true)]</c> — never present in the ordinary GET/List
    /// response or the entity echoed by Create/Update/PATCH. This is the one explicit,
    /// separately-permissioned way to read it back.
    /// </summary>
    [HttpGet("{id}/password")]
    [AccessControl(Action = "secretfield.secret.read",
        ActionName = "Reveal password", Destructive = true,
        Description = "Decrypts and returns the real service-account password. A materially bigger grant than ordinary read access.")]
    public async Task<IActionResult> RevealPassword(string id, CancellationToken cancellationToken)
    {
        try
        {
            var value = await _service.RevealPasswordAsync(id, cancellationToken);
            return Ok(ApiResponse<object>.SuccessResult(new { value }, "Password retrieved"));
        }
        catch (KeyNotFoundException ex)
        {
            return NotFound(ApiResponse<object>.ErrorResult(ex.Message));
        }
        catch (InvalidOperationException ex)
        {
            return BadRequest(ApiResponse<object>.ErrorResult(ex.Message));
        }
    }
}
