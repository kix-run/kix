+++
kind = "error"
packages = ["experimental/envoy-gateway", "experimental/traefik"]
id = "K5531"
+++
`envoy-gateway` now installs Envoy Gateway v1.10.0 itself: its CRDs, the
controller, its roles, the certgen Job, and the Envoy proxies' network
policy, beside the GatewayClass and Gateway it made before. `envoy-gateway`
and `traefik` now need the Gateway API CRDs from a `gateway-api` instance:
add `instances.<namespace>.gateway-api.package =
packages.experimental.gateway-api;`, and remove any Gateway API CRDs you
applied with kubectl or Helm from your install steps. `envoy-gateway` refuses
`controllerName`, `proxyNamespace`, `gatewayClassName`, and `gatewayName`;
delete them. If you installed Envoy Gateway with Helm, run `helm uninstall`
on that release first, then deploy once with `kix deploy <cluster>
--force-conflicts`, because Helm still owns fields of the CRDs and the
deploy stops on that conflict. The controller now starts the proxies in the
instance's namespace, so a Gateway whose proxies ran in another namespace
gets a new Service and, on a cloud load balancer, a new address. Point DNS
at it, or keep the old one with `addresses`, then delete the old proxies
from Helm's namespace with `kubectl delete
deployment,service,serviceaccount,configmap,hpa,pdb --namespace
envoy-gateway-system --selector app.kubernetes.io/managed-by=envoy-gateway`.
