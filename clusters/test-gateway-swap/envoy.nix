# Swap fixture, first build: File Browser routed through envoy-gateway. See
# the gateway-swap check in flake.nix.
{ kix, packages }:

kix.buildCluster {
  name = "test-gateway-swap";
  modules = [
    kix.flavors.kind
    (import ./consumer.nix { inherit packages; })
    { instances.envoy-system.envoy.package = packages.envoy-gateway; }
  ];
}
