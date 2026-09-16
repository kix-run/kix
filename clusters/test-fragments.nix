# clusters/test-fragments.nix — a cluster composed with `kix.mergeFragments`.
#
# The point of this cluster is the *public* call. `mergeFragments` was
# implemented in kix/lib/vocab/fragments.nix and documented in the handbook
# for months while `kix/lib/default.nix` never re-exported it, so every
# consuming flake that followed the documentation got
# "attribute 'mergeFragments' missing". Nothing built here used it, so
# nothing caught it. Now something does.
#
# Build:  nix build .#cluster-fragments --extra-experimental-features pipe-operators

{ kix, packages }:

let
  # Two fragments a platform team and an application team might own
  # separately. They contribute to the same namespace and must merge rather
  # than one winning.
  platform = {
    namespaces.kube-system.labels."app.kubernetes.io/part-of" = "platform";
    instances.kube-system.coredns.package = packages.coredns;
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
