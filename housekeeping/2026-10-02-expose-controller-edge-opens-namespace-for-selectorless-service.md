# 2026-10-02 · `kix/lib/vocab/compose.nix` · `kix.expose` writes an ingress-controller policy that selects every pod in the namespace when the Service has no selector.

`controllerEdgeFor` sets `endpointSelector.matchLabels = b.svc.rawManifest.spec.selector or { }`. For a Service without a selector (ExternalName, or one backed by EndpointSlices the user manages) that is `{ }`, which selects every pod in the namespace and admits the ingress controller to all of them on the Service's ports. tailscale's `out.mkBackendPolicy` refuses such a Service for the same reason.
