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
run `helm uninstall` on that Helm release, then delete the certificate hook
objects Helm leaves behind (the `<release>-gateway-helm-certgen`
ServiceAccount, Role, RoleBinding, ClusterRole, ClusterRoleBinding, and Job,
and the topology injector webhook), for example with `kubectl delete
serviceaccount,role,rolebinding,job --namespace envoy-gateway-system
--selector app.kubernetes.io/instance=<release>` and `kubectl delete
clusterrole,clusterrolebinding,mutatingwebhookconfiguration --selector
app.kubernetes.io/instance=<release>`. Then run `kix deploy <cluster>
--force-conflicts` once so Kix can take ownership of the CRD fields Helm wrote.
Helm installed the experimental channel of the Gateway API CRDs, and Kix
installs the standard channel: fields only the experimental channel defines
are dropped from stored routes and Gateways, so remove them first, and the
experimental-only CRDs (`xbackends`, `xbackendtrafficpolicies`, and `xmeshes`
in `gateway.networking.x-k8s.io`) stay installed until you delete them.
Envoy Gateway now starts proxy pods in the `envoy-gateway` instance's
namespace. If Helm ran the proxies in another namespace, the controller
creates a new proxy `Service`, and a cloud load balancer assigns it a new IP
address. Point DNS at the new address, then remove the old proxy resources
from Helm's namespace with `kubectl delete
deployment,service,serviceaccount,configmap,hpa,pdb --namespace
envoy-gateway-system --selector app.kubernetes.io/managed-by=envoy-gateway`.
To keep the old IP in `config.addresses` instead, run that delete before the
deploy, because the old `Service` holds the address; the Gateway serves no
traffic until the new `Service` gets it.
