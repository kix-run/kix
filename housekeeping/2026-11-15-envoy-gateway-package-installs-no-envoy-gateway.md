# 2026-11-15 · `kix/packages/experimental/envoy-gateway` · The package named envoy-gateway does not install Envoy Gateway.

It renders a GatewayClass, a Gateway, and an optional EnvoyProxy, and expects the controller and the Gateway API CRDs to come from upstream's Helm chart outside Kix. A reader who sees `packages.experimental.envoy-gateway` beside `traefik`, which does install its controller, expects the same. The description and header now say so, but the name still misleads, and the controller it depends on is not tracked by the dependency graph.

Decision required from Adam: what the package should be.
- Rename it to what it renders (`gateway`, or `gateway-api-resources`), since `controllerName` already lets it serve other implementations. Cheap; an `error` record for the old name.
- Add the controller, as `traefik` does: vendor Envoy Gateway's CRDs and RBAC and render the controller Deployment, so the gateway, its controller, and its version sit in the graph. Most work, and it makes the package one per cluster.
- Merge the resources into a controller package: an `envoy-gateway` that installs the controller and exposes `out.mkGateway` for the GatewayClass and Gateway, as traefik's Gateway already lives with its controller.

Recommendation: the second or third option, because a Gateway whose controller Kix cannot see breaks the rule that wiring comes from the graph (P1). The first is a fine stopgap if nobody needs Envoy Gateway soon.
