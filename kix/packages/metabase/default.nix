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

  # A Kubernetes memory quantity in MiB, for the forms a limit is written
  # in. Any other form fails the build rather than guessing a heap size.
  quantityToMiB =
    q:
    let
      m = builtins.match "([0-9]+)(Ki|Mi|Gi|Ti|K|M|G|T)?" q;
      n = lib.toInt (builtins.head m);
      bytesPer = {
        Ki = 1024;
        Mi = 1048576;
        Gi = 1073741824;
        Ti = 1099511627776;
        K = 1000;
        M = 1000000;
        G = 1000000000;
        T = 1000000000000;
      };
      unit = builtins.elemAt m 1;
    in
    if m == null then
      throw "metabase '${name}': cannot read the memory limit '${q}'; write it as an integer with an optional Ki, Mi, Gi, Ti, K, M, G or T suffix, or set JAVA_OPTS in env."
    else
      n * (if unit == null then 1 else bytesPer.${unit}) / 1048576;

  # Metabase's docs size -Xmx to leave 1 to 2 GB for everything else
  # ("1g on a machine with 2 GB of RAM, 2g on one with 4 GB"). The JVM in
  # metabase/metabase:v0.50.34 sized its heap from the node's memory on
  # kind, not the container's, so the heap is set explicitly.
  heapMiB = limitMiB: limitMiB - lib.min 2048 (limitMiB / 2);
in
{
  meta = {
    version = "v0.50.34";
    description = "Metabase, a business intelligence and analytics tool, backed by PostgreSQL";
    owner = "app-team";
  };

  # Metabase's first migration runs CREATE EXTENSION citext, and StackGres
  # installs an extension on the postgres image only when the SGCluster
  # lists it.
  deps.postgres.config.extensions = [ { name = "citext"; } ];

  options = {
    image = kix.options.image {
      repository = "docker.io/metabase/metabase";
      tag = "v0.50.34";
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
    # The pmint93/metabase chart sets no resources. The requests cover an
    # idle Metabase JVM, which held 1.9 GiB once started on kind. The
    # memory limit also sets the heap: -Xmx is the limit less 2 GiB, or
    # less half of it below 4 GiB. JAVA_OPTS in `env` overrides it.
    resources = lib.mkOption {
      type = lib.types.anything;
      default = {
        requests = {
          cpu = "250m";
          memory = "2Gi";
        };
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
    # Probe defaults follow the pmint93/metabase chart (2.x). /api/health
    # answers 503 until migrations and initialisation finish, so the startup
    # probe holds the other two off for up to five minutes.
    startupProbe = lib.mkOption {
      type = lib.types.anything;
      default = {
        path = "/api/health";
        initialDelaySeconds = 5;
        periodSeconds = 5;
        timeoutSeconds = 3;
        failureThreshold = 60;
      };
    };
    livenessProbe = lib.mkOption {
      type = lib.types.anything;
      default = {
        path = "/api/health";
        initialDelaySeconds = 5;
        periodSeconds = 10;
        timeoutSeconds = 30;
        failureThreshold = 6;
      };
    };
    readinessProbe = lib.mkOption {
      type = lib.types.anything;
      default = {
        path = "/api/health";
        initialDelaySeconds = 5;
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
              # Kubernetes default: Metabase documents no shutdown drain.
              template.spec.terminationGracePeriodSeconds = 30;
              template.spec.containers = [
                {
                  name = "web";
                  image = kix.image.ref config.image;
                  imagePullPolicy = config.image.pullPolicy;
                  env = kix.mkEnvVars (
                    {
                      JAVA_OPTS =
                        let
                          limit = config.resources.limits.memory or null;
                        in
                        if limit == null then null else "-Xmx${toString (heapMiB (quantityToMiB (toString limit)))}m";
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
                  startupProbe = {
                    httpGet = {
                      path = config.startupProbe.path;
                      port = config.port;
                      scheme = "HTTP";
                    };
                    initialDelaySeconds = config.startupProbe.initialDelaySeconds;
                    periodSeconds = config.startupProbe.periodSeconds;
                    timeoutSeconds = config.startupProbe.timeoutSeconds;
                    failureThreshold = config.startupProbe.failureThreshold;
                  };
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
                  # run_metabase.sh drops from root to the `metabase` user,
                  # uid and gid 2000 unless MUID/MGID say otherwise, and
                  # starts Java directly when it is already non-root.
                  securityContext = {
                    runAsNonRoot = true;
                    runAsUser = 2000;
                    runAsGroup = 2000;
                    allowPrivilegeEscalation = false;
                    readOnlyRootFilesystem = true;
                  };
                }
              ];
            };
          }
          |> kix.withMounts [
            # Metabase extracts its bundled drivers into /plugins on start.
            (kix.mount.emptyDir {
              name = "plugins";
              mountPath = "/plugins";
            })
            (kix.mount.emptyDir {
              name = "tmp";
              mountPath = "/tmp";
            })
          ]
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
