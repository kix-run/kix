# clusters/test-helm.nix — Tests the kixHelm bridge with a local test chart.
#
# Verifies that fromHelmChart produces valid v2 resources that pass
# through buildCluster, dependency tracking, and validation.

{ kixv2, kixHelm }:

let
  # Local test chart (no network fetch needed).
  testChartPath = ../tests/helm-test-chart;

  # Create a helm-bridge package from the local chart.
  testChartPackage = kixHelm.fromHelmChart {
    chart = testChartPath;
    values = {
      replicaCount = 2;
      image.tag = "1.27-alpine";
    };
    releaseName = "test-app";
  };
in

kixv2.buildCluster {
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
