import { Component, Type, inject } from '@angular/core';
import { NgComponentOutlet } from '@angular/common';
import { ActivatedRoute } from '@angular/router';

/**
 * Picks the page for the resource this mount serves. Every `frontend.routes[]` entry of the manifest mounts the
 * SAME remote (`./Extension`), so `extensions/admin-settings` and `extensions/admin-setting-consumers` both land
 * on these routes. The host stamps the entry's `resourceType` on the lazy route, and the remote's routes inherit
 * it (their parent is componentless), so each route lists one page per resource type in `data.pages` and this
 * component renders the matching one. A remote with one top-level resource does not need this.
 *
 * The page is created inside this route's injector, so it injects the same ActivatedRoute (params, data,
 * relative navigation) it would get as the route's own component.
 */
@Component({
  selector: 'as-resource-page',
  imports: [NgComponentOutlet],
  template: `
    @if (page; as p) {
      <ng-container *ngComponentOutlet="p" />
    } @else {
      <div class="text-muted p-2">This extension has no page for resource type '{{ resourceType }}'.</div>
    }
  `,
})
export class ResourcePageComponent {
  private readonly route = inject(ActivatedRoute);
  protected readonly resourceType: string = this.route.snapshot.data['resourceType'] ?? '';
  protected readonly page: Type<unknown> | undefined =
    (this.route.snapshot.data['pages'] as Record<string, Type<unknown>> | undefined)?.[this.resourceType];
}
