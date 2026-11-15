# Swap fixture, first build: File Browser routed through envoy-gateway. See
# the gateway-swap check in flake.nix.
{ kix, packages }:

kix.buildCluster {
  name = "test-gateway-swap";
  modules = [
    kix.flavors.kind
    (import ./consumer.nix { inherit packages; })
    # Both implementations take the Gateway API CRDs from here.
    { instances.gateway-api.gateway-api.package = packages.experimental.gateway-api; }
    { instances.envoy-system.envoy.package = packages.experimental.envoy-gateway; }
  ];
}
