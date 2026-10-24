using Duplo.Ai.DataManagement.AccessControl;
using Duplo.Ai.DataManagement.Controllers.User.Resource;
using Duplo.Ai.Model;
using Duplo.Ai.Model.Interfaces;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.Logging;

namespace Duplo.Extension.HelloWorld;

/// <summary>
/// The extension's own workspace-scoped REST controller. Inheriting
/// <see cref="ResourcesController{T,TSpec,TResult}"/> provides the full CRUD surface plus
/// <c>POST {id}/results</c>, <c>POST {id}/status</c> and the deprovision lifecycle — the same
/// endpoints every first-class resource exposes. The loader adds this assembly as an
/// ApplicationPart and refreshes routes, so this becomes live at
/// <c>.../environment/extensions/helloworlds</c> with no host restart.
/// <para>
/// Admin-scoped resource (platform-wide, administrators only)? Derive from
/// <c>AdminResourcesController&lt;HelloWorld, HelloWorldSpec, HelloWorldResult&gt;</c>
/// (<c>using Duplo.Ai.DataManagement.Controllers.Admin.Resource;</c>, SDK 1.0.7+) and route it at
/// <c>v1/aiservicedesk/admin/data/environment/extensions/helloworlds</c> — no <c>{workspaceId}</c>.
/// See reference/21-admin-resources.md and samples/admin-settings.
/// </para>
/// </summary>
[ApiController]
[Route("v1/aiservicedesk/user/data/workspaces/{workspaceId}/environment/extensions/helloworlds")]
// Access-node declaration: places this resource in the permission tree under its workspace, so
// permission sets can grant or deny it. Opt-in — without this the resource is invisible to the
// permission-set editor and any workspace member can CRUD it. See reference/18-access-control.md.
[AccessControl(Parent = typeof(Workspace), ParentIdProperty = "OwnerWorkspaceId")]
public class HelloWorldsController : ResourcesController<HelloWorld, HelloWorldSpec, HelloWorldResult>
{
    public HelloWorldsController(IEntityService<HelloWorld> service, ILogger<HelloWorldsController> logger)
        : base(service, logger)
    {
    }
}
