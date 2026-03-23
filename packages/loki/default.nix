# Loki — log aggregation system.
#
# Wraps the upstream Grafana Loki Helm chart via fromHelmChart.
# Deployed in distributed mode (read/write/backend) with S3 storage.
#
# Chart:   https://grafana.github.io/helm-charts
# Name:    loki
# Version: 6.46.0
#
# Usage in cluster definition:
#
#   loki = {
#     package = kix.fromHelmChart {
#       chart = kix.fetchHelmChart {
#         repo = "https://grafana.github.io/helm-charts";
#         name = "loki";
#         version = "6.46.0";
#         hash = "sha256-FIXME";
#       };
#       values = (import ./packages/loki).defaultValues;
#       releaseName = "loki";
#       mainSelector = { kind = "Service"; name = "loki-gateway"; };
#     };

#     config.values = { /* cluster-level overrides */ };
#   };

{
  chart = {
    repo = "https://grafana.github.io/helm-charts";
    name = "loki";
    version = "6.46.0";
  };

  defaultValues = {
    # --- Deployment mode ---
    deploymentMode = "SimpleScalable";

    # --- Multi-tenancy ---
    loki = {
      auth_enabled = true;

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
        max_query_parallelism = 64;
        ingestion_rate_mb = 50;
        ingestion_burst_size_mb = 100;
        ingestion_rate_strategy = "global";
        per_stream_rate_limit = "10MB";
        per_stream_rate_limit_burst = "20MB";
        max_cache_freshness_per_query = "10m";
        max_chunks_per_query = 10000000;
        max_global_streams_per_user = 50000;
        max_line_size = "256kb";
        query_timeout = "600s";
        reject_old_samples = true;
        reject_old_samples_max_age = "168h";
        split_queries_by_interval = "12h";
        volume_enabled = true;
      };

      # --- Querier ---
      querier = {
        max_concurrent = 16;
      };

      # --- Query scheduler ---
      query_scheduler = {
        max_outstanding_requests_per_tenant = 2048;
      };

      # --- Compactor (retention enforcement) ---
      compactor = {
        retention_enabled = true;
        delete_request_store = "s3";
        working_directory = "/var/loki/retention";
      };

      # --- Ruler ---
      rulerConfig = {
        enable_api = true;
        remote_write = {
          enabled = false;
          clients.prometheus.url = "http://prometheus-kube-prometheus-prometheus:9090/api/v1/write";
        };
        storage = {
          type = "local";
          local.directory = "/rules";
        };
      };
    };

    # --- Write path ---
    write = {
      replicas = 3;
      resources = {
        requests = {
          cpu = "100m";
          memory = "512Mi";
        };
        limits = {
          cpu = "2";
          memory = "4Gi";
        };
      };
      persistence = {
        enabled = true;
        size = "10Gi";
        storageClass = "localzfs";
      };
    };

    # --- Read path ---
    read = {
      replicas = 3;
      resources = {
        requests = {
          cpu = "100m";
          memory = "512Mi";
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
          cpu = "100m";
          memory = "512Mi";
        };
        limits = {
          cpu = "2";
          memory = "4Gi";
        };
      };
      persistence = {
        enabled = true;
        size = "10Gi";
        storageClass = "localzfs";
      };
    };

    # --- Gateway (nginx reverse proxy) ---
    gateway = {
      enabled = true;
      replicas = 1;
      basicAuth.enabled = false;
      resources = {
        requests = {
          cpu = "100m";
          memory = "512Mi";
        };
        limits = {
          cpu = "2";
          memory = "4Gi";
        };
      };
    };

    # --- Canary ---
    lokiCanary = {
      enabled = true;
      resources = {
        limits = {
          cpu = "250m";
          memory = "128Mi";
        };
      };
    };

    # --- Memcached caches ---
    chunksCache = {
      enabled = true;
    };
    resultsCache = {
      enabled = true;
    };

    # --- Sidecar (rules loader for backend) ---
    sidecar = {
      rules = {
        folderAnnotation = "k8s-sidecar-target-directory";
      };
    };

    # --- Disable components we don't use ---
    singleBinary.enabled = false;
    monitoring = {
      selfMonitoring.enabled = false;
    };
    test.enabled = false;
  };
}
