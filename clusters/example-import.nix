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
        # Storage infrastructure — managed by kix even when other deps are imported.
        kube-system = {
          storage-classes = {
            package = packages.storage-classes;
            aliases = [ "storageClasses" ];
          };
        };

        # Valkey exists in the cluster but is managed externally.
        # mkImport with `from` runs the valkey package build in import mode
        # (lightweight mkResource) to derive out.name, out.fqdn, out.port.
        # Only a marker PackageInstance CR is deployed.
        cache = {
          valkey = {
            package = kix.mkImport { from = packages.valkey; };

          };
        };

        # Postgres managed externally (e.g. StackGres, CloudNativePG, RDS).
        database = {
          postgres = {
            package = kix.mkImport { from = packages."stackgres-cluster"; };

          };
        };

        # Immich namespace: server + ML worker.
        # valkey resolves via DI from the cache namespace (cluster-wide).
        # postgres resolves via DI from the database namespace (cluster-wide).
        # storage resolves via DI from the same namespace (PVC).
        # machineLearning resolves via DI from the same namespace.
        immich = {
          storage = {
            package = packages."persistent-volume-claim";
            config = {
              size = "500Gi";
            };
          };

          immich = {
            package = packages.immich;
            config = {
              # DB auth provided via env (secrets):
              # env.DB_USERNAME = "immich";
              # env.DB_PASSWORD = "...";  # use external secret management
              # env.DB_DATABASE_NAME = "immich";
            };
          };

          machineLearning = {
            package = packages."immich-machine-learning";

          };
        };
      };
    }
  ];
}
