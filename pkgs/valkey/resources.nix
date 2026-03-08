# Valkey resource construction and config wiring.
#
# This file builds all Kubernetes resources for the Valkey module and wires
# them into config.manifests, config.registry, and config.monitoring.
# Option declarations live in options.nix.
#
# Source Helm chart: oci://registry-1.docker.io/bitnamicharts/valkey (v3.0.2, appVersion 8.1.1)
#
# Two modes:
#   REPLICATION (default): primary SS + replica SS + separate services/SAs
#   SENTINEL (sentinel.enabled = true): single "node" SS with valkey + sentinel + metrics containers
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
  cfg = config.services.valkey;

  # --- Naming helpers ---
  # Helm uses "release-name-valkey" as the base name. We just use "valkey".
  # These are used for resource names and DNS references in scripts.

  fullname = "valkey";
  headlessSvcName = "${fullname}-headless";

  # FQDN helper — delegates to kixlib.mkFqdn for the shared implementation.
  fqdn = name: kixlib.mkFqdn { inherit name; namespace = cfg.namespace; clusterDomain = cfg.clusterDomain; };

  headlessSvcFqdn = fqdn headlessSvcName;

  # --- Labels ---
  # Using kixlib.mkLabels for the standard label hierarchy.
  # Stable selector labels — NEVER include version here (breaks rolling updates).
  labels = kixlib.mkLabels {
    chart = "valkey";
    clusterLabels = config.cluster.labels;
    extra = { "app.kubernetes.io/part-of" = "valkey"; };
  };

  # --- kixlib setup ---
  kixlib' = kixlib.withMetadata {
    namespace = cfg.namespace;
    labels = labels.all;
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
    # parse_sentinels.awk uses @PRIMARY_SET@ — needs readScript, not bare readFile
    |> kixlib'.configMap.withEntry "parse_sentinels.awk" (readScript "parse_sentinels.awk")
    else cm);

  # --- ConfigMap: scripts ---
  # Start/lifecycle scripts contain Nix-interpolated service names, namespaces, and
  # replica counts. They are stored as separate .sh files in scripts/ with @PLACEHOLDER@
  # tokens, substituted at eval time via builtins.replaceStrings. This avoids the
  # escaping hell of embedding bash ${VAR} in Nix multiline strings (''${...}).
  # See SKILL.md "Shell Scripts in ConfigMaps" for the rationale.

  sentinelSvcFqdn = fqdn fullname;
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

  # --- Base valkey container helper ---
  # The primaryContainer, replicaContainer, and sentinelValkeyContainer are ~80%
  # identical. This helper captures the shared structure; each caller specifies
  # only its differences (start script, extra env vars, probes, resources, etc.).
  #
  # The portName parameter handles a subtle difference: replication mode containers
  # use "redis" (matching Helm's tcp-redis service port targetPort), while sentinel
  # mode uses "valkey" (sentinel service targets by port number, not name).
  mkValkeyContainer = {
    startScript,
    env ? [],
    probes ? {},
    resources,
    portName ? "redis",
    lifecycle ? {},
    volumeMounts ? commonVolumeMounts,
  }:
    kixlib'.pod.mkContainer {
      name = "valkey";
      image = kixlib.imageRef cfg.image;
      imagePullPolicy = cfg.image.pullPolicy;
      securityContext = cfg.containerSecurityContext;
      command = [ "/bin/bash" ];
      args = [ "-c" "/opt/bitnami/scripts/start-scripts/${startScript}" ];
      env = [
        { name = "BITNAMI_DEBUG"; value = "false"; }
        { name = "ALLOW_EMPTY_PASSWORD"; value = "no"; }
        { name = "VALKEY_PASSWORD_FILE"; value = "/opt/bitnami/valkey/secrets/valkey-password"; }
        { name = "VALKEY_TLS_ENABLED"; value = "no"; }
        { name = "VALKEY_PORT"; value = "6379"; }
      ] ++ env;
      ports = [{ name = portName; containerPort = 6379; }];
      inherit resources volumeMounts;
    } // probes // lifecycle;

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
      ports = [
        { name = "tcp-redis"; port = 6379; targetPort = "redis"; }
      ] ++ lib.optionals cfg.sentinel.enabled [
        { name = "tcp-sentinel"; port = 26379; targetPort = "valkey-sentinel"; }
      ];
      selector = labels.selector;
    } // lib.optionalAttrs cfg.sentinel.enabled {
      publishNotReadyAddresses = true;
    };
  };

  # ============================================================
  # SENTINEL MODE RESOURCES
  # ============================================================

  sentinelSvc = kixlib'.networking.mkService {
    metadata = {
      name = fullname;
      labels = labels.all // { "app.kubernetes.io/component" = "node"; };
    };
    spec = {
      type = "ClusterIP";
      sessionAffinity = "None";
      ports = [
        { name = "tcp-redis"; port = 6379; targetPort = 6379; }
        { name = "tcp-sentinel"; port = 26379; targetPort = 26379; }
      ];
      selector = labels.withComponent "node";
    };
  };

  # Sentinel mode: single StatefulSet with valkey + sentinel + optional metrics containers
  sentinelValkeyContainer = mkValkeyContainer {
    startScript = "start-node.sh";
    portName = "valkey";
    env = [
      { name = "VALKEY_PRIMARY_PORT_NUMBER"; value = "6379"; }
      { name = "VALKEY_PRIMARY_PASSWORD_FILE"; value = "/opt/bitnami/valkey/secrets/valkey-password"; }
      { name = "VALKEY_SENTINEL_TLS_ENABLED"; value = "no"; }
      { name = "VALKEY_SENTINEL_PORT"; value = "26379"; }
      { name = "VALKEY_DATA_DIR"; value = "/data"; }
    ];
    lifecycle = {
      lifecycle.preStop.exec.command = [
        "/bin/bash" "-c" "/opt/bitnami/scripts/start-scripts/prestop-valkey.sh"
      ];
    };
    probes = {
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
    };
    resources = cfg.primary.resources;
    volumeMounts = commonVolumeMounts ++ [
      { name = "sentinel-data"; mountPath = "/opt/bitnami/valkey-sentinel/etc"; }
    ];
  };

  sentinelContainer = kixlib'.pod.mkContainer {
    name = "sentinel";
    image = kixlib.imageRef cfg.sentinel.image;
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
    image = kixlib.imageRef cfg.metrics.image;
    imagePullPolicy = cfg.metrics.image.pullPolicy;
    securityContext = cfg.containerSecurityContext;
    command = [ "/bin/bash" "-c" ''
      export REDIS_PASSWORD="$(< $REDIS_PASSWORD_FILE)"
      redis_exporter
    '' ];
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
      labels = labels.all // { "app.kubernetes.io/component" = "node"; };
    };
    replicas = totalReplicas;
    serviceName = headlessSvcName;
    selectorLabels = labels.withComponent "node";
    updateStrategy = { type = "RollingUpdate"; };
    template = kixlib'.pod.mkPodTemplate {
      metadata = {
        labels = labels.withComponent "node";
        annotations = lib.optionalAttrs cfg.metrics.enabled {
          "prometheus.io/port" = "9121";
          "prometheus.io/scrape" = "true";
        };
      };
      spec = {
        automountServiceAccountToken = false;
        securityContext = cfg.podSecurityContext;
        serviceAccountName = fullname;
        affinity = mkAntiAffinity (labels.withComponent "node");
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
    volumeClaimTemplates = mkDataVolumeClaimTemplate (labels.withComponent "node");
  };

  # ============================================================
  # NON-SENTINEL (REPLICATION) MODE RESOURCES
  # ============================================================

  # Primary StatefulSet (non-sentinel)
  primaryContainer = mkValkeyContainer {
    startScript = "start-primary.sh";
    env = [
      { name = "VALKEY_REPLICATION_MODE"; value = "primary"; }
    ];
    probes = {
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
    };
    resources = cfg.primary.resources;
  };

  primaryStatefulSet = kixlib'.workload.mkStatefulSet {
    metadata = {
      name = "${fullname}-primary";
      labels = labels.all // { "app.kubernetes.io/component" = "primary"; };
    };
    replicas = 1;
    serviceName = headlessSvcName;
    selectorLabels = labels.withComponent "primary";
    updateStrategy = { type = "RollingUpdate"; };
    template = kixlib'.pod.mkPodTemplate {
      metadata.labels = labels.withComponent "primary";
      spec = {
        securityContext = cfg.podSecurityContext;
        serviceAccountName = "${fullname}-primary";
        automountServiceAccountToken = false;
        affinity = mkAntiAffinity (labels.withComponent "primary");
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
    volumeClaimTemplates = mkDataVolumeClaimTemplate (labels.withComponent "primary");
  };

  # Primary service (non-sentinel)
  primarySvc = kixlib'.networking.mkService {
    metadata = {
      name = "${fullname}-primary";
      labels = labels.all // { "app.kubernetes.io/component" = "primary"; };
    };
    spec = {
      type = "ClusterIP";
      internalTrafficPolicy = "Cluster";
      sessionAffinity = "None";
      ports = [{ name = "tcp-redis"; port = 6379; targetPort = "redis"; }];
      selector = labels.withComponent "primary";
    };
  };

  # Replica StatefulSet (non-sentinel)
  # The primary host is the first pod of the primary StatefulSet via the headless service.
  primaryHostFqdn = "${fullname}-primary-0.${headlessSvcFqdn}";

  replicaContainer = mkValkeyContainer {
    startScript = "start-replica.sh";
    env = [
      { name = "VALKEY_REPLICATION_MODE"; value = "replica"; }
      { name = "VALKEY_PRIMARY_HOST"; value = primaryHostFqdn; }
      { name = "VALKEY_PRIMARY_PORT_NUMBER"; value = "6379"; }
      { name = "VALKEY_PRIMARY_PASSWORD_FILE"; value = "/opt/bitnami/valkey/secrets/valkey-password"; }
    ];
    probes = {
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
    };
    resources = cfg.replica.resources;
  };

  replicaStatefulSet = kixlib'.workload.mkStatefulSet {
    metadata = {
      name = "${fullname}-replicas";
      labels = labels.all // { "app.kubernetes.io/component" = "replica"; };
    };
    replicas = cfg.replica.replicaCount;
    serviceName = headlessSvcName;
    selectorLabels = labels.withComponent "replica";
    updateStrategy = { type = "RollingUpdate"; };
    template = kixlib'.pod.mkPodTemplate {
      metadata.labels = labels.withComponent "replica";
      spec = {
        securityContext = cfg.podSecurityContext;
        serviceAccountName = "${fullname}-replica";
        automountServiceAccountToken = false;
        affinity = mkAntiAffinity (labels.withComponent "replica");
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
    volumeClaimTemplates = mkDataVolumeClaimTemplate (labels.withComponent "replica");
  };

  # Replica service (non-sentinel)
  replicaSvc = kixlib'.networking.mkService {
    metadata = {
      name = "${fullname}-replicas";
      labels = labels.all // { "app.kubernetes.io/component" = "replica"; };
    };
    spec = {
      type = "ClusterIP";
      internalTrafficPolicy = "Cluster";
      sessionAffinity = "None";
      ports = [{ name = "tcp-redis"; port = 6379; targetPort = "redis"; }];
      selector = labels.withComponent "replica";
    };
  };

  # Replica PDB (non-sentinel default mode creates a PDB for replicas)
  replicaPdb = kixlib'.policy.mkPodDisruptionBudget {
    metadata = {
      name = "${fullname}-replicas";
      labels = labels.all // { "app.kubernetes.io/component" = "replica"; };
    };
    selector.matchLabels = labels.withComponent "replica";
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
      labels = labels.all // { "app.kubernetes.io/component" = "metrics"; };
    };
    spec = {
      type = "ClusterIP";
      ports = [{ name = "http-metrics"; port = 9121; protocol = "TCP"; targetPort = "metrics"; }];
      selector = labels.selector;
    };
  };

  # Network policy
  networkPolicy = kixlib'.networking.mkNetworkPolicy {
    metadata.name = fullname;
    podSelector.matchLabels = labels.selector;
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
      labels = labels.all // { "app.kubernetes.io/component" = "node"; };
    };
    selector.matchLabels = labels.withComponent "node";
    maxUnavailable = cfg.pdb.maxUnavailable;
    minAvailable = cfg.pdb.minAvailable;
  };

  # --- HPA ---
  # In replication mode, targets the replica StatefulSet.
  # In sentinel mode, targets the node StatefulSet.
  replicaHpa = kixlib'.autoscaling.mkHorizontalPodAutoscaler {
    metadata = {
      name = if cfg.sentinel.enabled then "${fullname}-node" else "${fullname}-replicas";
      labels = labels.all // { "app.kubernetes.io/component" = "replica"; };
    };
    scaleTargetRef = {
      apiVersion = "apps/v1";
      kind = "StatefulSet";
      name = if cfg.sentinel.enabled then "${fullname}-node" else "${fullname}-replicas";
    };
    inherit (cfg.replica.autoscaling.hpa) minReplicas maxReplicas;
    metrics =
      lib.optional (cfg.replica.autoscaling.hpa.targetCPU != null) {
        type = "Resource";
        resource = {
          name = "cpu";
          target = {
            type = "Utilization";
            averageUtilization = cfg.replica.autoscaling.hpa.targetCPU;
          };
        };
      }
      ++ lib.optional (cfg.replica.autoscaling.hpa.targetMemory != null) {
        type = "Resource";
        resource = {
          name = "memory";
          target = {
            type = "Utilization";
            averageUtilization = cfg.replica.autoscaling.hpa.targetMemory;
          };
        };
      };
  };

  # PodMonitor — targets pods directly (no Service needed).
  podMonitor = kixlib'.monitoring.mkPodMonitor {
    metadata = {
      name = fullname;
      namespace = cfg.namespace;
      labels = labels.all;
    };
    podMetricsEndpoints = [{
      port = "metrics";
      interval = cfg.metrics.podMonitor.interval;
    }];
    namespaceSelector.matchNames = [ cfg.namespace ];
    selector.matchLabels = labels.selector;
  };

  # PrometheusRule — alerting/recording rules for Prometheus.
  prometheusRule = kixlib'.monitoring.mkPrometheusRule {
    metadata = {
      name = fullname;
      namespace = cfg.namespace;
      labels = labels.all;
    };
    groups = [{
      name = fullname;
      rules = cfg.metrics.prometheusRule.rules;
    }];
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
    selector.matchLabels = labels.selector // { "app.kubernetes.io/component" = "metrics"; };
  };

  # --- Declarative manifest list ---
  # All resources in a flat list with enable conditions. This replaces the
  # chained `// lib.optionalAttrs` pattern for clarity and maintainability.
  manifestList = [
    # Common to both modes
    { name = "valkey-configuration"; resource = configurationCM; enable = true; }
    { name = "valkey-health"; resource = healthCM; enable = true; }
    { name = "valkey-scripts"; resource = scriptsCM; enable = true; }
    { name = "valkey-headless"; resource = headlessSvc; enable = true; }
    # Sentinel mode
    { name = "valkey-serviceaccount"; resource = sa; enable = cfg.sentinel.enabled; }
    { name = "valkey-service"; resource = sentinelSvc; enable = cfg.sentinel.enabled; }
    { name = "valkey-node"; resource = sentinelStatefulSet; enable = cfg.sentinel.enabled; }
    # Replication mode
    { name = "valkey-primary-serviceaccount"; resource = primarySa; enable = !cfg.sentinel.enabled; }
    { name = "valkey-replica-serviceaccount"; resource = replicaSa; enable = !cfg.sentinel.enabled; }
    { name = "valkey-primary-service"; resource = primarySvc; enable = !cfg.sentinel.enabled; }
    { name = "valkey-replica-service"; resource = replicaSvc; enable = !cfg.sentinel.enabled; }
    { name = "valkey-primary"; resource = primaryStatefulSet; enable = !cfg.sentinel.enabled; }
    { name = "valkey-replicas"; resource = replicaStatefulSet; enable = !cfg.sentinel.enabled; }
    # Optional: metrics
    { name = "valkey-metrics"; resource = metricsSvc; enable = cfg.metrics.enabled; }
    # Optional: network policy
    { name = "valkey-networkpolicy"; resource = networkPolicy; enable = cfg.networkPolicy.enabled; }
    # Optional: PDB — sentinel gets one PDB, replication gets a different one
    { name = "valkey-pdb"; resource = sentinelPdb; enable = cfg.pdb.enabled && cfg.sentinel.enabled; }
    { name = "valkey-replica-pdb"; resource = replicaPdb; enable = cfg.pdb.enabled && !cfg.sentinel.enabled; }
    # Optional: monitoring — per-chart ServiceMonitor only when cross-cutting monitoring is off
    { name = "valkey-servicemonitor"; resource = serviceMonitor;
      enable = cfg.metrics.enabled && cfg.metrics.serviceMonitor.enabled && !config.monitoring.enabled; }
    { name = "valkey-podmonitor"; resource = podMonitor;
      enable = cfg.metrics.enabled && cfg.metrics.podMonitor.enabled; }
    { name = "valkey-prometheusrule"; resource = prometheusRule;
      enable = cfg.metrics.enabled && cfg.metrics.prometheusRule.enabled; }
    # Optional: HPA
    { name = "valkey-hpa"; resource = replicaHpa; enable = cfg.replica.autoscaling.hpa.enabled; }
  ];

