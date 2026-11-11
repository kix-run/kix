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

        # Per-app postgres cluster, declared so the database in this
        # namespace does not resolve to firezone's postgres. It sets no
        # `extensions`: immich's arrive through immich-db.
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
            password = "immich-dev-password";
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

      # Firezone VPN, with its own postgres cluster. Test values only: a
      # real cluster gives each secret a SOPS `source` or a `secret-ref`.
      instances.firezone = {
        firezone-pg = {
          package = packages.experimental.stackgres-cluster;
          aliases = [ "postgres" ];
        };
        firezone-db = {
          package = packages.experimental.stackgres-database;
          config.password = "firezone-dev-password";
        };

        firezone = {
          package = packages.experimental.firezone;
          config = {
            domain = "vpn.example.com";
            admin.email = "admin@example.com";
          };
        };
        firezone-secrets = {
          package = packages.secret;
          aliases = [ "applicationSecrets" ];
          config.stringData = {
            GUARDIAN_SECRET_KEY = "PLACEHOLDER_CHANGE_ME_guardian";
            SECRET_KEY_BASE = "PLACEHOLDER_CHANGE_ME_secret_key_base";
            DATABASE_ENCRYPTION_KEY = "PLACEHOLDER_CHANGE_ME_db_enc_key";
            LIVE_VIEW_SIGNING_SALT = "PLACEHOLDER_CHANGE_ME_lv_salt";
            COOKIE_SIGNING_SALT = "PLACEHOLDER_CHANGE_ME_cookie_salt";
            COOKIE_ENCRYPTION_SALT = "PLACEHOLDER_CHANGE_ME_cookie_enc_salt";
          };
        };
        firezone-admin = {
          package = packages.secret;
          aliases = [ "adminPassword" ];
          config.stringData.password = "changeme";
        };
        firezone-wireguard = {
          package = packages.secret;
          aliases = [ "wireguardKey" ];
          config.stringData.private_key = "PLACEHOLDER_GENERATE_WITH_wg_genkey";
        };
      };
    }
  ];
}
