# plausible: Plausible Analytics Community Edition, privacy-friendly web
# analytics, with its accounts on PostgreSQL and its events in ClickHouse.
#
# Installs a Deployment and a Service on port 8000, and a route through
# `kix.expose` when the cluster has an ingress controller or a gateway and
# the instance has a host (`ingress.host`, or the cluster's
# `cluster.domain`). The tracking script, the event endpoint
# (`/api/event`), and the dashboard are all served on that route.
#
# Dependencies:
#   database (required)            a PostgreSQL database and role honouring
#                                  the Postgres database contract
#                                  (kix.contracts.postgresDatabase), such as
#                                  stackgres-database. The package asks it
#                                  for the citext extension, which
#                                  Plausible's first migration creates. When
#                                  its `out.tls` is true, DATABASE_URL carries
#                                  `sslmode=require`.
#   clickhouseDatabase (required)  a clickhouse-database instance, on the
#                                  `clickhouse` package or on
#                                  `clickhouse-cluster` with any number of
#                                  replicas. The package asks it for CREATE
#                                  and DROP FUNCTION and CLUSTER on `*.*` and
#                                  SELECT on six system tables, which the
#                                  migrations and the replicate step need,
#                                  and refuses a user without ALL on its
#                                  database.
#   secretKeyBase (required)       a secret with key `key`, at least 32
#                                  bytes, that signs sessions and derives
#                                  the two-factor vault key. A `secret`, or a
#                                  `secret-ref` for a Secret that ESO, Vault,
#                                  or Infisical writes.
#   smtpPassword (optional)        a secret with key `password` for the SMTP
#                                  relay, read as SMTP_USER_PWD. Requires
#                                  `env.SMTP_USER_NAME`.
#
# Minimal instances, with a stackgres-cluster `postgres` and a `clickhouse`
# elsewhere (clusters/test-plausible.nix evaluates the same wiring with
# literal passwords):
#
#   instances.analytics = {
#     plausible = {
#       package = packages.plausible;
#       config.ingress.host = "plausible.example.org";
#     };
#     plausible-db = {
#       package = packages.stackgres-database;
#       config.passwordSource = ./secrets/plausible-db.yaml;
#       config.passwordHash = "...";
#     };
#     plausible-events = {
#       package = packages.clickhouse-database;
#       config.passwordSource = ./secrets/plausible-events.yaml;
#       config.passwordHash = "...";
#     };
#     plausible-secret-key-base = {
#       package = packages.secret;
#       aliases = [ "secretKeyBase" ];
#       config.source = ./secrets/plausible-key.sops.yaml;
#       config.keys = [ "key" ];   # a SOPS source must declare its keys
#       config.hash = "...";
#     };
#   };
#
# An init container runs Plausible's migrations, on PostgreSQL and on
# ClickHouse, before the server starts. The first start creates the whole
# schema and can take a few minutes.
#
# On a ClickHouse server with more than one replica, the migrations run on
# the first replica (`out.replicaHosts`), and a second init container,
# `replicate` (replicate.py beside this file), follows them. Plausible
# creates plain MergeTree tables on a fresh install and switches to
# replicated tables with ON CLUSTER only once its tables already are
# (Plausible.IngestRepo.clustered_table?). The step replaces each plain
# table of the database with a Replicated* table of the same definition,
# moving its parts across, and then creates the tables, dictionaries, and
# SQL functions on the other replicas, which fetch the data. It runs on
# every start, does nothing once every table is on every replica, and
# leaves a replica that is down to run its statements from ClickHouse's DDL
# queue when it returns. Later migrations, Plausible's own, take the ON
# CLUSTER path. The server itself uses the load-balanced Service.
#
# A changed password or key restarts the pod. A `secret-ref` has no content
# hash, so a Secret written outside Kix does not restart it.
#
# `BASE_URL` is the route's URL. When TLS terminates outside Kix (for
# example behind cloudflared), set `env.BASE_URL` to the public URL.
# Without a route and without `env.BASE_URL` the build fails.
#
# New accounts need an invitation (Plausible's `DISABLE_REGISTRATION`
# default, `invite_only`), except the first one, which the first visitor to
# the dashboard creates. Open the dashboard right after the first deploy.
#
# Mail (invitations, password resets, reports) goes out through
# `env.MAILER_ADAPTER` and its variables (`SMTP_HOST_ADDR`,
# `SMTP_HOST_PORT`, `SMTP_USER_NAME`), with the SMTP password from the
# `smtpPassword` dependency. With `SMTP_HOST_ADDR` set and the Bamboo.Mua
# (default) or Bamboo.SMTPAdapter adapter, the package adds egress to any
# address on the relay's port (`SMTP_HOST_PORT`, else 587 for Bamboo.Mua
# and 25 for Bamboo.SMTPAdapter). Without a relay Plausible delivers to
# each recipient's mail server on port 25, which the package does not
# open. Credentials the API adapters and integrations read (POSTMARK_API_KEY
# and the like) are refused as literal `env` strings; pass a `secretKeyRef`
# to a Secret managed outside Kix.
#
# Erlang distribution is off (`RELEASE_DISTRIBUTION=none`): Community
# Edition does not cluster, and every copy of the image ships the same
# distribution cookie, so a listening distribution port would accept code
# from anyone who reaches it.
#
# Network policy covers the two databases, the route, and the mail relay
# above. Under default-deny, the favicon proxy (icons.duckduckgo.com, for
# the dashboard's referrer icons) and the time zone data updater
# (data.iana.org) are unreachable, which degrades the dashboard and logs
# errors. Add a NetworkPolicy or a CiliumNetworkPolicy that selects this
# instance's pods to allow them.
#
# `out`: the Service's `name`, `fqdn`, and `port` (8000).
#
# Escape hatches: `env` for Plausible settings, and the instance's
# `partsOverlays` for probes, placement, and resources of the init
# container.
#
# Limits:
#   One replica at every availability level (`meta.availability.max`).
#   Community Edition keeps each visitor's session in the memory of the
#   node that received the visitor's last event
#   (lib/plausible/session/cache_store.ex) and starts no Erlang cluster
#   (the Cluster.Supervisor in lib/plausible/application.ex is Enterprise
#   only), so a second replica would split visitors' sessions between pods.
#   A deploy restarts the pod (Recreate): events sent while it starts are
#   lost, and visitors active across the restart start new sessions, since
#   Plausible's session transfer is off in Community Edition
#   (ENABLE_SESSION_TRANSFER defaults to the `prod` build only).
#   On a replicated ClickHouse, Plausible starts only while the first
#   replica answers, since the migrations and the replicate step run
#   there. Plausible's own ON CLUSTER migrations wait for every replica, so
#   take a Plausible release only while all replicas are up. Community
#   Edition documents a single ClickHouse server; the replicated path is
#   the one Plausible's hosted service uses, verified here on kind.
#   Both database passwords go into URLs unescaped (DATABASE_URL,
#   CLICKHOUSE_DATABASE_URL), so they must not contain URL delimiters such
#   as `@`, `/`, `:`, or `%`.
#   Metrics are not wired: Plausible serves /metrics (PromEx) on the same
#   port as the dashboard, so the route would publish it. The package ships
#   no alerts for the same reason.
#   MaxMind city geolocation (MAXMIND_LICENSE_KEY) and the Google
#   integrations are not wired; the image's bundled country database
#   serves geolocation.

