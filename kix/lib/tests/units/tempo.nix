# Tests for kix/packages/tempo: its root.out honours the OTLP endpoint
# contract, `retention` reaches the rendered config, and the settings
# locks, owned flags, backslashes in settings, and retentions outside
# Tempo's duration grammar are refused, and the alert rules render as the
# claim, the memory limit, and the dependencies say. Tempo runs in
# namespace `tracing` on a persistent-volume-claim, the prometheus stub in
# `monitoring`.

{
  lib,
  mkCluster,
  manifests,
  ofKind,
  byName,
  evalFails,
  storageClassImport,
  eval,
  kixlib,
  alertRulesOf,
  allSelect,
  prometheusStub,
  ...
}:

let
  tempoPackage = import ../../../packages/tempo;
  pvcPackage = import ../../../packages/persistent-volume-claim;

  # `modules` are added to the cluster.
  tempoCluster = config: tempoClusterWith { inherit config; };
  tempoClusterWith =
    {
      config ? { },
      modules ? [ ],
    }:
    mkCluster (
      [
        {
          instances.tracing = {
            storage = {
              package = pvcPackage;
              config = {
                size = "1Gi";
                storageClassName = "standard";
              };
            };
            standard-class = storageClassImport "standard";
            tempo = {
              package = tempoPackage;
              inherit config;
            };
          };
        }
      ]
      ++ modules
    );

  withPrometheus.instances.monitoring.prometheus.package = prometheusStub;
  rulesOf = cluster: alertRulesOf "PrometheusRule" "tempo" (manifests cluster);

  tempoConfigOf =
    cluster:
    builtins.fromJSON
      (byName "tempo-config" (ofKind "ConfigMap" (manifests cluster))).data."tempo.yaml";

  plain = builtins.unsafeDiscardStringContext;
in
{
  # The Service URLs reach root.out on the OTLP and query ports.
  tempo-out-honours-otlp-contract =
    let
      out = (tempoCluster { }).instances.tracing.tempo.raw.root.out;
    in
    builtins.match "http://tempo-otlp\\.tracing\\.svc\\..*:4317" (plain out.otlpGrpcUrl) != null
    && builtins.match "http://tempo-otlp\\.tracing\\.svc\\..*:4318" (plain out.otlpHttpUrl) != null
    && builtins.match "http://tempo\\.tracing\\.svc\\..*:3200" (plain out.queryUrl) != null
    && out.tls == false;

  # `retention` renders as the per-tenant default, and an unlocked
  # `settings` key merges beside the package's own.
  tempo-retention-and-settings-render =
    let
      cfg = tempoConfigOf (tempoCluster {
        retention = "72h";
        settings.query_frontend.search.max_duration = "336h";
      });
    in
    cfg.overrides.defaults.compaction.block_retention == "72h"
    && cfg.query_frontend.search.max_duration == "336h"
    && cfg.storage.trace.backend == "local"
    && cfg.live_store.wal.path == "/var/tempo/live-store/traces";

  # `retention` follows Prometheus `model.ParseDuration`, which Tempo uses
  # for `block_retention`: day and week units are accepted; a fraction, a
  # unit it does not know, and units out of order are refused, as is zero,
  # which Tempo reads as its 14-day default.
  tempo-retention-follows-tempo-grammar =
    !evalFails (tempoCluster {
      retention = "7d";
    })
    && !evalFails (tempoCluster {
      retention = "4w2d12h";
    })
    && evalFails (tempoCluster {
      retention = "1.5h";
    })
    && evalFails (tempoCluster {
      retention = "100us";
    })
    && evalFails (tempoCluster {
      retention = "30m1h";
    })
    && evalFails (tempoCluster {
      retention = "0s";
    });

  # Tempo's env expansion reads a backslash as an escape, so a settings
  # string holding one is refused, in an attrset or in a list.
  tempo-refuses-backslash-in-settings =
    !evalFails (tempoCluster {
      settings.server.http_path_prefix = "/a/b";
    })
    && evalFails (tempoCluster {
      settings.server.http_path_prefix = "/a\\d";
    })
    && evalFails (tempoCluster {
      settings.distributor.extra = [ "x\\y" ];
    });

  # Each refusal beside the positive control above: a locked settings path,
  # an ancestor of one, and an owned flag in both spellings.
  tempo-refuses-owned-paths =
    !evalFails (tempoCluster { })
    && evalFails (tempoCluster {
      settings.overrides.defaults.compaction.block_retention = "1h";
    })
    && evalFails (tempoCluster {
      settings.storage.trace = null;
    })
    && evalFails (tempoCluster {
      settings.multitenancy_enabled = true;
    })
    && evalFails (tempoCluster {
      settings.live_store.wal.path = "/tmp/wal";
    })
    && evalFails (tempoCluster {
      settings.backend_scheduler.local_work_path = "/tmp";
    })
    && evalFails (tempoCluster {
      extraArgs = [ "-live-store.shutdown_marker_dir=/tmp" ];
    })
    && evalFails (tempoCluster {
      extraArgs = [ "-target=distributor" ];
    })
    && evalFails (tempoCluster {
      extraArgs = [ "--storage.trace.backend=s3" ];
    })
    && !evalFails (tempoCluster {
      extraArgs = [ "-log.level=debug" ];
    });

  # The rules select on the Service and render only with a prometheus
  # dependency and metrics on. TempoBlocksNearClaimSize needs a storage
  # dependency that reports `out.size`, which the imported claim here does
  # not, and TempoMemoryNearLimit needs a memory limit.
  tempo-alerts =
    let
      on = rulesOf (tempoClusterWith {
        modules = [ withPrometheus ];
      });
      importedClaim = rulesOf (tempoClusterWith {
        modules = [
          withPrometheus
          {
            instances.tracing.storage.package = lib.mkForce (
              eval.mkImport {
                out.name = kixlib.untrackedRef {
                  name = "storage";
                  kind = "PersistentVolumeClaim";
                };
              }
            );
          }
        ];
      });
      noLimit = rulesOf (tempoClusterWith {
        config.resources.limits.memory = null;
        modules = [ withPrometheus ];
      });
    in
    (
      allSelect ''namespace="tracing",service="tempo"'' on
      && on ? TempoDown
      && on ? TempoBlocksNearClaimSize
      && on ? TempoMemoryNearLimit
      && importedClaim ? TempoDown
      && !(importedClaim ? TempoBlocksNearClaimSize)
      && !(noLimit ? TempoMemoryNearLimit)
      && rulesOf (tempoCluster { }) == null
      &&
        rulesOf (tempoClusterWith {
          config.metrics.enabled = false;
          modules = [ withPrometheus ];
        }) == null
    )
    || throw "tempo alerts: ${builtins.toJSON (builtins.attrNames on)}";
}
