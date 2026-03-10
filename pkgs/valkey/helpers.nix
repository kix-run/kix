# Valkey package-specific helpers.
#
# Contains: naming, labels, kixlib setup, volume definitions, env vars,
# script templating, pod spec helpers, monitoring guards.
#
# Source Helm chart: oci://registry-1.docker.io/bitnamicharts/valkey (v3.0.2)

{
  lib,
  config,
  kixlib,
  cfg,
  ...
}:

let
  # --- Naming helpers ---
  # Helm uses "release-name-valkey" as the base name. We just use "valkey".
  fullname = "valkey";
  headlessSvcName = "${fullname}-headless";

  # FQDN helper — delegates to kixlib.mkFqdn for the shared implementation.
  fqdn =
    name:
    kixlib.mkFqdn {
      inherit name;
      namespace = cfg.namespace;
      clusterDomain = cfg.clusterDomain;
    };

  headlessSvcFqdn = fqdn headlessSvcName;
  sentinelSvcFqdn = fqdn fullname;
  totalReplicas = cfg.replica.replicaCount;

  # --- Labels ---
  # Using kixlib.mkLabels for the standard label hierarchy.
  # Stable selector labels — NEVER include version here (breaks rolling updates).
  labels = kixlib.mkLabels {
    chart = "valkey";
    clusterLabels = config.cluster.labels;
    extra = {
      "app.kubernetes.io/part-of" = "valkey";
    };
  };

  # --- kixlib setup ---
  kixlib' = kixlib.withMetadata {
    namespace = cfg.namespace;
    labels = labels.all;
    name = fullname;
  };

  # --- Secret volume ---
  secretName = if cfg.auth.existingSecret != "" then cfg.auth.existingSecret else fullname;

  passwordVolume = {
    name = "valkey-password";
    secret = {
      secretName = secretName;
      items = [
        {
          key = cfg.auth.existingSecretPasswordKey;
          path = "valkey-password";
        }
      ];
    };
  };

  passwordVolumeMount = {
    name = "valkey-password";
    mountPath = "/opt/bitnami/valkey/secrets/";
  };

  # --- Common volume specs ---
  startScriptsVolume = {
    name = "start-scripts";
    configMap = {
      name = "${fullname}-scripts";
      defaultMode = 493; # 0755 in decimal
    };
  };

  healthVolume = {
    name = "health";
    configMap = {
      name = "${fullname}-health";
      defaultMode = 493;
    };
  };

  configVolume = {
    name = "config";
    configMap = {
      name = "${fullname}-configuration";
    };
  };

  emptyDirVolume = {
    name = "empty-dir";
    emptyDir = { };
  };

  # Common volume mounts shared across valkey containers
  commonVolumeMounts = [
    {
      name = "start-scripts";
      mountPath = "/opt/bitnami/scripts/start-scripts";
    }
    {
      name = "health";
      mountPath = "/health";
    }
    passwordVolumeMount
    {
      name = "valkey-data";
      mountPath = "/data";
    }
    {
      name = "config";
      mountPath = "/opt/bitnami/valkey/mounted-etc";
    }
    {
      name = "empty-dir";
      mountPath = "/opt/bitnami/valkey/etc";
      subPath = "app-conf-dir";
    }
    {
      name = "empty-dir";
      mountPath = "/tmp";
      subPath = "tmp-dir";
    }
  ];

  # Sentinel volume mounts — shares start-scripts, health, password, and data
  # volumes with valkey containers, but mounts config to the sentinel-specific
  # path and omits the valkey config + app-conf-dir mounts.
  sentinelVolumeMounts =
    builtins.filter (
      m: m.name != "config" && !(m.name == "empty-dir" && m ? subPath && m.subPath == "app-conf-dir")
    ) commonVolumeMounts
    ++ [
      {
        name = "sentinel-data";
        mountPath = "/opt/bitnami/valkey-sentinel/etc";
      }
      {
        name = "config";
        mountPath = "/opt/bitnami/valkey-sentinel/mounted-etc";
      }
    ];

  # VolumeClaimTemplate for persistent data.
  mkDataVolumeClaimTemplate =
    componentLabels:
    lib.optionals cfg.persistence.enabled [
      {
        apiVersion = "v1";
        kind = "PersistentVolumeClaim";
        metadata = {
          name = "valkey-data";
          labels = componentLabels;
        };
        spec = {
          accessModes = cfg.persistence.accessModes;
          resources.requests.storage = cfg.persistence.size;
        }
        // lib.optionalAttrs (cfg.persistence.storageClass != null) {
          storageClassName = cfg.persistence.storageClass;
        };
      }
    ];

  # --- Pod helpers ---

  # Pod anti-affinity (prefer spreading across nodes)
  mkAntiAffinity = componentLabels: {
    podAntiAffinity.preferredDuringSchedulingIgnoredDuringExecution = [
      {
        podAffinityTerm = {
          labelSelector.matchLabels = componentLabels;
          topologyKey = "kubernetes.io/hostname";
        };
        weight = 1;
      }
    ];
  };

  # Pod spec helper — the 3 StatefulSet pod template specs share 7 identical fields.
  mkPodSpec =
    {
      serviceAccountName,
      componentLabels,
      containers,
      volumes,
      annotations ? { },
    }:
    {
      automountServiceAccountToken = false;
      securityContext = cfg.podSecurityContext;
      affinity = mkAntiAffinity componentLabels;
      enableServiceLinks = true;
      terminationGracePeriodSeconds = 30;
      inherit serviceAccountName containers volumes;
    };

  # --- Shared environment variables ---
  sharedEnv = [
    {
      name = "BITNAMI_DEBUG";
      value = "false";
    }
    {
      name = "VALKEY_PASSWORD_FILE";
      value = "/opt/bitnami/valkey/secrets/valkey-password";
    }
  ];

  valkeyServerEnv = sharedEnv ++ [
    {
      name = "ALLOW_EMPTY_PASSWORD";
      value = "no";
    }
    {
      name = "VALKEY_TLS_ENABLED";
      value = "no";
    }
    {
      name = "VALKEY_PORT";
      value = "6379";
    }
  ];

  # --- Script templating ---
  # Scripts with @PLACEHOLDER@ tokens are substituted at eval time.
  # This avoids escaping hell of embedding bash ${VAR} in Nix multiline strings.
  readScript =
    file:
    builtins.readFile ./scripts/${file}
    |>
      builtins.replaceStrings
        [
          "@HEADLESS_SERVICE_FQDN@"
          "@SENTINEL_SERVICE_FQDN@"
          "@FULLNAME@"
          "@PRIMARY_SET@"
          "@REPLICA_COUNT@"
          "@SENTINEL_QUORUM@"
        ]
        [
          headlessSvcFqdn
          sentinelSvcFqdn
          fullname
          cfg.sentinel.primarySet
          (toString totalReplicas)
          (toString cfg.sentinel.quorum)
        ];

  renderDisableCommands = cmds: lib.concatMapStringsSep "\n" (cmd: ''rename-command ${cmd} ""'') cmds;

  # --- Monitoring guards ---
  # Guard MUST match the mkIf on capabilities.monitoring.valkey declaration in
  # resources.nix. Doc 12 rule #10.
  monitoringGuard = cfg.metrics.enabled && cfg.metrics.serviceMonitor.enabled;

  valkeyMonitoringLabels =
    if monitoringGuard then config.capabilities.monitoring.valkey.output.labels else { };
  valkeyMonitoringAnnotations =
    if monitoringGuard then config.capabilities.monitoring.valkey.output.annotations else { };

  # The primary host is the first pod of the primary StatefulSet via the headless service.
  primaryHostFqdn = "${fullname}-primary-0.${headlessSvcFqdn}";

in
{
  inherit
    fullname
    headlessSvcName
    fqdn
    headlessSvcFqdn
    sentinelSvcFqdn
    totalReplicas
    labels
    kixlib'
    passwordVolume
    startScriptsVolume
    healthVolume
    configVolume
    emptyDirVolume
    commonVolumeMounts
    sentinelVolumeMounts
    mkDataVolumeClaimTemplate
    mkAntiAffinity
    mkPodSpec
    sharedEnv
    valkeyServerEnv
    readScript
    renderDisableCommands
    monitoringGuard
    valkeyMonitoringLabels
    valkeyMonitoringAnnotations
    primaryHostFqdn
    ;
}
