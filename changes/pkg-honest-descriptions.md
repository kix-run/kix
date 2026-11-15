+++
kind = "changed"
packages = ["experimental/ingress-nginx", "experimental/firezone", "experimental/envoy-gateway"]
+++
If your cluster uses `packages.experimental.ingress-nginx`, move its Ingress routes to Gateway API, for example with `packages.experimental.traefik`. If your cluster uses `packages.experimental.firezone`, plan to replace it. Existing clusters still build without changes, and Kix now warns when a cluster uses either deprecated package. Neither project receives security fixes. Kubernetes retired ingress-nginx in March 2026 after v1.15.1. Firezone stopped updating Firezone 0.7 on 31 January 2024, and Firezone 1.x does not support self-hosting. The description of `packages.experimental.envoy-gateway` now states that it creates `GatewayClass`, `Gateway`, and optional `EnvoyProxy` resources, and does not install the Envoy Gateway controller or Gateway API CRDs.
