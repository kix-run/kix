# clusters/test-minimal.nix: minimal cluster, only coredns with its required clusterIP.
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
          config.clusterIP = "10.96.0.10";
        };
      };
    }
  ];
}
