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

        # pgvecto.rs extension is now auto-injected by immich via dep config injection.
        immich-db = {
          package = packages.stackgres-cluster;
          aliases = [ "postgres" ];
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
