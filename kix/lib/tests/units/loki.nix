# Tests for kix/packages/experimental/loki and the kix/lib behaviour it relies on:
# kix.mergeGuarded refuses an override that replaces an ancestor of a locked
# path, and the package's alert rules render as their settings, limits, and
# dependencies say. Loki runs in namespace `logs`, the prometheus stub in
# `monitoring`.

{
  lib,
  kixlib,
  mkCluster,
  manifests,
  alertRulesOf,
  allSelect,
  prometheusStub,
  storageClassImport,
  ...
}:

let
  merge = kixlib.mergeGuarded {
    who = "test ns/inst";
    what = "settings";
    locked = [
      [
        "a"
        "b"
      ]
    ];
  } { a.b = "locked"; };

  fails = overrides: !(builtins.tryEval (builtins.deepSeq (merge overrides) true)).success;

  lokiPackage = import ../../../packages/experimental/loki;
  pvcPackage = import ../../../packages/stable/persistent-volume-claim;

  # The `loki-alerts` rules of a Loki instance with `config`, beside the
  # prometheus stub unless `prometheus` is false.
  rulesOf =
    {
      config ? { },
      prometheus ? true,
    }:
    alertRulesOf "PrometheusRule" "loki" (
      manifests (mkCluster [
        {
          instances.logs = {
            storage = {
              package = pvcPackage;
              config = {
                size = "1Gi";
                storageClassName = "standard";
              };
            };
            standard-class = storageClassImport "standard";
            loki = {
              package = lokiPackage;
              inherit config;
            };
          };
        }
        (lib.optionalAttrs prometheus {
          instances.monitoring.prometheus.package = prometheusStub;
        })
      ])
    );
in
{
  # `{ a = null; }`, `{ a = 1; }` and `{ a.b = …; }` each replace the locked
  # `a.b` and throw; `{ a.c = 1; }` leaves it in place and merges.
  loki-mergeGuarded-null-ancestor =
    let
      sibling = merge { a.c = 1; };
    in
    (
      fails { a = null; }
      && fails { a = 1; }
      && fails { a.b = "other"; }
      &&
        sibling == {
          a = {
            b = "locked";
            c = 1;
          };
        }
    )
    || throw "mergeGuarded ancestors: a = null ${
      if fails { a = null; } then "throws" else "passes"
    }, a = 1 ${
      if fails { a = 1; } then "throws" else "passes"
    }, a.c = 1 gives ${builtins.toJSON sibling}";

  # The rules select on the Service and render only with a prometheus
  # dependency and metrics on. The two disk rules need the write-ahead log
  # on and `ingester.wal.disk_full_threshold` above 0, LokiRetentionStale
  # needs `compactor.retention_enabled`, and LokiMemoryNearLimit needs a
  # memory limit.
  loki-alerts =
    let
      on = rulesOf { };
      disk = [
        "LokiDiskNearlyFull"
        "LokiIngestionRefusedDiskFull"
      ];
      hasAll = names: rules: lib.all (n: rules ? ${n}) names;
      hasNone = names: rules: !lib.any (n: rules ? ${n}) names;
      noThreshold = rulesOf { config.settings.ingester.wal.disk_full_threshold = 0; };
      noWal = rulesOf { config.settings.ingester.wal.enabled = false; };
      noRetention = rulesOf { config.settings.compactor.retention_enabled = false; };
      noLimit = rulesOf { config.resources.limits.memory = null; };
    in
    (
      allSelect ''namespace="logs",service="loki"'' on
      && on ? LokiDown
      && hasAll disk on
      && on ? LokiRetentionStale
      && on ? LokiMemoryNearLimit
      && noThreshold ? LokiDown
      && hasNone disk noThreshold
      && hasNone disk noWal
      && hasAll disk noRetention
      && !(noRetention ? LokiRetentionStale)
      && !(noLimit ? LokiMemoryNearLimit)
      && rulesOf { prometheus = false; } == null
      && rulesOf { config.metrics.enabled = false; } == null
    )
    || throw "loki alerts: ${builtins.toJSON (builtins.attrNames on)}";
}
