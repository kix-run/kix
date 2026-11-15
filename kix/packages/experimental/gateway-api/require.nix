# Return the Gateway API CRD handles a Gateway API implementation builds
# from, or refuse the build when nothing answers the `gatewayApi` role.
# envoy-gateway and traefik take the role as an optional dependency and call
# this, so the refusal names the package to add and the change record that
# made the dependency necessary.
{ scope }:
gatewayApi:
if gatewayApi == null then
  scope.fail {
    id = "K5531";
    dependency = "gatewayApi";
    message = "this instance requires the Kubernetes Gateway API CRDs (gateway.networking.k8s.io), and nothing in the cluster provides the 'gatewayApi' role.";
    fix =
      "Add a `gateway-api` instance to your cluster definition:\n"
      + "  instances.gateway-system.gateway-api.package = packages.experimental.gateway-api;\n"
      + "If your Kubernetes provider already installs the Gateway API CRDs, set `cluster.roles.gatewayApi.binding = \"exclusive\";` and declare them with `kix.mkImport` (`roles = [ \"gatewayApi\" ]` and `crds`).";
  }
else
  gatewayApi.out.crds
