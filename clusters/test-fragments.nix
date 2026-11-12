# clusters/test-fragments.nix: Cluster composed with `kix.mergeFragments`.
#
# Exercises the public `kix.mergeFragments` entry point re-exported by
# `kix/lib/default.nix`.
#
# Build:  nix build .#cluster-fragments --extra-experimental-features pipe-operators

{ kix, packages }:

let
  # Two fragments a platform team and an application team might own
  # separately. They contribute to the same namespace and must merge rather
  # than one winning.
  platform = {
    namespaces.kube-system.labels."app.kubernetes.io/part-of" = "platform";
    instances.kube-system.coredns = {
      package = packages.experimental.coredns;
      config.clusterIP = "10.96.0.10";
    };
  };

  application = {
    namespaces.kube-system.labels."platform.example.com/tier" = "system";
  };

  composition = kix.mergeFragments {
    fragments = [
      platform
      application
    ];

    # The platform owner's last word, applied over the merged fragments.
    namespacePolicies.kube-system.labels."platform.example.com/managed" = "true";
  };
in
kix.buildCluster {
  name = "test-fragments";
  modules = [
    {
      namespaces = composition.namespaces;
      instances = composition.instances { };
    }
  ];
}
