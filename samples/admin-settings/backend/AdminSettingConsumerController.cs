using Duplo.Ai.DataManagement.AccessControl;
using Duplo.Ai.DataManagement.Controllers.User.Resource;
using Duplo.Ai.Model;
using Duplo.Ai.Model.Interfaces;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.Logging;

namespace Duplo.Extension.AdminSettings;

/// <summary>
/// An ordinary WORKSPACE controller for the resource that consumes an admin setting: the workspace route, the
/// usual access node, rows owned by the route workspace. Nothing about it is admin-specific — the cross-scope
/// rules live in <see cref="AdminSettingConsumerService"/>. The add form's picker reads the admin settings from
/// <see cref="AdminSettingsReadController"/>. See reference/21-admin-resources.md.
/// </summary>
[ApiController]
[Route("v1/aiservicedesk/user/data/workspaces/{workspaceId}/environment/extensions/admin-setting-consumers")]
[AccessControl(Parent = typeof(Workspace), ParentIdProperty = "OwnerWorkspaceId")]
public class AdminSettingConsumersController
    : ResourcesController<AdminSettingConsumer, AdminSettingConsumerSpec, AdminSettingConsumerResult>
{
    public AdminSettingConsumersController(
        IEntityService<AdminSettingConsumer> service, ILogger<AdminSettingConsumersController> logger)
        : base(service, logger)
    {
    }
}
