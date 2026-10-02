# metabase: Metabase, a business intelligence and analytics tool, with its
# application database on PostgreSQL.
#
# Installs a Deployment and a Service on port 3000, a route through
# `kix.expose` when the cluster has an ingress controller or a gateway, and
# a ServiceMonitor with a `prometheus` dependency. Metabase keeps all of its
# state in the application database, so the pods are stateless.
#
# Dependencies:
#   database (required)       a PostgreSQL database and role with
#                             `out.{host,port,database}` and `out.credentials`
#                             (keys `username` and `password`), such as
#                             stackgres-database. The package asks it for the
#                             citext extension, which Metabase's first
#                             migration creates.
#   encryptionKey (required)  a secret with key `key`, at least 16
#                             characters, that encrypts the data-source
#                             credentials Metabase stores. A `secret`, or a
#                             `secret-ref` for a Secret that ESO, Vault, or
#                             Infisical writes.
#   prometheus (optional)     turns on the metrics port and a ServiceMonitor.
#
# Minimal instances, with a stackgres-cluster `postgres` elsewhere:
#
#   instances.analytics = {
#     metabase.package = packages.metabase;
#     metabase-db = {
#       package = packages.stackgres-database;
#       config.passwordSource = ./secrets/metabase-db.yaml;
#       config.passwordHash = "...";
#     };
#     metabase-encryption-key = {
#       package = packages.secret;
#       aliases = [ "encryptionKey" ];
#       config.source = ./secrets/metabase-key.sops.yaml;
#       config.keys = [ "key" ];   # a SOPS source must declare its keys
#       config.hash = "...";
#     };
#   };
#
# The encryption key cannot change after the first start without Metabase's
# `rotate-encryption-key` command: the stored data-source credentials would
# no longer decrypt.
#
# The first start runs Metabase's schema migrations and can take longer than
# `kix deploy` waits for a Deployment. If the deploy reports a timeout, follow
# the rollout with `kubectl rollout status deploy/<instance>`.
#
# `MB_SITE_URL` is the route's URL. When TLS terminates outside Kix (for
# example behind cloudflared), set `env.MB_SITE_URL` to the public URL.
#
# Network policy covers the database and the route. Egress to the
# databases Metabase queries (its data sources) differs per instance, so
# under default-deny the cluster definition must allow it.
#
# `out`: the Service's `name`, `fqdn`, and `port` (3000).
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
in
{
  meta = {
    version = release;
    description = "Metabase, a business intelligence and analytics tool, with its application database on PostgreSQL";
    owner = "app-team";
  };

  # Metabase's first migration runs CREATE EXTENSION citext.
  deps.database.config.extensions = [ "citext" ];

  options = {
    image = kix.options.image {
      repository = "docker.io/metabase/metabase";
      tag = "v${release}";
      digest = "sha256:7324f83713df9851c6c7b6c8247098de14c0924fc3b868202f886df4877cd4ff";
    };
    # The requests cover an idle Metabase JVM, which holds about 1.9 GiB
    # once started. A memory limit also sizes the heap (see JAVA_OPTS).
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
      description = "Extra environment variables for Metabase settings the package does not set: a string, a `fieldRef` source, or a `secretKeyRef` source naming a Secret managed outside Kix with `kix.untrackedRef`. The database and encryptionKey dependencies are wired by the package. `JAVA_OPTS` replaces the heap setting and `MB_SITE_URL` the routed URL; null removes either.";
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
        metricsOn = prometheus != null && config.metrics.enabled;
        ek = kix.checkSecretKeys {
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
              # Null when nothing routes to the instance; Metabase then
              # records the URL of the first administrator's request.
              MB_SITE_URL = self.exposure.url;
              # The temurin JVM sizes its heap from the cgroup memory limit,
              # 25% by default. Half leaves room for metaspace, threads, and
              # off-heap buffers. run_metabase.sh puts a user's JAVA_OPTS
              # before its own flags, so env.JAVA_OPTS replaces only this.
              JAVA_OPTS = if hasMemoryLimit then "-XX:MaxRAMPercentage=50" else null;
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
                # run_metabase.sh exits 1 when a variable and its _FILE
                # variant are both set.
                names = [
                  "MB_DB_CONNECTION_URI"
                  "MB_DB_FILE"
                  "MB_DB_USER_FILE"
                  "MB_DB_PASS_FILE"
                  "MB_DB_CONNECTION_URI_FILE"
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
                  MB_JETTY_PORT = "3000";
                }
                // lib.optionalAttrs metricsOn { MB_PROMETHEUS_SERVER_PORT = "9191"; };
                names = lib.optional (!metricsOn) "MB_PROMETHEUS_SERVER_PORT";
                from = "the package, so the Service, probes, and ServiceMonitor match the container";
                fix = "Remove it from env.";
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
          {
            inherit name;
            spec = {
              replicas = kix.availability.pick availability {
                none = 1;
                pod = 2;
                node = 2;
                zone = 3;
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
                "checksum/database" = database.out.credentials.out.identityHash or null;
                "checksum/encryption-key" = ek.out.identityHash or null;
              };
              template.spec = {
                automountServiceAccountToken = false;
                # Kubernetes default: Metabase documents no shutdown drain.
                terminationGracePeriodSeconds = 30;
                containers = [
                  {
                    name = "metabase";
                    image = kix.image.ref config.image;
                    imagePullPolicy = config.image.pullPolicy;
                    inherit env;
                    ports = [
                      (kix.port "http" 3000)
                    ]
                    ++ lib.optional metricsOn (kix.port "metrics" 9191);
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
                    # non-root; 2000 is the image's `metabase` user.
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

        service = self.deployment |> kix.service.fromWorkload { inherit name; } |> scope.mkResource;

        root = self.service;
      }
    )
    (kix.expose { service = "service"; })
    (kix.monitor { service = "service"; })
  ];
}
