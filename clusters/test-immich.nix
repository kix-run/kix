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

        # Per-app postgres cluster, declared so the database in this
        # namespace does not resolve to firezone's postgres. It sets no
        # `extensions`: immich's arrive through immich-db.
        immich-pg = {
          package = packages.stackgres-cluster;
          aliases = [ "postgres" ];
        };

        # Per-app database and role. Only the dev password is set here;
        # immich adds its extensions to `extensions`, and stackgres-database
        # forwards them to immich-pg.
        immich-db = {
          package = packages.stackgres-database;
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

      # Firezone VPN, with its own postgres cluster.
      instances.firezone = {
        firezone-db = {
          package = packages.stackgres-cluster;
          aliases = [ "postgres" ];
        };

        firezone = {
          package = packages.firezone;
          config = {
            domain = "vpn.example.com";
            # firezone holds the `lossy-option-defaults` grant, so `admin` and
            # `wireguard` are set in full: a partial value replaces the default.
            admin = {
              email = "admin@example.com";
              password = "changeme";
              resetOnBoot = true;
            };
            wireguard = {
              port = 51820;
              privateKey = "PLACEHOLDER_GENERATE_WITH_wg_genkey";
              ipv4Network = "100.64.0.0/10";
              ipv4Address = "100.64.0.1";
              ipv6Network = "fd00::/106";
              ipv6Address = "fd00::1";
            };
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
