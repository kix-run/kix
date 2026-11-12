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
#   smtp (optional)                a mail server honouring the SMTP
#                                  contract (kix.contracts.smtp), usually a
#                                  kix.mkImport. See "Mail" below.
#
# Minimal instances, with a stackgres-cluster `postgres` and a `clickhouse`
# elsewhere (clusters/test-plausible.nix evaluates the same wiring with
# literal passwords):
#
#   instances.analytics = {
#     plausible = {
#       package = packages.experimental.plausible;
#       config.ingress.host = "plausible.example.org";
#     };
#     plausible-db = {
#       package = packages.experimental.stackgres-database;
#       deps.password = ref.analytics.plausible-db-password;
#     };
#     plausible-db-password = {
#       package = packages.secret;
#       config = { source = ./secrets/plausible-db.yaml; hash = "..."; keys = [ "password" ]; };
#     };
#     plausible-events = {
#       package = packages.experimental.clickhouse-database;
#       deps.password = ref.analytics.plausible-events-password;
#     };
#     plausible-events-password = {
#       package = packages.secret;
#       config = { source = ./secrets/plausible-events.yaml; hash = "..."; keys = [ "password" ]; };
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
# the first replica in `out.replicaHosts` that answers, replica 0 while it
# is up, and a second init container, on the same replica,
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
# Mail (invitations, password resets, reports) goes out through the `smtp`
# server, with Plausible's Bamboo.Mua mailer. The package sets the
# `SMTP_*` variables, `MAILER_ADAPTER`, and `MAILER_EMAIL` (the server's
# `out.from`, or `mail.from`) and refuses them in `env`. A server outside
# the cluster gets egress to any address on its port, because the network
# policy cannot name a host outside the cluster. Bamboo.Mua uses STARTTLS
# only when the server offers it, so with `out.credentials` the server must
# use implicit TLS (`tls = "implicit"`, usually port 465). Without `smtp`,
# Plausible delivers to each recipient's mail server on port 25, which the
# package does not open; `env.MAILER_ADAPTER` can pick an API adapter
# instead. Credentials the API adapters and integrations read
# (POSTMARK_API_KEY and the like) are refused as literal `env` strings;
# pass a `secretKeyRef` to a Secret managed outside Kix.
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
#   On a replicated ClickHouse, if a replica fails between an upgrade's
#   migrations and the replicate step, a table that upgrade created plain
#   is only on that replica until it returns and Plausible starts again.
#   Plausible's own ON CLUSTER migrations wait for every replica, so
#   upgrade Plausible only while all replicas are up. Community
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
              message = "deps.clickhouseDatabase reports ${replicas} replicas and ${toString (builtins.length replicaHosts)} replicaHosts. On several replicas Plausible migrates on one replica and then replicates its tables from there, so it needs one address per replica in out.replicaHosts.";
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
      description = "Extra environment variables for Plausible settings the package does not set: a string, a `fieldRef` source, or a `secretKeyRef` source naming a Secret managed outside Kix with `kix.untrackedRef`. The database, clickhouseDatabase, secretKeyBase, and smtp dependencies are wired by the package. `BASE_URL` replaces the routed URL, `TMPDIR` the temporary directory, and `ERL_MAX_PORTS` the port limit (65536); null removes any of them.";
    };
    ingress = kix.options.ingress;
    mail = kix.contracts.smtp.options;
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
        smtp ? null,
        smtpPassword ? null,
        ...
      }:
      let
        skb = kix.contracts.secret.helpers.use {
          inherit who;
          arg = "secretKeyBase";
          dep = secretKeyBase;
          keys = [ "key" ];
        };
        pg = database.out;
        ch = clickhouseDatabase.out;

        relay =
          if smtpPassword != null then
            throw "${who}: deps.smtpPassword was replaced by deps.smtp. Declare the mail server as a kix.mkImport in this namespace whose out sets host, port, tls, from, and credentials = ref.<ns>.<secret>, a secret with keys `username` and `password`. Remove the SMTP_* variables from env."
          else
            kix.contracts.smtp.helpers.settings {
              inherit who smtp;
              inherit (config.mail) from;
            };

        # Bamboo.Mua sends the login over a plain connection when the server
        # does not offer STARTTLS, so anyone who strips STARTTLS on the way
        # would see the password. Implicit TLS has no plain phase.
        _relayCheck =
          if relay != null && relay.credentials != null && relay.tls == "starttls" then
            throw "${who}: deps.smtp uses tls = \"starttls\" with credentials. Plausible's mailer (Bamboo.Mua) sends the password without TLS when the server does not offer STARTTLS, so it would leak to anyone who can strip STARTTLS on the way. Use the server's implicit TLS port: tls = \"implicit\" and port = \"465\" on the SMTP instance."
          else
            null;

        # Variables config/runtime.exs reads as credentials. A string value
        # would land in the Nix store and the rendered Deployment.
        credentialNames = [
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
            throw "${who}: env sets ${lib.concatStringsSep ", " literalCredentials} to a literal string, which would land in Kix's local store and the rendered Deployment. Pass a secretKeyRef source to a Secret managed outside Kix (kix.untrackedRef)."
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

        # On several replicas, the migrations run on one replica, the first
        # in `replicaHosts` that answers, so every plain table they create is
        # on that one. The migrate container writes its address to
        # `replicaHostFile`, and replicate.py then makes the tables
        # replicated and creates them on the others from the same replica.
        # Trying them in order keeps every start on replica 0 while it is
        # up. The server uses the load-balanced Service.
        replicated = ch.replicas != "1";
        replicaDir = "/run/plausible-replica";
        replicaHostFile = "${replicaDir}/host";
        # PLAUSIBLE_CH_USERNAME and PLAUSIBLE_CH_PASSWORD come from
        # credentialEnv. The image's entrypoint is /entrypoint.sh.
        chooseAndMigrate = ''
          for host in $CLICKHOUSE_REPLICA_HOSTS; do
            if wget -q -T 5 -O /dev/null "http://$host:${ch.ports.http}/ping"; then
              echo "migrate: migrating on $host"
              echo "$host" > ${replicaHostFile}
              export CLICKHOUSE_DATABASE_URL="http://$PLAUSIBLE_CH_USERNAME:$PLAUSIBLE_CH_PASSWORD@$host:${ch.ports.http}/${ch.database}"
              exec /entrypoint.sh db migrate
            fi
            echo "migrate: ClickHouse replica $host does not answer"
          done
          echo "migrate: no ClickHouse replica answers"
          exit 1
        '';
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
                  vars = lib.optionalAttrs (relay != null) (
                    {
                      MAILER_ADAPTER = "Bamboo.Mua";
                      MAILER_EMAIL = relay.from;
                      SMTP_HOST_ADDR = relay.host;
                      SMTP_HOST_PORT = relay.port;
                      SMTP_HOST_SSL_ENABLED = lib.boolToString (relay.tls == "implicit");
                    }
                    // lib.optionalAttrs (relay.credentials != null) {
                      SMTP_USER_NAME = relay.credentials.out.keyRef "username";
                      SMTP_USER_PWD = relay.credentials.out.keyRef "password";
                    }
                  );
                  names = [
                    "SMTP_HOST_ADDR"
                    "SMTP_HOST_PORT"
                    "SMTP_HOST_SSL_ENABLED"
                    "SMTP_USER_NAME"
                    "SMTP_USER_PWD"
                  ]
                  ++ lib.optionals (relay != null) [
                    "MAILER_ADAPTER"
                    "MAILER_EMAIL"
                  ];
                  from = "the smtp dependency";
                  fix = "Declare the mail server as a kix.mkImport whose out sets host, port, tls, and from, with credentials = ref.<ns>.<secret> naming a secret with keys `username` and `password` (a secret-ref for a Secret written outside Kix). Set the sender with mail.from.";
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
                CLICKHOUSE_HOST_FILE = replicaHostFile;
                CLICKHOUSE_PORT = ch.ports.http;
                CLICKHOUSE_DATABASE = ch.database;
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
        };

        # The replicate script, and the file through which it tells the
        # migrate container which replica to migrate on.
        replicateScriptMount = kix.mount.configMap self.replicateScript {
          name = "replicate";
          mountPath = "/replicate";
          readOnly = true;
        };
        replicaMount =
          readOnly:
          kix.mount.emptyDir {
            name = "replica";
            mountPath = replicaDir;
            medium = "Memory";
            sizeLimit = "1Mi";
            inherit readOnly;
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
          _relayCheck
          _credentialCheck
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
                  "checksum/smtp" =
                    if relay != null && relay.credentials != null then
                      relay.credentials.out.identityHash or null
                    else
                      null;
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
                  initContainers = [
                    (
                      container
                      // {
                        name = "migrate";
                      }
                      // (
                        if replicated then
                          {
                            command = [
                              "/bin/sh"
                              "-c"
                              chooseAndMigrate
                            ];
                            env = env ++ kix.mkEnvVars { CLICKHOUSE_REPLICA_HOSTS = lib.concatStringsSep " " ch.replicaHosts; };
                          }
                        else
                          {
                            args = [
                              "db"
                              "migrate"
                            ];
                          }
                      )
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
            # migrate writes the host of the replica it migrated on to the
            # replica volume; replicate reads that host and its script.
            |> (
              if replicated then
                kix.withMountsOn "replicate" [
                  replicateScriptMount
                  (replicaMount true)
                ]
              else
                lib.id
            )
            # The migrations read the same configuration and paths as the
            # server.
            |> kix.withMountsOn [ "migrate" "plausible" ] mounts
            |> (if replicated then kix.withMountsOn "migrate" [ (replicaMount false) ] else lib.id)
            |> scope.mkDeployment;

          replicateScript =
            if replicated then
              lib.warn
                "${who}: deps.clickhouseDatabase is on a ClickHouse server with ${ch.replicas} replicas. Plausible Community Edition documents a single ClickHouse server; Kix migrates on one replica and converts Plausible's tables to replicated ones in the `replicate` init container, which Plausible does not support. It was tested with Plausible v${release}. Before upgrading Plausible, test the new version on a replicated ClickHouse, and upgrade only while every replica is up."
                scope.mkResource
                {
                  apiVersion = "v1";
                  kind = "ConfigMap";
                  name = "${name}-replicate";
                  data."replicate.py" = replicatePy;
                }
            else
              null;

          mailEgress = kix.contracts.smtp.helpers.egressPolicy {
            inherit scope;
            smtp = relay;
            name = "${name}-mail-egress";
            selector = self.deployment.out.selector;
          };

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
