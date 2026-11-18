# 2026-11-18 · `kix/lib/vocab/expose.nix` · A package cannot ask kix.expose for a request body limit or a fallback backend.

Both are Envoy Gateway resources, so they cannot be written by `kix.expose`, which serves every Gateway API implementation and whose output the `gateway-swap` check compares across implementations. The gateway contract would need optional builders that a provider publishes, with `kix.expose` failing at evaluation when a package asks for one and the wired Gateway has none.

What works on Envoy Gateway v1.10.0, tested on kind on 2026-11-18:
- A body limit is a BackendTrafficPolicy `requestBuffer.limit` that targets the HTTPRoute. With no policy a 3 GiB upload passed, so there is no default limit to lift.
- A fallback page works only as two Backend resources with FQDN endpoints (the main Service and the fallback, the second with `fallback: true`) and a BackendTrafficPolicy active HTTP health check. With the main Deployment at zero replicas every request reached the fallback, and none failed across the change. A Service backendRef beside a fallback Backend sent about half the requests to 503, and so did two Services with `HTTPRouteFilter.backendPriority`. It needs `settings.extensionApis.enableBackend = true` on the controller, and the proxy then reaches the application through its Service's cluster IP, so kube-proxy balances across its pods.

Until then a package writes these resources itself from `gateway.out.crds`, which the `envoy-gateway` package publishes.
