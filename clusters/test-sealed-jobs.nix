# clusters/test-sealed-jobs.nix: cert-manager on a multi-node cluster with
# three zones, so its availability derives as "zone". No other cluster builds
# cert-manager at that level: its controller, cainjector, and webhook run two
# replicas with the derived zone spread and PodDisruptionBudgets. Its
# startupapicheck Job goes through scope.mkJob.
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
