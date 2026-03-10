# Valkey container definitions.
#
# All containers use pipe composition where practical.
# The base mkValkeyContainer helper captures ~80% shared structure across
# the primary, replica, and sentinel-valkey container variants.
#
# Source Helm chart: oci://registry-1.docker.io/bitnamicharts/valkey (v3.0.2)

{
  lib,
  kixlib,
  cfg,
  helpers,
  ...
}:

let
  inherit (helpers)
    kixlib'
    commonVolumeMounts
    sentinelVolumeMounts
    valkeyServerEnv
    sharedEnv
    primaryHostFqdn
    ;

  # --- Base valkey container helper ---
  # The primaryContainer, replicaContainer, and sentinelValkeyContainer are ~80%
  # identical. This helper captures the shared structure; each caller specifies
  # only its differences (start script, extra env vars, probes, resources, etc.).
  #
  # The portName parameter handles a subtle difference: replication mode containers
  # use "redis" (matching Helm's tcp-redis service port targetPort), while sentinel
  # mode uses "valkey" (sentinel service targets by port number, not name).
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
    kixlib'.pod.mkContainer {
      name = "valkey";
      image = kixlib.imageRef cfg.image;
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

in
{
  inherit mkValkeyContainer;

  # --- Primary container (non-sentinel) ---
  primary = mkValkeyContainer {
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

  # --- Replica container (non-sentinel) ---
  replica = mkValkeyContainer {
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

  # --- Sentinel-mode valkey container ---
  sentinelValkey = mkValkeyContainer {
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

  # --- Sentinel container ---
  sentinel =
    kixlib'.pod.mkContainer {
      name = "sentinel";
      image = kixlib.imageRef cfg.sentinel.image;
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
    }
    |> kixlib'.pod.withStartupProbe {
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
    }
    |> kixlib'.pod.withLivenessProbe {
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
    }
    |> kixlib'.pod.withReadinessProbe {
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

  # --- Metrics exporter container ---
  metrics =
    kixlib'.pod.mkContainer {
      name = "metrics";
      image = kixlib.imageRef cfg.metrics.image;
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
    }
    |> kixlib'.pod.withLivenessProbe {
      failureThreshold = 5;
      initialDelaySeconds = 10;
      periodSeconds = 10;
      successThreshold = 1;
      timeoutSeconds = 5;
      tcpSocket.port = "metrics";
    }
    |> kixlib'.pod.withReadinessProbe {
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
}
