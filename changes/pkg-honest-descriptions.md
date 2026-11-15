+++
kind = "changed"
packages = ["experimental/ingress-nginx", "experimental/firezone", "experimental/envoy-gateway"]
+++
`ingress-nginx` and `firezone` are deprecated, and a build that uses either one now warns. Kubernetes retired ingress-nginx in March 2026, and Firezone 0.7 has had no upstream updates since January 2024, so neither gets security fixes. Move ingress-nginx routes to Gateway API, for example with the `traefik` package. The description of `envoy-gateway` now says that it does not install the Envoy Gateway controller.
