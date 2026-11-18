+++
kind = "error"
library = ["kix.expose"]
id = "K6232"
+++
If a Gateway listener restricts namespaces by the `kubernetes.io/metadata.name`
label, make sure `allowedRoutes.namespaces.selector` includes the namespace of
every application routed through that listener, or set `ingress.host` on the
application to a hostname accepted by another listener. `kix.expose` now checks
selectors on `kubernetes.io/metadata.name` during evaluation and fails when the
selector excludes the application's namespace. Earlier releases built the
`HTTPRoute` with a warning, and the Gateway controller then rejected it in the
cluster.
