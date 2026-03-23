# Immich server — kix package.
#
# Deploys the Immich API and web UI. Requires valkey (Redis-compatible)
# for job queues. Optionally connects to an immich-machine-learning
# instance for smart features (facial recognition, search, etc.).
#
# Dependencies:
#   valkey              — required, job queue backend
#   postgres            — required, database (needs pgvecto.rs extension)
#   storage             — required, persistent volume for photo library
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
  storage,
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

    # Storage validation — warn if PVC is undersized for a photo library
    parseSizeGi = s:
      let
        str = builtins.unsafeDiscardStringContext s;
        matchTi = builtins.match "([0-9]+)Ti" str;
        matchGi = builtins.match "([0-9]+)Gi" str;
        matchMi = builtins.match "([0-9]+)Mi" str;
      in
      if matchTi != null then (builtins.fromJSON (builtins.head matchTi)) * 1024
      else if matchGi != null then builtins.fromJSON (builtins.head matchGi)
      else if matchMi != null then (builtins.fromJSON (builtins.head matchMi)) / 1024
      else null;

    storageSizeGi = parseSizeGi storage.out.size;
    _storageWarning =
      if storageSizeGi != null && storageSizeGi < 50 then
        builtins.trace "warning: immich '${name}' library storage is ${builtins.unsafeDiscardStringContext storage.out.size} — recommended minimum is 50Gi for photo libraries"
          null
      else null;
  in
  builtins.seq _storageWarning
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
                volumeMounts = [
                  {
                    name = "library";
                    mountPath = "/usr/src/app/upload";
                  }
                ]
                ++ lib.optional hasConfig {
                  name = "config";
                  mountPath = "/config";
                };
              })
            ];
            volumes = [
              {
                name = "library";
                persistentVolumeClaim.claimName = storage.out.name;
              }
            ]
            ++ lib.optional hasConfig {
              name = "config";
              configMap.name = self.configMap.out.name;
            };
          };
        };
      };
    };

    # --- Server Service ---
    service = self.deployment
      |> scope.expose { name = "${name}-server"; }
      |> scope.mkResource;

    # --- Ingress (optional) ---
    ingress =
      if config.ingress.enabled then
        self.service
        |> scope.ingress {
          inherit name;
          host = config.ingress.host;
          className =
            if ingressNginx != null then
              ingressNginx.out.ingressClassName
            else
              config.ingress.className or "public";
          tls =
            lib.optional (config.ingress.tls.enabled or false) {
              hosts = [ config.ingress.host ];
              secretName = config.ingress.tls.secretName;
            };
          annotations = {
            "nginx.ingress.kubernetes.io/proxy-body-size" = "0";
          } // config.ingress.annotations;
        }
        |> (if clusterIssuer != null then clusterIssuer.out.withCert else lib.id)
        |> scope.mkResource
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
