# metabase: Metabase, a business intelligence and analytics tool, with its
# application database on PostgreSQL.
#
# Installs a Deployment and a Service on port 3000, and a route through
# `kix.expose` when the cluster has an ingress controller or a gateway and
# the instance has a host (`ingress.host`, or the cluster's `cluster.domain`).
# Metabase keeps all of its state in the application database, so the pods
# are stateless.
#
# Dependencies:
#   database (required)       a PostgreSQL database and role honouring the
#                             Postgres database contract
#                             (kix.contracts.postgresDatabase), such as
#                             stackgres-database. The package asks it for the
#                             citext extension, which Metabase's first
#                             migration creates. A database from
#                             `kix.mkImport` takes no configuration, so it
#                             must already have citext.
#   encryptionKey (required)  a secret with key `key`, at least 16
#                             characters, that encrypts the data-source
#                             credentials Metabase stores. A `secret`, or a
#                             `secret-ref` for a Secret that ESO, Vault, or
#                             Infisical writes.
#   prometheus (optional)     adds the metrics port to the Service and a
#                             ServiceMonitor. The container serves metrics on
#                             port 9191 while `metrics.enabled` is true, with
#                             or without this dependency, so adding a
#                             Prometheus does not restart Metabase.
#
# Minimal instances, with a stackgres-cluster `postgres` elsewhere:
#
#   instances.analytics = {
#     metabase.package = packages.experimental.metabase;
#     metabase-db.package = packages.experimental.stackgres-database;
#     metabase-db-password = {
#       package = packages.secret;
#       aliases = [ "password" ];
#       config = { source = ./secrets/metabase-db.yaml; keys = [ "password" ]; };
#     };
#     metabase-encryption-key = {
#       package = packages.secret;
#       aliases = [ "encryptionKey" ];
#       config.source = ./secrets/metabase-key.sops.yaml;
#       config.keys = [ "key" ];   # a SOPS source must declare its keys
#     };
#   };
#
# The encryption key cannot change after the first start without Metabase's
# `rotate-encryption-key` command: the stored data-source credentials would
# no longer decrypt.
#
# Give each instance its own database. Two instances on one application
# database both migrate its schema and encrypt with different keys, and
# nothing in the build refuses that wiring.
#
# The first start runs Metabase's schema migrations and can take longer than
# `kix deploy` waits for a Deployment. If the deploy reports a timeout, follow
# the rollout with `kubectl rollout status -n <namespace> deploy/<instance>`.
#
# `MB_SITE_URL` is the route's URL. When TLS terminates outside Kix (for
# example behind cloudflared), set `env.MB_SITE_URL` to the public URL.
#
# `MB_ANON_TRACKING_ENABLED` defaults to "false", so Metabase sends no
# anonymous usage statistics; set `env.MB_ANON_TRACKING_ENABLED = "true"` to
# send them.
#
# Replicas follow the cluster's availability level (one at `none`, two
# above); the instance's `availability` overrides it.
#
# Network policy covers the database and the route. The databases Metabase
# queries (its data sources) differ per instance, and the package declares
# no egress to them. Under default-deny, add a NetworkPolicy or a
# CiliumNetworkPolicy that selects this instance's pods and allows egress to
# its data sources.
#
# `out`: the Service's `name`, `fqdn`, and `port` (3000), and `version`, the
# Metabase version `image.tag` names.
#
# Escape hatches: `env` for Metabase settings, and the instance's
# `partsOverlays` for probes, strategy, replicas, and placement.

{
  scope,
  lib,
  kix,
  availability,
}:

let
  release = "0.63.19";
  name = scope.instanceName;
  who = "metabase ${scope.namespaceName}/${name}";

  # The first start creates Metabase's schema. A pod killed during a
  # migration can leave the application database corrupt, so the startup
  # probe and the progress deadline both allow 30 minutes.
  startupSeconds = 1800;

  httpPort = 3000;
  metricsPort = 9191;
