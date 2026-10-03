# clusters/test-spegel.nix: Spegel on a multi-node kind cluster under Cilium
# default-deny, with its ServiceMonitor.
#
# The kind flavour declares one node and containerd's discard of unpacked
# layers, both of which the spegel package refuses, so this cluster
# declares the kind cluster it runs on. Create it with a worker, without
# the default CNI, and with the CRI patch Spegel needs:
#
#   kind: Cluster
#   apiVersion: kind.x-k8s.io/v1alpha4
#   networking:
#     disableDefaultCNI: true
#   containerdConfigPatches:
#     - |-
#       [plugins."io.containerd.cri.v1.images"]
#         discard_unpacked_layers = false
#   nodes:
#     - role: control-plane
#     - role: worker
#
# Cilium in kube-proxy mode serves the hostPort that containerd reaches the
# local Spegel pod through only with portmap chaining.
#
# Build:  nix build .#cluster-spegel --extra-experimental-features pipe-operators

{ kix, packages }:

kix.buildCluster {
  name = "spegel";
  modules = [
    kix.flavors.kind

    {
      cluster.capabilities.multiNode = true;
      cluster.containerd.discardUnpackedLayers = false;

      # kind runs with the default CNI disabled; the managed cilium instance
      # fills the vacant role.
      cluster.roles.cni = {
        binding = "absent";
        provider = null;
      };
      networkPolicy.enable = true;

      namespaces = {
        spegel = { };
        monitoring = { };
      };

      instances = {
        kube-system.cilium = {
          package = packages.cilium;
          config.values = {
            kubeProxyReplacement = false;
            cni.chainingMode = "portmap";
            prometheus.enabled = false;
            ipam.operator.clusterPoolIPv4PodCIDRList = [ "10.244.0.0/16" ];
          };
        };

        monitoring.prometheus-operator.package = packages.prometheus-operator;

        spegel.spegel = {
          package = packages.spegel;
          config = {
            mirroredRegistries = [
              "https://docker.io"
              "https://ghcr.io"
              "https://quay.io"
              "https://registry.k8s.io"
            ];
            metrics.enabled = true;
          };
        };
      };
    }
  ];
}
