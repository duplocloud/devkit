using System.Text.Json.Nodes;
using Duplo.Ai.DataManagement.Interfaces;
using Duplo.Ai.DataManagement.Services;
using Duplo.Ai.Model;
using Duplo.Ai.Model.Attributes;
using Duplo.Ai.Model.Interfaces;
using Duplo.Ai.Model.Resource;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using MongoDB.Bson.Serialization.Attributes;

namespace Duplo.Extension.AdminSettings;

// A WORKSPACE-scoped resource that CONSUMES an admin-scoped one — the common shape of an admin extension: an
// administrator provisions a platform-wide AdminSetting once, and each workspace creates an AdminSettingConsumer
// that picks it and is provisioned with its details. What the cross-scope link needs, end to end:
//   • the spec references the admin row by id (AdminSettingId);
//   • ValidateSpecAsync checks that row exists, belongs to the Admin Workspace and is Complete;
//   • GetExpandedSpecForAgentAsync embeds the admin row, because the platform only writes THIS resource's own
//     spec to shared/admin-setting-consumer.json — the agent has no other way to read it;
//   • the admin side refuses to deprovision or delete a setting that consumers still reference
//     (AdminSettingService.GuardNotInUseAsync).
// Reference: reference/21-admin-resources.md → "Workspace resources that consume an admin resource".

/// <summary>Workspace-supplied inputs: which admin setting this workspace uses.</summary>
[BsonIgnoreExtraElements]
public class AdminSettingConsumerSpec : BaseSpec
{
    /// <summary>Id of an <see cref="AdminSetting"/> owned by the Admin Workspace.</summary>
    public string? AdminSettingId { get; set; }
}

/// <summary>Outputs the provisioning skill writes back.</summary>
[BsonIgnoreExtraElements]
public class AdminSettingConsumerResult : BaseResult
{
    /// <summary>What the skill applied in this workspace, e.g. <c>Using maintenance-banner (admin setting 'banner')</c>.</summary>
    public string? Summary { get; set; }
}

[BsonCollection("extension_adminsettingconsumer")]
[BsonIgnoreExtraElements]
public class AdminSettingConsumer : ResourceBase<AdminSettingConsumerSpec, AdminSettingConsumerResult>
{
    public override string GetTicketOriginType() => "AdminSettingConsumer";
    public override string GetTicketOriginSubType() => "admin-setting-consumer";
}

public class AdminSettingConsumerHooks : DefaultEntityHooks<AdminSettingConsumer>
{
}

public class AdminSettingConsumerService : ResourceServiceBase<AdminSettingConsumer, AdminSettingConsumerSpec, AdminSettingConsumerResult>
{
    // The repository, not IEntityService<AdminSetting>: these reads run inside a WORKSPACE request, and the admin
    // rows belong to the Admin Workspace, so every lookup filters on OwnerWorkspaceId itself.
    private readonly IRepository<AdminSetting> _adminSettings;

    public AdminSettingConsumerService(
        IRepository<AdminSettingConsumer> repository,
        ILogger<AdminSettingConsumerService> logger,
        IServiceScopeFactory scopeFactory,
        IHttpContextAccessor httpContextAccessor,
        IRepository<AdminSetting> adminSettings)
        : base(repository, logger, scopeFactory, httpContextAccessor)
    {
        _adminSettings = adminSettings;
    }

    protected override async Task ValidateSpecAsync(
        AdminSettingConsumerSpec spec, bool isUpdate, AdminSettingConsumerSpec? existingSpec, CancellationToken cancellationToken)
    {
        await base.ValidateSpecAsync(spec, isUpdate, existingSpec, cancellationToken);

        // An edit that keeps the same setting stays valid even if that setting is being re-provisioned.
        if (isUpdate && existingSpec?.AdminSettingId == spec.AdminSettingId)
        {
            return;
        }
        if (string.IsNullOrWhiteSpace(spec.AdminSettingId))
        {
            throw new ArgumentException("Pick the admin setting this workspace uses (spec.adminSettingId).");
        }
        var setting = await FindAdminSettingAsync(spec.AdminSettingId, cancellationToken)
            ?? throw new ArgumentException($"Admin setting '{spec.AdminSettingId}' does not exist.");
        if (setting.Status != ResourceStatus.Complete)
        {
            throw new ArgumentException(
                $"Admin setting '{setting.Name}' is not ready (status {setting.Status}); pick one that is Complete.");
        }
    }

    /// <summary>
    /// The JSON the agent reads from <c>shared/admin-setting-consumer.json</c>. The base serializes only this
    /// resource, so embed the admin row here. Choose the fields deliberately: the agent sees all of them, and
    /// whatever the skill copies into the Result is visible to every member of the workspace.
    /// </summary>
    public override async Task<string> GetExpandedSpecForAgentAsync(AdminSettingConsumer resource, CancellationToken ct)
    {
        var json = JsonNode.Parse(await base.GetExpandedSpecForAgentAsync(resource, ct))!.AsObject();
        var setting = resource.Spec?.AdminSettingId is { } id ? await FindAdminSettingAsync(id, ct) : null;
        json["adminSetting"] = setting == null ? null : new JsonObject
        {
            ["id"] = setting.Id,
            ["name"] = setting.Name,
            ["status"] = setting.Status.ToString(),
            ["settingKey"] = setting.Spec?.SettingKey,
            ["settingValue"] = setting.Spec?.SettingValue,
        };
        return json.ToJsonString(new System.Text.Json.JsonSerializerOptions { WriteIndented = true });
    }

    private async Task<AdminSetting?> FindAdminSettingAsync(string id, CancellationToken ct)
    {
        var row = await _adminSettings.GetByIdAsync(id, ct);
        return row?.OwnerWorkspaceId == Workspace.AdminWorkspaceId ? row : null;
    }
}
