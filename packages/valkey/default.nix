# Valkey package — v2.
#
# Migrated from pkgs-fp/valkey/ (v1 fixpoint pattern).
# Source Helm chart: oci://registry-1.docker.io/bitnamicharts/valkey (v3.0.2, appVersion 8.1.1)
#
# Two modes:
#   REPLICATION (default): primary SS + replica SS + separate services/SAs
#   SENTINEL (sentinel.enabled = true): single "node" SS with valkey + sentinel + metrics containers
#
# The `main` resource is the primary Service (replication) or the sentinel Service.
# Deploying `main.closure` includes all StatefulSets, ConfigMaps, ServiceAccounts,
# and everything else needed to make that Service work.

{ scope, config, lib }:

let
  cfg = scope.defaults config {
    # --- Images ---
    image = {
      repository = "docker.io/bitnami/valkey";
      tag = "8.1.1-debian-12-r0";
      pullPolicy = "IfNotPresent";
    };

    # --- Auth ---
    auth = {
      enabled = true;
      existingSecret = "";
      existingSecretPasswordKey = "valkey-password";
      sentinel = true;
    };

    # --- Configuration ---
    commonConfiguration = ''
      # Enable AOF https://valkey.io/docs/topics/persistence.html
      appendonly yes
      # Disable RDB persistence, AOF persistence already enabled.
      save ""'';

    primary = {
      configuration = "";
      disableCommands = [
        "FLUSHDB"
        "FLUSHALL"
      ];
      resources = {
        requests = {
          cpu = "100m";
          memory = "128Mi";
          ephemeral-storage = "50Mi";
        };
        limits = {
          cpu = "150m";
          memory = "192Mi";
          ephemeral-storage = "2Gi";
        };
      };
    };

    replica = {
      replicaCount = 3;
      configuration = "";
      disableCommands = [
        "FLUSHDB"
        "FLUSHALL"
      ];
      resources = {
        requests = {
          cpu = "100m";
          memory = "128Mi";
          ephemeral-storage = "50Mi";
        };
        limits = {
          cpu = "150m";
          memory = "192Mi";
          ephemeral-storage = "2Gi";
        };
      };
      autoscaling = {
        hpa = {
          enabled = false;
          minReplicas = 1;
          maxReplicas = 11;
          targetCPU = null;
          targetMemory = null;
        };
      };
    };

    # --- Sentinel ---
    sentinel = {
      enabled = false;
      quorum = 2;
      primarySet = "myprimary";
      downAfterMilliseconds = 60000;
      failoverTimeout = 180000;
      parallelSyncs = 1;
      configuration = "";
      image = {
        repository = "docker.io/bitnami/valkey-sentinel";
        tag = "8.1.1-debian-12-r0";
        pullPolicy = "IfNotPresent";
      };
      resources = {
        requests = {
          cpu = "100m";
          memory = "128Mi";
          ephemeral-storage = "50Mi";
        };
        limits = {
          cpu = "150m";
          memory = "192Mi";
          ephemeral-storage = "2Gi";
        };
      };
    };

    # --- Persistence ---
    persistence = {
      enabled = true;
      size = "8Gi";
      storageClass = null;
      accessModes = [ "ReadWriteOnce" ];
    };

    # --- Security contexts ---
    podSecurityContext = {
      fsGroup = 1001;
      fsGroupChangePolicy = "Always";
    };

    containerSecurityContext = {
      allowPrivilegeEscalation = false;
      capabilities.drop = [ "ALL" ];
      readOnlyRootFilesystem = true;
      runAsGroup = 1001;
      runAsNonRoot = true;
      runAsUser = 1001;
      seccompProfile.type = "RuntimeDefault";
    };

    # --- Metrics ---
    metrics = {
      enabled = false;
      image = {
        repository = "docker.io/bitnami/redis-exporter";
        tag = "1.70.0-debian-12-r2";
        pullPolicy = "IfNotPresent";
      };
      resources = {
        requests = {
          cpu = "100m";
          memory = "128Mi";
          ephemeral-storage = "50Mi";
        };
        limits = {
          cpu = "150m";
          memory = "192Mi";
          ephemeral-storage = "2Gi";
        };
      };
    };

    # --- Network Policy ---
    networkPolicy = {
      enabled = true;
    };

    # --- PDB ---
    pdb = {
      enabled = true;
      maxUnavailable = 1;
      minAvailable = null;
    };

    clusterDomain = "cluster.local";
  };

  # -- Derived values --------------------------------------------------

  fullname = "${scope.instanceName}-valkey";
  headlessSvcName = "${fullname}-headless";
  imageRef = "${cfg.image.repository}:${cfg.image.tag}";
  sentinelImageRef = "${cfg.sentinel.image.repository}:${cfg.sentinel.image.tag}";
  metricsImageRef = "${cfg.metrics.image.repository}:${cfg.metrics.image.tag}";
  totalReplicas = cfg.replica.replicaCount;

  # FQDN helper
  fqdn = name: "${name}.${scope.namespaceName}.svc.${cfg.clusterDomain}";
  headlessSvcFqdn = fqdn headlessSvcName;
  sentinelSvcFqdn = fqdn fullname;
  primaryHostFqdn = "${fullname}-primary-0.${headlessSvcFqdn}";

  # Secret name for password volume
  secretName = if cfg.auth.existingSecret != "" then cfg.auth.existingSecret else fullname;

  # -- Labels ----------------------------------------------------------

  baseSelectorLabels = {
    "app.kubernetes.io/instance" = scope.instanceName;
    "app.kubernetes.io/name" = "valkey";
  };

  selectorLabels = baseSelectorLabels;

  withComponent =
    component:
    selectorLabels
    // {
      "app.kubernetes.io/component" = component;
    };

  allLabels =
    selectorLabels
    // {
      "app.kubernetes.io/managed-by" = "kix";
      "app.kubernetes.io/part-of" = "valkey";
    };

  allLabelsWithComponent =
    component:
    allLabels
    // {
      "app.kubernetes.io/component" = component;
    };

  # -- Script templating -----------------------------------------------

  readScript =
    file:
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
      ]
      (builtins.readFile (./scripts + "/${file}"));

  renderDisableCommands = cmds: lib.concatMapStringsSep "\n" (cmd: ''rename-command ${cmd} ""'') cmds;

  # -- Volume definitions -----------------------------------------------

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

  startScriptsVolume = scriptsCmName: {
    name = "start-scripts";
    configMap = {
      name = scriptsCmName;
      defaultMode = 493; # 0755
    };
  };

  healthVolume = healthCmName: {
    name = "health";
    configMap = {
      name = healthCmName;
      defaultMode = 493;
    };
  };

  configVolume = configCmName: {
    name = "config";
    configMap = {
      name = configCmName;
    };
  };

  emptyDirVolume = {
    name = "empty-dir";
    emptyDir = { };
  };

  # -- Volume mounts ----------------------------------------------------

  passwordVolumeMount = {
    name = "valkey-password";
    mountPath = "/opt/bitnami/valkey/secrets/";
  };

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

  # -- Environment variables --------------------------------------------

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

  # -- Pod anti-affinity ------------------------------------------------

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

  # -- VolumeClaimTemplate ----------------------------------------------

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

  # -- Container definitions --------------------------------------------

  mkValkeyContainer =
    {
      startScript,
      env ? [ ],
      probes ? { },
      resources,
      portName ? "redis",
      lifecycle ? { },
      volumeMounts ? commonVolumeMounts,
    }:
    {
      name = "valkey";
      image = imageRef;
      imagePullPolicy = cfg.image.pullPolicy;
      securityContext = cfg.containerSecurityContext;
      command = [ "/bin/bash" ];
      args = [
        "-c"
        "/opt/bitnami/scripts/start-scripts/${startScript}"
      ];
      env = valkeyServerEnv ++ env;
      ports = [
        {
          name = portName;
          containerPort = 6379;
        }
      ];
      inherit resources volumeMounts;
    }
    // probes
    // lifecycle;

  # Primary container (replication mode)
  primaryContainer = mkValkeyContainer {
    startScript = "start-primary.sh";
    env = [
      {
        name = "VALKEY_REPLICATION_MODE";
        value = "primary";
      }
    ];
    probes = {
      livenessProbe = {
        initialDelaySeconds = 20;
        periodSeconds = 5;
        timeoutSeconds = 6;
        successThreshold = 1;
        failureThreshold = 5;
        exec.command = [
          "sh"
          "-c"
          "/health/ping_liveness_local.sh 5"
        ];
      };
      readinessProbe = {
        initialDelaySeconds = 20;
        periodSeconds = 5;
        timeoutSeconds = 2;
        successThreshold = 1;
        failureThreshold = 5;
        exec.command = [
          "sh"
          "-c"
          "/health/ping_readiness_local.sh 1"
        ];
      };
    };
    resources = cfg.primary.resources;
  };

  # Replica container (replication mode)
  replicaContainer = mkValkeyContainer {
    startScript = "start-replica.sh";
    env = [
      {
        name = "VALKEY_REPLICATION_MODE";
        value = "replica";
      }
      {
        name = "VALKEY_PRIMARY_HOST";
        value = primaryHostFqdn;
      }
      {
        name = "VALKEY_PRIMARY_PORT_NUMBER";
        value = "6379";
      }
      {
        name = "VALKEY_PRIMARY_PASSWORD_FILE";
        value = "/opt/bitnami/valkey/secrets/valkey-password";
      }
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
        exec.command = [
          "sh"
          "-c"
          "/health/ping_liveness_local_and_primary.sh 5"
        ];
      };
      readinessProbe = {
        initialDelaySeconds = 20;
        periodSeconds = 5;
        timeoutSeconds = 2;
        successThreshold = 1;
        failureThreshold = 5;
        exec.command = [
          "sh"
          "-c"
          "/health/ping_readiness_local_and_primary.sh 1"
        ];
      };
    };
    resources = cfg.replica.resources;
  };

  # Sentinel-mode valkey container
  sentinelValkeyContainer = mkValkeyContainer {
    startScript = "start-node.sh";
    portName = "valkey";
    env = [
      {
        name = "VALKEY_PRIMARY_PORT_NUMBER";
        value = "6379";
      }
      {
        name = "VALKEY_PRIMARY_PASSWORD_FILE";
        value = "/opt/bitnami/valkey/secrets/valkey-password";
      }
      {
        name = "VALKEY_SENTINEL_TLS_ENABLED";
        value = "no";
      }
      {
        name = "VALKEY_SENTINEL_PORT";
        value = "26379";
      }
      {
        name = "VALKEY_DATA_DIR";
        value = "/data";
      }
    ];
    lifecycle = {
      lifecycle.preStop.exec.command = [
        "/bin/bash"
        "-c"
        "/opt/bitnami/scripts/start-scripts/prestop-valkey.sh"
      ];
    };
    probes = {
      startupProbe = {
        failureThreshold = 22;
        initialDelaySeconds = 10;
        periodSeconds = 10;
        successThreshold = 1;
        timeoutSeconds = 5;
        exec.command = [
          "sh"
          "-c"
          "/health/ping_liveness_local.sh 5"
        ];
      };
      livenessProbe = {
        initialDelaySeconds = 20;
        periodSeconds = 5;
        timeoutSeconds = 5;
        successThreshold = 1;
        failureThreshold = 5;
        exec.command = [
          "sh"
          "-c"
          "/health/ping_liveness_local.sh 5"
        ];
      };
      readinessProbe = {
        initialDelaySeconds = 20;
        periodSeconds = 5;
        timeoutSeconds = 1;
        successThreshold = 1;
        failureThreshold = 5;
        exec.command = [
          "sh"
          "-c"
          "/health/ping_readiness_local.sh 1"
        ];
      };
    };
    resources = cfg.primary.resources;
    volumeMounts = commonVolumeMounts ++ [
      {
        name = "sentinel-data";
        mountPath = "/opt/bitnami/valkey-sentinel/etc";
      }
    ];
  };

  # Sentinel container
  sentinelContainer = {
    name = "sentinel";
    image = sentinelImageRef;
    imagePullPolicy = cfg.sentinel.image.pullPolicy;
    securityContext = cfg.containerSecurityContext;
    command = [ "/bin/bash" ];
    args = [
      "-c"
      "/opt/bitnami/scripts/start-scripts/start-sentinel.sh"
    ];
    lifecycle.preStop.exec.command = [
      "/bin/bash"
      "-c"
      "/opt/bitnami/scripts/start-scripts/prestop-sentinel.sh"
    ];
    env = sharedEnv ++ [
      {
        name = "VALKEY_SENTINEL_TLS_ENABLED";
        value = "no";
      }
      {
        name = "VALKEY_SENTINEL_PORT";
        value = "26379";
      }
    ];
    ports = [
      {
        name = "valkey-sentinel";
        containerPort = 26379;
      }
    ];
    resources = cfg.sentinel.resources;
    volumeMounts = sentinelVolumeMounts;
    startupProbe = {
      failureThreshold = 22;
      initialDelaySeconds = 10;
      periodSeconds = 10;
      successThreshold = 1;
      timeoutSeconds = 5;
      exec.command = [
        "sh"
        "-c"
        "/health/ping_sentinel.sh 5"
      ];
    };
    livenessProbe = {
      initialDelaySeconds = 20;
      periodSeconds = 10;
      timeoutSeconds = 5;
      successThreshold = 1;
      failureThreshold = 6;
      exec.command = [
        "sh"
        "-c"
        "/health/ping_sentinel.sh 5"
      ];
    };
    readinessProbe = {
      initialDelaySeconds = 20;
      periodSeconds = 5;
      timeoutSeconds = 1;
      successThreshold = 1;
      failureThreshold = 6;
      exec.command = [
        "sh"
        "-c"
        "/health/ping_sentinel.sh 1"
      ];
    };
  };

  # Metrics exporter container
  metricsContainer = {
    name = "metrics";
    image = metricsImageRef;
    imagePullPolicy = cfg.metrics.image.pullPolicy;
    securityContext = cfg.containerSecurityContext;
    command = [
      "/bin/bash"
      "-c"
      ''
        export REDIS_PASSWORD="$(< $REDIS_PASSWORD_FILE)"
        redis_exporter
      ''
    ];
    env = [
      {
        name = "REDIS_ALIAS";
        value = "valkey";
      }
      {
        name = "REDIS_EXPORTER_WEB_LISTEN_ADDRESS";
        value = ":9121";
      }
      {
        name = "REDIS_USER";
        value = "default";
      }
      {
        name = "REDIS_PASSWORD_FILE";
        value = "/secrets/valkey-password";
      }
    ];
    ports = [
      {
        name = "metrics";
        containerPort = 9121;
      }
    ];
    resources = cfg.metrics.resources;
    volumeMounts = [
      {
        name = "empty-dir";
        mountPath = "/tmp";
        subPath = "tmp-dir";
      }
      {
        name = "valkey-password";
        mountPath = "/secrets/";
      }
    ];
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
      httpGet = {
        path = "/";
        port = "metrics";
      };
    };
  };

  # -- Pod spec helper ---------------------------------------------------

  mkPodSpec =
    {
      serviceAccountName,
      componentLabels,
      containers,
      volumes,
    }:
    {
      automountServiceAccountToken = false;
      securityContext = cfg.podSecurityContext;
      affinity = mkAntiAffinity componentLabels;
      enableServiceLinks = true;
      terminationGracePeriodSeconds = 30;
      inherit serviceAccountName containers volumes;
    };

