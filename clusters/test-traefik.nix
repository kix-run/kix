# clusters/test-traefik.nix: Traefik as the cluster's Gateway API
# implementation on kind, under Cilium default-deny.
#
# filebrowser, in a namespace of its own, is exposed through kix.expose, so
# it gets an HTTPRoute on the Traefik Gateway and a policy that admits the
# Traefik pods to its pod port. The kind flavour binds the loadBalancer role
# absent, so the Traefik Service is a NodePort. prometheus-operator answers
# the `prometheus` alias, so Traefik renders its metrics Service,
# ServiceMonitor, and alert rules, which test-traefik.rules-test.yaml tests.
# No Prometheus server runs.
#
# The Gateway API standard-channel CRDs (v1.6.1 or later) must be installed
# before deploy:
#   kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.1/standard-install.yaml
#
# Build:  kix build traefik

{ kix, packages }:

kix.buildCluster {
  name = "traefik";
  modules = [
    kix.flavors.kind

    {
      # kind runs with the default CNI disabled; the managed cilium instance
      # fills the vacant role.
      cluster.roles.cni = {
        binding = "absent";
        provider = null;
      };
      cluster.domain = "traefik.test";
      networkPolicy.enable = true;

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

        gateway-system.traefik = {
          package = packages.experimental.traefik;
          config.metrics.enabled = true;
        };

        files = {
          filebrowser.package = packages.experimental.filebrowser;
          filebrowser-data = {
            package = packages.persistent-volume-claim;
            aliases = [ "storage" ];
            config.size = "1Gi";
          };
        };
      };
    }
  ];
}
