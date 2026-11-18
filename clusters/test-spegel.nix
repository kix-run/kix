# clusters/test-spegel.nix: Spegel on a multi-node kind cluster under Cilium
# default-deny, with its ServiceMonitor.
#
# The kind flavour declares one node and containerd's discard of unpacked
# layers, both of which the spegel package refuses, so this cluster
# declares the kind cluster it runs on. Create it with a worker, without
# the default CNI, and with the CRI patches Spegel needs. The node image's
# containerd config is version 2 and sets discard_unpacked_layers in the
# `io.containerd.grpc.v1.cri` table, which containerd 2 copies over the
# `io.containerd.cri.v1.images` table, so the patch must use the old table.
# The kind 0.33 node image for Kubernetes 1.37 leaves the registry
# `config_path` empty, so containerd reads no `hosts.toml` until the patch
# sets it:
#
#   kind: Cluster
#   apiVersion: kind.x-k8s.io/v1alpha4
#   networking:
#     disableDefaultCNI: true
#   containerdConfigPatches:
#     - |-
#       [plugins."io.containerd.grpc.v1.cri".containerd]
#         discard_unpacked_layers = false
#       [plugins."io.containerd.grpc.v1.cri".registry]
#         config_path = "/etc/containerd/certs.d"
#   nodes:
#     - role: control-plane
#     - role: worker
#
# Cilium runs in kube-proxy mode, so kube-proxy serves the registry
# NodePort and its `trafficDistribution: PreferSameNode`.
#
# Build:  kix build spegel

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
          package = packages.experimental.cilium;
          config.values = {
            kubeProxyReplacement = false;
            prometheus.enabled = false;
            ipam.operator.clusterPoolIPv4PodCIDRList = [ "10.244.0.0/16" ];
          };
        };

        monitoring.prometheus-operator.package = packages.experimental.prometheus-operator;

        spegel.spegel = {
          package = packages.experimental.spegel;
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
