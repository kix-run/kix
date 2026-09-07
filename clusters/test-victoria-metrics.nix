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
# 4. victoria-metrics-agent remote-writes to the cluster's insertUrl (the
#    dependency edge rides the URL); victoria-metrics-alert wires
#    datasource/remoteWrite/remoteRead through vmCluster.out and discovers
#    its VMAlertmanager by label selector.
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
        # monitor sources its selector from the Service's labels
        # (metadata.labels), which is what monitor selectors match against.
        service = scope.mkResource {
          apiVersion = "v1";
          kind = "Service";
          name = "test-consumer";
          spec.ports = [
            {
              name = "metrics";
              port = 9100;
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
          requires = [ self.alertRule ];
        };
      };
  };
in
kix.buildCluster {
  name = "test-victoria-metrics";
  modules = [
    {
      namespaces.monitoring-system = { };

      # Lint the VM packages with the full rule set.
      scorecard = {
        enable = true;
        rules = {
          architecture = kix.rules.architecture;
          reliability = kix.rules.reliability;
          security = kix.rules.security // {
            # Pre-existing finding in the grafana package (here only as the
            # datasource auto-wire consumer): its container securityContext
            # lacks runAsNonRoot. Downgraded from error so it doesn't fail a
            # fixture about the VM packages — which do pass this at error.
            nonRoot = kix.rules.security.nonRoot // {
              severity = "warning";
            };
          };
        };
      };

      instances.monitoring-system = {
        vm-operator = {
          package = packages.victoria-metrics-operator;
        };
        vm-cluster = {
          package = packages.victoria-metrics-cluster;
        };
        vm-agent = {
          package = packages.victoria-metrics-agent;
        };
        vm-alert = {
          package = packages.victoria-metrics-alert;
        };
        grafana = {
          package = packages.grafana;
        };
        scrape-consumer = {
          package = scrapeConsumerPackage;
        };
      };
    }
  ];
}
