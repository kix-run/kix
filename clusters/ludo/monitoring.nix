# Monitoring — Prometheus, Grafana, Loki, Promtail.

{
  config,
  lib,
  kix,
  ...
}:
{
  options.monitoring.enabled = lib.mkEnableOption "cluster monitoring stack";

  config = lib.mkIf config.monitoring.enabled {
    instances.monitoring-system = {

      kube-prometheus-stack = {
        package = kix.fromHelmChart {
          chart = kix.fetchHelmChart {
            repo = "oci://ghcr.io/prometheus-community/charts";
            name = "kube-prometheus-stack";
            version = "71.2.0";
            hash = "sha256-TyftOI7LrTeqbU5IsVjRKb78xC1edDHwegq773QEuUM=";
          };
          values = (import ../../packages/kube-prometheus-stack).defaultValues;
          releaseName = "prometheus";
          includeCrds = true;
        };
        config.values = {
          prometheus.prometheusSpec.retention = "7d";
          grafana = {
            "grafana.ini".server.root_url = "http://grafana.${config.cluster.domain}";
            additionalDataSources = [
              {
                name = "Loki";
                type = "loki";
                url = "http://loki-gateway.monitoring-system.svc.cluster.local";
                access = "proxy";
                isDefault = false;
              }
            ];
          };
        };
      };

      loki = {
        package = kix.fromHelmChart {
          chart = kix.fetchHelmChart {
            repo = "https://grafana.github.io/helm-charts";
            name = "loki";
            version = "6.24.0";
            hash = "sha256-oMXOPOZZrT+UC5ve7vSWJPsUpeTuyECBTXby7arjyIY=";
          };
          values = (import ../../packages/loki).defaultValues;
          releaseName = "loki";
          rootSelector = {
            kind = "Service";
            name = "loki-gateway";
          };
        };
      };

      promtail = {
        package = kix.fromHelmChart {
          chart = kix.fetchHelmChart {
            repo = "https://grafana.github.io/helm-charts";
            name = "promtail";
            version = "6.16.6";
            hash = "sha256-HezE6O/HucgBrIy88PEd8llsK35ns72GztBZKSed3+4=";
          };
          values = (import ../../packages/promtail).defaultValues;
          releaseName = "promtail";
          rootSelector = {
            kind = "DaemonSet";
            name = "promtail";
          };
        };
      };

    };
  };
}
