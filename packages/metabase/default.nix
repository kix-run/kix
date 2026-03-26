# Metabase analytics/BI platform — kix package.
#
# Deploys Metabase backed by PostgreSQL (via StackGres). Simple
# single-deployment architecture with DI-driven Ingress/TLS.
#
# Dependencies:
#   postgres            — required, database
#   ingressNginx        — optional, auto-creates ingress when present (+ host is set)
#   clusterIssuer       — optional, auto-enables TLS when present
#
# Resources: Deployment (web), Service (web, port 80 -> 3000),
# Ingress (optional, DI-driven).
#
# root = Service (port 80).
# External secret expected to contain DB connection env vars.

{
  scope,
  lib,
  kix,
  postgres,
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
        host = null;
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

      # DI-driven ingress: created when ingressNginx is injected AND host is set.
      clusterDomain = clusterConfig.cluster.domain or null;
      effectiveHost =
        if config.ingress.host != null then
          config.ingress.host
        else if clusterDomain != null then
          "${name}.${clusterDomain}"
        else
          null;
      hasIngress = ingressNginx != null && effectiveHost != null;
      hasTls = hasIngress && clusterIssuer != null;
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
      # Port 80 -> targetPort 3000, so we pass explicit ports to override auto-derived ones.
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

      # --- Ingress (DI-driven) ---
      # Created automatically when ingressNginx is injected and host is set.
      # TLS is auto-enabled when clusterIssuer is injected.
      ingress =
        if hasIngress then
          self.service
          |> kix.ingress.fromService {
            inherit name;
            host = effectiveHost;
            className = ingressNginx.out.ingressClassName;
            tls = lib.optional hasTls {
              hosts = [ effectiveHost ];
              secretName = "${name}-tls";
            };
            annotations = config.ingress.annotations;
          }
          |> (if hasTls then clusterIssuer.out.withCert else lib.id)
          |> scope.mkResource
        else
          null;

      # --- Entry point ---
      root = self.service;
    };
}
