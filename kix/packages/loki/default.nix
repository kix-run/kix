# Loki — log aggregation system.
#
# Provides default Helm chart values for the upstream Grafana Loki chart.
# Cluster modules instantiate it via `kix.fromHelmChart` and pair it with a
# sibling persistent-volume-claim instance for the underlying PVC. The PVC
# participates in proper DI: its StorageClass comes from the flavor's
# `storageClasses` import (kind → standard, k3s → local-path), so the same
# cluster definition works on both without hardcoding.
#
# Why a value-provider and not a native kix package: the kix eval pipeline
# only exposes `kixlib` (pure helpers) to package build functions; the helm
# bridge (which needs `pkgs`) lives outside of eval, so a package's build
# can't call `fromHelmChart`. Until that's threaded through (see
# v2_discussions/), helm-wrapped services are instantiated at the
# cluster-module level, with their PVCs declared as proper sibling
# instances.
#
# Defaults: SingleBinary + filesystem object store. That's the only mode
# that maps cleanly to a single externally-owned PVC. For HA you need
# StatefulSet volumeClaimTemplates and a real object store — out of scope
# for these defaults; override via `extraValues` if needed.
#
# Chart:   https://grafana.github.io/helm-charts
# Name:    loki
# Version: 6.24.0

{
  meta = {
    version = "6.24.0";
    description = "Loki — log aggregation system (single-binary, filesystem)";
    # Logs are expendable — no migration pair on storage backend swaps.
    # See v2_discussions/67_stateful_migration_orchestration.md.
    lifecycle = "ephemeral";
  };

  chart = {
    repo = "https://grafana.github.io/helm-charts";
    name = "loki";
    version = "6.24.0";
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

    # SingleBinary is the only mode this default targets — explicitly zero
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
}
