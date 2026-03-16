# clusters/v2/test-minimal.nix — Minimal v2 cluster: only coredns with defaults.
#
# Tests that a minimal configuration produces the expected resources.
# Used for negative assertions (disabled features absent).

{ kixv2, packages }:

kixv2.buildCluster {
  namespaces.kube-system = { };

  instances = { ref, ... }: {
    kube-system = {
      coredns = {
        package = packages.coredns;
        packageType = "coredns";
      };
    };
  };
}
