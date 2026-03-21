# n8n workflow automation platform — kix package.
#
# Deploys the n8n main instance (UI/API) and queue workers backed by
# PostgreSQL (via StackGres) and Valkey (Redis-compatible) for Bull
# queue processing.
#
# Resources: ServiceAccount, ConfigMap (env), Deployment (main),
# Deployment (worker), Service (web UI), Ingress (optional).
#
# main = Service (port 80 by default, proxied to container port 5678).
# External secrets (DB password, encryption key, Redis password)
# are expected to be managed externally (e.g. via Infisical) and
# injected via existingSecret as a secretRef on envFrom.

{
  scope,
  lib,
  postgres ? null,
  valkey ? null,
}:

let
  name = scope.instanceName;

  selectorLabels = {
    "app.kubernetes.io/name" = "n8n";
    "app.kubernetes.io/instance" = name;
  };

  commonLabels = selectorLabels;

  mainSelectorLabels = selectorLabels // {
    "app.kubernetes.io/type" = "master";
  };

  workerSelectorLabels = selectorLabels // {
    "app.kubernetes.io/type" = "worker";
  };

in
{
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
    ingress = lib.mkOption {
      type = lib.types.anything;
      default = {
        enabled = false;
        className = "public";
        host = "";
        tls = {
          enabled = false;
          secretName = "";
          issuer = "";
        };
        annotations = { };
      };
    };
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
        host = null;
        name = "n8n";
        user = "n8n";
      };
    };
    redis = lib.mkOption {
      type = lib.types.anything;
      default = {
        host = null;
        port = "6379";
      };
    };
  };

  build = { self, config, clusterConfig }:
  let
    # Resolve database host: explicit config > postgres dependency fqdn > error.
    dbHost =
      if config.database.host != null then
        config.database.host
      else if postgres != null then
        postgres.out.fqdn
      else
        throw "n8n: database.host must be set or a postgres dependency must be available";

    # Resolve redis host: explicit config > valkey dependency fqdn > error.
    redisHost =
      if config.redis.host != null then
        config.redis.host
      else if valkey != null then
        valkey.out.fqdn
      else
        throw "n8n: redis.host must be set or a valkey dependency must be available";

    # Secret name for credentials (used as secretRef on envFrom).
    secretName = if config.existingSecret != null then config.existingSecret else "${name}-app-secret";

    # envFrom for main deployment: app configmap + secret.
    mainEnvFrom = [
      { configMapRef.name = self.configmap.out.name; }
      { secretRef.name = secretName; }
    ];

    # envFrom for worker deployment: app configmap + worker configmap + secret.
    workerEnvFrom = [
      { configMapRef.name = self.configmap.out.name; }
      { configMapRef.name = self.workerConfigmap.out.name; }
      { secretRef.name = secretName; }
    ];
  in
  {

    # --- ServiceAccount ---
    serviceAccount = scope.mkResource {
      apiVersion = "v1";
      kind = "ServiceAccount";
      name = "${name}";
      labels = commonLabels;
    };

    # --- ConfigMap (environment variables) ---
    configmap = scope.mkResource {
      apiVersion = "v1";
      kind = "ConfigMap";
      name = "${name}-app-config";
      labels = commonLabels;
      data = {
        # Database
        DB_TYPE = config.database.type;
        DB_POSTGRESDB_HOST = dbHost;
        DB_POSTGRESDB_DATABASE = config.database.name;
        DB_POSTGRESDB_USER = config.database.user;
        # Redis / Queue
        QUEUE_BULL_REDIS_HOST = redisHost;
        QUEUE_BULL_REDIS_PORT = config.redis.port;
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
      labels = commonLabels;
      data = {
        PORT = toString config.worker.port;
      };
    };

    # --- Deployment (main — UI + API) ---
    deployment = scope.mkResource {
      apiVersion = "apps/v1";
      kind = "Deployment";
      name = "${name}";
      labels = commonLabels;
      spec = {
        replicas = config.replicaCount;
        revisionHistoryLimit = 3;
        selector.matchLabels = mainSelectorLabels;
        strategy.type = "Recreate";
        template = {
          metadata = {
            labels = mainSelectorLabels;
            annotations = {
              "checksum/configmap" = self.configmap.out.identityHash;
            };
          };
          spec = {
            serviceAccountName = self.serviceAccount.out.name;
            securityContext = {
              fsGroup = 1000;
              runAsNonRoot = true;
              runAsUser = 1000;
              runAsGroup = 1000;
            };
            affinity = {
              podAntiAffinity = {
                preferredDuringSchedulingIgnoredDuringExecution = [
                  {
                    weight = 100;
                    podAffinityTerm = {
                      labelSelector = {
                        matchExpressions = [
                          {
                            key = "app.kubernetes.io/name";
                            operator = "In";
                            values = [ "n8n" ];
                          }
                        ];
                      };
                      topologyKey = "kubernetes.io/hostname";
                    };
                  }
                ];
              };
            };
            containers = [
              {
                name = "n8n";
                image = "${config.image.repository}:${config.image.tag}";
                imagePullPolicy = config.image.pullPolicy;
                envFrom = mainEnvFrom;
                ports = [
                  {
                    name = "http";
                    containerPort = config.port;
                    protocol = "TCP";
                  }
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
    };

    # --- Deployment (worker — queue workers) ---
    worker =
      if config.worker.enabled then
        scope.mkResource {
          apiVersion = "apps/v1";
          kind = "Deployment";
          name = "${name}-worker";
          labels = commonLabels;
          spec = {
            replicas = config.worker.replicaCount;
            revisionHistoryLimit = 3;
            selector.matchLabels = workerSelectorLabels;
            strategy.type = "Recreate";
            template = {
              metadata = {
                labels = workerSelectorLabels;
                annotations = {
                  "checksum/configmap" = self.configmap.out.identityHash;
                };
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
                      {
                        name = "http";
                        containerPort = config.worker.port;
                        protocol = "TCP";
                      }
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
      else
        null;

    # --- Service ---
    service = scope.mkResource {
      apiVersion = "v1";
      kind = "Service";
      name = "${name}";
      labels = commonLabels;
      spec = {
        type = "ClusterIP";
        selector = mainSelectorLabels;
        ports = [
          {
            name = "http";
            port = config.servicePort;
            targetPort = "http";
            protocol = "TCP";
          }
        ];
      };
      outputs = {
        port = toString config.servicePort;
      };
      requires = [ self.deployment ] ++ lib.optional (self.worker != null) self.worker;
    };

    # --- Ingress (optional) ---
    ingress =
      if config.ingress.enabled then
        scope.mkResource {
          apiVersion = "networking.k8s.io/v1";
          kind = "Ingress";
          name = "${name}";
          labels = commonLabels;
          annotations = {
            "kubernetes.io/ingress.class" = config.ingress.className;
          }
          // lib.optionalAttrs (config.ingress.tls.enabled && config.ingress.tls.issuer != "") {
            "cert-manager.io/cluster-issuer" = config.ingress.tls.issuer;
          }
          // config.ingress.annotations;
          spec = {
            ingressClassName = config.ingress.className;
            rules = [
              {
                host = config.ingress.host;
                http.paths = [
                  {
                    path = "/";
                    pathType = "Prefix";
                    backend.service = {
                      name = self.service.out.name;
                      port.number = config.servicePort;
                    };
                  }
                ];
              }
            ];
          }
          // lib.optionalAttrs config.ingress.tls.enabled {
            tls = [
              {
                hosts = [ config.ingress.host ];
                secretName = config.ingress.tls.secretName;
              }
            ];
          };
        }
      else
        null;

    # --- Entry point ---
    main = self.service;
  };
}
