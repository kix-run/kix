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
  config,
  lib,
  postgres ? null,
}:

let
  name = scope.instanceName;

  cfg = scope.defaults config {
    image = {
      repository = "docker.io/metabase/metabase";
      tag = "v0.50.34";
      pullPolicy = "IfNotPresent";
    };
    replicaCount = 2;
    port = 3000;
    servicePort = 80;
    resources = {
      limits = {
        cpu = "2";
        memory = "4Gi";
      };
    };
    ingress = {
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
    existingSecret = null;
    database = {
      type = "postgres";
    };
    siteUrl = "";
    timezone = "America/Toronto";
    emojiInLogs = "1";
    jettyHost = "0.0.0.0";
    env = { };
    livenessProbe = {
      path = "/";
      initialDelaySeconds = 120;
      periodSeconds = 10;
      timeoutSeconds = 30;
      failureThreshold = 6;
    };
    readinessProbe = {
      path = "/";
      initialDelaySeconds = 30;
      periodSeconds = 5;
      timeoutSeconds = 3;
      failureThreshold = 3;
    };
  };

  # Secret name for credentials.
  secretName =
    if cfg.existingSecret != null then cfg.existingSecret else "${name}-secrets";

  selectorLabels = {
    "app" = "metabase";
  };

  commonLabels = selectorLabels;

  # Build env list from config.
  envVars = [
    {
      name = "JAVA_TIMEZONE";
      value = cfg.timezone;
    }
    {
      name = "MB_DB_TYPE";
      value = cfg.database.type;
    }
    {
      name = "MB_EMOJI_IN_LOGS";
      value = cfg.emojiInLogs;
    }
    {
      name = "MB_JETTY_HOST";
      value = cfg.jettyHost;
    }
    {
      name = "MB_JETTY_PORT";
      value = toString cfg.port;
    }
  ]
  ++ lib.optional (cfg.siteUrl != "") {
    name = "MB_SITE_URL";
    value = cfg.siteUrl;
  }
  ++ lib.mapAttrsToList (k: v: { name = k; value = v; }) cfg.env;

in
self: {

  # --- Deployment ---
  deployment = scope.mkResource {
    apiVersion = "apps/v1";
    kind = "Deployment";
    name = "web";
    labels = commonLabels;
    spec = {
      replicas = cfg.replicaCount;
      selector.matchLabels = selectorLabels;
      template = {
        metadata = {
          labels = selectorLabels;
        };
        spec = {
          containers = [
            {
              name = "web";
              image = "${cfg.image.repository}:${cfg.image.tag}";
              imagePullPolicy = cfg.image.pullPolicy;
              env = envVars;
              envFrom = [
                { secretRef.name = secretName; }
              ];
              ports = [
                {
                  containerPort = cfg.port;
                  protocol = "TCP";
                }
              ];
              livenessProbe = {
                httpGet = {
                  path = cfg.livenessProbe.path;
                  port = cfg.port;
                  scheme = "HTTP";
                };
                initialDelaySeconds = cfg.livenessProbe.initialDelaySeconds;
                periodSeconds = cfg.livenessProbe.periodSeconds;
                timeoutSeconds = cfg.livenessProbe.timeoutSeconds;
                failureThreshold = cfg.livenessProbe.failureThreshold;
              };
              readinessProbe = {
                httpGet = {
                  path = cfg.readinessProbe.path;
                  port = cfg.port;
                  scheme = "HTTP";
                };
                initialDelaySeconds = cfg.readinessProbe.initialDelaySeconds;
                periodSeconds = cfg.readinessProbe.periodSeconds;
                timeoutSeconds = cfg.readinessProbe.timeoutSeconds;
                failureThreshold = cfg.readinessProbe.failureThreshold;
              };
              resources = cfg.resources;
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
      selector = selectorLabels;
      ports = [
        {
          name = "metabase";
          port = cfg.servicePort;
          targetPort = cfg.port;
          protocol = "TCP";
        }
      ];
    };
    outputs = {
      port = toString cfg.servicePort;
    };
    requires = [ self.deployment ];
  };

  # --- Ingress (optional) ---
  ingress =
    if cfg.ingress.enabled then
      scope.mkResource {
        apiVersion = "networking.k8s.io/v1";
        kind = "Ingress";
        name = "frontend";
        labels = commonLabels;
        annotations = {
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
      }
    else
      null;

  # --- Entry point ---
  main = self.service;
}
