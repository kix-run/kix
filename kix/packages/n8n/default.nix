# n8n workflow automation platform: kix package.
#
# Deploys the n8n main instance (UI/API) and queue workers backed by
# PostgreSQL (via StackGres) and Valkey (Redis-compatible) for Bull
# queue processing.
#
# Dependencies:
#   postgres              required, database
#   valkey                required, Redis-compatible queue backend
#   ingressNginx          optional, auto-creates ingress when present (+ host is set)
#   clusterIssuer         optional, auto-enables TLS when present
#
# Resources: ServiceAccount, ConfigMap (env), Deployment (main),
# Deployment (worker), Service (web UI), Ingress (optional).
#
# root = Service (port 80 by default, proxied to container port 5678).
# External secrets (DB password, encryption key, Redis password)
# are expected to be managed externally (e.g. via Infisical) and
# injected via existingSecret as a secretRef on envFrom.

{
  scope,
  lib,
  kix,
  availability,
}:

let
  name = scope.instanceName;

  mainSelectorLabels = scope.selectorLabels // {
    "app.kubernetes.io/type" = "master";
  };

  workerSelectorLabels = scope.selectorLabels // {
    "app.kubernetes.io/type" = "worker";
  };

in
{
  meta = {
    version = "1.74.2";
    description = "n8n workflow automation, a main instance and queue workers backed by PostgreSQL and Valkey";
    owner = "app-team";
    # The main process owns the scheduler and active webhooks, and n8n's
    # multi-main setup is an enterprise feature this package does not wire
    # up, so the main instance can never be made redundant: even a rolling
    # update is downtime.
    availability.max = "none";
  };

  # n8n 1.74 reaches Redis through QUEUE_BULL_REDIS_HOST (or cluster
  # nodes) and has no Sentinel client. With Sentinel on, the valkey Service
  # also routes to replicas, where Bull's writes fail with READONLY, and a
  # standalone valkey with several pods runs that many unrelated primaries.
  # So n8n asks its valkey for one standalone pod. That costs no redundancy
  # n8n has, since its main instance is already a single pod.
  deps.valkey = {
    config = {
      sentinel.enabled = false;
      replicaCount = 1;
    };
    # Catches a valkey the injection above does not reach, such as an import.
    assertions =
      dep:
      lib.optional (dep.out ? sentinelPort) {
        assertion = false;
        message = "n8n '${name}' needs a standalone valkey with one pod: n8n 1.74 has no Sentinel client, so its queue writes would reach read-only replicas through the valkey Service. Set sentinel.enabled = false and replicaCount = 1 on the valkey instance.";
      };
  };

  options = {
    image = kix.options.image {
      repository = "n8nio/n8n";
      tag = "1.74.2";
    };
    replicaCount = lib.mkOption {
      type = lib.types.int;
      # Single-writer at every level: the n8n main process owns the
      # scheduler, so a second one would double-run every trigger.
      default = kix.availability.pick availability {
        none = 1;
        pod = 1;
        node = 1;
        zone = 1;
      };
      description = ''
        Number of n8n main (UI/API) replicas. Pinned to one at every
        availability level (v2_discussions/145); see meta.availability.max.
      '';
    };
    worker = lib.mkOption {
      type = lib.types.anything;
      default = {
        enabled = true;
        # Workers are stateless queue consumers: one is enough when
        # downtime is fine, more once a pod or node loss must not stall
        # the queue. Defaults from the cluster's availability level
        # (v2_discussions/145).
        replicaCount = kix.availability.pick availability {
          none = 1;
          pod = 2;
          node = 3;
          zone = 3;
        };
        port = 5679;
        concurrency = 10;
        # The 8gears/n8n chart sets no resources. Workers run the same
        # workflow code as the main instance, so they get its defaults.
        resources = {
          requests = {
            cpu = "100m";
            memory = "256Mi";
          };
          limits = {
            cpu = "1";
            memory = "1Gi";
          };
        };
      };
    };
    port = lib.mkOption {
      type = lib.types.int;
      default = 5678;
    };
    servicePort = lib.mkOption {
      type = lib.types.int;
      default = 80;
    };
    resources = lib.mkOption {
      type = lib.types.anything;
      default = {
        requests = {
          cpu = "100m";
          memory = "256Mi";
        };
        limits = {
          cpu = "1";
          memory = "1Gi";
        };
      };
    };
    ingress = kix.options.ingress;
    env = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = ''
        Extra n8n environment variables, applied over the package's own.
        n8n runs with a read-only root filesystem, and
        N8N_RESTRICT_FILE_ACCESS_TO defaults to "/tmp", an emptyDir that
        does not survive a restart, so file nodes can read and write only
        there. The package mounts no other writable volume. Setting
        N8N_RESTRICT_FILE_ACCESS_TO here (";"-separated directories)
        widens what file nodes may read.
      '';
    };
    existingSecret = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
    database = lib.mkOption {
      type = lib.types.anything;
      default = {
        type = "postgresdb";
        name = "n8n";
        user = "n8n";
      };
    };
  };

  build = [
    (
      {
        self,
        config,
        clusterConfig,
        postgres,
        valkey,
        scope,
        kix,
        ...
      }:
      let
        # envFrom for main deployment: app configmap + secret.
        mainEnvFrom = [
          { configMapRef.name = self.configmap.out.name; }
          self.appSecret.out.envFrom
        ];

        # envFrom for worker deployment: app configmap + worker configmap + secret.
        workerEnvFrom = [
          { configMapRef.name = self.configmap.out.name; }
          { configMapRef.name = self.workerConfigmap.out.name; }
          self.appSecret.out.envFrom
        ];
      in
      {
        # --- Secret reference (dependency-tracked) ---
        appSecret = scope.mkSecretRef {
          name = if config.existingSecret != null then config.existingSecret else "${name}-app-secret";
          keys = [ ]; # keys unknown: external secret, used via envFrom
        };

        # --- ServiceAccount ---
        serviceAccount = scope.mkResource {
          apiVersion = "v1";
          kind = "ServiceAccount";
          name = "${name}";
        };

        # --- ConfigMap (environment variables) ---
        configmap = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "${name}-app-config";
          data = {
            # Database: derived from postgres DI dep
            DB_TYPE = config.database.type;
            DB_POSTGRESDB_HOST = postgres.out.fqdn;
            DB_POSTGRESDB_DATABASE = config.database.name;
            DB_POSTGRESDB_USER = config.database.user;
            # Redis / Queue: derived from valkey DI dep
            QUEUE_BULL_REDIS_HOST = valkey.out.fqdn;
            QUEUE_BULL_REDIS_PORT = valkey.out.port;
            # Execution mode: queue mode for workers
            EXECUTIONS_MODE = "queue";
            # The root filesystem is read-only, /tmp is an emptyDir and
            # N8N_BLOCK_FILE_ACCESS_TO_N8N_FILES (default true) blocks
            # ~/.n8n, so /tmp is the only place the Read/Write Files from
            # Disk node can write. Limiting file nodes to it makes a path
            # elsewhere fail with n8n's "not allowed" error, not EROFS.
            N8N_RESTRICT_FILE_ACCESS_TO = "/tmp";
          }
          // config.env;
        };

        # --- Worker ConfigMap (worker-specific overrides) ---
        workerConfigmap = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "${name}-worker-config";
          # A worker starts its /healthz server only when
          # QUEUE_HEALTH_CHECK_ACTIVE is true, and PORT does not apply to it.
          data = {
            QUEUE_HEALTH_CHECK_ACTIVE = "true";
            QUEUE_HEALTH_CHECK_PORT = toString config.worker.port;
          };
        };

        # --- Deployment (main: UI + API) ---
        deployment =
          {
            name = "${name}";
            spec = {
              replicas = config.replicaCount;
              revisionHistoryLimit = 3;
              selector.matchLabels = mainSelectorLabels;
              strategy.type = "Recreate";
              template = {
                metadata.annotations = {
                  "checksum/configmap" = self.configmap.out.identityHash;
                };
                spec = {
                  serviceAccountName = self.serviceAccount.out.name;
                  # The 8gears/n8n chart's value; n8n's own
                  # N8N_GRACEFUL_SHUTDOWN_TIMEOUT also defaults to 30s.
                  terminationGracePeriodSeconds = 30;
                  securityContext = {
                    fsGroup = 1000;
                    runAsNonRoot = true;
                    runAsUser = 1000;
                    runAsGroup = 1000;
                  };
                  containers = [
                    {
                      name = "n8n";
                      image = kix.image.ref config.image;
                      imagePullPolicy = config.image.pullPolicy;
                      envFrom = mainEnvFrom;
                      ports = [
                        (kix.port "http" config.port)
                      ];
                      # Probes follow the 8gears/n8n chart: n8n listens only
                      # after migrations, so the startup probe allows five
                      # minutes, and /healthz/readiness also reports the
                      # database connection.
                      startupProbe = {
                        httpGet = {
                          path = "/healthz";
                          port = "http";
                        };
                        periodSeconds = 10;
                        failureThreshold = 30;
                      };
                      livenessProbe = {
                        httpGet = {
                          path = "/healthz";
                          port = "http";
                        };
                        periodSeconds = 10;
                        timeoutSeconds = 1;
                        failureThreshold = 3;
                      };
                      readinessProbe = {
                        httpGet = {
                          path = "/healthz/readiness";
                          port = "http";
                        };
                        periodSeconds = 10;
                        timeoutSeconds = 1;
                        failureThreshold = 3;
                      };
                      resources = config.resources;
                      securityContext = {
                        allowPrivilegeEscalation = false;
                        readOnlyRootFilesystem = true;
                      };
                      volumeMounts = [
                        {
                          name = "data";
                          mountPath = "/home/node/.n8n";
                        }
                        {
                          name = "tmp";
                          mountPath = "/tmp";
                        }
                        # n8n compiles its static assets into ~/.cache on start.
                        {
                          name = "cache";
                          mountPath = "/home/node/.cache";
                        }
                      ];
                    }
                  ];
                  volumes = [
                    {
                      name = "data";
                      emptyDir = { };
                    }
                    {
                      name = "tmp";
                      emptyDir = { };
                    }
                    {
                      name = "cache";
                      emptyDir = { };
                    }
                  ];
                };
              };
            };
          }
          |> scope.mkDeployment;

        # --- Deployment (worker: queue workers) ---
        worker =
          if config.worker.enabled then
            {
              name = "${name}-worker";
              spec = {
                replicas = config.worker.replicaCount;
                revisionHistoryLimit = 3;
                selector.matchLabels = workerSelectorLabels;
                strategy.type = "Recreate";
                template = {
                  metadata.annotations = {
                    "checksum/configmap" = self.configmap.out.identityHash;
                  };
                  spec = {
                    serviceAccountName = self.serviceAccount.out.name;
                    terminationGracePeriodSeconds = 30;
                    securityContext = {
                      fsGroup = 1000;
                      runAsNonRoot = true;
                      runAsUser = 1000;
                      runAsGroup = 1000;
                    };
                    containers = [
                      {
                        name = "n8n-worker";
                        image = kix.image.ref config.image;
                        imagePullPolicy = config.image.pullPolicy;
                        command = [ "n8n" ];
                        args = [
                          "worker"
                          "--concurrency=${toString config.worker.concurrency}"
                        ];
                        envFrom = workerEnvFrom;
                        # Named "health" rather than "http": the worker
                        # serves only /healthz on it, and the main
                        # Deployment in this same instance already calls
                        # its port "http" with a different number.
                        ports = [
                          (kix.port "health" config.worker.port)
                        ];
                        livenessProbe = {
                          httpGet = {
                            path = "/healthz";
                            port = "health";
                          };
                          periodSeconds = 10;
                          timeoutSeconds = 1;
                          failureThreshold = 3;
                        };
                        readinessProbe = {
                          httpGet = {
                            path = "/healthz/readiness";
                            port = "health";
                          };
                          periodSeconds = 10;
                          timeoutSeconds = 1;
                          failureThreshold = 3;
                        };
                        resources = config.worker.resources;
                        securityContext = {
                          allowPrivilegeEscalation = false;
                          readOnlyRootFilesystem = true;
                        };
                        volumeMounts = [
                          {
                            name = "data";
                            mountPath = "/home/node/.n8n";
                          }
                          {
                            name = "tmp";
                            mountPath = "/tmp";
                          }
                          # n8n compiles its static assets into ~/.cache on start.
                          {
                            name = "cache";
                            mountPath = "/home/node/.cache";
                          }
                        ];
                      }
                    ];
                    volumes = [
                      {
                        name = "data";
                        emptyDir = { };
                      }
                      {
                        name = "tmp";
                        emptyDir = { };
                      }
                      {
                        name = "cache";
                        emptyDir = { };
                      }
                    ];
                  };
                };
              };
            }
            |> scope.mkDeployment
          else
            null;

        # --- Service ---
        service =
          self.deployment
          |> kix.service.fromWorkload {
            name = "${name}";
            ports = [
              {
                name = "http";
                port = config.servicePort;
                targetPort = config.port;
                protocol = "TCP";
              }
            ];
            outputs = {
              port = toString config.servicePort;
            };
            requires = lib.optional (self.worker != null) self.worker;
          }
          |> scope.mkResource;

        # --- Entry point ---
        root = self.service;
      }
    )
    (kix.expose { service = "service"; })
  ];
}
