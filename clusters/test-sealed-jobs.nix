# clusters/test-sealed-jobs.nix: a package whose Job goes through
# scope.mkJob: cert-manager (startupapicheck). Build this cluster to see a
# change to mkJob in a full package.
#
# Build:  nix build .#cluster-sealed-jobs --extra-experimental-features pipe-operators

{ kix, packages }:

kix.buildCluster {
  name = "sealed-jobs";
  modules = [
    kix.flavors.kind

    {
      cluster.capabilities.multiNode = true;
      cluster.capabilities.availabilityZones = [
        "a"
        "b"
        "c"
      ];

      namespaces.cert-manager = { };

      instances.cert-manager.cert-manager.package = packages.cert-manager;
    }
  ];
}
