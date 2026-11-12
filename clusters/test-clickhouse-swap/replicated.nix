# Swap fixture, second build: the same consumer on `clickhouse-cluster`.
# Nothing under ./consumer.nix changes; only what answers `clickhouse` does.
{ kix, packages }:

kix.buildCluster {
  name = "test-clickhouse-swap";
  modules = [
    kix.flavors.kind
    (import ./consumer.nix { inherit packages; })
    (
      { ref, ... }:
      {
        instances.app.events-db.deps.clickhouse = ref.db.ch;

        instances.clickhouse-system = {
          clickhouse-operator.package = packages.experimental.clickhouse-operator;
          clickhouse-operator-credentials = {
            package = packages.secret;
            aliases = [ "credentials" ];
            config.stringData = {
              username = "clickhouse_operator";
              password = "swap-fixture-operator";
            };
          };
        };

        instances.db = {
          keeper.package = packages.experimental.clickhouse-keeper;
          ch.package = packages.experimental.clickhouse-cluster;
          ch-credentials = {
            package = packages.secret;
            aliases = [ "credentials" ];
            config.stringData.password = "swap-fixture-admin";
          };
        };
      }
    )
  ];
}
