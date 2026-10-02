# clusters/example-import.nix — Example: immich with imported (external) valkey.
#
# Demonstrates mkImport: valkey is not managed by kix but exists in the cluster.
# The import derives out (name, fqdn, port) from the real valkey package via
# lazy evaluation, so immich's DI resolution gets correct connection details.
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

        # Valkey exists in the cluster but is managed externally.
        # mkImport with `from` runs the valkey package build in import mode
        # (lightweight mkResource) to derive out.name, out.fqdn, out.port.
        # Only a marker PackageInstance CR is deployed. The import's out has
        # no authSecret (housekeeping/2026-10-01-import-drops-root-out-extras.md),
        # so immich sends no password, and the external Valkey must accept
        # clients without one.
        cache = {
          valkey = {
            package = kix.mkImport { from = packages.valkey; };

          };
        };

        # Postgres managed externally (e.g. StackGres, CloudNativePG, RDS).
        database = {
          postgres = {
            package = kix.mkImport {
              from = packages."stackgres-cluster";
              # The extensions the external cluster has installed; the
              # stackgres-database below checks its own against them.
              out.extensions = [
                "vector"
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
        # valkey resolves via DI from the cache namespace: an import is
        # cluster-scoped, while a managed valkey serves only its own
        # namespace.
        # The stackgres-database instance below lives in *this* namespace
        # but talks to the imported postgres in the `database` namespace —
        # demonstrating the cross-namespace flow without cross-namespace
        # secret reads (the credentials Secret is materialized locally).
        immich = {
          storage = {
            package = packages."persistent-volume-claim";
            config = {
              size = "500Gi";
            };
          };

          immich-db = {
            package = packages."stackgres-database";
            aliases = [ "database" ];
            config = {
              database = "immich";
              user = "immich";
              extensions = [ "vector" ];
              password = "immich-dev-password";
            };
          };

          immich = {
            package = packages.immich;
          };

          machine-learning = {
            package = packages."immich-machine-learning";
          };
        };
      };
    }
  ];
}
