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
        # Valkey exists in the cluster but is managed externally.
        # mkImport with `from` runs the valkey package build in import mode
        # (lightweight mkResource) to derive out.name, out.fqdn, out.port.
        # Only a marker PackageInstance CR is deployed.
        cache = {
          valkey = {
            package = kix.mkImport { from = packages.valkey; };
            packageType = "valkey";
          };
        };

        # Immich is fully managed by kix.
        # Its `valkey` dependency resolves via DI to the import above,
        # getting out.fqdn for REDIS_HOSTNAME automatically.
        immich = {
          immich = {
            package = packages.immich;
            packageType = "immich";
            config = {
              library.existingClaim = "immich-library";
            };
          };
        };
      };
    }
  ];
}
