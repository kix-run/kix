# clusters/test-grafana-upgrade.nix: Grafana with Prometheus, Alertmanager,
# and Loki under Cilium default-deny, for testing a Grafana version change.
#
# Grafana keeps its SQLite database on a claim, so a deploy of a new Grafana
# version runs its database migrations over data the old version wrote.
# Prometheus, Alertmanager, and Loki are wired as datasources, so a request
# through each one shows that Grafana still loads their plugins. The node
# exporter and kube-state-metrics are off to keep the cluster small.
#
# Bring up: kind create cluster --name <name> --kubeconfig <file> --config <config>
#           where the config sets networking.disableDefaultCNI = true
# Deploy:   kix deploy grafana-upgrade --context kind-<name> -y

{ kix, packages }:

kix.buildCluster {
  name = "grafana-upgrade";
  specialArgs = { inherit packages kix; };
  modules = [
    kix.flavors.kind
    kix.modules.experimental.monitoring

    {
      cluster.availability.default = "none";
      # kind runs with disableDefaultCNI, so the managed cilium instance
      # fills the vacant CNI role.
      cluster.roles.cni = {
        binding = "absent";
        provider = null;
      };
      networkPolicy.enable = true;
      instances.kube-system.cilium.package = packages.experimental.cilium;

      monitoring = {
        enabled = true;
        nodeExporter.enabled = false;
        kubeStateMetrics.enabled = false;
        loki.enabled = true;
        grafana.persistence.size = "1Gi";
      };

      # Test values only.
      instances.monitoring-system.grafana-admin = {
        package = packages.secret;
        aliases = [ "grafanaAdmin" ];
        config.stringData = {
          admin-user = "admin";
          admin-password = "test-only";
        };
      };
    }
  ];
}
