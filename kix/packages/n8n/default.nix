# n8n workflow automation platform — kix package.
#
# Deploys the n8n main instance (UI/API) and queue workers backed by
# PostgreSQL (via StackGres) and Valkey (Redis-compatible) for Bull
# queue processing.
#
# Dependencies:
#   postgres            — required, database
#   valkey              — required, Redis-compatible queue backend
#   ingressNginx        — optional, auto-creates ingress when present (+ host is set)
#   clusterIssuer       — optional, auto-enables TLS when present
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
  };

  options = {
    image = lib.mkOption {
      type = lib.types.anything;
      default = {
        repository = "n8nio/n8n";
        tag = "1.74.2";
        pullPolicy = "IfNotPresent";
      };
    };
    replicaCount = lib.mkOption {
      type = lib.types.int;
      default = 1;
    };
    worker = lib.mkOption {
      type = lib.types.anything;
      default = {
        enabled = true;
        replicaCount = 3;
        port = 5679;
        concurrency = 10;
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
          keys = [ ]; # keys unknown — external secret, used via envFrom
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
            # Database — derived from postgres DI dep
            DB_TYPE = config.database.type;
            DB_POSTGRESDB_HOST = postgres.out.fqdn;
            DB_POSTGRESDB_DATABASE = config.database.name;
            DB_POSTGRESDB_USER = config.database.user;
            # Redis / Queue — derived from valkey DI dep
            QUEUE_BULL_REDIS_HOST = valkey.out.primaryFqdn;
            QUEUE_BULL_REDIS_PORT = valkey.out.port;
            # Execution mode — queue mode for workers
            EXECUTIONS_MODE = "queue";
          }
          // config.env;
        };

        # --- Worker ConfigMap (worker-specific overrides) ---
        workerConfigmap = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "${name}-worker-config";
          data = {
            PORT = toString config.worker.port;
          };
        };

        # --- Deployment (main — UI + API) ---
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
                  securityContext = {
                    fsGroup = 1000;
                    runAsNonRoot = true;
                    runAsUser = 1000;
                    runAsGroup = 1000;
                  };
                  containers = [
                    {
                      name = "n8n";
                      image = "${config.image.repository}:${config.image.tag}";
                      imagePullPolicy = config.image.pullPolicy;
                      envFrom = mainEnvFrom;
                      ports = [
                        (kix.port "http" config.port)
                      ];
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
                          path = "/healthz";
                          port = "http";
                        };
                        periodSeconds = 10;
                        timeoutSeconds = 1;
                        failureThreshold = 3;
                      };
                      resources = config.resources;
                      volumeMounts = [
                        {
                          name = "data";
                          mountPath = "/home/node/.n8n";
                        }
                      ];
                    }
                  ];
                  volumes = [
                    { name = "data"; }
                  ];
                };
              };
            };
          }
          |> scope.mkDeployment;

        # --- Deployment (worker — queue workers) ---
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
                    securityContext = {
                      fsGroup = 1000;
                      runAsNonRoot = true;
                      runAsUser = 1000;
                      runAsGroup = 1000;
                    };
                    containers = [
                      {
                        name = "n8n-worker";
                        image = "${config.image.repository}:${config.image.tag}";
                        imagePullPolicy = config.image.pullPolicy;
                        command = [ "n8n" ];
                        args = [
                          "worker"
                          "--concurrency=${toString config.worker.concurrency}"
                        ];
                        envFrom = workerEnvFrom;
                        ports = [
                          (kix.port "http" config.worker.port)
                        ];
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
                            path = "/healthz";
                            port = "http";
                          };
                          periodSeconds = 10;
                          timeoutSeconds = 1;
                          failureThreshold = 3;
                        };
                        volumeMounts = [
                          {
                            name = "data";
                            mountPath = "/home/node/.n8n";
                          }
                        ];
                      }
                    ];
                    volumes = [
                      { name = "data"; }
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
                targetPort = "http";
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
