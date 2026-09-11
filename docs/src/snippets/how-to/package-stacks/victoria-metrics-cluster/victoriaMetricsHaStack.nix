      instances.monitoring-system = {
        vm-operator = {
          package = packages.victoria-metrics-operator;
        };

        vm-cluster = {
          package = packages.victoria-metrics-cluster;
          config = {
            retentionPeriod = "30d";
            vmstorage.storage.resources.requests.storage = "20Gi";
          };
        };

        vm-agent = {
          package = packages.victoria-metrics-agent;
          config.externalLabels.cluster = "example";
        };

        vm-alert = {
          package = packages.victoria-metrics-alert;
        };

        grafana = {
          package = packages.grafana;
        };
      };