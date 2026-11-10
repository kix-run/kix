# Swap fixture, second build: the same Metabase on a cnpg-database. Nothing
# under ./consumer.nix changes; only what answers `database` does.
{ kix, packages }:

kix.buildCluster {
  name = "test-postgres-swap";
  modules = [
    kix.flavors.kind
    (import ./consumer.nix { inherit packages; })
    (
      { ref, ... }:
      # region:postgresSwapCnpg
      {
        instances.cnpg-system.cnpg-operator.package = packages.cnpg-operator;
        instances.db.pg.package = packages.cnpg-cluster;
        instances.app.metabase-db = {
          package = packages.cnpg-database;
          deps.postgres = ref.db.pg;
          # Test values only.
          config.password = "swap-fixture-password";
        };
      }
      # endregion:postgresSwapCnpg
    )
  ];
}