{
  scope,
  lib,
  kix,
}:

let
  release = "3.2.1";
  name = scope.instanceName;
  who = "plausible ${scope.namespaceName}/${name}";

  # The first start runs every PostgreSQL and ClickHouse migration in the
  # init container. The progress deadline covers init containers too.
  startupSeconds = 900;

  httpPort = 8000;
  dataDir = "/var/lib/plausible";

  # What the migrations and the LocationsSync worker need outside the
  # database. SQL functions belong to no database, and CREATE OR REPLACE
  # FUNCTION takes both function privileges. ClickHouse 26.3 asks for a
  # grant to read a system table: Plausible.IngestRepo.replica_count reads
  # system.replicas, the VersionedSessions data migration reads
  # system.parts and system.tables, LocationsSync reads system.tables, and
  # migration 20240502115822 reads system.columns. On more than one
  # replica, Plausible's migrations run DDL with ON CLUSTER (CLUSTER), and
  # replicate.py reads system.functions and system.clusters. The grants
  # are asked of every server, because an injection cannot read the
  # replica count it would depend on.
  requiredGrants = {
    "*.*" = [
      "CREATE FUNCTION"
      "DROP FUNCTION"
      "CLUSTER"
    ];
    "system.replicas" = [ "SELECT" ];
    "system.parts" = [ "SELECT" ];
    "system.tables" = [ "SELECT" ];
    "system.columns" = [ "SELECT" ];
    "system.functions" = [ "SELECT" ];
    "system.clusters" = [ "SELECT" ];
  };