in
{
  config = {
    # Consume cluster-wide DNS domain via mkDefault so per-chart override still wins.
    services.valkey.clusterDomain = lib.mkDefault config.cluster.domain;

    # --- Level 2: service registry ---
    # Advertise our endpoints. Mode-aware: sentinel mode exposes a single service
    # (clients use sentinel protocol to discover the current primary), while
    # replication mode exposes separate primary/replica services.
    registry.valkey = lib.mkIf cfg.enable {
      endpoints = (if cfg.sentinel.enabled then {
        primary = {
          host = fqdn fullname;
          port = 6379;
          protocol = "redis";
        };
      } else {
        primary = {
          host = fqdn "${fullname}-primary";
          port = 6379;
          protocol = "redis";
        };
        replicas = {
          host = fqdn "${fullname}-replicas";
          port = 6379;
          protocol = "redis";
        };
      })
      // lib.optionalAttrs cfg.sentinel.enabled {
        sentinel = {
          host = fqdn fullname;
          port = 26379;
          protocol = "redis-sentinel";
        };
      }
      // lib.optionalAttrs cfg.metrics.enabled {
        metrics = {
          host = fqdn "${fullname}-metrics";
          port = 9121;
          protocol = "http";
        };
      };
    };

    # --- Level 3: monitoring target ---
    # Declare our metrics endpoint for the cross-cutting monitoring module.
    monitoring.targets.valkey = lib.mkIf (cfg.enable && cfg.metrics.enabled) {
      serviceName = "${fullname}-metrics";
      namespace = cfg.namespace;
      portName = "http-metrics";
      # null defers to monitoring.defaultInterval set by the cross-cutting module
      interval = null;
      selector = labels.selector // { "app.kubernetes.io/component" = "metrics"; };
    };

    # --- Level 3: network policy declaration ---
    networkPolicies.services.valkey = lib.mkIf cfg.enable {
      namespace = cfg.namespace;
      podSelector = labels.selector;
      ingressPorts = [ 6379 ] ++ lib.optionals cfg.sentinel.enabled [ 26379 ]
        ++ lib.optionals cfg.metrics.enabled [ 9121 ];
      egressTo = [];
    };

    # Build manifests from the declarative list — filter by enable, then serialize.
    manifests = lib.optionalAttrs cfg.enable (
      lib.listToAttrs (
        map (r: lib.nameValuePair r.name (kixlib'.mkManifest r.resource))
        (builtins.filter (r: r.enable) manifestList)
      )
    );
  };
}
