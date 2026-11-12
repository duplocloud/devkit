import { inject } from '@angular/core';
import { CanMatchFn, PRIMARY_OUTLET, Router, Routes, UrlSegmentGroup } from '@angular/router';
import { ListHelloComponent } from './list/list-hello.component';
import { AddHelloComponent } from './add/add-hello.component';
import { ViewHelloComponent } from './view/view-hello.component';

// Must equal manifest frontend.setup.relativeUrl; scripts/validate-setup.sh fails the build otherwise.
export const SETUP_PATH = 'extensions/helloworld-setup';

// Every manifest route mounts this module and admin-scoped resources get data.scope 'admin' too, so match the path.
// A canMatch snapshot has no parent route, so read the URL being recognized.
const isSetupMount: CanMatchFn = (_route, _segments, snapshot) =>
  snapshot.data['scope'] === 'admin' && primaryPath(inject(Router).currentNavigation()?.extractedUrl.root).endsWith(`/${SETUP_PATH}`);

function primaryPath(group: UrlSegmentGroup | undefined): string {
  let path = '';
  for (let g = group; g; g = g.children[PRIMARY_OUTLET]) {
    path += g.segments.map(s => `/${s.path}`).join('');
  }
  return path;
}

// What the host lazy-loads (manifest frontend.remote.exposedModule = './Extension').
//
// A `Routes` array, not an NgModule: Angular's `loadChildren` accepts either, and the host's
// extension-route-registrar resolves the export named `Extension` and hands it straight to loadChildren.
// The components are standalone and declare their own `imports`, so there is nothing left for a module
// to do. THE EXPORTED CONST MUST STILL BE NAMED `Extension`.
export const Extension: Routes = [
  // The setup mount (manifest frontend.setup) gets the setup page; every other mount gets the list.
  {
    path: '',
    pathMatch: 'full',
    canMatch: [isSetupMount],
    loadComponent: () => import('./setup/setup.component').then(m => m.SetupComponent),
  },
  { path: '', component: ListHelloComponent },
  { path: 'add', component: AddHelloComponent },
  // Add and Edit share one component (platform convention); `action` drives the labels.
  { path: 'edit/:id', component: AddHelloComponent, data: { action: 'Edit' } },
  { path: 'view/:id', component: ViewHelloComponent },
];
