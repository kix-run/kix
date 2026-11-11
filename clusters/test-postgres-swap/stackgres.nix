# Swap fixture, first build: Metabase on a stackgres-database. See the
# postgres-swap check in flake.nix.
{ kix, packages }:

kix.buildCluster {
  name = "test-postgres-swap";
  modules = [
    kix.flavors.kind
    (import ./consumer.nix { inherit packages; })
    (
      { ref, ... }:
      # region:postgresSwapStackgres
      {
        instances.stackgres-system.stackgres-operator.package = packages.experimental.stackgres-operator;
        instances.db.pg.package = packages.experimental.stackgres-cluster;
        instances.app.metabase-db = {
          package = packages.experimental.stackgres-database;
          deps.postgres = ref.db.pg;
          # Test values only.
          config.password = "swap-fixture-password";
        };
      }
      # endregion:postgresSwapStackgres
    )
  ];
}
