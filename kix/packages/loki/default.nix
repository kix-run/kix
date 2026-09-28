# Loki: log aggregation system.
#
# Wraps the upstream Grafana Loki Helm chart via importChart.
# Cluster modules pair it with a sibling persistent-volume-claim instance
# for the underlying PVC. The PVC participates in proper DI: its
# StorageClass comes from the flavor's `storageClasses` import
# (kind → standard, k3s → local-path), so the same cluster definition
# works on both without hardcoding.
#
# Defaults: SingleBinary + filesystem object store. That's the only mode
# that maps cleanly to a single externally-owned PVC. For HA you need
# StatefulSet volumeClaimTemplates and a real object store. That is out of scope
# for these defaults; override via `config.values` if needed.
#
# Chart:   https://grafana.github.io/helm-charts
# Name:    loki
# Version: 7.1.0

{
  scope,
  lib,
  kix,
  availability,
}:
let
  chart = scope.helm.fetchHelmChart {
    repo = "https://grafana.github.io/helm-charts";
    name = "loki";
    version = "7.1.0";
    hash = "sha256-NDYcyiu7b6l1/RruxPnV4rkeLJmvfdb5wU73/mRkk9E=";
  };

  defaultValues = {
    deploymentMode = "SingleBinary";

    loki = {
      auth_enabled = false;
      commonConfig.replication_factor = 1;

      schemaConfig.configs = [
        {
          from = "2024-04-01";
          store = "tsdb";
          object_store = "filesystem";
          schema = "v13";
          index = {
            prefix = "index_";
            period = "24h";
          };
        }
      ];

      storage = {
        type = "filesystem";
        bucketNames = {
          chunks = "chunks";
          ruler = "ruler";
          admin = "admin";
        };
      };

      pattern_ingester.enabled = true;
      limits_config = {
        allow_structured_metadata = true;
        volume_enabled = true;
        retention_period = "168h"; # 7d
      };

      compactor = {
        retention_enabled = true;
        delete_request_store = "filesystem";
      };

      rulerConfig.storage = {
        type = "local";
        local.directory = "/var/loki/rules";
      };
    };

    # SingleBinary is the only mode this default targets; explicitly zero
    # out the SimpleScalable replicas so a stale chart default can't spawn
    # empty StatefulSets.
    write.replicas = 0;
    read.replicas = 0;
    backend.replicas = 0;

    # Optional add-ons that need infra we don't want to assume.
    chunksCache.enabled = false;
    resultsCache.enabled = false;
    lokiCanary.enabled = false;
    monitoring.selfMonitoring.enabled = false;
    test.enabled = false;

    # Gateway (nginx reverse proxy in front of single-binary).
    gateway = {
      enabled = true;
      replicas = 1;
      basicAuth.enabled = false;
    };

    # The loki single-binary chart template hardcodes volumeClaimTemplates
    # and ignores `existingClaim` entirely (verified against chart 6.24.0,
    # `templates/single-binary/statefulset.yaml`). To use a kix-managed PVC
    # we disable the chart's own persistence and mount our PVC by name via
    # extraVolumes/extraVolumeMounts. The cluster module guarantees a PVC
    # called "storage" exists in the same namespace as a sibling instance.
    singleBinary = {
      replicas = 1;
      persistence.enabled = false;
      extraVolumes = [
        {
          name = "storage";
          persistentVolumeClaim.claimName = "storage";
        }
      ];
      extraVolumeMounts = [
        {
          name = "storage";
          mountPath = "/var/loki";
        }
      ];
    };
  };
in
{
  meta = {
    version = "7.1.0";
    description = "Loki: log aggregation system (single-binary, filesystem)";
    owner = "platform";
    lifecycle = "ephemeral";
    # Single-binary Loki over a filesystem store on one ReadWriteOnce PVC:
    # a second replica has no volume to mount and no shared object store to
    # read, so nothing here can be mapped to the level. The replica counts
    # below are fixed, and a cluster that needs more must move to
    # SimpleScalable with a real object store via `values`.
    availability.max = "none";
    # Helm chart is opaque: intra-package edges (gateway → backend) aren't
    # visible via store-path context.  Declare them explicitly so Cilium
    # allows the traffic under default-deny.
    network.intents = {
      intra-package = {
        ingress = [
          {
            from = "all-pods";
            ports = [
              {
                port = 3100;
                protocol = "TCP";
              } # Loki HTTP API
              {
                port = 9095;
                protocol = "TCP";
              } # gRPC
            ];
          }
        ];
      };
    };
  };

  options.values = lib.mkOption {
    type = lib.types.attrsOf lib.types.anything;
    default = { };
    description = "Helm values to deep-merge with the chart's package-level values.";
  };

  build =
    { config, scope, ... }:
    let
      mergedValues = lib.recursiveUpdate defaultValues (config.values or { });
      isSingleBinary = (mergedValues.deploymentMode or "SingleBinary") == "SingleBinary";
      resources = scope.helm.importChart {
        inherit chart scope;
        values = mergedValues;
        releaseName = "loki";
        # The gateway (nginx) proxies to the loki backend(s). No K8s
        # manifest reference exists between them, so the DAG can't infer
        # the edge. Declare it explicitly. Targets depend on
        # deploymentMode (SingleBinary vs SimpleScalable).
        extraEdges =
          if isSingleBinary then
            [
              {
                from = {
                  kind = "Deployment";
                  name = "loki-gateway";
                };
                to = {
                  kind = "StatefulSet";
                  name = "loki";
                };
              }
            ]
          else
            [
              {
                from = {
                  kind = "Deployment";
                  name = "loki-gateway";
                };
                to = {
                  kind = "StatefulSet";
                  name = "loki-write";
                };
              }
              {
                from = {
                  kind = "Deployment";
                  name = "loki-gateway";
                };
                to = {
                  kind = "Deployment";
                  name = "loki-read";
                };
              }
              {
                from = {
                  kind = "Deployment";
                  name = "loki-gateway";
                };
                to = {
                  kind = "StatefulSet";
                  name = "loki-backend";
                };
              }
            ];
      };
    in
    resources.mkParts {
      root = resources.get "Service" "loki-gateway";
    };
}
