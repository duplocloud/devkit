using Duplo.Ai.DataManagement.Interfaces;
using Duplo.Ai.DataManagement.Services;
using Duplo.Ai.Model.Attributes;
using Duplo.Ai.Model.Interfaces;
using Duplo.Ai.Model.Resource;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using MongoDB.Bson.Serialization.Attributes;

namespace Duplo.Extension.AdminSettings;

// An ADMIN-SCOPED first-class resource shipped inside a hot-loaded extension DLL. The entity, hooks and
// service are exactly what a workspace-scoped resource uses (ResourceBase + ResourceServiceBase); only the
// controller differs — AdminSettingsController derives from AdminResourcesController, which serves the
// resource on an admin-only route and makes every row belong to the system Admin Workspace.
//
// Use admin scope for platform-wide configuration an administrator owns, never per-tenant data.
// Reference: reference/21-admin-resources.md (admin scope end to end), reference/03-base-classes.md.

/// <summary>Admin-supplied inputs: one platform setting.</summary>
[BsonIgnoreExtraElements]
public class AdminSettingSpec : BaseSpec
{
    public string? SettingKey { get; set; }
    public string? SettingValue { get; set; }
}

/// <summary>Outputs the provisioning skill writes back.</summary>
[BsonIgnoreExtraElements]
public class AdminSettingResult : BaseResult
{
    /// <summary>What the skill applied, e.g. <c>maintenance-banner = "Back at 18:00"</c>.</summary>
    public string? Summary { get; set; }
}

/// <summary>
/// The entity. Its own Mongo collection (real persistence). The ticket origin type/sub-type drive
/// skill-mapping resolution during provisioning.
/// </summary>
[BsonCollection("extension_adminsetting")]
[BsonIgnoreExtraElements]
public class AdminSetting : ResourceBase<AdminSettingSpec, AdminSettingResult>
{
    public override string GetTicketOriginType() => "AdminSetting";
    public override string GetTicketOriginSubType() => "admin-setting";
}

/// <summary>
/// No-op hooks (framework default base). Swap to <c>ResourceHooksBase&lt;AdminSetting, AdminSettingSpec,
/// AdminSettingResult&gt;</c> if you need the standard invariants (OwnerWorkspaceId immutability, immutable
/// spec fields, delete-status gate) and override <c>GetImmutableSpecFields</c>/<c>GetDeletableStatuses</c>.
/// See reference/04-hooks.md.
/// </summary>
public class AdminSettingHooks : DefaultEntityHooks<AdminSetting>
{
}

/// <summary>
/// Resource service deriving from the real <see cref="ResourceServiceBase{TResource,TSpec,TResult}"/>.
/// Standard CRUD + the provisioning lifecycle (OnAfterCreate fires a ticket) come from the base; the
/// extension host's per-extension child container satisfies the ctor dependencies.
/// </summary>
public class AdminSettingService : ResourceServiceBase<AdminSetting, AdminSettingSpec, AdminSettingResult>
{
    public AdminSettingService(
        IRepository<AdminSetting> repository,
        ILogger<AdminSettingService> logger,
        IServiceScopeFactory scopeFactory,
        IHttpContextAccessor httpContextAccessor)
        : base(repository, logger, scopeFactory, httpContextAccessor)
    {
    }
}
