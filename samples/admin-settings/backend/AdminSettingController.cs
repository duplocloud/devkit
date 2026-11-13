using Duplo.Ai.DataManagement.AccessControl;
using Duplo.Ai.DataManagement.Controllers.Admin.Resource;
using Duplo.Ai.Model;
using Duplo.Ai.Model.Interfaces;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.Logging;

namespace Duplo.Extension.AdminSettings;

/// <summary>
/// The extension's own ADMIN-scoped REST controller. Inheriting
/// <see cref="AdminResourcesController{T,TSpec,TResult}"/> gives the same CRUD surface, <c>POST {id}/results</c>,
/// <c>POST {id}/status</c> and the deprovision lifecycle as a workspace resource, with two differences:
/// <list type="bullet">
///   <item>The route lives under <c>v1/aiservicedesk/admin/data/environment/…</c> and has no <c>{workspaceId}</c>.</item>
///   <item>Every row is owned by the system Admin Workspace (<c>Workspace.AdminWorkspaceId</c>), not a tenant.</item>
/// </list>
/// Access follows the Admin Workspace's permission-set grants: administrators, plus any user granted the Admin
/// Workspace. That is why the access-node declaration below is the same one a workspace controller carries — the
/// node sits under the Admin Workspace. It is mandatory: the host refuses to load an admin controller whose entity
/// is not a registered access node. See reference/21-admin-resources.md.
/// </summary>
[ApiController]
[Route("v1/aiservicedesk/admin/data/environment/extensions/admin-settings")]
[AccessControl(Parent = typeof(Workspace), ParentIdProperty = "OwnerWorkspaceId")]
public class AdminSettingsController : AdminResourcesController<AdminSetting, AdminSettingSpec, AdminSettingResult>
{
    public AdminSettingsController(IEntityService<AdminSetting> service, ILogger<AdminSettingsController> logger)
        : base(service, logger)
    {
    }
}
