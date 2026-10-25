# clusters/test-victoria-metrics.nix — VictoriaMetrics stack smoke test.
#
# Exercises (v2_discussions/133 phases 1–2):
# 1. victoria-metrics-operator builds: CRDs (VM-native + prometheus-operator
#    compat), RBAC, deployment.
# 2. The operator claims the `prometheus` DI alias — an inline consumer's
#    prometheus.out.mkServiceMonitor / mkPrometheusRule calls render as
#    monitoring.coreos.com CRs, proving the drop-in surface for kix.monitor
#    and app packages.
# 3. victoria-metrics-cluster renders a VMCluster CR with the HA defaults
#    (RF=2, 3x vmstorage, dedup flags, PDBs, anti-affinity) and claims the
#    `prometheusServer` alias — the grafana instance auto-wires its
#    Prometheus datasource from out.serviceUrl with zero config.
# 4. victoria-metrics-agent remote-writes to the cluster's remoteWriteUrl (the
#    dependency edge rides the URL); victoria-metrics-alert wires
#    datasource/remoteWrite/remoteRead through vmCluster.out and discovers
#    its VMAlertmanager by label selector.
# 5. Each VM package renders its alert rules as a PrometheusRule through the
#    operator's builder; test-victoria-metrics.rules-test.yaml runs promtool
#    tests against them (the rules-cluster-victoria-metrics check).
#
# Build:  nix build .#cluster-victoria-metrics --extra-experimental-features pipe-operators

{ kix, packages }:

let
  # Inline consumer standing in for any app package using kix.monitor's
  # builder surface via the `prometheus` alias.
  scrapeConsumerPackage = {
    meta.version = "0.0.0";
    build =
      {
        self,
        scope,
        prometheus,
        ...
      }:
      {
        # Selectorless Service (no pods behind it — this fixture only tests
        # the ServiceMonitor→VMServiceScrape conversion contract). The
        # monitor sources its selector from the Service's labels, the shape
        # monitorSelectorMatchesService enforces.
        service = scope.mkResource {
          apiVersion = "v1";
          kind = "Service";
          name = "test-consumer";
          labels."app.kubernetes.io/component" = "consumer";
          spec.ports = [
            {
              name = "metrics";
              port = 9100;
            }
          ];
        };

        # PROBE: second Service, identical labels, same port name — the
        # over-match rule must fail this build.
        probeService = scope.mkResource {
          apiVersion = "v1";
          kind = "Service";
          name = "test-consumer-probe";
          labels."app.kubernetes.io/component" = "probe";
          spec.ports = [
            {
              name = "metrics";
              port = 9101;
            }
          ];
        };

        serviceMonitor = prometheus.out.mkServiceMonitor scope {
          name = "test-consumer";
          spec = {
            selector.matchLabels = self.service.out.selector;
            endpoints = [ { port = "metrics"; } ];
          };
        };

        alertRule = prometheus.out.mkPrometheusRule scope {
          name = "test-consumer";
          spec.groups = [
            {
              name = "test-consumer";
              rules = [
                {
                  alert = "TestConsumerDown";
                  expr = "up{job=\"test-consumer\"} == 0";
                  "for" = "5m";
                  labels.severity = "warning";
                }
              ];
            }
          ];
        };

        # No `self.service` in requires: the monitor's selector carries the
        # Service's store-path context, so the edge is already tracked.
        # (Contrast node-exporter, where the requires entry is load-bearing
        # for the prometheus-absent case.)
        root = {
          resource = self.serviceMonitor;
          requires = [
            self.alertRule
            self.probeService
          ];
        };
      };
  };
in
kix.buildCluster {
  name = "test-victoria-metrics";
  modules = [
    {
      namespaces.monitoring-system = { };

      instances.monitoring-system = {
        vm-operator = {
          package = packages.victoria-metrics-operator;
        };
        vm-cluster = {
          package = packages.victoria-metrics-cluster;
          # The rules test expects VMStorageReplicationLost and
          # VMInsertIncompleteReplication, which render only with more
          # nodes than copies and more than one copy.
          config = {
            replicationFactor = 2;
            vmstorage.replicaCount = 3;
          };
        };
        vm-agent = {
          package = packages.victoria-metrics-agent;
          # The post-deploy probe Job (kix.healthCheck).
          config.healthCheck.enabled = true;
        };
        vm-alert = {
          package = packages.victoria-metrics-alert;
          config.healthCheck.enabled = true;
          # VMAlertmanagerMembersInconsistent renders only with a pair.
          config.alertmanager.replicaCount = 2;
        };
        grafana = {
          package = packages.grafana;
          # The auto-wired datasource is VictoriaMetrics, not Prometheus.
          config.prometheusDatasource.name = "VictoriaMetrics";
          # The rename path: drop the entry an older Grafana kept under the
          # default name, which holds the same uid.
          config.deleteDatasources = [ { name = "Prometheus"; } ];
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
        scrape-consumer = {
          package = scrapeConsumerPackage;
        };
      };
    }
  ];
}
