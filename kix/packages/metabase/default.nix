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
  availability,
}:

let
  name = scope.instanceName;
in
{
  meta = {
    version = "v0.50.34";
    description = "Metabase, a business intelligence and analytics tool, backed by PostgreSQL";
    owner = "app-team";
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
      # Stateless and serving user traffic; all state lives in the shared
      # postgres application database, so replicas scale out freely.
      default = kix.availability.pick availability {
        none = 1;
        pod = 2;
        node = 2;
        zone = 3;
      };
      description = ''
        Number of Metabase `Deployment` replicas. Defaults from the
        cluster's availability level (v2_discussions/145).
      '';
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
    ingress = kix.options.ingress;
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

  build = [
    (
      {
        self,
        config,
        clusterConfig,
        postgres,
        scope,
        kix,
        ...
      }:
      {
        # --- Secret ref (external or default name) ---
        appSecret = scope.mkSecretRef {
          name = if config.existingSecret != null then config.existingSecret else "${name}-secrets";
          keys = [ ]; # keys unknown — external secret, used via envFrom
        };

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
                    self.appSecret.out.envFrom
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

        # --- Entry point ---
        root = self.service;
      }
    )
    (kix.expose { service = "service"; })
  ];
}
