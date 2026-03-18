# n8n workflow automation platform — kix package.
#
# Deploys the n8n main instance (UI/API) and queue workers backed by
# PostgreSQL (via StackGres) and Valkey (Redis-compatible) for Bull
# queue processing.
#
# Resources: ServiceAccount, ConfigMap (env), Deployment (main),
# Deployment (worker), Service (web UI), Ingress (optional).
#
# main = Service (port 5678).
# External secrets (DB password, encryption key, Redis password)
# are expected to be managed externally (e.g. via Infisical).

{
  scope,
  config,
  lib,
  postgres ? null,
  valkey ? null,
}:

let
  name = scope.instanceName;

  cfg = scope.defaults config {
    image = {
      repository = "n8nio/n8n";
      tag = "1.74.2";
      pullPolicy = "IfNotPresent";
    };
    replicaCount = 1;
    worker = {
      enabled = true;
      replicaCount = 3;
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
    port = 5678;
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
    ingress = {
      enabled = false;
      className = "public-v2";
      host = "";
      tls = {
        enabled = false;
        secretName = "";
        issuer = "";
      };
      annotations = { };
    };
    env = { };
    existingSecret = null;
    database = {
      type = "postgresdb";
      host = null;
      port = "5432";
      name = "n8n";
      user = "n8n";
    };
    redis = {
      host = null;
      port = "6379";
    };
    encryption = {
      existingSecret = null;
    };
  };

  # Resolve database host: explicit config > postgres dependency fqdn > error.
  dbHost =
    if cfg.database.host != null then
      cfg.database.host
    else if postgres != null then
      postgres.fqdn
    else
      throw "n8n: database.host must be set or a postgres dependency must be available";

  # Resolve redis host: explicit config > valkey dependency fqdn > error.
  redisHost =
    if cfg.redis.host != null then
      cfg.redis.host
    else if valkey != null then
      valkey.fqdn
    else
      throw "n8n: redis.host must be set or a valkey dependency must be available";

  selectorLabels = {
    "app.kubernetes.io/name" = "n8n";
    "app.kubernetes.io/instance" = name;
  };

  commonLabels = selectorLabels;

  mainSelectorLabels = selectorLabels // {
    "app.kubernetes.io/component" = "main";
  };

  workerSelectorLabels = selectorLabels // {
    "app.kubernetes.io/component" = "worker";
  };

  # Secret name for credentials.
  secretName = if cfg.existingSecret != null then cfg.existingSecret else "${name}-secrets";

  # Environment variables shared between main and worker containers.
  commonEnvFrom = [
    { configMapRef.name = "\${${placeholder "configmap"}}"; }
  ];

  commonEnv = [
    {
      name = "DB_POSTGRESDB_PASSWORD";
      valueFrom.secretKeyRef = {
        name = secretName;
        key = "DB_POSTGRESDB_PASSWORD";
      };
    }
    {
      name = "N8N_ENCRYPTION_KEY";
      valueFrom.secretKeyRef = {
        name = if cfg.encryption.existingSecret != null then cfg.encryption.existingSecret else secretName;
        key = "N8N_ENCRYPTION_KEY";
      };
    }
    {
      name = "QUEUE_BULL_REDIS_PASSWORD";
      valueFrom.secretKeyRef = {
        name = secretName;
        key = "QUEUE_BULL_REDIS_PASSWORD";
      };
    }
  ];

  # Placeholder replaced in self: block with actual configmap ref.
  placeholder = _: "will-be-replaced";

