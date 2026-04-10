# clusters/test-helm.nix — Tests the helm bridge with a local test chart.
#
# Verifies that importChart produces valid resources that pass
# through buildCluster, dependency tracking, and validation.

{ kix }:

let
  # Local test chart (no network fetch needed).
  testChartPath = ../tests/helm-test-chart;

  # Inline package using importChart with a local chart path.
  testChartPackage =
    { scope, lib }:
    {
      meta = {
        version = "0.1.0";
        isHelm = true;
      };

      options.values = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = { };
      };

      build =
        { config, scope, ... }:
        let
          resources = scope.helm.importChart {
            chart = testChartPath;
            inherit scope;
            values = {
              replicaCount = 2;
              image.tag = "1.27-alpine";
            }
            // (config.values or { });
            releaseName = "test-app";
          };
        in
        resources.mkParts {
          root = resources.autoRoot;
        };
    };
in

kix.buildCluster {
  name = "test-helm";
  modules = [
    {
      namespaces.test-helm = { };

      instances.test-helm = {
        test-app = {
          package = testChartPackage;
          aliases = [ "test-chart" ];
          config = {
            values = {
              service.port = 8080;
            };
          };
        };
      };
    }
  ];
}
