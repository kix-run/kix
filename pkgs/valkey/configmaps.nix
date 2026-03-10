# Valkey ConfigMap resources.
#
# Three ConfigMaps:
#   configuration — valkey.conf, primary.conf, replica.conf, sentinel.conf
#   health        — liveness/readiness probe scripts (static, no Nix interpolation)
#   scripts       — start/lifecycle scripts with @PLACEHOLDER@ substitution

{
  cfg,
  helpers,
  ...
}:

let
  inherit (helpers)
    fullname
    headlessSvcFqdn
    kixlib'
    readScript
    renderDisableCommands
    ;
in
{
  # --- Configuration ConfigMap ---
  configuration =
    kixlib'.configMap.mkConfigMap {
      metadata.name = "${fullname}-configuration";
    }
    |> kixlib'.configMap.withEntry "valkey.conf" ''
      # User-supplied common configuration:
      ${cfg.commonConfiguration}
      # End of common configuration''
    |> kixlib'.configMap.withEntry "primary.conf" ''
      dir /data
      # User-supplied primary configuration:
      ${cfg.primary.configuration}${renderDisableCommands cfg.primary.disableCommands}
      # End of primary configuration''
    |> kixlib'.configMap.withEntry "replica.conf" ''
      dir /data
      # User-supplied replica configuration:
      ${cfg.replica.configuration}${renderDisableCommands cfg.replica.disableCommands}
      # End of replica configuration''
    |> (
      cm:
      if cfg.sentinel.enabled then
        kixlib'.configMap.withEntry "sentinel.conf" ''
          dir "/tmp"
          port 26379
          sentinel monitor ${cfg.sentinel.primarySet} ${fullname}-node-0.${headlessSvcFqdn} 6379 ${toString cfg.sentinel.quorum}
          sentinel down-after-milliseconds ${cfg.sentinel.primarySet} ${toString cfg.sentinel.downAfterMilliseconds}
          sentinel failover-timeout ${cfg.sentinel.primarySet} ${toString cfg.sentinel.failoverTimeout}
          sentinel parallel-syncs ${cfg.sentinel.primarySet} ${toString cfg.sentinel.parallelSyncs}
          # User-supplied sentinel configuration:
          ${cfg.sentinel.configuration}
          # End of sentinel configuration'' cm
      else
        cm
    );

  # --- Health scripts ConfigMap ---
  # Static bash scripts for probes. Use only env vars — no Nix interpolation needed.
  health =
    kixlib'.configMap.mkConfigMap {
      metadata.name = "${fullname}-health";
    }
    |> kixlib'.configMap.withEntry "ping_readiness_local.sh" (
      builtins.readFile ./scripts/ping_readiness_local.sh
    )
    |> kixlib'.configMap.withEntry "ping_liveness_local.sh" (
      builtins.readFile ./scripts/ping_liveness_local.sh
    )
    |> kixlib'.configMap.withEntry "ping_readiness_primary.sh" (
      builtins.readFile ./scripts/ping_readiness_primary.sh
    )
    |> kixlib'.configMap.withEntry "ping_liveness_primary.sh" (
      builtins.readFile ./scripts/ping_liveness_primary.sh
    )
    |> kixlib'.configMap.withEntry "ping_readiness_local_and_primary.sh" (
      builtins.readFile ./scripts/ping_readiness_local_and_primary.sh
    )
    |> kixlib'.configMap.withEntry "ping_liveness_local_and_primary.sh" (
      builtins.readFile ./scripts/ping_liveness_local_and_primary.sh
    )
    |> (
      cm:
      if cfg.sentinel.enabled then
        kixlib'.configMap.withEntry "ping_sentinel.sh" (builtins.readFile ./scripts/ping_sentinel.sh) cm
        |> kixlib'.configMap.withEntry "parse_sentinels.awk" (readScript "parse_sentinels.awk")
      else
        cm
    );

  # --- Start/lifecycle scripts ConfigMap ---
  # Scripts with @PLACEHOLDER@ tokens substituted via readScript.
  scripts =
    kixlib'.configMap.mkConfigMap {
      metadata.name = "${fullname}-scripts";
    }
    |> (
      cm:
      if cfg.sentinel.enabled then
        cm
        |> kixlib'.configMap.withEntry "start-node.sh" (readScript "start-node.sh")
        |> kixlib'.configMap.withEntry "start-sentinel.sh" (readScript "start-sentinel.sh")
        |> kixlib'.configMap.withEntry "prestop-sentinel.sh" (readScript "prestop-sentinel.sh")
        |> kixlib'.configMap.withEntry "prestop-valkey.sh" (readScript "prestop-valkey.sh")
      else
        cm
        |> kixlib'.configMap.withEntry "start-primary.sh" (builtins.readFile ./scripts/start-primary.sh)
        |> kixlib'.configMap.withEntry "start-replica.sh" (readScript "start-replica.sh")
    );
}
