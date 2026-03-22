# Immich photo management platform — kix package.
#
# Deploys the Immich server (API/web UI) and machine-learning worker,
# backed by an external database and Valkey (Redis-compatible) for job queues.
#
# Resources: Deployment (server), Service (server), Deployment (ML),
# Service (ML), optional ConfigMap (immich config), optional Ingress.
#
# main = Service (server, port 2283).

{
  scope,
  lib,
  valkey ? null,
}:

let
  name = scope.instanceName;

  selectorLabels = {
    "app.kubernetes.io/name" = "immich";
    "app.kubernetes.io/instance" = name;
  };

  serverSelectorLabels = selectorLabels // {
    "app.kubernetes.io/component" = "server";
  };

  mlSelectorLabels = selectorLabels // {
    "app.kubernetes.io/component" = "machine-learning";
  };

in
{
  options = {
    server = lib.mkOption {
      type = lib.types.anything;
      default = {
        image = {
          repository = "ghcr.io/immich-app/immich-server";
          tag = "v2.0.0";
          pullPolicy = "IfNotPresent";
        };
        replicaCount = 1;
      };
    };
    machineLearning = lib.mkOption {
      type = lib.types.anything;
      default = {
        enabled = true;
        image = {
          repository = "ghcr.io/immich-app/immich-machine-learning";
          tag = "v2.0.0";
          pullPolicy = "IfNotPresent";
        };
        replicaCount = 1;
        persistence = {
          enabled = false;
          size = "10Gi";
          storageClass = null;
        };
      };
    };
    redis = lib.mkOption {
      type = lib.types.anything;
      default = {
        hostname = null;
      };
    };
    env = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Extra environment variables for the server container";
    };
    library = lib.mkOption {
      type = lib.types.anything;
      default = {
        existingClaim = null;
      };
    };
    configuration = lib.mkOption {
      type = lib.types.nullOr lib.types.anything;
      default = null;
      description = "Immich config (immich-config.yaml content as attrset). Null to disable.";
    };
    metrics = lib.mkOption {
      type = lib.types.anything;
      default = {
        enabled = false;
      };
    };
    ingress = lib.mkOption {
      type = lib.types.anything;
      default = {
        enabled = false;
        className = "public";
        host = "";
        annotations = { };
        tls = {
          enabled = false;
          secretName = "";
          issuer = "";
        };
      };
    };
  };

  build = { self, config, clusterConfig }:
  let
    # Resolve redis hostname: explicit config > valkey dependency > error.
    redisHostname =
      if config.redis.hostname != null then
        config.redis.hostname
      else if valkey != null then
        valkey.out.fqdn
      else
        throw "immich: redis.hostname must be set or a valkey dependency must be available";

    # ML service URL (internal reference via service FQDN).
    mlUrl = "http://${self.mlService.out.fqdn}:3003";

    hasConfig = config.configuration != null;

  in
  {

    # --- Optional: Immich configuration ConfigMap ---
    configMap =
      if hasConfig then
        scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "${name}-immich-config";
          data = {
            "immich-config.yaml" = builtins.toJSON config.configuration;
          };
        }
      else
        null;

    # --- Server Deployment ---
    serverDeployment = scope.mkResource {
      apiVersion = "apps/v1";
      kind = "Deployment";
      name = "${name}-server";
      spec = {
        replicas = config.server.replicaCount;
        selector.matchLabels = serverSelectorLabels;
        strategy.type = "RollingUpdate";
        template = {
          metadata.labels = serverSelectorLabels;
          spec = {
            containers = [
              ({
                name = "immich-server";
                image = "${config.server.image.repository}:${config.server.image.tag}";
                imagePullPolicy = config.server.image.pullPolicy;
                env = [
                  { name = "REDIS_HOSTNAME"; value = redisHostname; }
                  { name = "IMMICH_MACHINE_LEARNING_URL"; value = mlUrl; }
                ]
                ++ lib.optional hasConfig {
                  name = "IMMICH_CONFIG_FILE";
                  value = "/config/immich-config.yaml";
                }
                ++ lib.optional config.metrics.enabled {
                  name = "IMMICH_TELEMETRY_INCLUDE";
                  value = "all";
                }
                ++ lib.mapAttrsToList (k: v: { name = k; value = v; }) config.env;
                ports = [
                  { name = "http"; containerPort = 2283; protocol = "TCP"; }
                ]
                ++ lib.optionals config.metrics.enabled [
                  { name = "metrics-api"; containerPort = 8081; protocol = "TCP"; }
                  { name = "metrics-ms"; containerPort = 8082; protocol = "TCP"; }
                ];
                livenessProbe = {
                  httpGet = { path = "/api/server/ping"; port = "http"; };
                  periodSeconds = 10;
                  timeoutSeconds = 1;
                  failureThreshold = 3;
                };
                readinessProbe = {
                  httpGet = { path = "/api/server/ping"; port = "http"; };
                  periodSeconds = 10;
                  timeoutSeconds = 1;
                  failureThreshold = 3;
                };
                startupProbe = {
                  httpGet = { path = "/api/server/ping"; port = "http"; };
                  periodSeconds = 10;
                  timeoutSeconds = 1;
                  failureThreshold = 30;
                };
                volumeMounts = lib.optional (config.library.existingClaim != null) {
                  name = "library";
                  mountPath = "/usr/src/app/upload";
                }
                ++ lib.optional hasConfig {
                  name = "config";
                  mountPath = "/config";
                };
              })
            ];
            volumes = lib.optional (config.library.existingClaim != null) {
              name = "library";
              persistentVolumeClaim.claimName = config.library.existingClaim;
            }
            ++ lib.optional hasConfig {
              name = "config";
              configMap.name = self.configMap.out.name;
            };
          };
        };
      };
    };

    # --- Server Service ---
    serverService = scope.mkResource {
      apiVersion = "v1";
      kind = "Service";
      name = "${name}-server";
      spec = {
        type = "ClusterIP";
        selector = self.serverDeployment.out.selector;
        ports = [
          { name = "http"; port = 2283; targetPort = "http"; protocol = "TCP"; }
        ]
        ++ lib.optionals config.metrics.enabled [
          { name = "metrics-api"; port = 8081; targetPort = "metrics-api"; protocol = "TCP"; }
          { name = "metrics-ms"; port = 8082; targetPort = "metrics-ms"; protocol = "TCP"; }
        ];
      };
      outputs = {
        port = "2283";
      };
      requires =
        lib.optional (self.ingress != null) self.ingress
        ++ lib.optional (self.serviceMonitor != null) self.serviceMonitor
        ++ lib.optional (self.mlCachePvc != null) self.mlCachePvc;
    };

    # --- Machine Learning Deployment ---
    mlDeployment =
      if config.machineLearning.enabled then
        scope.mkResource {
          apiVersion = "apps/v1";
          kind = "Deployment";
          name = "${name}-machine-learning";
          spec = {
            replicas = config.machineLearning.replicaCount;
            selector.matchLabels = mlSelectorLabels;
            strategy.type = "RollingUpdate";
            template = {
              metadata.labels = mlSelectorLabels;
              spec = {
                containers = [
                  {
                    name = "immich-machine-learning";
                    image = "${config.machineLearning.image.repository}:${config.machineLearning.image.tag}";
                    imagePullPolicy = config.machineLearning.image.pullPolicy;
                    env = [
                      { name = "TRANSFORMERS_CACHE"; value = "/cache"; }
                      { name = "HF_XET_CACHE"; value = "/cache/huggingface-xet"; }
                      { name = "MPLCONFIGDIR"; value = "/cache/matplotlib-config"; }
                    ];
                    ports = [
                      { name = "http"; containerPort = 3003; protocol = "TCP"; }
                    ];
                    livenessProbe = {
                      httpGet = { path = "/ping"; port = "http"; };
                      periodSeconds = 10;
                      timeoutSeconds = 1;
                      failureThreshold = 3;
                    };
                    readinessProbe = {
                      httpGet = { path = "/ping"; port = "http"; };
                      periodSeconds = 10;
                      timeoutSeconds = 1;
                      failureThreshold = 3;
                    };
                    startupProbe = {
                      httpGet = { path = "/ping"; port = "http"; };
                      periodSeconds = 10;
                      timeoutSeconds = 1;
                      failureThreshold = 60;
                    };
                    volumeMounts = [
                      { name = "cache"; mountPath = "/cache"; }
                    ];
                  }
                ];
                volumes = [
                  (if config.machineLearning.persistence.enabled then {
                    name = "cache";
                    persistentVolumeClaim.claimName = self.mlCachePvc.out.name;
                  } else {
                    name = "cache";
                    emptyDir = { };
                  })
                ];
              };
            };
          };
        }
      else
        null;

    # --- ML cache PVC (optional) ---
    mlCachePvc =
      if config.machineLearning.enabled && config.machineLearning.persistence.enabled then
        scope.mkResource {
          apiVersion = "v1";
          kind = "PersistentVolumeClaim";
          name = "${name}-ml-cache";
          spec = {
            accessModes = [ "ReadWriteOnce" ];
            resources.requests.storage = config.machineLearning.persistence.size;
          } // lib.optionalAttrs (config.machineLearning.persistence.storageClass != null) {
            storageClassName = config.machineLearning.persistence.storageClass;
          };
        }
      else
        null;

    # --- Machine Learning Service ---
    mlService =
      if config.machineLearning.enabled then
        scope.mkResource {
          apiVersion = "v1";
          kind = "Service";
          name = "${name}-machine-learning";
          spec = {
            type = "ClusterIP";
            selector = self.mlDeployment.out.selector;
            ports = [
              { name = "http"; port = 3003; targetPort = "http"; protocol = "TCP"; }
            ];
          };
        }
      else
        null;

    # --- Ingress (optional) ---
    ingress =
      if config.ingress.enabled then
        scope.mkResource {
          apiVersion = "networking.k8s.io/v1";
          kind = "Ingress";
          name = "${name}";
          annotations = {
            "nginx.ingress.kubernetes.io/proxy-body-size" = "0";
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
                      name = self.serverService.out.name;
                      port.number = 2283;
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

    # --- ServiceMonitor (optional) ---
    serviceMonitor =
      if config.metrics.enabled then
        scope.mkClusterResource {
          apiVersion = "monitoring.coreos.com/v1";
          kind = "ServiceMonitor";
          name = "${name}";
          spec = {
            namespaceSelector.matchNames = [ scope.namespaceName ];
            selector.matchLabels = self.serverService.out.selector;
            endpoints = [
              { port = "metrics-api"; scheme = "http"; }
              { port = "metrics-ms"; scheme = "http"; }
            ];
          };
        }
      else
        null;

    # --- Entry point ---
    main = self.serverService;
  };
}
