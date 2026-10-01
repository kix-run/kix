# clusters/test-immich.nix — Immich with auto-instantiation.
#
# Only immich, its storage PVC, the per-app database (which needs an
# explicit dev password) and storage-classes are declared. storage-classes
# is declared because the cluster has no flavor to provide a class, and an
# optional dependency does not auto-instantiate it. valkey, the
# stackgres-cluster postgres backend, and the database's required
# extensions are all picked up via auto-instantiation + dep config
# injection — immich declares it needs `vector`, the database forwards
# that to postgres, and the operator installs it on the postgres image.
#
# Build:  nix build .#cluster-immich --extra-experimental-features pipe-operators

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

      # Operator is cluster-scoped — declare once to avoid duplicate CRDs.
      instances.stackgres-system.stackgres-operator = {
        package = packages.stackgres-operator;
      };

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

        # Per-app postgres cluster. Declared so the database in this
        # namespace doesn't reach across namespaces to firezone's
        # postgres via cluster-wide DI resolution. Notably: NO `extensions`
        # config — the vector extension comes via dep config injection
        # (immich → immich-db → immich-pg) at build time.
        immich-pg = {
          package = packages.stackgres-cluster;
          aliases = [ "postgres" ];
        };

        # Per-app database + role. The only thing we have to set is the
        # dev password — extensions and the underlying postgres backend
        # are wired automatically:
        #   immich.deps.database.config.extensions = [ "vector" ]
        #     → stackgres-database forwards to its postgres dep (immich-pg)
        #     → operator installs the extension on the postgres image
        immich-db = {
          package = packages.stackgres-database;
          aliases = [ "database" ];
          config = {
            database = "immich";
            user = "immich";
            password = "immich-dev-password";
          };
        };
      };

      # Firezone VPN — shares the postgres instance from immich namespace.
      instances.firezone = {
        firezone-db = {
          package = packages.stackgres-cluster;
          aliases = [ "postgres" ];
        };

        firezone = {
          package = packages.firezone;
          config = {
            domain = "vpn.example.com";
            admin = {
              email = "admin@example.com";
              password = "changeme";
            };
            wireguard.privateKey = "PLACEHOLDER_GENERATE_WITH_wg_genkey";
            secrets = {
              guardianSecretKey = "PLACEHOLDER_CHANGE_ME_guardian";
              secretKeyBase = "PLACEHOLDER_CHANGE_ME_secret_key_base";
              databaseEncryptionKey = "PLACEHOLDER_CHANGE_ME_db_enc_key";
              liveViewSigningSalt = "PLACEHOLDER_CHANGE_ME_lv_salt";
              cookieSigningSalt = "PLACEHOLDER_CHANGE_ME_cookie_salt";
              cookieEncryptionSalt = "PLACEHOLDER_CHANGE_ME_cookie_enc_salt";
            };
          };
        };
      };
    }
  ];
}
