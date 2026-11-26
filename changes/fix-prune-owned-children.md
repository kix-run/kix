+++
kind = "fixed"
+++
When pruning or garbage-collecting a custom resource whose CRD declaration sets
`controller`, Kix now deletes the custom resource with `Foreground` propagation.
Kubernetes keeps the custom resource until any owned child objects that block
its deletion are gone, so Kix keeps the controller running to remove their
finalizers. Previously, removing a cert-manager `Certificate` along with
cert-manager could leave a pending `Challenge` stuck with a finalizer after the
controller was already deleted. Kix also now applies each
`ValidatingWebhookConfiguration` and `MutatingWebhookConfiguration` after any
`Service` in the build referenced in `clientConfig.service` (unless the
`Service` already depends on it), and deletes the webhook configuration before
that `Service` during pruning and garbage collection. This keeps the API server
from sending requests to a webhook before its `Service` exists or after its
`Service` is removed.
