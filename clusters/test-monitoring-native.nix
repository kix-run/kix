# Test cluster: the monitoring module with every package option that
# renders something on.
#
# Default rules, Prometheus and Alertmanager on claims with three
# Alertmanager receivers (so its egress policy has world ports), a Grafana
# datasource beside the wired ones, the dashboards and datasources sidecars
# reading ConfigMaps and Secrets, init-chown-data, a Grafana route through
# ingress-nginx, and network policy, at availability `node` so Prometheus and
# Alertmanager run several replicas with spread constraints and disruption
# budgets.
#
# Build: nix build ./clusters#cluster-monitoring-native --extra-experimental-features pipe-operators

{ kix, packages }:

kix.buildCluster {
  name = "monitoring-native";
  specialArgs = { inherit packages kix; };
  modules = [
    kix.flavors.kind
    kix.modules.monitoring

    {
      cluster.domain = "monitoring.test";
      cluster.capabilities.multiNode = true;
      cluster.availability.default = "node";
      cluster.roles.cni = {
        binding = "absent";
        provider = null;
      };
      networkPolicy.enable = true;
      instances.kube-system.cilium.package = packages.cilium;
      instances.ingress-nginx.ingress-nginx.package = packages.ingress-nginx;

      monitoring = {
        enabled = true;
        defaultRules.enabled = true;
        prometheus = {
          retention = "15d";
          retentionSize = "8GB";
          storage.size = "10Gi";
        };
        alertmanager.settings = {
          global.smtp_smarthost = "smtp.example.com:587";
          route.receiver = "ops";
          receivers = [
            { name = "null"; }
            {
              name = "ops";
              email_configs = [ { to = "ops@example.com"; } ];
              webhook_configs = [ { url = "https://hooks.example.com/alertmanager"; } ];
              slack_configs = [ { api_url_file = "/etc/alertmanager/secrets/slack/url"; } ];
            }
          ];
        };
        grafana.datasources = [
          {
            name = "Tempo";
            type = "tempo";
            uid = "tempo";
            url = "http://tempo.tracing.svc:3200";
            access = "proxy";
          }
        ];
      };

      instances.monitoring-system = {
        alertmanager.config = {
          storage.size = "1Gi";
          extraSpec.secrets = [ "slack" ];
        };
        grafana.config = {
          ingress.host = "grafana.monitoring.test";
          initChownData.enabled = true;
          sidecar.sources.secrets = true;
        };
        # Test values only.
        grafana-admin = {
          package = packages.secret;
          aliases = [ "grafanaAdmin" ];
          config.stringData = {
            admin-user = "admin";
            admin-password = "test-only";
          };
        };
      };
    }
  ];
}
