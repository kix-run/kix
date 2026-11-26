+++
kind = "fixed"
+++
Pruning a custom resource whose kind names a `controller` now uses `Foreground`
propagation, so Kix waits for the objects the controller made for it before
deleting the controller. Before, deleting a cert-manager Certificate together
with cert-manager could leave a pending Challenge stuck with a finalizer that
no controller would remove. Kix also deletes a `ValidatingWebhookConfiguration`
or `MutatingWebhookConfiguration` before the Service that its webhooks call, and
creates it after that Service, so the API server never calls a webhook with
nothing behind it.
