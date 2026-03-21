# Metabase analytics/BI platform — kix package.
#
# Deploys Metabase backed by PostgreSQL (via StackGres). Simple
# single-deployment architecture with optional Ingress.
#
# Resources: Deployment (web), Service (web, port 80 -> 3000),
# Ingress (frontend, optional).
#
# main = Service (port 80).
# External secret expected to contain DB connection env vars.

{
  scope,
  lib,
  postgres ? null,
}:

let
  name = scope.instanceName;

  selectorLabels = {
    "app" = "metabase";
  };

  commonLabels = selectorLabels;

in
{
  options = {
    image = lib.mkOption {
      type = lib.types.anything;
      default = {
        repository = "docker.io/metabase/metabase";
        tag = "v0.50.34";
        pullPolicy = "IfNotPresent";
      };
    };
    replicaCount = lib.mkOption {
      type = lib.types.int;
      default = 2;
    };
    port = lib.mkOption {
      type = lib.types.int;
      default = 3000;
    };
    servicePort = lib.mkOption {
      type = lib.types.int;
      default = 80;
    };
    resources = lib.mkOption {
      type = lib.types.anything;
      default = {
        limits = {
          cpu = "2";
          memory = "4Gi";
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
          secretName = "tls";
          issuer = "";
        };
        annotations = { };
      };
    };
    existingSecret = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
    database = lib.mkOption {
      type = lib.types.anything;
      default = {
        type = "postgres";
      };
    };
    siteUrl = lib.mkOption {
      type = lib.types.str;
      default = "";
    };
    timezone = lib.mkOption {
      type = lib.types.str;
      default = "America/Toronto";
    };
    emojiInLogs = lib.mkOption {
      type = lib.types.str;
      default = "1";
    };
    jettyHost = lib.mkOption {
      type = lib.types.str;
      default = "0.0.0.0";
    };
    env = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
    };
    livenessProbe = lib.mkOption {
      type = lib.types.anything;
      default = {
        path = "/";
        initialDelaySeconds = 120;
        periodSeconds = 10;
        timeoutSeconds = 30;
        failureThreshold = 6;
      };
    };
    readinessProbe = lib.mkOption {
      type = lib.types.anything;
      default = {
        path = "/";
        initialDelaySeconds = 30;
        periodSeconds = 5;
        timeoutSeconds = 3;
        failureThreshold = 3;
      };
    };
  };

  build = { self, config, clusterConfig }:
  let
    # Secret name for credentials.
    secretName =
      if config.existingSecret != null then config.existingSecret else "${name}-secrets";

    # Build env list from config.
    envVars = [
      {
        name = "JAVA_TIMEZONE";
        value = config.timezone;
      }
      {
        name = "MB_DB_TYPE";
        value = config.database.type;
      }
      {
        name = "MB_EMOJI_IN_LOGS";
        value = config.emojiInLogs;
      }
      {
        name = "MB_JETTY_HOST";
        value = config.jettyHost;
      }
      {
        name = "MB_JETTY_PORT";
        value = toString config.port;
      }
    ]
    ++ lib.optional (config.siteUrl != "") {
      name = "MB_SITE_URL";
      value = config.siteUrl;
    }
    ++ lib.mapAttrsToList (k: v: { name = k; value = v; }) config.env;

  in
  {

    # --- Deployment ---
    deployment = scope.mkResource {
      apiVersion = "apps/v1";
      kind = "Deployment";
      name = "web";
      labels = commonLabels;
      spec = {
        replicas = config.replicaCount;
        selector.matchLabels = selectorLabels;
        template = {
          metadata = {
            labels = selectorLabels;
          };
          spec = {
            containers = [
              {
                name = "web";
                image = "${config.image.repository}:${config.image.tag}";
                imagePullPolicy = config.image.pullPolicy;
                env = envVars;
                envFrom = [
                  { secretRef.name = secretName; }
                ];
                ports = [
                  {
                    containerPort = config.port;
                    protocol = "TCP";
                  }
                ];
                livenessProbe = {
                  httpGet = {
                    path = config.livenessProbe.path;
                    port = config.port;
                    scheme = "HTTP";
                  };
                  initialDelaySeconds = config.livenessProbe.initialDelaySeconds;
                  periodSeconds = config.livenessProbe.periodSeconds;
                  timeoutSeconds = config.livenessProbe.timeoutSeconds;
                  failureThreshold = config.livenessProbe.failureThreshold;
                };
                readinessProbe = {
                  httpGet = {
                    path = config.readinessProbe.path;
                    port = config.port;
                    scheme = "HTTP";
                  };
                  initialDelaySeconds = config.readinessProbe.initialDelaySeconds;
                  periodSeconds = config.readinessProbe.periodSeconds;
                  timeoutSeconds = config.readinessProbe.timeoutSeconds;
                  failureThreshold = config.readinessProbe.failureThreshold;
                };
                resources = config.resources;
              }
            ];
          };
        };
      };
    };

    # --- Service ---
    service = scope.mkResource {
      apiVersion = "v1";
      kind = "Service";
      name = "web";
      labels = commonLabels;
      spec = {
        type = "ClusterIP";
        selector = self.deployment.out.selector;
        ports = [
          {
            name = "metabase";
            port = config.servicePort;
            targetPort = config.port;
            protocol = "TCP";
          }
        ];
      };
      outputs = {
        port = toString config.servicePort;
      };
    };

    # --- Ingress (optional) ---
    ingress =
      if config.ingress.enabled then
        scope.mkResource {
          apiVersion = "networking.k8s.io/v1";
          kind = "Ingress";
          name = "frontend";
          labels = commonLabels;
          annotations = {
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
