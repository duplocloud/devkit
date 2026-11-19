import { Routes } from '@angular/router';
import { ListAdminSettingComponent } from './list/list-admin-setting.component';
import { AddAdminSettingComponent } from './add/add-admin-setting.component';
import { ViewAdminSettingComponent } from './view/view-admin-setting.component';
import { ListAdminSettingConsumerComponent } from './consumer/list-admin-setting-consumer.component';
import { AddAdminSettingConsumerComponent } from './consumer/add-admin-setting-consumer.component';
import { ViewAdminSettingConsumerComponent } from './consumer/view-admin-setting-consumer.component';
import { ResourcePageComponent } from './resource-page.component';

// What the host lazy-loads (manifest frontend.remote.exposedModule = './Extension').
//
// A `Routes` array, not an NgModule: Angular's `loadChildren` accepts either, and the host's
// extension-route-registrar resolves the export named `Extension` and hands it straight to loadChildren.
// The components are standalone and declare their own `imports`, so there is nothing left for a module
// to do. THE EXPORTED CONST MUST STILL BE NAMED `Extension`.
//
// This remote serves TWO top-level resources — the admin-scoped AdminSetting (extensions/admin-settings, both
// sides) and the workspace-scoped AdminSettingConsumer (extensions/admin-setting-consumers) — and the host mounts
// these same routes under each path. ResourcePageComponent renders the page for the mount's resourceType.
export const Extension: Routes = [
  {
    path: '',
    component: ResourcePageComponent,
    data: { pages: { AdminSetting: ListAdminSettingComponent, AdminSettingConsumer: ListAdminSettingConsumerComponent } },
  },
  {
    path: 'add',
    component: ResourcePageComponent,
    data: { pages: { AdminSetting: AddAdminSettingComponent, AdminSettingConsumer: AddAdminSettingConsumerComponent } },
  },
  // Add and Edit share one component (platform convention); `action` drives the labels.
  {
    path: 'edit/:id',
    component: ResourcePageComponent,
    data: {
      action: 'Edit',
      pages: { AdminSetting: AddAdminSettingComponent, AdminSettingConsumer: AddAdminSettingConsumerComponent },
    },
  },
  {
    path: 'view/:id',
    component: ResourcePageComponent,
    data: { pages: { AdminSetting: ViewAdminSettingComponent, AdminSettingConsumer: ViewAdminSettingConsumerComponent } },
  },
];
