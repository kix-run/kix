# Sources the package accepts for `sources`, with the RBAC each one needs and
# the Gateway API kinds it reads. The rules follow
# charts/external-dns/templates/clusterrole.yaml in chart 1.23.0 (external-dns
# v0.23.0). Another upstream source is added here when a cluster needs it.
#
# `intents` are RBAC DSL intents (kix/lib/vocab/rbac.nix). `crdRefs` name
# Gateway API kinds whose CRDs must exist before the controller starts; the
# package declares one `scope.mkCRDRef` marker per kind.
rbac:
let
  inherit (rbac)
    core
    group
    watch
    allow
    ;
  discovery = group "discovery.k8s.io" [ "endpointslices" ];
  networking = group "networking.k8s.io" [ "ingresses" ];
  gatewayApi = group "gateway.networking.k8s.io" [
    "gateways"
    "httproutes"
    "grpcroutes"
  ];

  gateway = route: kind: {
    intents = [
      (watch [
        gatewayApi.gateways
        gatewayApi.${route}
        core.namespaces
      ])
    ];
    crdRefs = [
      {
        kind = "Gateway";
        plural = "gateways";
      }
      {
        inherit kind;
        plural = route;
      }
    ];
  };
in
{
  service = {
    intents = [
      (allow [ "list" "watch" ] core.nodes)
      (watch [
        core.pods
        core.services
        discovery.endpointslices
      ])
    ];
    crdRefs = [ ];
  };
  ingress = {
    intents = [ (watch networking.ingresses) ];
    crdRefs = [ ];
  };
  node = {
    intents = [ (allow [ "list" "watch" ] core.nodes) ];
    crdRefs = [ ];
  };
  pod = {
    intents = [
      (allow [ "list" "watch" ] core.nodes)
      (watch core.pods)
    ];
    crdRefs = [ ];
  };
  gateway-httproute = gateway "httproutes" "HTTPRoute";
  gateway-grpcroute = gateway "grpcroutes" "GRPCRoute";
}
