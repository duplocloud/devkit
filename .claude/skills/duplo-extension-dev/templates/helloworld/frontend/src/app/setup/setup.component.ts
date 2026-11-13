import { Component, OnInit, computed, inject, signal, viewChild } from '@angular/core';
import {
  ConnectionFieldComponent,
  ConnectionTypeDefinition,
  FormGroupErrorsComponent,
  SharedFormsModule,
} from '@duplocloud-internal/ng-common-lib';
import { SettingsService } from '../settings.service';
import { StatusBadgeComponent } from '../shared/status-badge.component';

// Sample provider type; the connection field registers it on first use if no type has this name.
const HELLO_WORLD_TYPE: ConnectionTypeDefinition = {
  type: 'helloworld',
  label: 'Hello World',
  category: 'other',
  credentialSchema: {
    fields: [
      { key: 'endpoint', label: 'Endpoint URL', htmlType: 'url', required: 'always', placeholder: 'https://api.example.com' },
      { key: 'apiToken', label: 'API token', htmlType: 'password', sensitive: true, required: 'always' },
    ],
  },
};

// Admin setup page (AI Admin → Agent Setup). Admin-wide: it never reads the current workspace.
@Component({
  selector: 'hw-setup',
  imports: [SharedFormsModule, ConnectionFieldComponent, StatusBadgeComponent],
  templateUrl: './setup.component.html',
})
export class SetupComponent implements OnInit {
  private readonly settings = inject(SettingsService);
  private readonly formErrors = viewChild(FormGroupErrorsComponent);

  protected readonly sampleType = HELLO_WORLD_TYPE;
  protected readonly scopeId = signal('');
  private readonly savedScopeId = signal('');
  protected readonly loading = signal(true);
  protected readonly saving = signal(false);
  /** True when the settings endpoint is missing and values live in localStorage. */
  protected readonly local = signal(false);

  protected readonly done = computed(() => !!this.savedScopeId() && this.savedScopeId() === this.scopeId());

  ngOnInit(): void {
    this.settings.load().subscribe({
      next: ({ settings, local }) => {
        this.apply(settings.scopeId ?? '', local);
        this.loading.set(false);
      },
      error: err => {
        // Stay locked: Save would overwrite settings that never loaded.
        this.formErrors()?.reportError(err);
      },
    });
  }

  protected save(): void {
    this.formErrors()?.clearError();
    this.saving.set(true);
    this.settings.save({ scopeId: this.scopeId() }).subscribe({
      next: ({ settings, local }) => {
        this.apply(settings.scopeId ?? '', local);
        this.saving.set(false);
      },
      error: err => {
        this.saving.set(false);
        this.formErrors()?.reportError(err);
      },
    });
  }

  private apply(scopeId: string, local: boolean): void {
    this.scopeId.set(scopeId);
    this.savedScopeId.set(scopeId);
    this.local.set(local);
  }
}
