# Valkey kix module — migrated from the Bitnami valkey Helm chart (v3.0.2, appVersion 8.1.1)
#
# Source Helm chart: oci://registry-1.docker.io/bitnamicharts/valkey
# Chart stored at: /tmp/valkey/ (fetched during migration, not committed)
#
# This module produces Kubernetes resources for Valkey in two modes:
#
# 1. REPLICATION MODE (default, sentinel.enabled = false):
#    - Primary StatefulSet (1 replica)
#    - Replica StatefulSet (N replicas)
#    - Primary Service, Replica Service, Headless Service
#    - 2 ServiceAccounts (primary, replica)
#    - 3 ConfigMaps (configuration, health scripts, start scripts)
#
# 2. SENTINEL MODE (sentinel.enabled = true):
#    - Single "node" StatefulSet with 3 containers (valkey, sentinel, metrics)
#    - Sentinel Service, Headless Service
#    - 1 ServiceAccount (shared)
#    - 3 ConfigMaps (configuration, health scripts, start scripts)
#
# Optional resources (behind enable flags, both modes):
#    - PodDisruptionBudget
#    - NetworkPolicy
#    - Metrics Service + ServiceMonitor (requires metrics.enabled)
#
# Key design decisions:
#   - Scripts are stored as separate .sh files in scripts/ for editor support,
#     shellcheck compatibility, and to avoid Nix ''${...} escaping hell.
#     Scripts needing Nix values use @PLACEHOLDER@ tokens substituted at eval time
#     via builtins.replaceStrings (standard nixpkgs pattern).
#   - Auth secrets are ALWAYS external (auth.existingSecret). This module never
#     generates secrets — that's handled by the deployer (Ansible, etc.).
#   - Default values match upstream Helm chart defaults for parity testing.

{
  lib,
  pkgs,
  config,
  kixlib,
  ...
}:

