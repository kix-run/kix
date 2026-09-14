# clusters/test-victoria-metrics-crd-ref.nix — the VM operator on a cluster
# that already runs prometheus-operator.
#
# Companion to test-victoria-metrics.nix, which covers the default: the
# operator declares the four monitoring.coreos.com CRDs itself. This one
# covers `prometheusOperatorCRDs = "reference"`, where they already exist
# and kix waits for them instead.
#
# What it proves:
# 1. No CustomResourceDefinition is rendered for ServiceMonitor,
#    PodMonitor, PrometheusRule or Probe — four import markers instead.
# 2. `out.mkServiceMonitor` / `mkPrometheusRule` still build CRs, because
#    mkCRDRef returns the same builders mkCRD does. An inline consumer
#    calls both, so a regression here fails the build rather than the
#    deploy.
# 3. The VM-native CRDs are unaffected: the operator still ships its own
#    complete bundle, which it must (kinds.nix).
#
# Build:  nix build .#cluster-victoria-metrics-crd-ref --extra-experimental-features pipe-operators

{ kix, packages }:

let
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

        # Built from the referenced CRD, not a declared one.
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

        root = {
          resource = self.serviceMonitor;
          requires = [ self.alertRule ];
        };
      };
  };
in
kix.buildCluster {
  name = "test-victoria-metrics-crd-ref";
  modules = [
    {
      namespaces.monitoring-system = { };

      instances.monitoring-system = {
        vm-operator = {
          package = packages.victoria-metrics-operator;
          config.prometheusOperatorCRDs = "reference";
        };
        vm-cluster = {
          package = packages.victoria-metrics-cluster;
        };
        scrape-consumer = {
          package = scrapeConsumerPackage;
        };
      };
    }
  ];
}
