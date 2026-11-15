# clusters/test-metrics-server.nix: metrics-server on kind under Cilium
# default-deny, with a consumer of metrics.k8s.io.
#
# The kind flavour binds the metricsApi role absent, so the descheduler's
# KubernetesMetrics source evaluates only because the metrics-server
# instance claims the role. kind's kubelets serve self-signed certificates,
# so the instance passes --kubelet-insecure-tls. Network policy is on, so
# the package's intents (API server ingress, kubelet egress) are rendered.
#
# Build:  kix build metrics-server

{ kix, packages }:

kix.buildCluster {
  name = "metrics-server";
  modules = [
    kix.flavors.kind

    {
      # kind runs with the default CNI disabled; the managed cilium instance
      # fills the vacant role.
      cluster.roles.cni = {
        binding = "absent";
        provider = null;
      };
      networkPolicy.enable = true;

      namespaces = {
        metrics-server = { };
        descheduler = { };
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

        metrics-server.metrics-server = {
          package = packages.experimental.metrics-server;
          config.extraArgs = [ "--kubelet-insecure-tls" ];
        };

        descheduler.descheduler = {
          package = packages.experimental.descheduler;
          config.policy = {
            metricsProviders = [ { source = "KubernetesMetrics"; } ];
            profiles.default.pluginConfig.LowNodeUtilization.metricsUtilization.source = "KubernetesMetrics";
          };
        };
      };
    }
  ];
}
