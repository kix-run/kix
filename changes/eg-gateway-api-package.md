+++
kind = "added"
packages = ["experimental/gateway-api"]
+++
A new experimental `gateway-api` package (`packages.experimental.gateway-api`)
installs the Kubernetes Gateway API v1.6.1 standard-channel CRDs and the
upstream `ValidatingAdmissionPolicy` that blocks downgrades below v1.5.0 or
replacing standard-channel CRDs with experimental-channel ones. It claims the
new `gatewayApi` role so a cluster installs only one copy of the CRDs, and
exposes CRD builders on `out.crds` for Gateway API controllers such as
`envoy-gateway` and `traefik`. If your Kubernetes provider already installs the
Gateway API CRDs, set `cluster.roles.gatewayApi.binding = "exclusive"` and
declare them with `kix.mkImport` (`roles = [ "gatewayApi" ]` and `crds`) instead
of adding `gateway-api`.
