# clusters/test-immich.nix — Immich with auto-instantiation.
#
# Only immich, its storage PVC, and postgres are declared explicitly.
# Everything else (valkey, storage-classes) is auto-instantiated.
#
# Build:  nix build .#cluster-immich --extra-experimental-features pipe-operators

{ kix, packages }:

kix.buildCluster {
  name = "test-immich";
  modules = [
    {
      availablePackages = packages;

      instances.immich = {
        immich = {
          package = packages.immich;
        };

        immich-library = {
          package = packages.persistent-volume-claim;
          aliases = [ "storage" ];
          config = {
            size = "200Gi";
          };
        };

        # Explicit — needs pgvecto.rs extension for immich.
        immich-db = {
          package = packages.stackgres-cluster;
          aliases = [ "postgres" ];
          config.postgres.extensions = [
            {
              name = "vectors";
              publisher = "tensorchord";
              version = "0.4.0";
              repository = "https://extensions.stackgres.io/postgres/repository";
            }
          ];
        };
      };
    }
  ];
}
