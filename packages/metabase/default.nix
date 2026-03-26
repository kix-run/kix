# Metabase analytics/BI platform — kix package.
#
# Deploys Metabase backed by PostgreSQL (via StackGres). Simple
# single-deployment architecture with optional Ingress.
#
# Dependencies:
#   postgres            — optional, database (for DI tracking)
#   ingressNginx        — optional, provides IngressClass for ingress
#   clusterIssuer       — optional, provides withCert transformer for TLS
#
# Resources: Deployment (web), Service (web, port 80 -> 3000),
# Ingress (frontend, optional).
#
# root = Service (port 80).
# External secret expected to contain DB connection env vars.

{
  scope,
  lib,
  kix,
  postgres ? null,
  ingressNginx ? null,
  clusterIssuer ? null,
}:

let
  name = scope.instanceName;
in
{
  meta = {
    version = "v0.50.34";
  };

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

  build =
    {
      self,
      config,
      clusterConfig,
    }:
    let
      # Secret name for credentials.
      secretName = if config.existingSecret != null then config.existingSecret else "${name}-secrets";
    in
    {

      # --- Deployment ---
      deployment =
        {
          name = "web";
          spec = {
            replicas = config.replicaCount;
            selector.matchLabels = scope.selectorLabels;
            template.spec.containers = [
              {
                name = "web";
                image = "${config.image.repository}:${config.image.tag}";
                imagePullPolicy = config.image.pullPolicy;
                env = kix.mkEnvVars (
                  {
                    JAVA_TIMEZONE = config.timezone;
                    MB_DB_TYPE = config.database.type;
                    MB_EMOJI_IN_LOGS = config.emojiInLogs;
                    MB_JETTY_HOST = config.jettyHost;
                    MB_JETTY_PORT = toString config.port;
                    MB_SITE_URL = if config.siteUrl != "" then config.siteUrl else null;
                  }
                  // config.env
                );
                envFrom = [
                  { secretRef.name = secretName; }
                ];
                ports = [
                  (kix.port "http" config.port)
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
        }
        |> scope.mkDeployment;

      # --- Service ---
      # Port 80 → targetPort 3000, so we pass explicit ports to override auto-derived ones.
      service =
        self.deployment
        |> kix.service.fromWorkload {
          name = "web";
          ports = [
            {
              name = "metabase";
              port = config.servicePort;
              targetPort = config.port;
              protocol = "TCP";
            }
          ];
        }
        |> scope.mkResource;

      # --- Ingress (optional) ---
      ingress =
        if config.ingress.enabled then
          self.service
          |> kix.ingress.fromService {
            name = "frontend";
            host = config.ingress.host;
            port = config.servicePort;
            className =
              if ingressNginx != null then
                ingressNginx.out.ingressClassName
              else
                config.ingress.className or "public";
            tls = lib.optional (config.ingress.tls.enabled or false) {
              hosts = [ config.ingress.host ];
              secretName = config.ingress.tls.secretName;
            };
            annotations = config.ingress.annotations;
          }
          |> (if clusterIssuer != null then clusterIssuer.out.withCert else lib.id)
          |> scope.mkResource
        else
          null;

      # --- Entry point ---
      root = self.service;
    };
}
