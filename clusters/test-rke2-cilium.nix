# clusters/test-rke2-cilium.nix: an RKE2 cluster whose server config sets
# `cni: cilium`, with network policy on.
#
# An evaluation fixture for the cilium package's helmChartConfig delivery
# and the rke2 flavour's platform intents. The cilium instance writes only
# HelmChartConfig/kube-system/rke2-cilium; RKE2 installs Cilium itself.
# Never deploy it to a real RKE2 cluster: it would overwrite that cluster's
# rke2-cilium values.
#
# Build:  nix build ./clusters#cluster-rke2-cilium --extra-experimental-features pipe-operators

{ kix, packages }:

kix.buildCluster {
  name = "rke2-cilium";
  modules = [
    kix.flavors.rke2

    {
      cluster.flavor.rke2.cni = [ "cilium" ];
      networkPolicy.enable = true;

      instances.kube-system.cilium = {
        package = packages.experimental.cilium;
      };

      instances.echo.echo-server = {
        package = packages.echo-server;
      };
    }
  ];
}
