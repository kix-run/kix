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
      port = 5679;
      concurrency = 10;
    };
    port = 5678;
    servicePort = 80;
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
      className = "public";
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
      name = "n8n";
      user = "n8n";
    };
    redis = {
      host = null;
      port = "6379";
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
    "app.kubernetes.io/type" = "master";
  };

  workerSelectorLabels = selectorLabels // {
    "app.kubernetes.io/type" = "worker";
  };

  # Secret name for credentials (used as secretRef on envFrom).
  secretName = if cfg.existingSecret != null then cfg.existingSecret else "${name}-app-secret";

in
self:
let
  # envFrom for main deployment: app configmap + secret.
  mainEnvFrom = [
    { configMapRef.name = "${self.configmap}"; }
    { secretRef.name = secretName; }
  ];

  # envFrom for worker deployment: app configmap + worker configmap + secret.
  workerEnvFrom = [
    { configMapRef.name = "${self.configmap}"; }
    { configMapRef.name = "${self.workerConfigmap}"; }
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
      DB_TYPE = cfg.database.type;
      DB_POSTGRESDB_HOST = dbHost;
      DB_POSTGRESDB_DATABASE = cfg.database.name;
      DB_POSTGRESDB_USER = cfg.database.user;
      # Redis / Queue
      QUEUE_BULL_REDIS_HOST = redisHost;
      QUEUE_BULL_REDIS_PORT = cfg.redis.port;
      # Execution mode — queue mode for workers
      EXECUTIONS_MODE = "queue";
    }
    // cfg.env;
  };

  # --- Worker ConfigMap (worker-specific overrides) ---
  workerConfigmap = scope.mkResource {
    apiVersion = "v1";
    kind = "ConfigMap";
    name = "${name}-worker-config";
    labels = commonLabels;
    data = {
      PORT = toString cfg.worker.port;
    };
  };

  # --- Deployment (main — UI + API) ---
  deployment = scope.mkResource {
    apiVersion = "apps/v1";
    kind = "Deployment";
    name = "${name}";
    labels = commonLabels;
    spec = {
      replicas = cfg.replicaCount;
      revisionHistoryLimit = 3;
      selector.matchLabels = mainSelectorLabels;
      strategy.type = "Recreate";
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
              image = "${cfg.image.repository}:${cfg.image.tag}";
              imagePullPolicy = cfg.image.pullPolicy;
              envFrom = mainEnvFrom;
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
              resources = cfg.resources;
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
    if cfg.worker.enabled then
      scope.mkResource {
        apiVersion = "apps/v1";
        kind = "Deployment";
        name = "${name}-worker";
        labels = commonLabels;
        spec = {
          replicas = cfg.worker.replicaCount;
          revisionHistoryLimit = 3;
          selector.matchLabels = workerSelectorLabels;
          strategy.type = "Recreate";
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
              };
              containers = [
                {
                  name = "n8n-worker";
                  image = "${cfg.image.repository}:${cfg.image.tag}";
                  imagePullPolicy = cfg.image.pullPolicy;
                  command = [ "n8n" ];
                  args = [
                    "worker"
                    "--concurrency=${toString cfg.worker.concurrency}"
                  ];
                  envFrom = workerEnvFrom;
                  ports = [
                    {
                      name = "http";
                      containerPort = cfg.worker.port;
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
          port = cfg.servicePort;
          targetPort = "http";
          protocol = "TCP";
        }
      ];
    };
    outputs = {
      port = toString cfg.servicePort;
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
                    port.number = cfg.servicePort;
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