in self: {

  # -- Configuration ConfigMaps -----------------------------------------

  configurationCm = scope.mkResource {
    apiVersion = "v1";
    kind = "ConfigMap";
    name = "${fullname}-configuration";
    labels = allLabels;
    data = {
      "valkey.conf" = ''
        # User-supplied common configuration:
        ${cfg.commonConfiguration}
        # End of common configuration'';
      "primary.conf" = ''
        dir /data
        # User-supplied primary configuration:
        ${cfg.primary.configuration}${renderDisableCommands cfg.primary.disableCommands}
        # End of primary configuration'';
      "replica.conf" = ''
        dir /data
        # User-supplied replica configuration:
        ${cfg.replica.configuration}${renderDisableCommands cfg.replica.disableCommands}
        # End of replica configuration'';
    }
    // lib.optionalAttrs cfg.sentinel.enabled {
      "sentinel.conf" = ''
        dir "/tmp"
        port 26379
        sentinel monitor ${cfg.sentinel.primarySet} ${fullname}-node-0.${headlessSvcFqdn} 6379 ${toString cfg.sentinel.quorum}
        sentinel down-after-milliseconds ${cfg.sentinel.primarySet} ${toString cfg.sentinel.downAfterMilliseconds}
        sentinel failover-timeout ${cfg.sentinel.primarySet} ${toString cfg.sentinel.failoverTimeout}
        sentinel parallel-syncs ${cfg.sentinel.primarySet} ${toString cfg.sentinel.parallelSyncs}
        # User-supplied sentinel configuration:
        ${cfg.sentinel.configuration}
        # End of sentinel configuration'';
    };
  };

  healthCm = scope.mkResource {
    apiVersion = "v1";
    kind = "ConfigMap";
    name = "${fullname}-health";
    labels = allLabels;
    data = {
      "ping_readiness_local.sh" = builtins.readFile ./scripts/ping_readiness_local.sh;
      "ping_liveness_local.sh" = builtins.readFile ./scripts/ping_liveness_local.sh;
      "ping_readiness_primary.sh" = builtins.readFile ./scripts/ping_readiness_primary.sh;
      "ping_liveness_primary.sh" = builtins.readFile ./scripts/ping_liveness_primary.sh;
      "ping_readiness_local_and_primary.sh" =
        builtins.readFile ./scripts/ping_readiness_local_and_primary.sh;
      "ping_liveness_local_and_primary.sh" =
        builtins.readFile ./scripts/ping_liveness_local_and_primary.sh;
    }
    // lib.optionalAttrs cfg.sentinel.enabled {
      "ping_sentinel.sh" = builtins.readFile ./scripts/ping_sentinel.sh;
      "parse_sentinels.awk" = readScript "parse_sentinels.awk";
    };
  };

  scriptsCm = scope.mkResource {
    apiVersion = "v1";
    kind = "ConfigMap";
    name = "${fullname}-scripts";
    labels = allLabels;
    data =
      if cfg.sentinel.enabled then
        {
          "start-node.sh" = readScript "start-node.sh";
          "start-sentinel.sh" = readScript "start-sentinel.sh";
          "prestop-sentinel.sh" = readScript "prestop-sentinel.sh";
          "prestop-valkey.sh" = readScript "prestop-valkey.sh";
        }
      else
        {
          "start-primary.sh" = builtins.readFile ./scripts/start-primary.sh;
          "start-replica.sh" = readScript "start-replica.sh";
        };
  };

  # -- Headless Service (shared across both modes) ----------------------

  headlessSvc = scope.mkResource {
    apiVersion = "v1";
    kind = "Service";
    name = headlessSvcName;
    labels = allLabels;
    spec = {
      type = "ClusterIP";
      clusterIP = "None";
      publishNotReadyAddresses = cfg.sentinel.enabled;
      selector = selectorLabels;
      ports = [
        {
          name = "tcp-redis";
          port = 6379;
          targetPort = "redis";
        }
      ]
      ++ lib.optionals cfg.sentinel.enabled [
        {
          name = "tcp-sentinel";
          port = 26379;
          targetPort = "valkey-sentinel";
        }
      ];
    };
  };

  # -- Sentinel mode resources ------------------------------------------

  sentinelSa = scope.mkResource {
    apiVersion = "v1";
    kind = "ServiceAccount";
    name = fullname;
    labels = allLabels;
    extra.automountServiceAccountToken = false;
  };

  sentinelSvc = scope.mkResource {
    apiVersion = "v1";
    kind = "Service";
    name = fullname;
    labels = allLabelsWithComponent "node";
    outputs = {
      redisPort = 6379;
      sentinelPort = 26379;
    };
    spec = {
      type = "ClusterIP";
      sessionAffinity = "None";
      selector = withComponent "node";
      ports = [
        {
          name = "tcp-redis";
          port = 6379;
          targetPort = 6379;
        }
        {
          name = "tcp-sentinel";
          port = 26379;
          targetPort = 26379;
        }
      ];
    };
  };

  sentinelSs = scope.mkResource {
    apiVersion = "apps/v1";
    kind = "StatefulSet";
    name = "${fullname}-node";
    labels = allLabelsWithComponent "node";
    requires = [
      self.sentinelSa
      self.configurationCm
      self.healthCm
      self.scriptsCm
      self.headlessSvc
    ]
    ++ lib.optional (cfg.pdb.enabled && cfg.sentinel.enabled) self.pdb
    ++ lib.optional cfg.replica.autoscaling.hpa.enabled self.hpa;
    spec = {
      replicas = if cfg.replica.autoscaling.hpa.enabled then null else totalReplicas;
      serviceName = "${self.headlessSvc}";
      selector.matchLabels = withComponent "node";
      updateStrategy.type = "RollingUpdate";
      template = {
        metadata = {
          labels = withComponent "node";
          annotations = lib.optionalAttrs cfg.metrics.enabled {
            "prometheus.io/port" = "9121";
            "prometheus.io/scrape" = "true";
          };
        };
        spec = mkPodSpec {
          serviceAccountName = "${self.sentinelSa}";
          componentLabels = withComponent "node";
          containers = [
            sentinelValkeyContainer
            sentinelContainer
          ]
          ++ lib.optionals cfg.metrics.enabled [ metricsContainer ];
          volumes = [
            (startScriptsVolume "${self.scriptsCm}")
            (healthVolume "${self.healthCm}")
            passwordVolume
            (configVolume "${self.configurationCm}")
            {
              name = "sentinel-data";
              emptyDir = { };
            }
            emptyDirVolume
          ];
        };
      };
    };
    extra = {
      spec.volumeClaimTemplates = mkDataVolumeClaimTemplate (withComponent "node");
    };
  };

  # -- Replication mode resources ---------------------------------------

  primarySa = scope.mkResource {
    apiVersion = "v1";
    kind = "ServiceAccount";
    name = "${fullname}-primary";
    labels = allLabelsWithComponent "primary";
    extra.automountServiceAccountToken = false;
  };

  replicaSa = scope.mkResource {
    apiVersion = "v1";
    kind = "ServiceAccount";
    name = "${fullname}-replica";
    labels = allLabelsWithComponent "replica";
    extra.automountServiceAccountToken = false;
  };

  primarySvc = scope.mkResource {
    apiVersion = "v1";
    kind = "Service";
    name = "${fullname}-primary";
    labels = allLabelsWithComponent "primary";
    outputs = {
      redisPort = 6379;
    };
    spec = {
      type = "ClusterIP";
      internalTrafficPolicy = "Cluster";
      sessionAffinity = "None";
      selector = withComponent "primary";
      ports = [
        {
          name = "tcp-redis";
          port = 6379;
          targetPort = "redis";
        }
      ];
    };
  };

  replicaSvc = scope.mkResource {
    apiVersion = "v1";
    kind = "Service";
    name = "${fullname}-replicas";
    labels = allLabelsWithComponent "replica";
    outputs = {
      redisPort = 6379;
    };
    spec = {
      type = "ClusterIP";
      internalTrafficPolicy = "Cluster";
      sessionAffinity = "None";
      selector = withComponent "replica";
      ports = [
        {
          name = "tcp-redis";
          port = 6379;
          targetPort = "redis";
        }
      ];
    };
  };

  primarySs = scope.mkResource {
    apiVersion = "apps/v1";
    kind = "StatefulSet";
    name = "${fullname}-primary";
    labels = allLabelsWithComponent "primary";
    requires = [
      self.primarySa
      self.configurationCm
      self.healthCm
      self.scriptsCm
      self.headlessSvc
    ];
    spec = {
      replicas = 1;
      serviceName = "${self.headlessSvc}";
      selector.matchLabels = withComponent "primary";
      updateStrategy.type = "RollingUpdate";
      template = {
        metadata.labels = withComponent "primary";
        spec = mkPodSpec {
          serviceAccountName = "${self.primarySa}";
          componentLabels = withComponent "primary";
          containers = [ primaryContainer ];
          volumes = [
            (startScriptsVolume "${self.scriptsCm}")
            (healthVolume "${self.healthCm}")
            passwordVolume
            (configVolume "${self.configurationCm}")
            emptyDirVolume
          ];
        };
      };
    };
    extra = {
      spec.volumeClaimTemplates = mkDataVolumeClaimTemplate (withComponent "primary");
    };
  };

  replicaSs = scope.mkResource {
    apiVersion = "apps/v1";
    kind = "StatefulSet";
    name = "${fullname}-replicas";
    labels = allLabelsWithComponent "replica";
    requires = [
      self.replicaSa
      self.configurationCm
      self.healthCm
      self.scriptsCm
      self.headlessSvc
    ]
    ++ lib.optional (cfg.pdb.enabled && !cfg.sentinel.enabled) self.pdb
    ++ lib.optional cfg.replica.autoscaling.hpa.enabled self.hpa;
    spec = {
      replicas = if cfg.replica.autoscaling.hpa.enabled then null else cfg.replica.replicaCount;
      serviceName = "${self.headlessSvc}";
      selector.matchLabels = withComponent "replica";
      updateStrategy.type = "RollingUpdate";
      template = {
        metadata.labels = withComponent "replica";
        spec = mkPodSpec {
          serviceAccountName = "${self.replicaSa}";
          componentLabels = withComponent "replica";
          containers = [ replicaContainer ];
          volumes = [
            (startScriptsVolume "${self.scriptsCm}")
            (healthVolume "${self.healthCm}")
            passwordVolume
            (configVolume "${self.configurationCm}")
            emptyDirVolume
          ];
        };
      };
    };
    extra = {
      spec.volumeClaimTemplates = mkDataVolumeClaimTemplate (withComponent "replica");
    };
  };

  # -- Optional resources -----------------------------------------------

  metricsService = scope.mkResource {
    apiVersion = "v1";
    kind = "Service";
    name = "${fullname}-metrics";
    labels = allLabels // {
      "app.kubernetes.io/component" = "metrics";
    };
    outputs = {
      port = 9121;
    };
    spec = {
      type = "ClusterIP";
      selector = selectorLabels;
      ports = [
        {
          name = "http-metrics";
          port = 9121;
          protocol = "TCP";
          targetPort = 9121;
        }
      ];
    };
  };

  networkPolicyRes = scope.mkResource {
    apiVersion = "networking.k8s.io/v1";
    kind = "NetworkPolicy";
    name = fullname;
    labels = allLabels;
    spec = {
      podSelector.matchLabels = selectorLabels;
      policyTypes = [
        "Ingress"
        "Egress"
      ];
      egress = [ { } ];
      ingress = [
        {
          ports = [ { port = 6379; } ] ++ lib.optionals cfg.sentinel.enabled [ { port = 26379; } ];
        }
      ]
      ++ lib.optionals cfg.metrics.enabled [
        { ports = [ { port = 9121; } ]; }
      ];
    };
  };

  # PDB — targets sentinel nodes or replicas depending on mode
  pdb = scope.mkResource {
    apiVersion = "policy/v1";
    kind = "PodDisruptionBudget";
    name = if cfg.sentinel.enabled then "${fullname}-node" else "${fullname}-replicas";
    labels =
      if cfg.sentinel.enabled then allLabelsWithComponent "node" else allLabelsWithComponent "replica";
    spec = {
      selector.matchLabels = if cfg.sentinel.enabled then withComponent "node" else withComponent "replica";
    }
    // lib.optionalAttrs (cfg.pdb.maxUnavailable != null) {
      maxUnavailable = cfg.pdb.maxUnavailable;
    }
    // lib.optionalAttrs (cfg.pdb.minAvailable != null) {
      minAvailable = cfg.pdb.minAvailable;
    };
  };

  # HPA — targets replica SS in replication mode, node SS in sentinel mode
  hpa = scope.mkResource {
    apiVersion = "autoscaling/v2";
    kind = "HorizontalPodAutoscaler";
    name = if cfg.sentinel.enabled then "${fullname}-node" else "${fullname}-replicas";
    labels = allLabelsWithComponent "replica";
    spec = {
      scaleTargetRef = {
        apiVersion = "apps/v1";
        kind = "StatefulSet";
        name = if cfg.sentinel.enabled then "${self.sentinelSs}" else "${self.replicaSs}";
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
  };

  # -- Main: the public interface ----------------------------------------
  #
  # From outside, Valkey IS the Service. But deploying it requires
  # the StatefulSets behind it, plus optionally the metrics service,
  # network policy, etc.

  main = (if cfg.sentinel.enabled then self.sentinelSvc else self.primarySvc) // {
    requires =
      if cfg.sentinel.enabled then
        [ self.sentinelSs ]
        ++ lib.optional cfg.metrics.enabled self.metricsService
        ++ lib.optional cfg.networkPolicy.enabled self.networkPolicyRes
      else
        [
          self.primarySs
          self.replicaSs
        ]
        ++ lib.optional cfg.metrics.enabled self.metricsService
        ++ lib.optional cfg.networkPolicy.enabled self.networkPolicyRes;
  };
}
