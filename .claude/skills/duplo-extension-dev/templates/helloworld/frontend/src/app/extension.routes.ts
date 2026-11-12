import { CanMatchFn, Routes } from '@angular/router';
import { ListHelloComponent } from './list/list-hello.component';
import { AddHelloComponent } from './add/add-hello.component';
import { ViewHelloComponent } from './view/view-hello.component';

// Every manifest route mounts this same module; the host stamps data.scope on the mount and '' children inherit it.
const isAdminMount: CanMatchFn = (_route, _segments, snapshot) => snapshot.data['scope'] === 'admin';

// What the host lazy-loads (manifest frontend.remote.exposedModule = './Extension').
//
// A `Routes` array, not an NgModule: Angular's `loadChildren` accepts either, and the host's
// extension-route-registrar resolves the export named `Extension` and hands it straight to loadChildren.
// The components are standalone and declare their own `imports`, so there is nothing left for a module
// to do. THE EXPORTED CONST MUST STILL BE NAMED `Extension`.
export const Extension: Routes = [
  // Admin mount (manifest frontend.setup): the setup page. Workspace mounts skip it and get the list.
  {
    path: '',
    pathMatch: 'full',
    canMatch: [isAdminMount],
    loadComponent: () => import('./setup/setup.component').then(m => m.SetupComponent),
  },
  { path: '', component: ListHelloComponent },
  { path: 'add', component: AddHelloComponent },
  // Add and Edit share one component (platform convention); `action` drives the labels.
  { path: 'edit/:id', component: AddHelloComponent, data: { action: 'Edit' } },
  { path: 'view/:id', component: ViewHelloComponent },
];
