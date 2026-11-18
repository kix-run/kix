# clusters/test-immich.nix: Immich with auto-instantiation.
#
# Only immich, its storage claim, its postgres cluster, the per-app database
# (which needs an explicit dev password), valkey's password, and
# storage-classes are declared. storage-classes is declared because the
# cluster has no flavor to provide a class, and an optional dependency does
# not auto-instantiate it. valkey and the extensions immich needs (vchord,
# uuid-ossp, cube, earthdistance, unaccent, pg_trgm) arrive through
# auto-instantiation and dependency config injection: immich adds them to
# the database, which forwards them to its postgres cluster, and the
# operator installs them on the postgres image.
#
# Build:  kix build immich

{ kix, packages }:

kix.buildCluster {
  name = "test-immich";
  modules = [
    {
      availablePackages = packages;

      instances.kube-system.storage-classes = {
        package = packages.storage-classes;
        config.classes.local-path = {
          provisioner = "rancher.io/local-path";
          volumeBindingMode = "WaitForFirstConsumer";
        };
      };

      # The operator is cluster-scoped: declare it once to avoid duplicate CRDs.
      instances.stackgres-system.stackgres-operator = {
        package = packages.experimental.stackgres-operator;
      };

      instances.immich = {
        immich = {
          package = packages.experimental.immich;
        };

        immich-library = {
          package = packages.persistent-volume-claim;
          aliases = [ "storage" ];
          config = {
            size = "200Gi";
          };
        };

        # Per-app postgres cluster. It sets no `extensions`, because
        # immich's arrive through immich-db.
        immich-pg = {
          package = packages.experimental.stackgres-cluster;
          aliases = [ "postgres" ];
        };

        # Per-app database and role. Only the dev password is set here;
        # immich adds its extensions to `extensions`, and stackgres-database
        # forwards them to immich-pg.
        immich-db = {
          package = packages.experimental.stackgres-database;
          aliases = [ "database" ];
          config = {
            database = "immich";
            user = "immich";
          };
        };
        immich-db-password = {
          package = packages.secret;
          aliases = [ "password" ];
          config = {
            source = ./dev-secrets/immich-db.sops.yaml;
            keys = [ "password" ];
          };
        };

        # The auto-instantiated valkey lands in this namespace and requires
        # its password here.
        valkey-password = {
          package = packages.secret;
          aliases = [ "valkeyPassword" ];
          config.stringData.password = "valkey-dev-password";
        };
      };
    }
  ];
}
