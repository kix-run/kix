# Swap fixture, second build: the same File Browser routed through traefik.
# Nothing under ./consumer.nix changes; only what answers `gateway` does.
{ kix, packages }:

kix.buildCluster {
  name = "test-gateway-swap";
  modules = [
    kix.flavors.kind
    (import ./consumer.nix { inherit packages; })
    # Both implementations take the Gateway API CRDs from here.
    { instances.gateway-api.gateway-api.package = packages.experimental.gateway-api; }
    { instances.traefik-system.traefik.package = packages.experimental.traefik; }
  ];
}
