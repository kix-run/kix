# clusters/example-import.nix: example of immich with imported (external) valkey.
#
# Demonstrates mkImport: valkey and postgres are not managed by kix but exist
# in the cluster. Each import's `out` gives immich the connection details.
#
# Build:  nix build .#cluster-example-import

{ kix, packages }:

kix.buildCluster {
  name = "example-import";
  modules = [
    {
      clusterLabels = {
        "app.kubernetes.io/part-of" = "kix-example-import";
      };

      instances = {
        # The cluster's existing StorageClass, imported as the storageClasses
        # provider. The immich claim below names no class and gets this one.
        # region:importedStorageClass
        kube-system.platform-storage.package = kix.mkImport {
          kind = "StorageClass";
          apiVersion = "storage.k8s.io/v1";
          roles = [ "storageClasses" ];
          out = {
            name = "local-path";
            storageClassName = "local-path";
          };
        };
        # endregion:importedStorageClass

        # Valkey exists in the cluster but is managed externally. The
        # import's `out` sets the fields of the Redis contract
        # (kix.contracts.redis) that immich reads. Only a marker
        # PackageInstance CR is deployed. This server takes no password;
        # for one that does, put the import in immich's namespace with
        # `scope = "namespace"` and `credentials = ref.<ns>.<secret>`.
        cache = {
          redis = {
            package = kix.mkImport {
              out = {
                host = "valkey.cache.svc.cluster.local";
                port = "6379";
              };
            };
          };
        };

        # Postgres managed externally (e.g. StackGres, CloudNativePG, RDS).
        database = {
          postgres = {
            package = kix.mkImport {
              from = packages.experimental."stackgres-cluster";
              # The extensions the external cluster has installed. The
              # stackgres-database below checks the ones immich asks for
              # against this list.
              out.extensions = [
                "vchord"
                "uuid-ossp"
                "cube"
                "earthdistance"
                "unaccent"
                "pg_trgm"
              ];
            };

          };
        };

        # Immich namespace: server + ML worker + per-app database instance.
        # redis resolves via DI from the cache namespace: an import is
        # cluster-scoped, while a managed valkey serves only its own
        # namespace.
        # The stackgres-database instance below lives in *this* namespace
        # but talks to the imported postgres in the `database` namespace,
        # demonstrating the cross-namespace flow without cross-namespace
        # secret reads (the credentials Secret is materialized locally).
        immich = {
          storage = {
            package = packages."persistent-volume-claim";
            config = {
              size = "500Gi";
            };
          };

          # immich adds the extensions it needs to this instance, which
          # checks them against the imported cluster's out.extensions.
          immich-db = {
            package = packages.experimental."stackgres-database";
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
              hash = "sha256-vwbLaeeessNjQjxi7gXuctFP+UjgTrRHzy8XO/cXeTc=";
              keys = [ "password" ];
            };
          };

          immich = {
            package = packages.experimental.immich;
          };

          machine-learning = {
            package = packages.experimental."immich-machine-learning";
          };
        };
      };
    }
  ];
}
