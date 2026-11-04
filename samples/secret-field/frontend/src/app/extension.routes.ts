import { Routes } from '@angular/router';
import { ListSecretFieldServiceAccountComponent } from './list/list-secret-field-service-account.component';
import { AddSecretFieldServiceAccountComponent } from './add/add-secret-field-service-account.component';
import { ViewSecretFieldServiceAccountComponent } from './view/view-secret-field-service-account.component';

// What the host lazy-loads (manifest frontend.remote.exposedModule = './Extension').
// THE EXPORTED CONST MUST STILL BE NAMED `Extension`.
export const Extension: Routes = [
  { path: '', component: ListSecretFieldServiceAccountComponent },
  { path: 'add', component: AddSecretFieldServiceAccountComponent },
  // Add and Edit share one component (platform convention); `action` drives the labels.
  { path: 'edit/:id', component: AddSecretFieldServiceAccountComponent, data: { action: 'Edit' } },
  { path: 'view/:id', component: ViewSecretFieldServiceAccountComponent },
];
