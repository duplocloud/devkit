using Duplo.Ai.DataManagement.Controllers.Admin.Resource;
using Duplo.Ai.Model.Interfaces;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.Logging;

namespace Duplo.Extension.AdminSettings;

/// <summary>
/// The extension's own ADMIN-scoped REST controller. Inheriting
/// <see cref="AdminResourcesController{T,TSpec,TResult}"/> gives the same CRUD surface, <c>POST {id}/results</c>,
/// <c>POST {id}/status</c> and the deprovision lifecycle as a workspace resource, with two differences:
/// <list type="bullet">
///   <item>The route lives under <c>v1/aiservicedesk/admin/data/environment/…</c> and has no <c>{workspaceId}</c>.
///   The platform's tenant policy makes every <c>/aiservicedesk/admin</c> route admin-only, so no attribute is
///   needed here.</item>
///   <item>Every row is owned by the system Admin Workspace (<c>Workspace.AdminWorkspaceId</c>), not a tenant.</item>
/// </list>
/// No access-node declaration: unlike a workspace controller there is no workspace to place it under, and
/// administrators bypass hierarchical access. Requires an SDK that ships AdminResourcesController (1.0.7 or
/// later). See reference/21-admin-resources.md.
/// </summary>
[ApiController]
[Route("v1/aiservicedesk/admin/data/environment/extensions/admin-settings")]
public class AdminSettingsController : AdminResourcesController<AdminSetting, AdminSettingSpec, AdminSettingResult>
{
    public AdminSettingsController(IEntityService<AdminSetting> service, ILogger<AdminSettingsController> logger)
        : base(service, logger)
    {
    }
}
