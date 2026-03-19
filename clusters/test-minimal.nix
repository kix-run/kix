# clusters/test-minimal.nix — Minimal cluster: only coredns with defaults.
#
# Tests that a minimal configuration produces the expected resources.
# Used for negative assertions (disabled features absent).

{ kix, packages }:

kix.buildCluster {
  name = "test-minimal";
  namespaces.kube-system = { };

  instances =
    { ref, ... }:
    {
      kube-system = {
        coredns = {
          package = packages.coredns;
          packageType = "coredns";
        };
      };
    };
}