in
{
  meta = {
    version = "v${release}";
    description = "Plausible Analytics Community Edition, web analytics on PostgreSQL and ClickHouse";
    owner = "app-team";
    # See Limits in the header.
    availability.max = "none";
  };

  deps = {
    database = {
      # Plausible's first PostgreSQL migration runs CREATE EXTENSION citext.
      config.extensions = [ "citext" ];
      assertions = dep: kix.contracts.postgresDatabase.assertions who dep;
    };

    clickhouseDatabase = {
      # priv/ingest_repo/migrations/20250218094453_create_custom_event_array_function.exs
      # and the AcquisitionChannel data migration run CREATE OR REPLACE
      # FUNCTION; requiredGrants lists the rest.
      config.grants = requiredGrants;
      assertions =
        dep:
        let
          out = dep.out;
          privileges = out.privileges or [ ];
          grants = out.grants or { };
          missingGrants = lib.concatLists (
            lib.mapAttrsToList (
              object: wanted: map (p: "${p} ON ${object}") (lib.subtractLists (grants.${object} or [ ]) wanted)
            ) requiredGrants
          );
          replicas = out.replicas or null;
          replicaHosts = out.replicaHosts or [ ];
        in
        lib.optional (replicas == null) {
          assertion = false;
          message = "deps.clickhouseDatabase publishes no `replicas`, and Plausible's ClickHouse migrations run differently on one replica and on several. Wire a clickhouse-database instance, or add `replicas` (and `replicaHosts` above one) to the stand-in's out.";
        }
        ++
          lib.optional
            (replicas != null && replicas != "1" && builtins.length replicaHosts != lib.toInt replicas)
            {
              assertion = false;
              message = "deps.clickhouseDatabase reports ${replicas} replicas and ${toString (builtins.length replicaHosts)} replicaHosts. On several replicas Plausible migrates on the first replica and then replicates its tables from there, so it needs one address per replica in out.replicaHosts.";
            }
        ++ lib.optional (!(builtins.elem "ALL" privileges)) {
          assertion = false;
          message = "deps.clickhouseDatabase grants ${
            if privileges == [ ] then "no privileges" else lib.concatStringsSep ", " privileges
          }, and Plausible's migrations create, alter, and drop tables and dictionaries. Set that instance's privileges to [ \"ALL\" ].";
        }
        ++ lib.optional (missingGrants != [ ]) {
          assertion = false;
          message = "deps.clickhouseDatabase does not grant ${lib.concatStringsSep ", " missingGrants}, which Plausible's migrations need. The package asks a clickhouse-database for these through its `grants`; a stand-in must grant them on the server and publish them in out.grants.";
        };
    };
  };

  options = {
    image = kix.options.image {
      repository = "ghcr.io/plausible/community-edition";
      tag = "v${release}";
      digest = "sha256:33e60bfb40f2df5da00f8753b76fad04f67dba3abe6d73eb516e440e3fb62985";
    };
    # No CPU limit, so a burst of events or a CSV import is not throttled;
    # the memory limit bounds the pod.
    resources = kix.options.resources {
      requests = {
        cpu = "100m";
        memory = "512Mi";
      };
      limits.memory = "2Gi";
    };
    env = kix.options.env // {
      description = "Extra environment variables for Plausible settings the package does not set: a string, a `fieldRef` source, or a `secretKeyRef` source naming a Secret managed outside Kix with `kix.untrackedRef`. The database, clickhouseDatabase, secretKeyBase, and smtpPassword dependencies are wired by the package. `BASE_URL` replaces the routed URL, `TMPDIR` the temporary directory, and `ERL_MAX_PORTS` the port limit (65536); null removes any of them.";
    };
    ingress = kix.options.ingress;
  };

  build = [
    (
      {
        self,
        config,
        scope,
        kix,
        database,
        clickhouseDatabase,
        secretKeyBase,
        smtpPassword ? null,
        ...
      }:
      let
        skb = kix.checkSecretKeys {
          inherit who;
          arg = "secretKeyBase";
          dep = secretKeyBase;
          keys = [ "key" ];
        };
        smtp =
          if smtpPassword == null then
            null
          else
            kix.checkSecretKeys {
              inherit who;
              arg = "smtpPassword";
              dep = smtpPassword;
              keys = [ "password" ];
            };

        pg = database.out;
        ch = clickhouseDatabase.out;

        mailerAdapter = config.env.MAILER_ADAPTER or null;
        usesMua = mailerAdapter == null || mailerAdapter == "Bamboo.Mua";
        smtpRelay = config.env.SMTP_HOST_ADDR or null;
        relayEgress = smtpRelay != null && (usesMua || mailerAdapter == "Bamboo.SMTPAdapter");
        # The defaults of config/runtime.exs for each adapter.
        smtpPortText = config.env.SMTP_HOST_PORT or null;
        smtpPort =
          if smtpPortText == null then
            (if usesMua then 587 else 25)
          else if builtins.isString smtpPortText && builtins.match "[0-9]+" smtpPortText != null then
            lib.toInt smtpPortText
          else
            throw "${who}: env.SMTP_HOST_PORT must be a port number as a string: the package opens egress to it, and Plausible parses it as an integer.";

        # With Bamboo.Mua, Plausible raises at start when only one of
        # SMTP_USER_NAME and SMTP_USER_PWD is set (config/runtime.exs).
        smtpUser = config.env.SMTP_USER_NAME or null;
        _smtpCheck =
          if !usesMua then
            null
          else if smtp != null && smtpUser == null then
            throw "${who}: the smtpPassword dependency is wired, and Plausible's Bamboo.Mua mailer needs SMTP_USER_NAME with it. Set env.SMTP_USER_NAME."
          else if smtp == null && smtpUser != null && !(config.env ? SMTP_USER_PWD) then
            throw "${who}: env.SMTP_USER_NAME is set without a password, and Plausible's Bamboo.Mua mailer refuses to start with one of the two. Wire a secret with key `password` as deps.smtpPassword."
          else
            null;

        # Variables config/runtime.exs reads as credentials. A string value
        # would land in the Nix store and the rendered Deployment.
        credentialNames = [
          "SMTP_USER_PWD"
          "POSTMARK_API_KEY"
          "MAILGUN_API_KEY"
          "MANDRILL_API_KEY"
          "SENDGRID_API_KEY"
          "MAXMIND_LICENSE_KEY"
          "GOOGLE_CLIENT_SECRET"
          "TOTP_VAULT_KEY"
          "HCAPTCHA_SECRET"
        ];
        literalCredentials = builtins.filter (
          n: builtins.isString (config.env.${n} or null)
        ) credentialNames;
        _credentialCheck =
          if literalCredentials != [ ] then
            throw "${who}: env sets ${lib.concatStringsSep ", " literalCredentials} to a literal string, which would land in the Nix store and the rendered Deployment. Pass a secretKeyRef source to a Secret managed outside Kix (kix.untrackedRef), or wire deps.smtpPassword for SMTP_USER_PWD."
          else
            null;

        # The credentials reach the URLs through Kubernetes $(VAR)
        # expansion, which reads only variables earlier in the list; the
        # mkEnv entries come first. ClickHouse takes credentials in the
        # URL's userinfo over HTTP.
        credentialEnv =
          pg.credentials.out.mkEnv {
            PLAUSIBLE_PG_USERNAME = "username";
            PLAUSIBLE_PG_PASSWORD = "password";
          }
          ++ ch.credentials.out.mkEnv {
            PLAUSIBLE_CH_USERNAME = "username";
            PLAUSIBLE_CH_PASSWORD = "password";
          };
        # The contract's `tls` is true, false, or null (the provider cannot
        # tell). Plausible connects without TLS unless sslmode is set, and
        # `require` encrypts without verifying the server's certificate.
        databaseUrl =
          "postgresql://$(PLAUSIBLE_PG_USERNAME):$(PLAUSIBLE_PG_PASSWORD)@${pg.host}:${toString pg.port}/${pg.database}"
          + lib.optionalString ((pg.tls or null) == true) "?sslmode=require";
        clickhouseUrlOn =
          host:
          "http://$(PLAUSIBLE_CH_USERNAME):$(PLAUSIBLE_CH_PASSWORD)@${host}:${ch.ports.http}/${ch.database}";
        clickhouseUrl = clickhouseUrlOn ch.host;

        # On several replicas, the migrations run on the first replica, so
        # every plain table they create is on that one, and replicate.py
        # then makes the tables replicated and creates them on the others.
        # The server uses the load-balanced Service.
        replicated = ch.replicas != "1";
        migrationHost = if replicated then builtins.head ch.replicaHosts else ch.host;
        replicatePy = builtins.readFile ./replicate.py;
        replicateRuntime = kix.healthCheck.runtimes.python;

        env =
          credentialEnv
          ++ kix.mkEnvVars (
            kix.mergeEnv {
              inherit who;
              defaults = {
                BASE_URL = self.exposure.url;
                TMPDIR = "/tmp";
                # The BEAM sizes its port table from the open-files limit.
                # Where the container runtime sets that limit to the kernel
                # maximum (kind's containerd does), the table outgrows the
                # memory limit and the container is OOM-killed at start.
                # Upstream's compose file sets nofile to 65535.
                ERL_MAX_PORTS = "65536";
              };
              owned = [
                {
                  vars.DATABASE_URL = databaseUrl;
                  names = [
                    "PLAUSIBLE_PG_USERNAME"
                    "PLAUSIBLE_PG_PASSWORD"
                    # Deprecated, and replaces the host in DATABASE_URL.
                    "DATABASE_SOCKET_DIR"
                  ];
                  from = "the database dependency";
                  fix = "Wire a different database instance through deps.database instead.";
                }
                {
                  vars.CLICKHOUSE_DATABASE_URL = clickhouseUrl;
                  names = [
                    "PLAUSIBLE_CH_USERNAME"
                    "PLAUSIBLE_CH_PASSWORD"
                  ];
                  from = "the clickhouseDatabase dependency";
                  fix = "Wire a different clickhouse-database instance through deps.clickhouseDatabase instead.";
                }
                {
                  vars.SECRET_KEY_BASE = skb.out.keyRef "key";
                  from = "the secretKeyBase dependency";
                  fix = "Wire a different secret through deps.secretKeyBase instead.";
                }
                {
                  vars = lib.optionalAttrs (smtp != null) { SMTP_USER_PWD = smtp.out.keyRef "password"; };
                  from = "the smtpPassword dependency";
                  fix = "Remove it from env; the dependency supplies it.";
                }
                {
                  vars = {
                    LISTEN_IP = "0.0.0.0";
                    HTTP_PORT = toString httpPort;
                    # Plausible reads every setting from a file of the same
                    # name in CONFIG_DIR before the environment, so a file
                    # mounted there would replace the variables above. No
                    # volume is mounted at this path.
                    CONFIG_DIR = "/run/plausible-config";
                    DATA_DIR = dataDir;
                    RELEASE_DISTRIBUTION = "none";
                  };
                  names = [
                    # PORT is read when HTTP_PORT is unset.
                    "PORT"
                    # HTTPS_PORT starts Plausible's own ACME client on the
                    # pod; TLS terminates at the route.
                    "HTTPS_PORT"
                    "PERSISTENT_CACHE_DIR"
                    "DEFAULT_DATA_DIR"
                  ];
                  from = "the package, so the Service, probes, and mounts match the container, and Erlang distribution stays off";
                  fix = "Remove it from env.";
                }
              ];
            } config.env
          );

        container = {
          image = kix.image.ref config.image;
          imagePullPolicy = config.image.pullPolicy;
          inherit env;
          resources = config.resources;
          # 999 is the `plausible` user of the image; 65533 is Alpine's
          # nogroup, its group.
          securityContext = {
            runAsNonRoot = true;
            runAsUser = 999;
            runAsGroup = 65533;
            allowPrivilegeEscalation = false;
            readOnlyRootFilesystem = true;
            capabilities.drop = [ "ALL" ];
          };
        };

        mounts = [
          # DATA_DIR: the time zone database, and the geolocation cache.
          (kix.mount.emptyDir {
            name = "data";
            mountPath = dataDir;
            sizeLimit = "1Gi";
          })
          # TMPDIR, for CSV imports and exports.
          (kix.mount.emptyDir {
            name = "tmp";
            mountPath = "/tmp";
            sizeLimit = "2Gi";
          })
        ];

        migrateEnv = map (
          e:
          if e.name == "CLICKHOUSE_DATABASE_URL" then
            {
              inherit (e) name;
              value = clickhouseUrlOn migrationHost;
            }
          else
            e
        ) env;

        replicateContainer = {
          name = "replicate";
          image = kix.image.ref replicateRuntime.image;
          command = replicateRuntime.interpreter ++ [
            "-I"
            "/replicate/replicate.py"
          ];
          env =
            ch.credentials.out.mkEnv {
              CLICKHOUSE_USER = "username";
              CLICKHOUSE_PASSWORD = "password";
            }
            ++ kix.mkEnvVars (
              replicateRuntime.env
              // {
                CLICKHOUSE_URL = "http://${migrationHost}:${ch.ports.http}/${ch.database}";
                REPLICAS = ch.replicas;
              }
            );
          resources = {
            requests = {
              cpu = "10m";
              memory = "32Mi";
            };
            limits.memory = "128Mi";
          };
          securityContext = {
            runAsNonRoot = true;
            runAsUser = 65534;
            runAsGroup = 65534;
            allowPrivilegeEscalation = false;
            readOnlyRootFilesystem = true;
            capabilities.drop = [ "ALL" ];
          };
          volumeMounts = [
            {
              name = "replicate";
              mountPath = "/replicate";
              readOnly = true;
            }
          ];
        };

        httpProbe = path: {
          httpGet = {
            inherit path;
            port = "http";
          };
        };
      in
      builtins.deepSeq
        [
          _smtpCheck
          _credentialCheck
          # Checked with or without an enforcer to render the rule.
          (if relayEgress then smtpPort else null)
        ]
        {
          deployment =
            {
              inherit name;
              spec = {
                replicas = 1;
                # One pod holds the visitors' sessions in memory, and the init
                # container migrates the schema the old pod still reads.
                strategy.type = "Recreate";
                progressDeadlineSeconds = startupSeconds + 60;
                selector.matchLabels = scope.selectorLabels;
                # A changed password or key restarts the pod, which reads
                # them once at start. A `secret-ref` has no content hash.
                template.metadata.annotations = lib.filterAttrs (_: v: v != null) {
                  "checksum/database" = pg.credentials.out.identityHash or null;
                  "checksum/clickhouse" = ch.credentials.out.identityHash or null;
                  "checksum/secret-key-base" = skb.out.identityHash or null;
                  "checksum/smtp" = if smtp != null then smtp.out.identityHash or null else null;
                  "checksum/replicate" =
                    if replicated then builtins.substring 0 16 (builtins.hashString "sha256" replicatePy) else null;
                };
                template.spec = {
                  automountServiceAccountToken = false;
                  # Plausible reads settings such as SMTP_HOST_PORT from the
                  # environment, and a Service named smtp-host would inject
                  # SMTP_HOST_PORT=tcp://...
                  enableServiceLinks = false;
                  # Kubernetes default: Plausible documents no shutdown drain.
                  terminationGracePeriodSeconds = 30;
                  # The image's createdb step is left out: both dependencies
                  # create the databases, and PostgreSQL refuses CREATE
                  # DATABASE to a role without CREATEDB even when the database
                  # exists.
                  # kix.withMounts keeps volumes already in the spec.
                  volumes = lib.optional replicated {
                    name = "replicate";
                    configMap.name = self.replicateScript.out.name;
                  };
                  initContainers = [
                    (
                      container
                      // {
                        name = "migrate";
                        env = migrateEnv;
                        args = [
                          "db"
                          "migrate"
                        ];
                        # kix.withMounts fills only `containers`; the
                        # migrations read the same configuration and paths.
                        volumeMounts = map (m: { inherit (m) name mountPath; }) mounts;
                      }
                    )
                  ]
                  ++ lib.optional replicated replicateContainer;
                  containers = [
                    (
                      container
                      // {
                        name = "plausible";
                        ports = [ (kix.port "http" httpPort) ];
                        # The server answers once the migrations have run, so
                        # this covers only the release's boot.
                        startupProbe = httpProbe "/api/system/health/live" // {
                          periodSeconds = 5;
                          timeoutSeconds = 3;
                          failureThreshold = 60;
                        };
                        # /live checks no dependency, so a database outage does
                        # not restart the pod and drop its sessions.
                        livenessProbe = httpProbe "/api/system/health/live" // {
                          periodSeconds = 10;
                          timeoutSeconds = 5;
                          failureThreshold = 6;
                        };
                        # /ready answers 500 until PostgreSQL, ClickHouse, and
                        # the sites cache answer.
                        readinessProbe = httpProbe "/api/system/health/ready" // {
                          periodSeconds = 10;
                          timeoutSeconds = 5;
                          failureThreshold = 3;
                        };
                      }
                    )
                  ];
                };
              };
            }
            |> kix.withMounts mounts
            |> scope.mkDeployment;

          replicateScript =
            if replicated then
              lib.warn
                "${who}: deps.clickhouseDatabase is on a ClickHouse server with ${ch.replicas} replicas. Plausible Community Edition documents a single ClickHouse server; Kix migrates on the first replica and converts Plausible's tables to replicated ones in the `replicate` init container, which Plausible does not support. It is tested with Plausible v${release}; test it again before taking another release, and take a release only while every replica is up."
                scope.mkResource
                {
                  apiVersion = "v1";
                  kind = "ConfigMap";
                  name = "${name}-replicate";
                  data."replicate.py" = replicatePy;
                }
            else
              null;

          # The relay's address is the site's, so the rule allows any address
          # on its port. kix.operandPolicy renders nothing without an enforcer.
          mailEgress =
            if relayEgress then
              kix.operandPolicy {
                inherit scope;
                name = "${name}-mail-egress";
                spec =
                  let
                    netpol = scope.networkPolicyEnforcer.netpol;
                  in
                  netpol.mkEndpointSelector self.deployment.out.selector
                  // {
                    egress =
                      (netpol.translateIntentRules {
                        intents.mail.egress = [
                          {
                            to = "world";
                            ports = [
                              {
                                port = smtpPort;
                                protocol = "TCP";
                              }
                            ];
                          }
                        ];
                      }).egressRules;
                  };
              }
            else
              null;

          service =
            self.deployment
            |> kix.service.fromWorkload {
              inherit name;
              ports = [
                {
                  name = "http";
                  port = httpPort;
                  targetPort = "http";
                }
              ];
            }
            |> scope.mkResource;

          root = self.service;
        }
    )
    (kix.expose { service = "service"; })
  ];
}
