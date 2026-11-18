+++
kind = "error"
packages = ["experimental/envoy-gateway", "experimental/envoy-gateway-controller", "experimental/traefik"]
id = "K5531"
+++
Add `instances.<namespace>.gateway-api.package = packages.experimental.gateway-api;`
to clusters that use `envoy-gateway` or `traefik`, and remove any `kubectl` or
Helm step you used to install the Gateway API CRDs. Both packages now read the
Gateway API CRDs from the `gatewayApi` role instead of expecting them to be
installed outside Kix. In clusters that use `envoy-gateway`, also add
`instances.<namespace>.envoy-gateway-controller.package =
packages.experimental.envoy-gateway-controller;` in the same namespace as
`envoy-gateway`, and remove `controllerName`, `proxyNamespace`,
`gatewayClassName`, `gatewayName`, and `proxySpec.mergeGateways` from your
`envoy-gateway` instances. The new `envoy-gateway-controller` package deploys
one Envoy Gateway v1.10.0 controller per cluster, along with its CRDs, RBAC,
certificate Job, and `GatewayClass`. Each `envoy-gateway` instance now creates
one `Gateway` on that controller with its own Envoy proxies, `Service`, and
proxy network policies, so a cluster can run several Gateways (for example, one
public and one private).

If your cluster already runs the controller from an earlier 0.10 release
candidate of `envoy-gateway`, delete the controller Deployment first with
`kubectl delete deployment envoy-gateway --namespace <namespace>`, then deploy
with `kix deploy <cluster> --prune`. Moving the controller to
`envoy-gateway-controller` changes the Deployment's label selector, which
Kubernetes cannot update in place, and `--prune` removes the old
`GatewayClass`, RBAC resources, and network policies. Existing Envoy proxy pods
keep serving traffic while the new controller starts.

Before deploying this upgrade to a cluster where Helm installed Envoy Gateway,
remove any experimental-only Gateway API fields from your routes and Gateways.
Helm installed the experimental Gateway API CRDs, while Kix installs the
standard channel, which drops experimental-only fields from stored objects. The
experimental-only CRDs (`xbackends`, `xbackendtrafficpolicies`, and `xmeshes`
in `gateway.networking.x-k8s.io`) stay installed until you delete them. Next,
run `helm uninstall` on that Helm release, and delete the hook objects Helm
leaves behind: the `<release>-gateway-helm-certgen` ServiceAccount, Role,
RoleBinding, ClusterRole, ClusterRoleBinding, and Job, plus the topology
injector webhook. For example, run `kubectl delete
serviceaccount,role,rolebinding,job --namespace envoy-gateway-system
--selector app.kubernetes.io/instance=<release>` and `kubectl delete
clusterrole,clusterrolebinding,mutatingwebhookconfiguration --selector
app.kubernetes.io/instance=<release>`. Then run `kix deploy <cluster>
--force-conflicts` once so Kix can take ownership of the CRD fields Helm wrote.

Envoy Gateway now starts proxy pods in the `envoy-gateway-controller`
instance's namespace. If Helm ran the proxies in another namespace, the controller creates
a new proxy `Service`, and a cloud load balancer assigns it a new IP address.
Point DNS at the new address, then remove the old proxy resources from Helm's
namespace with `kubectl delete
deployment,service,serviceaccount,configmap,hpa,pdb --namespace
envoy-gateway-system --selector app.kubernetes.io/managed-by=envoy-gateway`. To
keep the old IP address in `config.addresses` instead, delete those old proxy
resources before running `kix deploy`, because the old `Service` still holds
the IP. The Gateway serves no traffic until the new `Service` gets the address.
