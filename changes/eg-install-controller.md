+++
kind = "error"
packages = ["experimental/envoy-gateway", "experimental/traefik"]
id = "K5531"
+++
Add `instances.<namespace>.gateway-api.package = packages.experimental.gateway-api;`
to clusters that use `envoy-gateway` or `traefik`, and remove any `kubectl` or
Helm step you used to install the Gateway API CRDs. Both packages now read the
Gateway API CRDs from the `gatewayApi` role instead of expecting them to be
installed outside Kix. On `envoy-gateway` instances, also remove the deleted
options `controllerName`, `proxyNamespace`, `gatewayClassName`, and
`gatewayName`: `envoy-gateway` now deploys Envoy Gateway v1.10.0 itself
(controller, CRDs, RBAC, certificate Job, and proxy network policies) alongside
the `GatewayClass` and `Gateway`.

Before deploying this upgrade to a cluster where Helm installed Envoy Gateway,
run `helm uninstall` on that Helm release, then run `kix deploy <cluster>
--force-conflicts` once so Kix can take ownership of the CRD fields Helm wrote.
Envoy Gateway now starts proxy pods in the `envoy-gateway` instance's
namespace. If Helm ran the proxies in another namespace, Kubernetes creates a
new proxy `Service` and a cloud load balancer assigns a new IP address. Point
DNS at the new address (or keep the old IP in `config.addresses`), then remove
the old proxy resources from Helm's namespace with `kubectl delete
deployment,service,serviceaccount,configmap,hpa,pdb --namespace
envoy-gateway-system --selector app.kubernetes.io/managed-by=envoy-gateway`.