in
self:
let
  # Rebuild envFrom with the actual configmap reference.
  envFrom = [
    { configMapRef.name = "${self.configmap}"; }
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
    name = "${name}-config";
    labels = commonLabels;
    data = {
      N8N_PORT = toString cfg.port;
      N8N_PROTOCOL = "http";
      NODE_ENV = "production";
      GENERIC_TIMEZONE = "UTC";
      # Database
      DB_TYPE = cfg.database.type;
      DB_POSTGRESDB_HOST = dbHost;
      DB_POSTGRESDB_PORT = cfg.database.port;
      DB_POSTGRESDB_DATABASE = cfg.database.name;
      DB_POSTGRESDB_USER = cfg.database.user;
      # Redis / Queue
      QUEUE_BULL_REDIS_HOST = redisHost;
      QUEUE_BULL_REDIS_PORT = cfg.redis.port;
      QUEUE_HEALTH_CHECK_ACTIVE = "true";
      # Execution mode — queue mode for workers
      EXECUTIONS_MODE = "queue";
    }
    // cfg.env;
  };

  # --- Deployment (main — UI + API) ---
  deployment = scope.mkResource {
    apiVersion = "apps/v1";
    kind = "Deployment";
    name = "${name}";
    labels = commonLabels // {
      "app.kubernetes.io/component" = "main";
    };
    spec = {
      replicas = cfg.replicaCount;
      revisionHistoryLimit = 3;
      selector.matchLabels = mainSelectorLabels;
      template = {
        metadata = {
          labels = mainSelectorLabels;
          annotations = {
            "checksum/configmap" = "\${${self.configmap}}";
          };
        };
        spec = {
          serviceAccountName = "${self.serviceAccount}";
          securityContext = {
            fsGroup = 1000;
            runAsNonRoot = true;
            runAsUser = 1000;
            runAsGroup = 1000;
            seccompProfile.type = "RuntimeDefault";
          };
          containers = [
            {
              name = "n8n";
              image = "${cfg.image.repository}:${cfg.image.tag}";
              imagePullPolicy = cfg.image.pullPolicy;
              inherit envFrom;
              env = commonEnv;
              ports = [
                {
                  name = "http";
                  containerPort = cfg.port;
                  protocol = "TCP";
                }
              ];
              livenessProbe = {
                httpGet = {
                  path = "/healthz";
                  port = "http";
                };
                initialDelaySeconds = 30;
                periodSeconds = 10;
                timeoutSeconds = 5;
                failureThreshold = 5;
              };
              readinessProbe = {
                httpGet = {
                  path = "/healthz";
                  port = "http";
                };
                initialDelaySeconds = 15;
                periodSeconds = 10;
                timeoutSeconds = 5;
                failureThreshold = 3;
              };
              resources = cfg.resources;
              securityContext = {
                allowPrivilegeEscalation = false;
                capabilities.drop = [ "ALL" ];
                readOnlyRootFilesystem = false;
              };
            }
          ];
        };
      };
    };
  };

  # --- Deployment (worker — queue workers) ---
  worker =
    if cfg.worker.enabled then
      scope.mkResource {
        apiVersion = "apps/v1";
        kind = "Deployment";
        name = "${name}-worker";
        labels = commonLabels // {
          "app.kubernetes.io/component" = "worker";
        };
        spec = {
          replicas = cfg.worker.replicaCount;
          revisionHistoryLimit = 3;
          selector.matchLabels = workerSelectorLabels;
          template = {
            metadata = {
              labels = workerSelectorLabels;
              annotations = {
                "checksum/configmap" = "\${${self.configmap}}";
              };
            };
            spec = {
              serviceAccountName = "${self.serviceAccount}";
              securityContext = {
                fsGroup = 1000;
                runAsNonRoot = true;
                runAsUser = 1000;
                runAsGroup = 1000;
                seccompProfile.type = "RuntimeDefault";
              };
              containers = [
                {
                  name = "n8n-worker";
                  image = "${cfg.image.repository}:${cfg.image.tag}";
                  imagePullPolicy = cfg.image.pullPolicy;
                  command = [
                    "n8n"
                    "worker"
                  ];
                  inherit envFrom;
                  env = commonEnv;
                  livenessProbe = {
                    httpGet = {
                      path = "/healthz";
                      port = 5678;
                    };
                    initialDelaySeconds = 30;
                    periodSeconds = 10;
                    timeoutSeconds = 5;
                    failureThreshold = 5;
                  };
                  readinessProbe = {
                    httpGet = {
                      path = "/healthz";
                      port = 5678;
                    };
                    initialDelaySeconds = 15;
                    periodSeconds = 10;
                    timeoutSeconds = 5;
                    failureThreshold = 3;
                  };
                  resources = cfg.worker.resources;
                  securityContext = {
                    allowPrivilegeEscalation = false;
                    capabilities.drop = [ "ALL" ];
                    readOnlyRootFilesystem = false;
                  };
                }
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
          port = cfg.port;
          targetPort = "http";
          protocol = "TCP";
        }
      ];
    };
    outputs = {
      port = toString cfg.port;
    };
    requires = [ self.deployment ] ++ lib.optional (self.worker != null) self.worker;
  };

  # --- Ingress (optional) ---
  ingress =
    if cfg.ingress.enabled then
      scope.mkResource {
        apiVersion = "networking.k8s.io/v1";
        kind = "Ingress";
        name = "${name}";
        labels = commonLabels;
        annotations = {
          "kubernetes.io/ingress.class" = cfg.ingress.className;
        }
        // lib.optionalAttrs (cfg.ingress.tls.enabled && cfg.ingress.tls.issuer != "") {
          "cert-manager.io/cluster-issuer" = cfg.ingress.tls.issuer;
        }
        // cfg.ingress.annotations;
        spec = {
          ingressClassName = cfg.ingress.className;
          rules = [
            {
              host = cfg.ingress.host;
              http.paths = [
                {
                  path = "/";
                  pathType = "Prefix";
                  backend.service = {
                    name = "${self.service}";
                    port.number = cfg.port;
                  };
                }
              ];
            }
          ];
        }
        // lib.optionalAttrs cfg.ingress.tls.enabled {
          tls = [
            {
              hosts = [ cfg.ingress.host ];
              secretName = cfg.ingress.tls.secretName;
            }
          ];
        };
        requires = [ self.service ];
      }
    else
      null;

  # --- Entry point ---
  main = self.service;
}
