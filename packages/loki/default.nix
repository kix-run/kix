# Loki — log aggregation system.
#
# Wraps the upstream Grafana Loki Helm chart via fromHelmChart.
# Deployed in distributed mode (read/write/backend) with S3 storage.
#
# Chart:   https://grafana.github.io/helm-charts
# Name:    loki
# Version: 6.24.0
#
# Usage in cluster definition:
#
#   loki = {
#     package = kix.fromHelmChart {
#       chart = kix.fetchHelmChart {
#         repo = "https://grafana.github.io/helm-charts";
#         name = "loki";
#         version = "6.24.0";
#         hash = "sha256-FIXME";
#       };
#       values = (import ./packages/loki).defaultValues;
#       releaseName = "loki";
#       mainSelector = { kind = "Service"; name = "loki-gateway"; };
#     };
#     packageType = "loki";
#     config.values = { /* cluster-level overrides */ };
#   };

{
  chart = {
    repo = "https://grafana.github.io/helm-charts";
    name = "loki";
    version = "6.24.0";
  };

  defaultValues = {
    # --- Deployment mode ---
    deploymentMode = "Distributed";

    # --- Multi-tenancy ---
    loki = {
      auth_enabled = true;
      tenants = [ "system" ];

      # --- Schema / Storage ---
      schemaConfig.configs = [
        {
          from = "2024-01-01";
          store = "tsdb";
          object_store = "s3";
          schema = "v13";
          index = {
            prefix = "index_";
            period = "24h";
          };
        }
      ];

      storage = {
        type = "s3";
        s3 = {
          region = "eu-central";
          bucketnames = "loki-chunks";
          # endpoint and credentials are injected via cluster-level overrides
          # or environment variables from a Secret.
        };
        bucketNames = {
          chunks = "loki-chunks";
          ruler = "loki-ruler";
          admin = "loki-admin";
        };
      };

      # --- Limits ---
      limits_config = {
        retention_period = "4320h"; # 180 days
        max_query_series = 5000;
        max_query_parallelism = 32;
        ingestion_rate_mb = 16;
        ingestion_burst_size_mb = 32;
        per_stream_rate_limit = "5MB";
        per_stream_rate_limit_burst = "15MB";
      };

      # --- Compactor (retention enforcement) ---
      compactor = {
        retention_enabled = true;
        delete_request_store = "s3";
        working_directory = "/tmp/loki/compactor";
      };

      # --- Ruler ---
      ruler = {
        storage = {
          type = "local";
          local.directory = "/tmp/loki/rules";
        };
      };
    };

    # --- Write path ---
    write = {
      replicas = 3;
      resources = {
        requests = {
          cpu = "500m";
          memory = "1Gi";
        };
        limits = {
          cpu = "2";
          memory = "4Gi";
        };
      };
      persistence = {
        enabled = true;
        size = "50Gi";
      };
    };

    # --- Read path ---
    read = {
      replicas = 3;
      resources = {
        requests = {
          cpu = "500m";
          memory = "1Gi";
        };
        limits = {
          cpu = "2";
          memory = "4Gi";
        };
      };
    };

    # --- Backend ---
    backend = {
      replicas = 3;
      resources = {
        requests = {
          cpu = "250m";
          memory = "512Mi";
        };
        limits = {
          cpu = "1";
          memory = "2Gi";
        };
      };
      persistence = {
        enabled = true;
        size = "50Gi";
      };
    };

    # --- Gateway (nginx reverse proxy) ---
    gateway = {
      enabled = true;
      replicas = 1;
      resources = {
        requests = {
          cpu = "50m";
          memory = "64Mi";
        };
        limits = {
          cpu = "250m";
          memory = "128Mi";
        };
      };
      priorityClassName = "monitoring-loki";
    };

    # --- Disable components we don't use ---
    singleBinary.enabled = false;
    monitoring = {
      selfMonitoring.enabled = false;
      lokiCanary.enabled = false;
    };
    test.enabled = false;
  };
}
