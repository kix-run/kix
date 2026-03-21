# clusters/test-minimal.nix — Minimal cluster: only coredns with defaults.
#
# Tests that a minimal configuration produces the expected resources.
# Used for negative assertions (disabled features absent).

{ kix, packages }:

kix.buildCluster {
  name = "test-minimal";
  modules = [
    {
      namespaces.kube-system = { };

      instances.kube-system = {
        coredns = {
          package = packages.coredns;
          packageType = "coredns";
        };
      };
    }
  ];
}
