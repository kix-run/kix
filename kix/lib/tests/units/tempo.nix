# Tests for kix/packages/tempo: its root.out honours the OTLP endpoint
# contract, `retention` reaches the rendered config, and the settings
# locks, owned flags, and zero retention are refused. Tempo runs in
# namespace `tracing` on a persistent-volume-claim.

{
  lib,
  mkCluster,
  manifests,
  ofKind,
  byName,
  evalFails,
  storageClassImport,
  ...
}:

let
  tempoPackage = import ../../../packages/tempo;
  pvcPackage = import ../../../packages/persistent-volume-claim;

  tempoCluster =
    config:
    mkCluster [
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
    ];

  tempoConfigOf =
    cluster:
    builtins.fromJSON (byName "tempo-config" (ofKind "ConfigMap" (manifests cluster))).data."tempo.yaml";

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
    && cfg.storage.trace.backend == "local";

  # Each refusal beside the positive control above: a locked settings path,
  # an ancestor of one, an owned flag in both spellings, and a zero
  # retention, which Tempo would read as its 14-day default.
  tempo-refuses-owned-paths =
    !evalFails (tempoCluster { })
    && evalFails (tempoCluster { settings.overrides.defaults.compaction.block_retention = "1h"; })
    && evalFails (tempoCluster { settings.storage.trace = null; })
    && evalFails (tempoCluster { settings.multitenancy_enabled = true; })
    && evalFails (tempoCluster { extraArgs = [ "-target=distributor" ]; })
    && evalFails (tempoCluster { extraArgs = [ "--storage.trace.backend=s3" ]; })
    && evalFails (tempoCluster { retention = "0s"; })
    && !evalFails (tempoCluster { extraArgs = [ "-log.level=debug" ]; });
}
