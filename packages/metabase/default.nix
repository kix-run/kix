# Metabase analytics/BI platform — kix package.
#
# Deploys Metabase backed by PostgreSQL (via StackGres). Simple
# single-deployment architecture with optional Ingress.
#
# Resources: Deployment, Service (port 3000), ConfigMap (env),
# Ingress (optional).
#
# main = Service (port 3000).
# External secret (DB password) expected to be managed externally.

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
      repository = "metabase/metabase";
      tag = "v0.52.4";
      pullPolicy = "IfNotPresent";
    };
    replicaCount = 2;
    port = 3000;
    resources = {
      requests = {
        cpu = "100m";
        memory = "512Mi";
      };
      limits = {
        cpu = "2";
        memory = "2Gi";
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
    };
    database = {
      type = "postgres";
      host = null;
      port = "5432";
      name = "metabase";
      user = "metabase";
      existingSecret = null;
    };
    javaOpts = "-Xmx1g";
  };

  # Resolve database host: explicit config > postgres dependency fqdn > error.
  dbHost =
    if cfg.database.host != null then
      cfg.database.host
    else if postgres != null then
      postgres.fqdn
    else
      throw "metabase: database.host must be set or a postgres dependency must be available";

  # Secret name for DB credentials.
  secretName =
    if cfg.database.existingSecret != null then cfg.database.existingSecret else "${name}-secrets";

  selectorLabels = {
    "app.kubernetes.io/name" = "metabase";
    "app.kubernetes.io/instance" = name;
  };

  commonLabels = selectorLabels;

in
self: {

  # --- ConfigMap (environment variables) ---
  configmap = scope.mkResource {
    apiVersion = "v1";
    kind = "ConfigMap";
    name = "${name}-config";
    labels = commonLabels;
    data = {
      MB_DB_TYPE = cfg.database.type;
      MB_DB_HOST = dbHost;
      MB_DB_PORT = cfg.database.port;
      MB_DB_DBNAME = cfg.database.name;
      MB_DB_USER = cfg.database.user;
      MB_JETTY_PORT = toString cfg.port;
      JAVA_OPTS = cfg.javaOpts;
    };
  };

  # --- Deployment ---
  deployment = scope.mkResource {
    apiVersion = "apps/v1";
    kind = "Deployment";
    name = "${name}";
    labels = commonLabels;
    spec = {
      replicas = cfg.replicaCount;
      revisionHistoryLimit = 3;
      selector.matchLabels = selectorLabels;
      template = {
        metadata = {
          labels = selectorLabels;
          annotations = {
            "checksum/configmap" = "\${${self.configmap}}";
          };
        };
        spec = {
          securityContext = {
            fsGroup = 2000;
            runAsNonRoot = true;
            runAsUser = 2000;
            runAsGroup = 2000;
            seccompProfile.type = "RuntimeDefault";
          };
          containers = [
            {
              name = "metabase";
              image = "${cfg.image.repository}:${cfg.image.tag}";
              imagePullPolicy = cfg.image.pullPolicy;
              envFrom = [
                { configMapRef.name = "${self.configmap}"; }
              ];
              env = [
                {
                  name = "MB_DB_PASS";
                  valueFrom.secretKeyRef = {
                    name = secretName;
                    key = "MB_DB_PASS";
                  };
                }
              ];
              ports = [
                {
                  name = "http";
                  containerPort = cfg.port;
                  protocol = "TCP";
                }
              ];
              livenessProbe = {
                httpGet = {
                  path = "/api/health";
                  port = "http";
                };
                initialDelaySeconds = 120;
                periodSeconds = 15;
                timeoutSeconds = 5;
                failureThreshold = 5;
              };
              readinessProbe = {
                httpGet = {
                  path = "/api/health";
                  port = "http";
                };
                initialDelaySeconds = 30;
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

  # --- Service ---
  service = scope.mkResource {
    apiVersion = "v1";
    kind = "Service";
    name = "${name}";
    labels = commonLabels;
    spec = {
      type = "ClusterIP";
      selector = selectorLabels;
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
    requires = [ self.deployment ];
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
        };
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
