# Immich server — kix package.
#
# Deploys the Immich API and web UI. Requires valkey (Redis-compatible)
# for job queues. Optionally connects to an immich-machine-learning
# instance for smart features (facial recognition, search, etc.).
#
# Dependencies:
#   valkey              — required, job queue backend
#   postgres            — required, database (needs pgvecto.rs extension)
#   machineLearning     — optional, ML inference service
#   ingressNginx        — optional, provides IngressClass for ingress
#   clusterIssuer       — optional, provides withCert transformer for TLS
#
# Resources: Deployment, Service, optional ConfigMap, optional Ingress,
# optional ServiceMonitor.
#
# main = Service (port 2283).

{
  scope,
  lib,
  valkey,
  postgres,
  machineLearning ? null,
  ingressNginx ? null,
  clusterIssuer ? null,
}:

let
  name = scope.instanceName;
in
{
  options = {
    image = lib.mkOption {
      type = lib.types.anything;
      default = {
        repository = "ghcr.io/immich-app/immich-server";
        tag = "v2.0.0";
        pullPolicy = "IfNotPresent";
      };
    };
    replicaCount = lib.mkOption {
      type = lib.types.int;
      default = 1;
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
        host = "";
        annotations = { };
        tls = {
          enabled = false;
          secretName = "";
        };
      };
    };
  };

  build = { self, config, clusterConfig }:
  let
    hasConfig = config.configuration != null;
    hasMl = machineLearning != null;
    mlUrl =
      if hasMl then
        "http://${machineLearning.out.fqdn}:${machineLearning.out.port}"
      else
        null;
  in
  {

    # --- Optional: Immich configuration ConfigMap ---
    configMap =
      if hasConfig then
        scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "${name}-config";
          data = {
            "immich-config.yaml" = builtins.toJSON config.configuration;
          };
        }
      else
        null;

    # --- Server Deployment ---
    deployment = scope.mkResource {
      apiVersion = "apps/v1";
      kind = "Deployment";
      name = "${name}-server";
      spec = {
        replicas = config.replicaCount;
        selector.matchLabels = scope.selectorLabels;
        strategy.type = "RollingUpdate";
        template = {
          metadata.labels = scope.selectorLabels;
          spec = {
            containers = [
              ({
                name = "immich-server";
                image = "${config.image.repository}:${config.image.tag}";
                imagePullPolicy = config.image.pullPolicy;
                env = [
                  { name = "DB_HOSTNAME"; value = postgres.out.fqdn; }
                  { name = "DB_PORT"; value = postgres.out.port or "5432"; }
                  { name = "REDIS_HOSTNAME"; value = valkey.out.fqdn; }
                ]
                ++ lib.optional hasMl {
                  name = "IMMICH_MACHINE_LEARNING_URL";
                  value = mlUrl;
                }
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
    service = scope.mkResource {
      apiVersion = "v1";
      kind = "Service";
      name = "${name}-server";
      spec = {
        type = "ClusterIP";
        selector = self.deployment.out.selector;
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
        ++ lib.optional (self.serviceMonitor != null) self.serviceMonitor;
    };

    # --- Ingress (optional) ---
    ingress =
      if config.ingress.enabled then
        scope.mkResource (
          {
            apiVersion = "networking.k8s.io/v1";
            kind = "Ingress";
            name = name;
            annotations = {
              "nginx.ingress.kubernetes.io/proxy-body-size" = "0";
            }
            // config.ingress.annotations;
            spec = {
              ingressClassName =
                if ingressNginx != null then
                  ingressNginx.out.ingressClassName
                else
                  config.ingress.className or "public";
              rules = [
                {
                  host = config.ingress.host;
                  http.paths = [
                    {
                      path = "/";
                      pathType = "Prefix";
                      backend.service = {
                        name = self.service.out.name;
                        port.number = 2283;
                      };
                    }
                  ];
                }
              ];
            }
            // lib.optionalAttrs (config.ingress.tls.enabled or false) {
              tls = [
                {
                  hosts = [ config.ingress.host ];
                  secretName = config.ingress.tls.secretName;
                }
              ];
            };
          }
          |> (if clusterIssuer != null then clusterIssuer.out.withCert else lib.id)
        )
      else
        null;

    # --- ServiceMonitor (optional) ---
    serviceMonitor =
      if config.metrics.enabled then
        scope.mkClusterResource {
          apiVersion = "monitoring.coreos.com/v1";
          kind = "ServiceMonitor";
          name = name;
          spec = {
            namespaceSelector.matchNames = [ scope.namespaceName ];
            selector.matchLabels = self.service.out.selector;
            endpoints = [
              { port = "metrics-api"; scheme = "http"; }
              { port = "metrics-ms"; scheme = "http"; }
            ];
          };
        }
      else
        null;

    # --- Entry point ---
    main = self.service;
  };
}
