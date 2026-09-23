# 15 — Surfacing API errors in the frontend

When a create/update fails, users must see the **real reason** — not a generic "Invalid request". This is the #1
form papercut, and it's caused by reading the wrong field of the error response.

## The API error shape (know this)

Every resource create/update failure returns HTTP `400` with an `ApiResponse` envelope:
```json
{ "success": false, "message": "Invalid request", "errors": "Resource with name 'foo' already exists" }
```
- **`message`** = a generic **title** (`"Invalid request"` / `"Error creating resource"` / `"Validation error"`) —
  hardcoded by the base controller.
- **`errors`** = the **real, human-readable reason** (`ex.Message`) — a plain string on all create paths.

So reading `err.error.message` shows the useless title and **drops the real reason in `err.error.errors`**. That is
the bug behind "Invalid request".

## Do this — reuse the platform's error reporter

The vendored lib `@duplocloud-internal/ng-common-lib` (already imported via `SharedFormsModule`) ships the whole
mechanism. **Do not read `err.error.message` yourself.**

### Standard forms → `formGroupErrors.reportError(err)`
The `form-group-errors` directive you already mount for client-side validation also implements `ErrorReporter`.
Grab it and report the raw error — it unwraps via `extractErrorMessage` (which reads `errors` → `Message` →
`message` → string) and renders the reason as the form's summary banner. This is the portal convention.
```ts
import { Component, signal, viewChild } from '@angular/core';
import { FormGroupErrorsComponent } from '@duplocloud-internal/ng-common-lib';

private readonly formErrors = viewChild(FormGroupErrorsComponent);   // a signal — call it
protected readonly saving = signal(false);

submit() {
  this.saving.set(true);
  this.svc.create(this.name(), this.model).subscribe({
    next: () => this.router.navigate(['..'], { relativeTo: this.route }),
    error: (err) => { this.saving.set(false); this.formErrors()?.reportError(err); },
  });
}
```
Template (already present in the templates): `<div class="form-container" form-group-errors #formGroupErrors
showDetailsWhen="submitted"> … </div>`. No bespoke `<div class="alert">` needed — the directive renders the banner.
See `samples/helloworld` and the `templates/helloworld` add form.

### Custom error placement → `extractErrorMessage(err)`
When you render the error somewhere the directive can't reach (e.g. a wizard's own error slot), use the extractor
directly to get the real string:
```ts
import { extractErrorMessage } from '@duplocloud-internal/ng-common-lib';
error: (err) => { this.saving = false; this.error = extractErrorMessage(err); }
```
See `samples/network-stack`'s add wizard (feeds `<duplo-wizard-stepper [error]>`).

## Constraints / notes

- **Toasts reach the host, but report form errors inline.** `ngx-toastr` is a shared singleton, so the lib's
  `SharedAlertsService` shows the host's toast from a remote — the confirm dialogs and `app-code-block-with-copy`
  do this on their own ([20-ui-library](20-ui-library.md#confirm-dialogs)). A failed create/update still goes
  **inline** (form banner / wizard slot), beside the form the user has to fix. Never report one failure both ways.
- **No field-level error map.** On create, `errors` is a single string, not a per-field dict — surface it as one
  message; don't expect to map it onto individual fields.
- **Where the real message comes from:** e.g. the name-uniqueness check throws
  `ArgumentException("<Type> with name '<n>' already exists")`, which the base controller puts into `errors`. Your
  own `OnBeforeCreateAsync` / `ValidateSpecAsync` throws surface the same way — throw with a clear message and it
  reaches the user via the above.
