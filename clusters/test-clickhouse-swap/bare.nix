# Swap fixture, first build: the consumer on the bare `clickhouse` package.
# See the clickhouse-swap check in flake.nix (v2_discussions/148, phase 6).
{ kix, packages }:

kix.buildCluster {
  name = "test-clickhouse-swap";
  modules = [
    kix.flavors.kind
    (import ./consumer.nix { inherit packages; })
    {
      instances.db = {
        ch.package = packages.clickhouse;
        ch-data = {
          package = packages.persistent-volume-claim;
          aliases = [ "storage" ];
          config.size = "5Gi";
        };
        ch-credentials = {
          package = packages.secret;
          aliases = [ "credentials" ];
          config.stringData.password = "swap-fixture-admin";
        };
      };
    }
  ];
}
