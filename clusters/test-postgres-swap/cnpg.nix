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
          package = packages.experimental.cnpg-database;
          deps.postgres = ref.db.pg;
        };
        instances.app.metabase-db-password = {
          package = packages.secret;
          aliases = [ "password" ];
          # Test values only.
          config = {
            source = ../dev-secrets/swap-fixture-db.sops.yaml;
            hash = "sha256-S6OA4+BOL7HbLYUJCq1lhtu/Z8pg2Um/ws0nhRFUSWc=";
            keys = [ "password" ];
          };
        };
      }
      # endregion:postgresSwapCnpg
    )
  ];
}