let
  types = lib.types;
  cfg = config.services.valkey;

  # --- Reusable option submodules ---

  imageSubmodule = { repository, tag, pullPolicy ? "IfNotPresent" }: types.submodule {
    options = {
      repository = lib.mkOption { type = types.str; default = repository; };
      tag = lib.mkOption { type = types.str; default = tag; };
      pullPolicy = lib.mkOption { type = types.str; default = pullPolicy; };
    };
  };

  resourcesSubmodule = { defaultRequests ? {}, defaultLimits ? {} }: types.submodule {
    options = {
      requests = lib.mkOption { type = types.attrsOf types.str; default = defaultRequests; };
      limits = lib.mkOption { type = types.attrsOf types.str; default = defaultLimits; };
    };
  };

  # --- Options ---

  options.services.valkey = {
    enable = lib.mkOption {
      type = types.bool;
      default = false;
      description = "Enable Valkey service.";
    };

    namespace = lib.mkOption {
      type = types.str;
      default = "default";
      description = "Kubernetes namespace for all Valkey resources.";
    };

    clusterDomain = lib.mkOption {
      type = types.str;
      default = "cluster.local";
      description = "Kubernetes cluster domain for DNS resolution in scripts.";
    };

    # --- Images ---

    image = lib.mkOption {
      type = imageSubmodule {
        repository = "docker.io/bitnami/valkey";
        tag = "8.1.1-debian-12-r0";
      };
      default = {};
      description = "Valkey container image.";
    };

    # --- Auth ---
    # Valkey auth is always via an existing secret. We never generate secrets.

    auth = lib.mkOption {
      type = types.submodule {
        options = {
          enabled = lib.mkOption { type = types.bool; default = true; };
          existingSecret = lib.mkOption {
            type = types.str;
            default = "";
            description = "Name of existing secret containing valkey-password key. If empty, Helm would auto-generate (we don't support that).";
          };
          existingSecretPasswordKey = lib.mkOption {
            type = types.str;
            default = "valkey-password";
          };
          sentinel = lib.mkOption {
            type = types.bool;
            default = true;
            description = "Whether sentinel uses auth too.";
          };
        };
      };
      default = {};
    };

    # --- Configuration ---

    commonConfiguration = lib.mkOption {
      type = types.str;
      default = ''
        # Enable AOF https://valkey.io/docs/topics/persistence.html
        appendonly yes
        # Disable RDB persistence, AOF persistence already enabled.
        save ""'';
      description = "Common valkey.conf content applied to all nodes.";
    };

    primary = lib.mkOption {
      type = types.submodule {
        options = {
          configuration = lib.mkOption { type = types.str; default = ""; };
          disableCommands = lib.mkOption {
            type = types.listOf types.str;
            default = [ "FLUSHDB" "FLUSHALL" ];
          };
          resources = lib.mkOption {
            type = resourcesSubmodule {
              defaultRequests = { cpu = "100m"; memory = "128Mi"; ephemeral-storage = "50Mi"; };
              defaultLimits = { cpu = "150m"; memory = "192Mi"; ephemeral-storage = "2Gi"; };
            };
            default = {};
          };
        };
      };
      default = {};
    };

    replica = lib.mkOption {
      type = types.submodule {
        options = {
          replicaCount = lib.mkOption { type = types.int; default = 3; };
          configuration = lib.mkOption { type = types.str; default = ""; };
          disableCommands = lib.mkOption {
            type = types.listOf types.str;
            default = [ "FLUSHDB" "FLUSHALL" ];
          };
          resources = lib.mkOption {
            type = resourcesSubmodule {
              defaultRequests = { cpu = "100m"; memory = "128Mi"; ephemeral-storage = "50Mi"; };
              defaultLimits = { cpu = "150m"; memory = "192Mi"; ephemeral-storage = "2Gi"; };
            };
            default = {};
          };
        };
      };
      default = {};
    };

    # --- Sentinel ---

    sentinel = lib.mkOption {
      type = types.submodule {
        options = {
          enabled = lib.mkOption {
            type = types.bool;
            default = false;
            description = "Enable Sentinel for HA. Changes architecture from separate primary/replica to single node StatefulSet.";
          };
          quorum = lib.mkOption { type = types.int; default = 2; };
          primarySet = lib.mkOption { type = types.str; default = "myprimary"; };
          downAfterMilliseconds = lib.mkOption { type = types.int; default = 30000; };
          failoverTimeout = lib.mkOption { type = types.int; default = 180000; };
          parallelSyncs = lib.mkOption { type = types.int; default = 1; };
          configuration = lib.mkOption {
            type = types.str;
            default = "";
            description = "Extra sentinel.conf content.";
          };
          image = lib.mkOption {
            type = imageSubmodule {
              repository = "docker.io/bitnami/valkey-sentinel";
              tag = "8.1.1-debian-12-r0";
            };
            default = {};
          };
          resources = lib.mkOption {
            type = resourcesSubmodule {
              defaultRequests = { cpu = "100m"; memory = "128Mi"; ephemeral-storage = "50Mi"; };
              defaultLimits = { cpu = "150m"; memory = "192Mi"; ephemeral-storage = "2Gi"; };
            };
            default = {};
          };
        };
      };
      default = {};
    };

    # --- Persistence ---

    persistence = lib.mkOption {
      type = types.submodule {
        options = {
          enabled = lib.mkOption { type = types.bool; default = true; };
          size = lib.mkOption { type = types.str; default = "8Gi"; };
          storageClass = lib.mkOption { type = types.nullOr types.str; default = null; };
          accessModes = lib.mkOption { type = types.listOf types.str; default = [ "ReadWriteOnce" ]; };
        };
      };
      default = {};
    };

    # --- Security contexts ---

    podSecurityContext = lib.mkOption {
      type = types.attrsOf types.anything;
      default = {
        fsGroup = 1001;
        fsGroupChangePolicy = "Always";
      };
    };

    containerSecurityContext = lib.mkOption {
      type = types.attrsOf types.anything;
      default = {
        allowPrivilegeEscalation = false;
        capabilities.drop = [ "ALL" ];
        readOnlyRootFilesystem = true;
        runAsGroup = 1001;
        runAsNonRoot = true;
        runAsUser = 1001;
        seccompProfile.type = "RuntimeDefault";
      };
    };

    # --- Optional features ---

    metrics = lib.mkOption {
      type = types.submodule {
        options = {
          enabled = lib.mkOption { type = types.bool; default = false; };
          image = lib.mkOption {
            type = imageSubmodule {
              repository = "docker.io/bitnami/redis-exporter";
              tag = "1.70.0-debian-12-r2";
            };
            default = {};
          };
          resources = lib.mkOption {
            type = resourcesSubmodule {
              defaultRequests = { cpu = "100m"; memory = "128Mi"; ephemeral-storage = "50Mi"; };
              defaultLimits = { cpu = "150m"; memory = "192Mi"; ephemeral-storage = "2Gi"; };
            };
            default = {};
          };
          serviceMonitor = lib.mkOption {
            type = types.submodule {
              options = {
                enabled = lib.mkOption { type = types.bool; default = false; };
                namespace = lib.mkOption { type = types.nullOr types.str; default = null; };
                interval = lib.mkOption { type = types.str; default = "30s"; };
              };
            };
            default = {};
          };
        };
      };
      default = {};
    };

    networkPolicy = lib.mkOption {
      type = types.submodule {
        options = {
          enabled = lib.mkOption { type = types.bool; default = false; };
        };
      };
      default = {};
    };

    pdb = lib.mkOption {
      type = types.submodule {
        options = {
          enabled = lib.mkOption { type = types.bool; default = false; };
          maxUnavailable = lib.mkOption { type = types.nullOr types.int; default = 1; };
          minAvailable = lib.mkOption { type = types.nullOr types.int; default = null; };
        };
      };
      default = {};
    };
  };

  # --- Naming helpers ---
  # Helm uses "release-name-valkey" as the base name. We just use "valkey".
  # These are used for resource names and DNS references in scripts.

  fullname = "valkey";
  headlessSvcName = "${fullname}-headless";
  headlessSvcFqdn = "${headlessSvcName}.${cfg.namespace}.svc.${cfg.clusterDomain}";

  # --- Labels ---
  # Stable selector labels — NEVER include version here.
  selectorLabels = {
    "app.kubernetes.io/instance" = "release-name";
    "app.kubernetes.io/name" = "valkey";
  };

  allLabels = selectorLabels // {
    "app.kubernetes.io/managed-by" = "kix";
    "app.kubernetes.io/part-of" = "valkey";
  };

  # Component-specific selector labels for non-sentinel mode
  primarySelectorLabels = selectorLabels // {
    "app.kubernetes.io/component" = "primary";
  };

  replicaSelectorLabels = selectorLabels // {
    "app.kubernetes.io/component" = "replica";
  };

  # Component-specific selector labels for sentinel mode
  nodeSelectorLabels = selectorLabels // {
    "app.kubernetes.io/component" = "node";
  };

  # --- kixlib setup ---
  kixlib' = kixlib.withMetadata {
    namespace = cfg.namespace;
    labels = allLabels;
    name = fullname;
  };

  # --- Secret volume ---
  # The password secret volume, used by all StatefulSets.
  # References either the auto-generated Helm secret name or an existing secret.
  secretName = if cfg.auth.existingSecret != "" then cfg.auth.existingSecret else fullname;

  passwordVolume = {
    name = "valkey-password";
    secret = {
      secretName = secretName;
      items = [{ key = cfg.auth.existingSecretPasswordKey; path = "valkey-password"; }];
    };
  };

  passwordVolumeMount = {
    name = "valkey-password";
    mountPath = "/opt/bitnami/valkey/secrets/";
  };

  # --- ConfigMap: configuration ---
  # Contains valkey.conf, primary.conf, replica.conf, and sentinel.conf (if enabled).

  renderDisableCommands = cmds:
    lib.concatStringsSep "\n" (map (cmd: ''rename-command ${cmd} ""'') cmds);

  configurationCM = kixlib'.configMap.mkConfigMap {
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
  |> (cm: if cfg.sentinel.enabled then
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
    else cm);

  # --- ConfigMap: health scripts ---
  # These are static bash scripts for liveness/readiness probes.
  # They use only environment variables — no Nix interpolation needed.
  # Stored as separate .sh files in scripts/ for editor support and shellcheck.

  healthCM = kixlib'.configMap.mkConfigMap {
    metadata.name = "${fullname}-health";
  }
  |> kixlib'.configMap.withEntry "ping_readiness_local.sh" (builtins.readFile ./scripts/ping_readiness_local.sh)
  |> kixlib'.configMap.withEntry "ping_liveness_local.sh" (builtins.readFile ./scripts/ping_liveness_local.sh)
  |> kixlib'.configMap.withEntry "ping_readiness_primary.sh" (builtins.readFile ./scripts/ping_readiness_primary.sh)
  |> kixlib'.configMap.withEntry "ping_liveness_primary.sh" (builtins.readFile ./scripts/ping_liveness_primary.sh)
  |> kixlib'.configMap.withEntry "ping_readiness_local_and_primary.sh" (builtins.readFile ./scripts/ping_readiness_local_and_primary.sh)
  |> kixlib'.configMap.withEntry "ping_liveness_local_and_primary.sh" (builtins.readFile ./scripts/ping_liveness_local_and_primary.sh)
  |> (cm: if cfg.sentinel.enabled then
    kixlib'.configMap.withEntry "ping_sentinel.sh" (builtins.readFile ./scripts/ping_sentinel.sh) cm
    |> kixlib'.configMap.withEntry "parse_sentinels.awk" (builtins.readFile ./scripts/parse_sentinels.awk)
    else cm);

  # --- ConfigMap: scripts ---
  # Start/lifecycle scripts contain Nix-interpolated service names, namespaces, and
  # replica counts. They are stored as separate .sh files in scripts/ with @PLACEHOLDER@
  # tokens, substituted at eval time via builtins.replaceStrings. This avoids the
  # escaping hell of embedding bash ${VAR} in Nix multiline strings (''${...}).
  # See SKILL.md "Shell Scripts in ConfigMaps" for the rationale.

  sentinelSvcFqdn = "${fullname}.${cfg.namespace}.svc.${cfg.clusterDomain}";
  totalReplicas = cfg.replica.replicaCount;

  # Read a script file and substitute @PLACEHOLDER@ tokens with Nix values.
  # Scripts that use only env vars (health checks) don't need this — use builtins.readFile directly.
  readScript = file: builtins.readFile ./scripts/${file}
    |> builtins.replaceStrings
      [ "@HEADLESS_SERVICE_FQDN@" "@SENTINEL_SERVICE_FQDN@" "@FULLNAME@"
        "@PRIMARY_SET@" "@REPLICA_COUNT@" "@SENTINEL_QUORUM@" ]
      [ headlessSvcFqdn sentinelSvcFqdn fullname
        cfg.sentinel.primarySet (toString totalReplicas) (toString cfg.sentinel.quorum) ];

  scriptsCM = kixlib'.configMap.mkConfigMap {
    metadata.name = "${fullname}-scripts";
  }
  |> (cm: if cfg.sentinel.enabled then
    # --- Sentinel mode scripts ---
    cm
    |> kixlib'.configMap.withEntry "start-node.sh" (readScript "start-node.sh")
    |> kixlib'.configMap.withEntry "start-sentinel.sh" (readScript "start-sentinel.sh")
    |> kixlib'.configMap.withEntry "prestop-sentinel.sh" (readScript "prestop-sentinel.sh")
    |> kixlib'.configMap.withEntry "prestop-valkey.sh" (readScript "prestop-valkey.sh")
  else
    # --- Non-sentinel (replication) mode scripts ---
    cm
    # start-primary.sh has no @PLACEHOLDER@ tokens — bare readFile is sufficient
    |> kixlib'.configMap.withEntry "start-primary.sh" (builtins.readFile ./scripts/start-primary.sh)
    |> kixlib'.configMap.withEntry "start-replica.sh" (readScript "start-replica.sh")
  );

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
    emptyDir = {};
  };

  # Common volume mounts shared across valkey containers
  commonVolumeMounts = [
    { name = "start-scripts"; mountPath = "/opt/bitnami/scripts/start-scripts"; }
    { name = "health"; mountPath = "/health"; }
    passwordVolumeMount
    { name = "valkey-data"; mountPath = "/data"; }
    { name = "config"; mountPath = "/opt/bitnami/valkey/mounted-etc"; }
    { name = "empty-dir"; mountPath = "/opt/bitnami/valkey/etc"; subPath = "app-conf-dir"; }
    { name = "empty-dir"; mountPath = "/tmp"; subPath = "tmp-dir"; }
  ];

  # VolumeClaimTemplate for persistent data.
  # Takes component labels so the PVC gets the right component label
  # (e.g., "node" for sentinel, "primary"/"replica" for replication mode).
  mkDataVolumeClaimTemplate = componentLabels: lib.optionals cfg.persistence.enabled [{
    apiVersion = "v1";
    kind = "PersistentVolumeClaim";
    metadata = {
      name = "valkey-data";
      labels = componentLabels;
    };
    spec = {
      accessModes = cfg.persistence.accessModes;
      resources.requests.storage = cfg.persistence.size;
    } // lib.optionalAttrs (cfg.persistence.storageClass != null) {
      storageClassName = cfg.persistence.storageClass;
    };
  }];

  # Pod anti-affinity (prefer spreading across nodes)
  mkAntiAffinity = componentLabels: {
    podAntiAffinity.preferredDuringSchedulingIgnoredDuringExecution = [{
      podAffinityTerm = {
        labelSelector.matchLabels = componentLabels;
        topologyKey = "kubernetes.io/hostname";
      };
      weight = 1;
    }];
  };

  # --- ServiceAccount ---
  # In sentinel mode: single shared SA named "valkey"
  # In non-sentinel mode: separate SAs per component ("valkey-primary", "valkey-replica")

  sa = kixlib'.rbac.mkServiceAccount {
    metadata.name = fullname;
  } // { automountServiceAccountToken = false; };

  primarySa = kixlib'.rbac.mkServiceAccount {
    metadata.name = "${fullname}-primary";
  } // { automountServiceAccountToken = false; };

  replicaSa = kixlib'.rbac.mkServiceAccount {
    metadata.name = "${fullname}-replica";
  } // { automountServiceAccountToken = false; };

  # --- Headless Service ---
  headlessSvc = kixlib'.networking.mkService {
    metadata.name = headlessSvcName;
    spec = {
      type = "ClusterIP";
      clusterIP = "None";
      publishNotReadyAddresses = cfg.sentinel.enabled;
      ports = [
        { name = "tcp-redis"; port = 6379; targetPort = "redis"; }
      ] ++ lib.optionals cfg.sentinel.enabled [
        { name = "tcp-sentinel"; port = 26379; targetPort = "valkey-sentinel"; }
      ];
      selector = selectorLabels;
    };
  };

  # ============================================================
  # SENTINEL MODE RESOURCES
  # ============================================================

  sentinelSvc = kixlib'.networking.mkService {
    metadata = {
      name = fullname;
      labels = allLabels // { "app.kubernetes.io/component" = "node"; };
    };
    spec = {
      type = "ClusterIP";
      sessionAffinity = "None";
      ports = [
        { name = "tcp-redis"; port = 6379; targetPort = 6379; }
        { name = "tcp-sentinel"; port = 26379; targetPort = 26379; }
      ];
      selector = nodeSelectorLabels;
    };
  };

  # Sentinel mode: single StatefulSet with valkey + sentinel + optional metrics containers
  sentinelValkeyContainer = kixlib'.pod.mkContainer {
    name = "valkey";
    image = "${cfg.image.repository}:${cfg.image.tag}";
    imagePullPolicy = cfg.image.pullPolicy;
    securityContext = cfg.containerSecurityContext;
    command = [ "/bin/bash" ];
    args = [ "-c" "/opt/bitnami/scripts/start-scripts/start-node.sh" ];
    lifecycle.preStop.exec.command = [
      "/bin/bash" "-c" "/opt/bitnami/scripts/start-scripts/prestop-valkey.sh"
    ];
    env = [
      { name = "BITNAMI_DEBUG"; value = "false"; }
      { name = "VALKEY_PRIMARY_PORT_NUMBER"; value = "6379"; }
      { name = "ALLOW_EMPTY_PASSWORD"; value = "no"; }
      { name = "VALKEY_PASSWORD_FILE"; value = "/opt/bitnami/valkey/secrets/valkey-password"; }
      { name = "VALKEY_PRIMARY_PASSWORD_FILE"; value = "/opt/bitnami/valkey/secrets/valkey-password"; }
      { name = "VALKEY_TLS_ENABLED"; value = "no"; }
      { name = "VALKEY_PORT"; value = "6379"; }
      { name = "VALKEY_SENTINEL_TLS_ENABLED"; value = "no"; }
      { name = "VALKEY_SENTINEL_PORT"; value = "26379"; }
      { name = "VALKEY_DATA_DIR"; value = "/data"; }
    ];
    ports = [{ name = "valkey"; containerPort = 6379; }];
    startupProbe = {
      failureThreshold = 22;
      initialDelaySeconds = 10;
      periodSeconds = 10;
      successThreshold = 1;
      timeoutSeconds = 5;
      exec.command = [ "sh" "-c" "/health/ping_liveness_local.sh 5" ];
    };
    livenessProbe = {
      initialDelaySeconds = 20;
      periodSeconds = 5;
      timeoutSeconds = 5;
      successThreshold = 1;
      failureThreshold = 5;
      exec.command = [ "sh" "-c" "/health/ping_liveness_local.sh 5" ];
    };
    readinessProbe = {
      initialDelaySeconds = 20;
      periodSeconds = 5;
      timeoutSeconds = 1;
      successThreshold = 1;
      failureThreshold = 5;
      exec.command = [ "sh" "-c" "/health/ping_readiness_local.sh 1" ];
    };
    resources = cfg.primary.resources;
    volumeMounts = commonVolumeMounts ++ [
      { name = "sentinel-data"; mountPath = "/opt/bitnami/valkey-sentinel/etc"; }
    ];
  };

  sentinelContainer = kixlib'.pod.mkContainer {
    name = "sentinel";
    image = "${cfg.sentinel.image.repository}:${cfg.sentinel.image.tag}";
    imagePullPolicy = cfg.sentinel.image.pullPolicy;
    securityContext = cfg.containerSecurityContext;
    command = [ "/bin/bash" ];
    args = [ "-c" "/opt/bitnami/scripts/start-scripts/start-sentinel.sh" ];
    lifecycle.preStop.exec.command = [
      "/bin/bash" "-c" "/opt/bitnami/scripts/start-scripts/prestop-sentinel.sh"
    ];
    env = [
      { name = "BITNAMI_DEBUG"; value = "false"; }
      { name = "VALKEY_PASSWORD_FILE"; value = "/opt/bitnami/valkey/secrets/valkey-password"; }
      { name = "VALKEY_SENTINEL_TLS_ENABLED"; value = "no"; }
      { name = "VALKEY_SENTINEL_PORT"; value = "26379"; }
    ];
    ports = [{ name = "valkey-sentinel"; containerPort = 26379; }];
    startupProbe = {
      failureThreshold = 22;
      initialDelaySeconds = 10;
      periodSeconds = 10;
      successThreshold = 1;
      timeoutSeconds = 5;
      exec.command = [ "sh" "-c" "/health/ping_sentinel.sh 5" ];
    };
    livenessProbe = {
      initialDelaySeconds = 20;
      periodSeconds = 10;
      timeoutSeconds = 5;
      successThreshold = 1;
      failureThreshold = 6;
      exec.command = [ "sh" "-c" "/health/ping_sentinel.sh 5" ];
    };
    readinessProbe = {
      initialDelaySeconds = 20;
      periodSeconds = 5;
      timeoutSeconds = 1;
      successThreshold = 1;
      failureThreshold = 6;
      exec.command = [ "sh" "-c" "/health/ping_sentinel.sh 1" ];
    };
    resources = cfg.sentinel.resources;
    volumeMounts = [
      { name = "empty-dir"; mountPath = "/tmp"; subPath = "tmp-dir"; }
      { name = "start-scripts"; mountPath = "/opt/bitnami/scripts/start-scripts"; }
      { name = "health"; mountPath = "/health"; }
      { name = "sentinel-data"; mountPath = "/opt/bitnami/valkey-sentinel/etc"; }
      passwordVolumeMount
      { name = "valkey-data"; mountPath = "/data"; }
      { name = "config"; mountPath = "/opt/bitnami/valkey-sentinel/mounted-etc"; }
    ];
  };

  metricsContainer = kixlib'.pod.mkContainer {
    name = "metrics";
    image = "${cfg.metrics.image.repository}:${cfg.metrics.image.tag}";
    imagePullPolicy = cfg.metrics.image.pullPolicy;
    securityContext = cfg.containerSecurityContext;
    command = [ "/bin/bash" "-c" ''
      export REDIS_PASSWORD="$(< $REDIS_PASSWORD_FILE)"
      redis_exporter'' ];
    env = [
      { name = "REDIS_ALIAS"; value = fullname; }
      { name = "REDIS_EXPORTER_WEB_LISTEN_ADDRESS"; value = ":9121"; }
      { name = "REDIS_USER"; value = "default"; }
      { name = "REDIS_PASSWORD_FILE"; value = "/secrets/valkey-password"; }
    ];
    ports = [{ name = "metrics"; containerPort = 9121; }];
    livenessProbe = {
      failureThreshold = 5;
      initialDelaySeconds = 10;
      periodSeconds = 10;
      successThreshold = 1;
      timeoutSeconds = 5;
      tcpSocket.port = "metrics";
    };
    readinessProbe = {
      failureThreshold = 3;
      initialDelaySeconds = 5;
      periodSeconds = 10;
      successThreshold = 1;
      timeoutSeconds = 1;
      httpGet = { path = "/"; port = "metrics"; };
    };
    resources = cfg.metrics.resources;
    volumeMounts = [
      { name = "empty-dir"; mountPath = "/tmp"; subPath = "tmp-dir"; }
      { name = "valkey-password"; mountPath = "/secrets/"; }
    ];
  };

  sentinelStatefulSet = kixlib'.workload.mkStatefulSet {
    metadata = {
      name = "${fullname}-node";
      labels = allLabels // { "app.kubernetes.io/component" = "node"; };
    };
    replicas = totalReplicas;
    serviceName = headlessSvcName;
    selectorLabels = nodeSelectorLabels;
    updateStrategy = { type = "RollingUpdate"; };
    template = kixlib'.pod.mkPodTemplate {
      metadata = {
        labels = nodeSelectorLabels;
        annotations = lib.optionalAttrs cfg.metrics.enabled {
          "prometheus.io/port" = "9121";
          "prometheus.io/scrape" = "true";
        };
      };
      spec = {
        automountServiceAccountToken = false;
        securityContext = cfg.podSecurityContext;
        serviceAccountName = fullname;
        affinity = mkAntiAffinity nodeSelectorLabels;
        enableServiceLinks = true;
        terminationGracePeriodSeconds = 30;
        containers = [ sentinelValkeyContainer sentinelContainer ]
          ++ lib.optionals cfg.metrics.enabled [ metricsContainer ];
        volumes = [
          startScriptsVolume
          healthVolume
          passwordVolume
          configVolume
          { name = "sentinel-data"; emptyDir = {}; }
          emptyDirVolume
        ];
      };
    };
    volumeClaimTemplates = mkDataVolumeClaimTemplate nodeSelectorLabels;
  };

  # ============================================================
  # NON-SENTINEL (REPLICATION) MODE RESOURCES
  # ============================================================

  # Primary StatefulSet (non-sentinel)
  primaryContainer = kixlib'.pod.mkContainer {
    name = "valkey";
    image = "${cfg.image.repository}:${cfg.image.tag}";
    imagePullPolicy = cfg.image.pullPolicy;
    securityContext = cfg.containerSecurityContext;
    command = [ "/bin/bash" ];
    args = [ "-c" "/opt/bitnami/scripts/start-scripts/start-primary.sh" ];
    env = [
      { name = "BITNAMI_DEBUG"; value = "false"; }
      { name = "VALKEY_REPLICATION_MODE"; value = "primary"; }
      { name = "ALLOW_EMPTY_PASSWORD"; value = "no"; }
      { name = "VALKEY_PASSWORD_FILE"; value = "/opt/bitnami/valkey/secrets/valkey-password"; }
      { name = "VALKEY_TLS_ENABLED"; value = "no"; }
      { name = "VALKEY_PORT"; value = "6379"; }
    ];
    ports = [{ name = "redis"; containerPort = 6379; }];
    livenessProbe = {
      initialDelaySeconds = 20;
      periodSeconds = 5;
      timeoutSeconds = 6;
      successThreshold = 1;
      failureThreshold = 5;
      exec.command = [ "sh" "-c" "/health/ping_liveness_local.sh 5" ];
    };
    readinessProbe = {
      initialDelaySeconds = 20;
      periodSeconds = 5;
      timeoutSeconds = 2;
      successThreshold = 1;
      failureThreshold = 5;
      exec.command = [ "sh" "-c" "/health/ping_readiness_local.sh 1" ];
    };
    resources = cfg.primary.resources;
    volumeMounts = commonVolumeMounts;
  };

  primaryStatefulSet = kixlib'.workload.mkStatefulSet {
    metadata = {
      name = "${fullname}-primary";
      labels = allLabels // { "app.kubernetes.io/component" = "primary"; };
    };
    replicas = 1;
    serviceName = headlessSvcName;
    selectorLabels = primarySelectorLabels;
    updateStrategy = { type = "RollingUpdate"; };
    template = kixlib'.pod.mkPodTemplate {
      metadata.labels = primarySelectorLabels;
      spec = {
        securityContext = cfg.podSecurityContext;
        serviceAccountName = "${fullname}-primary";
        automountServiceAccountToken = false;
        affinity = mkAntiAffinity primarySelectorLabels;
        enableServiceLinks = true;
        terminationGracePeriodSeconds = 30;
        containers = [ primaryContainer ];
        volumes = [
          startScriptsVolume
          healthVolume
          passwordVolume
          configVolume
          emptyDirVolume
        ];
      };
    };
    volumeClaimTemplates = mkDataVolumeClaimTemplate primarySelectorLabels;
  };

  # Primary service (non-sentinel)
  primarySvc = kixlib'.networking.mkService {
    metadata = {
      name = "${fullname}-primary";
      labels = allLabels // { "app.kubernetes.io/component" = "primary"; };
    };
    spec = {
      type = "ClusterIP";
      internalTrafficPolicy = "Cluster";
      sessionAffinity = "None";
      ports = [{ name = "tcp-redis"; port = 6379; targetPort = "redis"; }];
      selector = primarySelectorLabels;
    };
  };

  # Replica StatefulSet (non-sentinel)
  # The primary host is the first pod of the primary StatefulSet via the headless service.
  primaryHostFqdn = "${fullname}-primary-0.${headlessSvcFqdn}";

  replicaContainer = kixlib'.pod.mkContainer {
    name = "valkey";
    image = "${cfg.image.repository}:${cfg.image.tag}";
    imagePullPolicy = cfg.image.pullPolicy;
    securityContext = cfg.containerSecurityContext;
    command = [ "/bin/bash" ];
    args = [ "-c" "/opt/bitnami/scripts/start-scripts/start-replica.sh" ];
    env = [
      { name = "BITNAMI_DEBUG"; value = "false"; }
      { name = "VALKEY_REPLICATION_MODE"; value = "replica"; }
      { name = "VALKEY_PRIMARY_HOST"; value = primaryHostFqdn; }
      { name = "VALKEY_PRIMARY_PORT_NUMBER"; value = "6379"; }
      { name = "ALLOW_EMPTY_PASSWORD"; value = "no"; }
      { name = "VALKEY_PASSWORD_FILE"; value = "/opt/bitnami/valkey/secrets/valkey-password"; }
      { name = "VALKEY_PRIMARY_PASSWORD_FILE"; value = "/opt/bitnami/valkey/secrets/valkey-password"; }
      { name = "VALKEY_TLS_ENABLED"; value = "no"; }
      { name = "VALKEY_PORT"; value = "6379"; }
    ];
    ports = [{ name = "redis"; containerPort = 6379; }];
    startupProbe = {
      failureThreshold = 22;
      initialDelaySeconds = 10;
      periodSeconds = 10;
      successThreshold = 1;
      timeoutSeconds = 5;
      tcpSocket.port = "redis";
    };
    livenessProbe = {
      initialDelaySeconds = 20;
      periodSeconds = 5;
      timeoutSeconds = 6;
      successThreshold = 1;
      failureThreshold = 5;
      exec.command = [ "sh" "-c" "/health/ping_liveness_local_and_primary.sh 5" ];
    };
    readinessProbe = {
      initialDelaySeconds = 20;
      periodSeconds = 5;
      timeoutSeconds = 2;
      successThreshold = 1;
      failureThreshold = 5;
      exec.command = [ "sh" "-c" "/health/ping_readiness_local_and_primary.sh 1" ];
    };
    resources = cfg.replica.resources;
    volumeMounts = commonVolumeMounts;
  };

  replicaStatefulSet = kixlib'.workload.mkStatefulSet {
    metadata = {
      name = "${fullname}-replicas";
      labels = allLabels // { "app.kubernetes.io/component" = "replica"; };
    };
    replicas = cfg.replica.replicaCount;
    serviceName = headlessSvcName;
    selectorLabels = replicaSelectorLabels;
    updateStrategy = { type = "RollingUpdate"; };
    template = kixlib'.pod.mkPodTemplate {
      metadata.labels = replicaSelectorLabels;
      spec = {
        securityContext = cfg.podSecurityContext;
        serviceAccountName = "${fullname}-replica";
        automountServiceAccountToken = false;
        affinity = mkAntiAffinity replicaSelectorLabels;
        enableServiceLinks = true;
        terminationGracePeriodSeconds = 30;
        containers = [ replicaContainer ];
        volumes = [
          startScriptsVolume
          healthVolume
          passwordVolume
          configVolume
          emptyDirVolume
        ];
      };
    };
    volumeClaimTemplates = mkDataVolumeClaimTemplate replicaSelectorLabels;
  };

  # Replica service (non-sentinel)
  replicaSvc = kixlib'.networking.mkService {
    metadata = {
      name = "${fullname}-replicas";
      labels = allLabels // { "app.kubernetes.io/component" = "replica"; };
    };
    spec = {
      type = "ClusterIP";
      internalTrafficPolicy = "Cluster";
      sessionAffinity = "None";
      ports = [{ name = "tcp-redis"; port = 6379; targetPort = "redis"; }];
      selector = replicaSelectorLabels;
    };
  };

  # Replica PDB (non-sentinel default mode creates a PDB for replicas)
  replicaPdb = kixlib'.policy.mkPodDisruptionBudget {
    metadata = {
      name = "${fullname}-replicas";
      labels = allLabels // { "app.kubernetes.io/component" = "replica"; };
    };
    selector.matchLabels = replicaSelectorLabels;
    maxUnavailable = cfg.pdb.maxUnavailable;
    minAvailable = cfg.pdb.minAvailable;
  };

  # ============================================================
  # SHARED OPTIONAL RESOURCES (both modes)
  # ============================================================

  # Metrics service
  metricsSvc = kixlib'.networking.mkService {
    metadata = {
      name = "${fullname}-metrics";
      labels = allLabels // { "app.kubernetes.io/component" = "metrics"; };
    };
    spec = {
      type = "ClusterIP";
      ports = [{ name = "http-metrics"; port = 9121; protocol = "TCP"; targetPort = "metrics"; }];
      selector = selectorLabels;
    };
  };

  # Network policy
  networkPolicy = kixlib'.networking.mkNetworkPolicy {
    metadata.name = fullname;
    podSelector.matchLabels = selectorLabels;
    policyTypes = [ "Ingress" "Egress" ];
    egress = [{}]; # Allow all egress
    ingress = [
      { ports = [{ port = 6379; }] ++ lib.optionals cfg.sentinel.enabled [{ port = 26379; }]; }
    ] ++ lib.optionals cfg.metrics.enabled [
      { ports = [{ port = 9121; }]; }
    ];
  };

  # PDB for sentinel mode
  sentinelPdb = kixlib'.policy.mkPodDisruptionBudget {
    metadata = {
      name = "${fullname}-node";
      labels = allLabels // { "app.kubernetes.io/component" = "node"; };
    };
    selector.matchLabels = nodeSelectorLabels;
    maxUnavailable = cfg.pdb.maxUnavailable;
    minAvailable = cfg.pdb.minAvailable;
  };

  # ServiceMonitor
  serviceMonitor = kixlib'.monitoring.mkServiceMonitor {
    metadata = {
      name = fullname;
    } // lib.optionalAttrs (cfg.metrics.serviceMonitor.namespace != null) {
      namespace = cfg.metrics.serviceMonitor.namespace;
    };
    endpoints = [{ port = "http-metrics"; interval = cfg.metrics.serviceMonitor.interval; }];
    namespaceSelector.matchNames = [ cfg.namespace ];
    selector.matchLabels = selectorLabels // { "app.kubernetes.io/component" = "metrics"; };
  };

