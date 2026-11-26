+++
kind = "fixed"
+++
When pruning or garbage-collecting a custom resource whose CRD declaration sets
`controller`, Kix now deletes the custom resource with `Foreground` propagation.
Kubernetes keeps the custom resource until any owned child objects that block
its deletion are gone, so Kix keeps the controller running to remove their
finalizers. Previously, removing a cert-manager `Certificate` along with
cert-manager could leave a pending `Challenge` stuck with a finalizer after the
controller was already deleted. Kix also now deletes each
`ValidatingWebhookConfiguration` and `MutatingWebhookConfiguration` before any
`Service` in the build referenced in `clientConfig.service` (unless the
`Service` already depends on it) during pruning and garbage collection. This
keeps the API server from sending requests to a webhook after its `Service` is
removed. A delete that waits on its finalizers no longer prints `stalled>`
lines while Kix keeps reading the object; the `waiting>` lines say what it
waits for.
