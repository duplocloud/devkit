using Duplo.Ai.DataManagement.AccessControl;
using Duplo.Ai.DataManagement.Models;
using Duplo.Ai.Model;
using Duplo.Ai.Model.Interfaces;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace Duplo.Extension.AdminSettings;

/// <summary>
/// What a workspace member may see of an admin setting. The value is left out, and so is the result
/// summary, because the provisioning skill writes it as <c>key = "value"</c>. Faults, ticket and
/// blocked reasons stay admin-only too.
/// </summary>
public class AdminSettingView
{
    public string Id { get; set; } = string.Empty;
    public string Name { get; set; } = string.Empty;
    public string Status { get; set; } = string.Empty;
    public DateTime CreatedAt { get; set; }
    public DateTime UpdatedAt { get; set; }
    public AdminSettingViewSpec Spec { get; set; } = new();
}

public class AdminSettingViewSpec
{
    public string? SettingKey { get; set; }
}

/// <summary>
/// READ-ONLY workspace view of the admin settings, so non-admins can see what administrators provisioned.
/// It serves the same <c>extensions/admin-settings</c> segment on the workspace side, with only
/// <c>GET</c> (list) and <c>GET {id}</c>, and every response is an <see cref="AdminSettingView"/>.
/// <list type="bullet">
///   <item>Plain <see cref="ControllerBase"/> on purpose: <c>ResourcesController</c> would add the write
///   endpoints and filter rows to the ROUTE workspace, while these rows all belong to the Admin Workspace.</item>
///   <item><c>[Authorize]</c> is what runs the tenant policy (the caller must be a member of
///   <c>{workspaceId}</c>). The host has no fallback policy, so without it this route would be anonymous.</item>
///   <item><c>[AccessControl("workspaceId", AnchorNode = "Workspace")]</c> gates every action on the caller's
///   grant for the route workspace. It anchors only; the AdminSetting node is declared by nobody.</item>
/// </list>
/// See reference/21-admin-resources.md ("Read-only workspace view").
/// </summary>
[ApiController]
[Authorize]
[AccessControl("workspaceId", AnchorNode = "Workspace")]
[Route("v1/aiservicedesk/user/data/workspaces/{workspaceId}/environment/extensions/admin-settings")]
public class AdminSettingsReadController : ControllerBase
{
    private readonly IEntityService<AdminSetting> _service;

    public AdminSettingsReadController(IEntityService<AdminSetting> service)
    {
        _service = service;
    }

    [HttpGet]
    public async Task<IActionResult> GetAll(string workspaceId, CancellationToken cancellationToken)
    {
        var rows = await _service.FindAsync(e => e.OwnerWorkspaceId == Workspace.AdminWorkspaceId, cancellationToken);
        var items = rows.OrderBy(e => e.Name).Select(ToView).ToList();
        var page = new PagedResponse<AdminSettingView>
        {
            Items = items,
            Page = 1,
            // PageSize 0 would make TotalPages divide by zero.
            PageSize = Math.Max(items.Count, 1),
            TotalCount = items.Count,
        };
        return Ok(ApiResponse<PagedResponse<AdminSettingView>>.SuccessResult(page));
    }

    [HttpGet("{id}")]
    public async Task<IActionResult> GetById(string workspaceId, string id, CancellationToken cancellationToken)
    {
        var row = await _service.GetByIdAsync(id, cancellationToken);
        if (row == null || row.OwnerWorkspaceId != Workspace.AdminWorkspaceId)
        {
            return NotFound(ApiResponse<object>.ErrorResult($"Admin setting '{id}' not found."));
        }
        return Ok(ApiResponse<AdminSettingView>.SuccessResult(ToView(row)));
    }

    private static AdminSettingView ToView(AdminSetting e) => new()
    {
        Id = e.Id,
        Name = e.Name,
        Status = e.Status.ToString(),
        CreatedAt = e.CreatedAt,
        UpdatedAt = e.UpdatedAt,
        Spec = new AdminSettingViewSpec { SettingKey = e.Spec?.SettingKey },
    };
}
