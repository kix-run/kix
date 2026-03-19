# clusters/test-helm.nix — Tests the helm bridge with a local test chart.
#
# Verifies that fromHelmChart produces valid resources that pass
# through buildCluster, dependency tracking, and validation.

{ kix }:

let
  # Local test chart (no network fetch needed).
  testChartPath = ../tests/helm-test-chart;

  # Create a helm-bridge package from the local chart.
  testChartPackage = kix.fromHelmChart {
    chart = testChartPath;
    values = {
      replicaCount = 2;
      image.tag = "1.27-alpine";
    };
    releaseName = "test-app";
  };
in

kix.buildCluster {
  name = "test-helm";
  namespaces.test-helm = { };

  instances =
    { ref, ... }:
    {
      test-helm = {
        test-app = {
          package = testChartPackage;
          packageType = "test-chart";
          config = {
            values = {
              service.port = 8080;
            };
          };
        };
      };
    };
}