in
{
  meta = {
    version = release;
    description = "Metabase, a business intelligence and analytics tool, with its application database on PostgreSQL";
    owner = "app-team";
  };

  # region:postgresDatabaseAssertions
  deps.database = {
    # Metabase's first migration runs CREATE EXTENSION citext.
    config.extensions = [ "citext" ];
    assertions = dep: kix.contracts.postgresDatabase.assertions who dep;
  };
  # endregion:postgresDatabaseAssertions

  options = {
    image = kix.options.image {
      repository = "docker.io/metabase/metabase";
      tag = "v${release}";
      digest = "sha256:7324f83713df9851c6c7b6c8247098de14c0924fc3b868202f886df4877cd4ff";
    };
    # A memory limit also sizes the heap (see JAVA_OPTS).
    resources = kix.options.resources {
      requests = {
        cpu = "250m";
        memory = "2Gi";
      };
      limits = {
        cpu = "2";
        memory = "4Gi";
      };
    };
    env = kix.options.env // {
      description = "Extra environment variables for Metabase settings the package does not set: a string, a `fieldRef` source, or a `secretKeyRef` source naming a Secret managed outside Kix with `kix.untrackedRef`. The database and encryptionKey dependencies are wired by the package. `JAVA_OPTS` replaces the heap setting and `MB_SITE_URL` the routed URL; null removes either. `MB_ANON_TRACKING_ENABLED` defaults to \"false\".";
    };
    ingress = kix.options.ingress;
    metrics = kix.options.monitor;
  };

  build = [
    (
      {
        self,
        config,
        scope,
        kix,
        database,
        encryptionKey,
        prometheus ? null,
        ...
      }:
      let
        # Only `metrics.enabled` decides the metrics variable and container
        # port. Wiring a prometheus dependency changes the Service and the
        # ServiceMonitor but not the pod template, so it does not restart
        # the Recreate Deployment.
        metricsOn = config.metrics.enabled;
        scraped = metricsOn && prometheus != null;
        ek = kix.contracts.secret.helpers.use {
          inherit who;
          arg = "encryptionKey";
          dep = encryptionKey;
          keys = [ "key" ];
        };
        # `kix.options.resources` drops null fields, so a removed limit is
        # absent here.
        hasMemoryLimit = (config.resources.limits or { }) ? memory;

        env = kix.mkEnvVars (
          kix.mergeEnv {
            inherit who;
            defaults = {
              # Null when Kix cannot derive the URL, such as when nothing
              # routes to the instance; Metabase then records the URL of the
              # first administrator's request.
              MB_SITE_URL = self.exposure.urlOrNull;
              # The temurin JVM sizes its heap from the cgroup memory limit,
              # 25% by default. Half leaves room for metaspace, threads, and
              # off-heap buffers. run_metabase.sh puts a user's JAVA_OPTS
              # before its own flags, so env.JAVA_OPTS replaces only this.
              JAVA_OPTS = if hasMemoryLimit then "-XX:MaxRAMPercentage=50" else null;
              # Metabase sends anonymous usage statistics unless this is false.
              MB_ANON_TRACKING_ENABLED = "false";
            };
            owned = [
              {
                vars = {
                  MB_DB_TYPE = "postgres";
                  MB_DB_HOST = database.out.host;
                  MB_DB_PORT = toString database.out.port;
                  MB_DB_DBNAME = database.out.database;
                  MB_DB_USER = database.out.credentials.out.keyRef "username";
                  MB_DB_PASS = database.out.credentials.out.keyRef "password";
                };
                # MB_DB_CONNECTION_URI, or the file MB_DB_CONNECTION_URI_FILE
                # names, replaces the host, port, and credentials above.
                # run_metabase.sh exits 1 when MB_DB_USER or MB_DB_PASS and
                # its _FILE variant are both set.
                names = [
                  "MB_DB_CONNECTION_URI"
                  "MB_DB_CONNECTION_URI_FILE"
                  "MB_DB_USER_FILE"
                  "MB_DB_PASS_FILE"
                ];
                from = "the database dependency";
                fix = "Wire a different database instance through deps.database instead.";
              }
              {
                vars.MB_ENCRYPTION_SECRET_KEY = ek.out.keyRef "key";
                from = "the encryptionKey dependency";
                fix = "Wire a different secret through deps.encryptionKey instead.";
              }
              {
                vars = {
                  MB_JETTY_HOST = "0.0.0.0";
                  MB_JETTY_PORT = toString httpPort;
                };
                from = "the package, so the Service and probes match the container";
                fix = "Remove it from env.";
              }
              {
                vars = lib.optionalAttrs metricsOn { MB_PROMETHEUS_SERVER_PORT = toString metricsPort; };
                names = lib.optional (!metricsOn) "MB_PROMETHEUS_SERVER_PORT";
                from = "the metrics.enabled option (port ${toString metricsPort}, matching the container port, the Service, and the ServiceMonitor)";
                fix =
                  if metricsOn then
                    "Remove it from env."
                  else
                    "Remove it from env, and set metrics.enabled = true to serve metrics.";
              }
            ];
          } config.env
        );

        httpProbe = path: {
          httpGet = {
            inherit path;
            port = "http";
          };
        };
      in
      {
        deployment =
          lib.pipe
            {
              inherit name;
              spec = {
                replicas = kix.availability.pick availability {
                  none = 1;
                  pod = 2;
                  node = 2;
                  zone = 2;
                };
                # Metabase migrates its schema on start, and pods of the old
                # version fail against the migrated schema. Pods of one version
                # may start together: Liquibase locks the application database.
                strategy.type = "Recreate";
                progressDeadlineSeconds = startupSeconds + 60;
                selector.matchLabels = scope.selectorLabels;
                # A changed database password or encryption key restarts the
                # pods, which read both once at start. A `secret-ref` has no
                # content hash; an External Secret rolls the pods through
                # reloader's `withReloadOn`.
                template.metadata.annotations = lib.filterAttrs (_: v: v != null) {
                  "checksum/database" = database.out.credentials.out.contentHash or null;
                  "checksum/encryption-key" = ek.out.contentHash or null;
                };
                template.spec = {
                  automountServiceAccountToken = false;
                  # Metabase reads every MB_* variable as a setting, and a
                  # Service named mb-<x> would inject MB_<X>_SERVICE_HOST and
                  # MB_<X>_PORT.
                  enableServiceLinks = false;
                  # Kubernetes default: Metabase documents no shutdown drain.
                  terminationGracePeriodSeconds = 30;
                  containers = [
                    {
                      name = "metabase";
                      image = kix.image.ref config.image;
                      imagePullPolicy = config.image.pullPolicy;
                      inherit env;
                      ports = [
                        (kix.port "http" httpPort)
                      ]
                      ++ lib.optional metricsOn (kix.port "metrics" metricsPort);
                      # /api/health answers 503 until the migrations finish.
                      startupProbe = httpProbe "/api/health" // {
                        periodSeconds = 10;
                        timeoutSeconds = 5;
                        failureThreshold = startupSeconds / 10;
                      };
                      # /livez does not check the database, so an outage of the
                      # application database does not restart every pod into a
                      # fresh start.
                      livenessProbe = httpProbe "/livez" // {
                        periodSeconds = 10;
                        timeoutSeconds = 5;
                        failureThreshold = 6;
                      };
                      # /readyz answers 503 while the application database is
                      # unreachable, so the pods leave the Service.
                      readinessProbe = httpProbe "/readyz" // {
                        periodSeconds = 5;
                        timeoutSeconds = 3;
                        failureThreshold = 3;
                      };
                      resources = config.resources;
                      # run_metabase.sh starts Java directly when it is already
                      # non-root. 2000 is the uid run_metabase.sh gives its
                      # `metabase` user when the container starts as root.
                      securityContext = {
                        runAsNonRoot = true;
                        runAsUser = 2000;
                        runAsGroup = 2000;
                        allowPrivilegeEscalation = false;
                        readOnlyRootFilesystem = true;
                        capabilities.drop = [ "ALL" ];
                      };
                    }
                  ];
                };
              };
            }
            [
              (kix.withMounts [
                # Metabase's plugins directory, `plugins` under the image's
                # working directory `/`, for drivers that metabase.jar does not
                # bundle.
                (kix.mount.emptyDir {
                  name = "plugins";
                  mountPath = "/plugins";
                  sizeLimit = "512Mi";
                })
                # java.io.tmpdir, for JVM and Jetty temporary files. The kubelet
                # evicts the pod when a volume exceeds its sizeLimit.
                (kix.mount.emptyDir {
                  name = "tmp";
                  mountPath = "/tmp";
                  sizeLimit = "2Gi";
                })
              ])
              scope.mkDeployment
            ];

        # The metrics port joins the Service only when something scrapes it.
        service = lib.pipe self.deployment [
          (kix.service.fromWorkload {
            inherit name;
            ports = [
              {
                name = "http";
                port = httpPort;
                targetPort = "http";
              }
            ]
            ++ lib.optional scraped {
              name = "metrics";
              port = metricsPort;
              targetPort = "metrics";
            };
          })
          scope.mkResource
        ];

        root = {
          resource = self.service;
          out.version = kix.image.version config.image;
        };
      }
    )
    (kix.expose { service = "service"; })
    (kix.monitor { service = "service"; })
  ];
}
