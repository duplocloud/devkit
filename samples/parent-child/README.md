# Parent / Child agent sample

A worked **two-resource** agent: a `HelloParent` that owns many `HelloChild` resources — the generic
shape behind real parent/child pairs (a Job with its Builds, an Environment with its States). It mirrors
`samples/helloworld` but demonstrates the multi-resource wiring in `reference/08-parent-child-and-menus.md`,
and uses the platform UI library `@duplocloud-internal/ng-common-lib` for every view.

## What it shows
- **Backend:** two typed resources in one DLL. The child's spec extends `ParentRefSpec<HelloParent>` and its
  controller (`ChildResourceController<…>`) is mounted at the nested route
  `…/hello-parents/{parentId}/hello-children`, stamping `Spec.ParentId` from the URL.
- **Manifest:** two `resources[]` entries; the child declares the `parent` link. One menu entry for the parent.
- **Frontend (Pattern B):** a single remote mount (`extensions/hello-parents`) with internal routes for the parent
  list/add/view and the nested child add/view. The parent's **view** lists its children in a
  `<searchable-datatable>` tab inside the Result strip, with row-links into the child route; both detail pages
  are the platform detail shell with an Agent-mode lifecycle rail (reference/19-detail-page.md).

## Deprovision
Both resources are **Agent mode**, so delete follows the agent lifecycle (reference/11-deprovisioning.md):
`POST {id}/deprovision` flips the row to `DeProvisioning` and the platform force-sends the generic teardown
message (*"Deprovision this resource. Tear down all infrastructure managed by this resource."*) to the
resource's **existing** provisioning ticket — there is no separate deprovision skill mapping. The sample's
skills create nothing durable (slug/message only), so their teardown is a no-op status walk to
`DeProvisioned`, after which the row auto-deletes. **The parent CASCADES its children**: `HelloParentHooks`
deletes every `HelloChild` row when the parent row is deleted or reaches `DeProvisioned` — delete the
children first only if you need their own teardown to run (a cascaded row delete runs no child deprovision).

## Build / load
Same flow as `helloworld` (see `.claude/skills/duplo-extension-dev/SKILL.md`):
```bash
# @duplocloud-internal/ng-common-lib installs from the repo-root packages/*.tgz — no registry auth needed
# fetch SDK → dotnet publish backend → npm install && npm run build (frontend; a plain install — the
#   ngx-toastr peer conflict is handled by the "overrides" block, not by `--legacy-peer-deps`)
# → zip {manifest.json, backend/, fe/, skills/} → load-bundle
```
> Controller route changes (the child's nested route) need a studio restart or a version bump to evict the old
> MVC routes — see `reference/08-parent-child-and-menus.md`.
