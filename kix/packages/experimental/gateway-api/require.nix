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
    message = "this package needs the Gateway API CRDs, and no instance answers the gatewayApi role.";
    fix = "Add a gateway-api instance, such as `instances.gateway-system.gateway-api.package = packages.experimental.gateway-api;`, or, when the cluster's provider installs the CRDs, bind `cluster.roles.gatewayApi` to \"exclusive\" and declare the CRDs with a `kix.mkImport` that claims the gatewayApi role.";
  }
else
  gatewayApi.out.crds
