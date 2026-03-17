# Valkey (Redis-compatible) kix package with Sentinel support.
#
# Deploys a Valkey cluster using StatefulSet with sentinel sidecar for
# automatic failover. Mirrors the Bitnami Valkey Helm chart topology.
#
# Resources: ServiceAccount, ConfigMap (scripts + config), StatefulSet
# (valkey + sentinel containers), Service (headless), Service (sentinel),
# and optionally: Service (read replicas), Service (metrics), Secret (auth).
#
# main = sentinel Service (consumers connect to sentinel to discover primary).

{
  scope,
  config,
  lib,
}:

let
  name = scope.instanceName;

  cfg = scope.defaults config {
    image = {
      repository = "docker.io/bitnami/valkey";
      tag = "8.1.1-debian-12-r0";
      pullPolicy = "IfNotPresent";
    };
    replicaCount = 3;
    auth = {
      enabled = true;
      existingSecret = null;
      existingSecretPasswordKey = "valkey-password";
      password = null;
    };
    sentinel = {
      enabled = true;
      image = {
        repository = "docker.io/bitnami/valkey-sentinel";
        tag = "8.1.1-debian-12-r0";
        pullPolicy = "IfNotPresent";
      };
      quorum = 2;
      downAfterMilliseconds = 60000;
      failoverTimeout = 180000;
      parallelSyncs = 1;
      primarySet = "mymaster";
      resources = {
        requests = {
          cpu = "100m";
          memory = "128Mi";
        };
        limits = {
          cpu = "150m";
          memory = "192Mi";
        };
      };
    };
    persistence = {
      enabled = true;
      size = "8Gi";
      storageClass = null;
    };
    resources = {
      requests = {
        cpu = "100m";
        memory = "128Mi";
      };
      limits = {
        cpu = "250m";
        memory = "256Mi";
      };
    };
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
        };
        limits = {
          cpu = "150m";
          memory = "192Mi";
        };
      };
    };
  };

  selectorLabels = {
    "app.kubernetes.io/name" = "valkey";
    "app.kubernetes.io/instance" = name;
  };

  commonLabels = selectorLabels // {
    "app.kubernetes.io/component" = "node";
  };

  # Auth-related helpers.
  authSecretName =
    if cfg.auth.existingSecret != null then cfg.auth.existingSecret else "${name}-auth";

  authPasswordKey = cfg.auth.existingSecretPasswordKey;

  # Auth env vars shared by valkey, sentinel, and metrics containers.
  authEnv =
    if cfg.auth.enabled then
      [
        {
          name = "VALKEY_PASSWORD";
          valueFrom.secretKeyRef = {
            name = authSecretName;
            key = authPasswordKey;
          };
        }
      ]
    else
      [ ];

  authCliFlag = if cfg.auth.enabled then ''-a "$VALKEY_PASSWORD"'' else "";

  # ── ConfigMap data ──────────────────────────────────────────────

  defaultConf = ''
    # Valkey default configuration
    bind 0.0.0.0
    port 6379
    tcp-backlog 511
    timeout 0
    tcp-keepalive 300
    daemonize no
    loglevel notice
    databases 16
    save 900 1
    save 300 10
    save 60 10000
    stop-writes-on-bgsave-error yes
    rdbcompression yes
    rdbchecksum yes
    dbfilename dump.rdb
    dir /data
    maxmemory-policy noeviction
    appendonly yes
    appendfilename "appendonly.aof"
    appendfsync everysec
    no-appendfsync-on-rewrite no
    auto-aof-rewrite-percentage 100
    auto-aof-rewrite-min-size 64mb
  ''
  + lib.optionalString cfg.auth.enabled ''
    masterauth VALKEY_PASSWORD_PLACEHOLDER
    requirepass VALKEY_PASSWORD_PLACEHOLDER
  '';

  sentinelConf = ''
    port 26379
    dir /tmp
    sentinel monitor ${cfg.sentinel.primarySet} ${name}-node-0.${name}-headless.${scope.namespaceName}.svc.cluster.local 6379 ${toString cfg.sentinel.quorum}
    sentinel down-after-milliseconds ${cfg.sentinel.primarySet} ${toString cfg.sentinel.downAfterMilliseconds}
    sentinel failover-timeout ${cfg.sentinel.primarySet} ${toString cfg.sentinel.failoverTimeout}
    sentinel parallel-syncs ${cfg.sentinel.primarySet} ${toString cfg.sentinel.parallelSyncs}
  ''
  + lib.optionalString cfg.auth.enabled ''
    sentinel auth-pass ${cfg.sentinel.primarySet} VALKEY_PASSWORD_PLACEHOLDER
  '';

  # Health check: valkey liveness (simple PING).
  pingLivenessScript = ''
    #!/bin/bash
    set -e
    response=$(timeout 5 valkey-cli \
      -h localhost \
      -p 6379 \
      ${authCliFlag} \
      ping)
    if [ "$response" != "PONG" ]; then
      echo "PING failed: $response"
      exit 1
    fi
  '';

  # Health check: valkey readiness (PING + replication check).
  pingReadinessScript = ''
    #!/bin/bash
    set -e
    response=$(timeout 5 valkey-cli \
      -h localhost \
      -p 6379 \
      ${authCliFlag} \
      ping)
    if [ "$response" != "PONG" ]; then
      echo "PING failed: $response"
      exit 1
    fi
    # Check replication link is up (for replicas)
    role=$(valkey-cli -h localhost -p 6379 ${authCliFlag} info replication | grep role: | tr -d '\r')
    if echo "$role" | grep -q "slave"; then
      link=$(valkey-cli -h localhost -p 6379 ${authCliFlag} info replication | grep master_link_status: | tr -d '\r')
      if ! echo "$link" | grep -q "up"; then
        echo "Replication link is down"
        exit 1
      fi
    fi
  '';

  # Health check: sentinel liveness (PING).
  sentinelLivenessScript = ''
    #!/bin/bash
    set -e
    response=$(timeout 5 valkey-cli \
      -h localhost \
      -p 26379 \
      ping)
    if [ "$response" != "PONG" ]; then
      echo "Sentinel PING failed: $response"
      exit 1
    fi
  '';

  # Health check: sentinel readiness (check master is known).
  sentinelReadinessScript = ''
    #!/bin/bash
    set -e
    response=$(timeout 5 valkey-cli \
      -h localhost \
      -p 26379 \
      ping)
    if [ "$response" != "PONG" ]; then
      echo "Sentinel PING failed: $response"
      exit 1
    fi
    # Verify sentinel knows about the master
    master=$(timeout 5 valkey-cli \
      -h localhost \
      -p 26379 \
      sentinel get-master-addr-by-name ${cfg.sentinel.primarySet} 2>/dev/null)
    if [ -z "$master" ]; then
      echo "Sentinel does not know master ${cfg.sentinel.primarySet}"
      exit 1
    fi
  '';

  # Start script for Valkey nodes. Determines if this node is the initial
  # primary (ordinal 0) or a replica, then configures replication accordingly.
  startNodeScript = ''
    #!/bin/bash
    set -e

    HOSTNAME=$(hostname)
    ORDINAL=''${HOSTNAME##*-}

    # Copy config and replace password placeholder
    cp /opt/bitnami/valkey/etc/valkey-default.conf /opt/bitnami/valkey/etc/valkey.conf
  ''
  + lib.optionalString cfg.auth.enabled ''
    sed -i "s/VALKEY_PASSWORD_PLACEHOLDER/$VALKEY_PASSWORD/g" /opt/bitnami/valkey/etc/valkey.conf
  ''
  + ''

    if [ "$ORDINAL" = "0" ]; then
      echo "Starting as initial primary"
    else
      echo "Starting as replica of ${name}-node-0.${name}-headless.${scope.namespaceName}.svc.cluster.local"
      echo "replicaof ${name}-node-0.${name}-headless.${scope.namespaceName}.svc.cluster.local 6379" >> /opt/bitnami/valkey/etc/valkey.conf
    fi

    exec valkey-server /opt/bitnami/valkey/etc/valkey.conf
  '';

  # Start script for sentinel sidecar.
  startSentinelScript = ''
    #!/bin/bash
    set -e

    # Copy sentinel config and replace password placeholder
    cp /opt/bitnami/valkey/etc/sentinel-default.conf /tmp/sentinel.conf
  ''
  + lib.optionalString cfg.auth.enabled ''
    sed -i "s/VALKEY_PASSWORD_PLACEHOLDER/$VALKEY_PASSWORD/g" /tmp/sentinel.conf
  ''
  + ''

    # Wait for the valkey node to be ready before starting sentinel
    until valkey-cli -h localhost -p 6379 ${authCliFlag} ping 2>/dev/null | grep -q PONG; do
      echo "Waiting for valkey node..."
      sleep 2
    done

    exec valkey-sentinel /tmp/sentinel.conf
  '';

  # ── Containers ──────────────────────────────────────────────────

  valkeyContainer = {
    name = "valkey";
    image = "${cfg.image.repository}:${cfg.image.tag}";
    imagePullPolicy = cfg.image.pullPolicy;
    command = [
      "/bin/bash"
      "-c"
      "/scripts/start-node.sh"
    ];
    env = [
      {
        name = "POD_NAME";
        valueFrom.fieldRef.fieldPath = "metadata.name";
      }
    ]
    ++ authEnv;
    ports = [
      {
        name = "valkey";
        containerPort = 6379;
        protocol = "TCP";
      }
    ];
    livenessProbe = {
      exec.command = [
        "/bin/bash"
        "/scripts/ping-liveness.sh"
      ];
      initialDelaySeconds = 20;
      periodSeconds = 10;
      timeoutSeconds = 6;
      successThreshold = 1;
      failureThreshold = 5;
    };
    readinessProbe = {
      exec.command = [
        "/bin/bash"
        "/scripts/ping-readiness.sh"
      ];
      initialDelaySeconds = 20;
      periodSeconds = 5;
      timeoutSeconds = 6;
      successThreshold = 1;
      failureThreshold = 5;
    };
    resources = cfg.resources;
    volumeMounts = [
      {
        name = "scripts";
        mountPath = "/scripts";
        readOnly = true;
      }
      {
        name = "valkey-config";
        mountPath = "/opt/bitnami/valkey/etc";
      }
      {
        name = "data";
        mountPath = "/data";
      }
    ];
    securityContext = {
      allowPrivilegeEscalation = false;
      capabilities.drop = [ "ALL" ];
      runAsNonRoot = true;
      runAsUser = 1001;
      runAsGroup = 1001;
      seccompProfile.type = "RuntimeDefault";
    };
  };

  sentinelContainer = {
    name = "sentinel";
    image = "${cfg.sentinel.image.repository}:${cfg.sentinel.image.tag}";
    imagePullPolicy = cfg.sentinel.image.pullPolicy;
    command = [
      "/bin/bash"
      "-c"
      "/scripts/start-sentinel.sh"
    ];
    env = authEnv;
    ports = [
      {
        name = "sentinel";
        containerPort = 26379;
        protocol = "TCP";
      }
    ];
    livenessProbe = {
      exec.command = [
        "/bin/bash"
        "/scripts/sentinel-liveness.sh"
      ];
      initialDelaySeconds = 30;
      periodSeconds = 10;
      timeoutSeconds = 6;
      successThreshold = 1;
      failureThreshold = 5;
    };
    readinessProbe = {
      exec.command = [
        "/bin/bash"
        "/scripts/sentinel-readiness.sh"
      ];
      initialDelaySeconds = 30;
      periodSeconds = 5;
      timeoutSeconds = 6;
      successThreshold = 1;
      failureThreshold = 5;
    };
    resources = cfg.sentinel.resources;
    volumeMounts = [
      {
        name = "scripts";
        mountPath = "/scripts";
        readOnly = true;
      }
      {
        name = "valkey-config";
        mountPath = "/opt/bitnami/valkey/etc";
        readOnly = true;
      }
    ];
    securityContext = {
      allowPrivilegeEscalation = false;
      capabilities.drop = [ "ALL" ];
      runAsNonRoot = true;
      runAsUser = 1001;
      runAsGroup = 1001;
      seccompProfile.type = "RuntimeDefault";
    };
  };

  metricsContainer = {
    name = "metrics";
    image = "${cfg.metrics.image.repository}:${cfg.metrics.image.tag}";
    imagePullPolicy = cfg.metrics.image.pullPolicy;
    env = [
      {
        name = "REDIS_ADDR";
        value = "redis://localhost:6379";
      }
    ]
    ++ lib.optionals cfg.auth.enabled [
      {
        name = "REDIS_PASSWORD";
        valueFrom.secretKeyRef = {
          name = authSecretName;
          key = authPasswordKey;
        };
      }
    ];
    ports = [
      {
        name = "metrics";
        containerPort = 9121;
        protocol = "TCP";
      }
    ];
    livenessProbe = {
      httpGet = {
        path = "/health";
        port = 9121;
      };
      initialDelaySeconds = 15;
      periodSeconds = 15;
      timeoutSeconds = 5;
      failureThreshold = 3;
    };
    readinessProbe = {
      httpGet = {
        path = "/health";
        port = 9121;
      };
      initialDelaySeconds = 15;
      periodSeconds = 15;
      timeoutSeconds = 5;
      failureThreshold = 3;
    };
    resources = cfg.metrics.resources;
    securityContext = {
      allowPrivilegeEscalation = false;
      capabilities.drop = [ "ALL" ];
      runAsNonRoot = true;
      runAsUser = 1001;
      runAsGroup = 1001;
      seccompProfile.type = "RuntimeDefault";
    };
  };

  # Assemble the container list.
  containers = [
    valkeyContainer
    sentinelContainer
  ]
  ++ lib.optional cfg.metrics.enabled metricsContainer;

in
self: {

  # --- ServiceAccount ---
  serviceAccount = scope.mkResource {
    apiVersion = "v1";
    kind = "ServiceAccount";
    name = "${name}";
    labels = commonLabels;
  };

  # --- Secret (auth, only when no existingSecret) ---
  secret =
    if cfg.auth.enabled && cfg.auth.existingSecret == null then
      scope.mkResource {
        apiVersion = "v1";
        kind = "Secret";
        name = "${name}-auth";
        labels = commonLabels;
        extra = {
          type = "Opaque";
          stringData = lib.optionalAttrs (cfg.auth.password != null) {
            ${authPasswordKey} = cfg.auth.password;
          };
        };
      }
    else
      null;

  # --- ConfigMap (configuration + scripts) ---
  configmap = scope.mkResource {
    apiVersion = "v1";
    kind = "ConfigMap";
    name = "${name}-scripts";
    labels = commonLabels;
    data = {
      "valkey-default.conf" = defaultConf;
      "sentinel-default.conf" = sentinelConf;
      "start-node.sh" = startNodeScript;
      "start-sentinel.sh" = startSentinelScript;
      "ping-liveness.sh" = pingLivenessScript;
      "ping-readiness.sh" = pingReadinessScript;
      "sentinel-liveness.sh" = sentinelLivenessScript;
      "sentinel-readiness.sh" = sentinelReadinessScript;
    };
  };

  # --- StatefulSet (valkey-node) ---
  statefulSet = scope.mkResource {
    apiVersion = "apps/v1";
    kind = "StatefulSet";
    name = "${name}-node";
    labels = commonLabels;
    spec = {
      serviceName = "${self.headlessService}";
      replicas = cfg.replicaCount;
      podManagementPolicy = "Parallel";
      updateStrategy = {
        type = "RollingUpdate";
      };
      selector.matchLabels = selectorLabels // {
        "app.kubernetes.io/component" = "node";
      };
      template = {
        metadata = {
          labels = selectorLabels // {
            "app.kubernetes.io/component" = "node";
          };
          annotations = {
            "checksum/configmap" = "\${${self.configmap}}";
          };
        };
        spec = {
          serviceAccountName = "${self.serviceAccount}";
          terminationGracePeriodSeconds = 30;
          securityContext = {
            fsGroup = 1001;
            seccompProfile.type = "RuntimeDefault";
          };
          affinity.podAntiAffinity.preferredDuringSchedulingIgnoredDuringExecution = [
            {
              weight = 100;
              podAffinityTerm = {
                labelSelector.matchLabels = selectorLabels // {
                  "app.kubernetes.io/component" = "node";
                };
                topologyKey = "kubernetes.io/hostname";
              };
            }
          ];
          initContainers = [
            {
              name = "init-config";
              image = "${cfg.image.repository}:${cfg.image.tag}";
              imagePullPolicy = cfg.image.pullPolicy;
              command = [
                "/bin/bash"
                "-c"
                ''
                  cp /configmap/valkey-default.conf /config/valkey-default.conf
                  cp /configmap/sentinel-default.conf /config/sentinel-default.conf
                  chmod 0660 /config/*.conf
                ''
              ];
              volumeMounts = [
                {
                  name = "scripts";
                  mountPath = "/configmap";
                  readOnly = true;
                }
                {
                  name = "valkey-config";
                  mountPath = "/config";
                }
              ];
              securityContext = {
                allowPrivilegeEscalation = false;
                capabilities.drop = [ "ALL" ];
                runAsNonRoot = true;
                runAsUser = 1001;
                runAsGroup = 1001;
              };
            }
          ];
          inherit containers;
          volumes = [
            {
              name = "scripts";
              configMap = {
                name = "${self.configmap}";
                defaultMode = 493; # 0755
              };
            }
            {
              name = "valkey-config";
              emptyDir = { };
            }
          ]
          ++ lib.optional (!cfg.persistence.enabled) {
            name = "data";
            emptyDir = { };
          };
        };
      };
    }
    // lib.optionalAttrs cfg.persistence.enabled {
      volumeClaimTemplates = [
        {
          metadata = {
            name = "data";
            labels = selectorLabels;
          };
          spec = {
            accessModes = [ "ReadWriteOnce" ];
            resources.requests.storage = cfg.persistence.size;
          }
          // lib.optionalAttrs (cfg.persistence.storageClass != null) {
            storageClassName = cfg.persistence.storageClass;
          };
        }
      ];
    };
  };

  # --- Service (headless, for StatefulSet DNS) ---
  headlessService = scope.mkResource {
    apiVersion = "v1";
    kind = "Service";
    name = "${name}-headless";
    labels = commonLabels;
    spec = {
      type = "ClusterIP";
      clusterIP = "None";
      publishNotReadyAddresses = true;
      selector = selectorLabels // {
        "app.kubernetes.io/component" = "node";
      };
      ports = [
        {
          name = "valkey";
          port = 6379;
          targetPort = "valkey";
          protocol = "TCP";
        }
        {
          name = "sentinel";
          port = 26379;
          targetPort = "sentinel";
          protocol = "TCP";
        }
      ];
    };
    requires = [ self.statefulSet ];
  };

  # --- Service (sentinel, main entry point for consumers) ---
  sentinelService = scope.mkResource {
    apiVersion = "v1";
    kind = "Service";
    name = "${name}-sentinel";
    labels = commonLabels // {
      "app.kubernetes.io/component" = "sentinel";
    };
    spec = {
      type = "ClusterIP";
      selector = selectorLabels // {
        "app.kubernetes.io/component" = "node";
      };
      ports = [
        {
          name = "sentinel";
          port = 26379;
          targetPort = "sentinel";
          protocol = "TCP";
        }
      ];
    };
    outputs = {
      sentinelPort = "26379";
      port = "6379";
      primarySet = cfg.sentinel.primarySet;
    };
    requires = [ self.statefulSet ];
  };

  # --- Service (read replicas, optional) ---
  readService = scope.mkResource {
    apiVersion = "v1";
    kind = "Service";
    name = "${name}-read";
    labels = commonLabels // {
      "app.kubernetes.io/component" = "read";
    };
    spec = {
      type = "ClusterIP";
      selector = selectorLabels // {
        "app.kubernetes.io/component" = "node";
      };
      ports = [
        {
          name = "valkey";
          port = 6379;
          targetPort = "valkey";
          protocol = "TCP";
        }
      ];
    };
    requires = [ self.statefulSet ];
  };

  # --- Service (metrics, optional) ---
  metricsService =
    if cfg.metrics.enabled then
      scope.mkResource {
        apiVersion = "v1";
        kind = "Service";
        name = "${name}-metrics";
        labels = commonLabels // {
          "app.kubernetes.io/component" = "metrics";
        };
        annotations = {
          "prometheus.io/scrape" = "true";
          "prometheus.io/port" = "9121";
        };
        spec = {
          type = "ClusterIP";
          selector = selectorLabels // {
            "app.kubernetes.io/component" = "node";
          };
          ports = [
            {
              name = "metrics";
              port = 9121;
              targetPort = "metrics";
              protocol = "TCP";
            }
          ];
        };
        outputs = {
          metricsPort = "9121";
        };
        requires = [ self.statefulSet ];
      }
    else
      null;

  # --- Entry point ---
  # main = sentinel Service. Consumers connect to sentinel to discover
  # the current primary via SENTINEL get-master-addr-by-name.
  main = self.sentinelService;
}