in
{
  inherit options;

  config = {
    manifests = lib.optionalAttrs cfg.enable (
      # --- Resources common to both modes ---
      {
        "valkey-configuration" = kixlib'.mkManifest configurationCM;
        "valkey-health" = kixlib'.mkManifest healthCM;
        "valkey-scripts" = kixlib'.mkManifest scriptsCM;
        "valkey-headless" = kixlib'.mkManifest headlessSvc;
      }
      # --- Mode-specific resources ---
      // (if cfg.sentinel.enabled then {
        # Sentinel mode
        "valkey-serviceaccount" = kixlib'.mkManifest sa;
        "valkey-service" = kixlib'.mkManifest sentinelSvc;
        "valkey-node" = kixlib'.mkManifest sentinelStatefulSet;
      } else {
        # Replication mode (non-sentinel)
        "valkey-primary-serviceaccount" = kixlib'.mkManifest primarySa;
        "valkey-replica-serviceaccount" = kixlib'.mkManifest replicaSa;
        "valkey-primary-service" = kixlib'.mkManifest primarySvc;
        "valkey-replica-service" = kixlib'.mkManifest replicaSvc;
        "valkey-primary" = kixlib'.mkManifest primaryStatefulSet;
        "valkey-replicas" = kixlib'.mkManifest replicaStatefulSet;
      })
      # --- Optional resources ---
      // lib.optionalAttrs cfg.metrics.enabled {
        "valkey-metrics" = kixlib'.mkManifest metricsSvc;
      }
      // lib.optionalAttrs cfg.networkPolicy.enabled {
        "valkey-networkpolicy" = kixlib'.mkManifest networkPolicy;
      }
      // lib.optionalAttrs cfg.pdb.enabled (
        if cfg.sentinel.enabled then {
          "valkey-pdb" = kixlib'.mkManifest sentinelPdb;
        } else {
          "valkey-replica-pdb" = kixlib'.mkManifest replicaPdb;
        }
      )
      // lib.optionalAttrs (cfg.metrics.enabled && cfg.metrics.serviceMonitor.enabled) {
        "valkey-servicemonitor" = kixlib'.mkManifest serviceMonitor;
      }
    );
  };
}
