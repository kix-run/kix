# ClickHouse database: one database and one user on a ClickHouse server,
# with the user's credentials in the consumer's own namespace
# (v2_discussions/148, phase 2). The package an application depends on; it
# never depends on the server directly.
#
# Works against either implementation of the `clickhouse` contract
# (../clickhouse/contract.nix), because everything it runs is replicated DDL
# (`ON CLUSTER '{cluster}'`), which a bare single node with embedded Keeper
# and an operator-run cluster both accept. The dep is held to the contract
# at eval time, and to a minimum server version, since the SQL the Job runs
# was only ever verified against recent releases.
#
# Why it exists, and why it looks like stackgres-database:
#   Secrets are namespaced. The server's own credentials sit next to the
#   server and belong to its administrator account, which an application in
#   another namespace can neither mount nor should have. Here each consumer
#   gets a user with exactly the privileges it names, on its own database,
#   and the Secret holding that user's password is in the consumer's
#   namespace.
#
# How it works:
#   1. `credentials`, a Secret in this (the consumer's) namespace with
#      username, password, database, host and ports.
#   2. `bootstrapPassword`, the same password in the server's namespace
#      (`scope.forService clickhouse`), so the Job there can take it by
#      secretKeyRef.
#   3. `schemaFiles`, a ConfigMap in the server's namespace holding the
#      consumer's `schema` files, when there are any.
#   4. `bootstrapJob`, in the server's namespace, logged in as the server's
#      administrator from `clickhouse.out.authSecret`. It creates the
#      database and the user, sets the password, grants the privileges and
#      then runs the schema files in name order. Every statement is
#      idempotent. The Job's name carries a hash of its inputs, so a change
#      is a new Job and the old one is reaped by its TTL. It deliberately
#      does not carry the rerun-on-change annotation: that would run the
#      consumer's schema again whenever anything upstream of the server
#      moved, and only the package's own statements are known to be safe
#      to repeat.
#
# Two users on one database (a writer and a reader, say) are two instances
# with the same `database` and different `user` and `privileges`.
#
# Schema files are the consumer's own SQL. They should be written so they
# can run twice (`CREATE TABLE IF NOT EXISTS`), use `ON CLUSTER '{cluster}'`
# with a `Replicated*` engine, and name the database as
# `{database:Identifier}`, which the Job binds. Migrations beyond
# create-if-absent are the application's business.
#
# Practice the server does not enforce:
#   - Insert in batches (a thousand rows or more, about one insert a
#     second) or with `async_insert`. Each insert writes a part for every
#     partition it touches, and a partition past parts_to_throw_insert
#     (3000 active parts) refuses inserts.
#   - Prefer `CODEC(ZSTD(1))` on large columns over the LZ4 default when
#     disk matters more than CPU.
#   - A materialized view runs inside every insert into its source and
#     counts against that insert's memory. A view that needs more than
#     planned fails the inserts, and until then takes from the server's
#     memory cap that every other query shares. Users created here take
#     the server's `default` settings profile, so `max_memory_usage` set
#     there caps each of their queries: `usersConfig` on clickhouse,
#     `extraSpec.configuration.profiles` on clickhouse-cluster.
#   - Retry a failed insert with the same rows in the same order, so that
#     replicated insert deduplication drops the copy. Different batches on
#     retry write the data twice, and every materialized view with it. An
#     `async_insert` is deduplicated only with `async_insert_deduplicate`
#     on (off by default).
#
# DI deps:
#   clickhouse (required)  anything honouring the clickhouse contract
#
# Exposes:
#   out.httpUrl, out.nativeEndpoint, out.host, out.ports
#                       the server's, carrying an edge to the bootstrap Job
#                       so a consumer starts after its database exists
#   out.database        database name
#   out.username        user name
#   out.privileges      what the user was granted, so a consumer can refuse
#                       a database it could not use
#   out.credentials     the Secret; keys username, password, database, host,
#                       httpPort, nativePort
#   out.version         the server release as YY.M, forwarded from the
#                       contract, for a consumer with a requirement of its own
#
# root = credentials Secret.

{
  scope,
  lib,
  kix,
}:
let
  name = scope.instanceName;

  # Both end up inside backquoted identifiers in SQL the Job runs as the
  # administrator.
  identifier = lib.types.strMatching "[A-Za-z_][A-Za-z0-9_]*";

  contract = import ../clickhouse/contract.nix { inherit lib; };

  # The bootstrap SQL and the probe were written and verified against 26.3.
  # Nothing older than this has been tried, and an untried server is
  # refused rather than assumed to work. Raise it when something the Job
  # runs needs a newer server; lower it only after running the fixture
  # against the older one.
  supportedFrom = "25.3";
in
{
  meta = {
    version = "0.1.0";
    description = "A database and a user on a ClickHouse server, credentials in the consumer's namespace";
    lifecycle = "stateful";
    scope = "namespace";
    defaultAliases = [ "clickhouseDatabase" ];
  };

  deps = {
    # The contract first, so the version check below can trust out.version.
    clickhouse.assertions =
      dep:
      let
        who = "clickhouse-database '${name}'";
        contractProblems = contract.assertions who dep.out;
      in
      if contractProblems != [ ] then
        contractProblems
      else
        lib.optional (lib.versionOlder dep.out.version supportedFrom) {
          assertion = false;
          message = "${who} needs ClickHouse ${supportedFrom} or newer for the SQL its bootstrap runs, and the clickhouse instance it resolved to is ${dep.out.version}.";
        };
  };

  options = {
    database = lib.mkOption {
      type = identifier;
      default = lib.replaceStrings [ "-" ] [ "_" ] name;
      description = "Database to create. Defaults to the instance name with dashes as underscores.";
    };

    user = lib.mkOption {
      type = identifier;
      default = lib.replaceStrings [ "-" ] [ "_" ] name;
      description = "User to create. Defaults to the instance name with dashes as underscores.";
    };

    privileges = lib.mkOption {
      type = lib.types.listOf (lib.types.strMatching "[A-Z][A-Z ]*");
      default = [ "ALL" ];
      example = [
        "SELECT"
        "INSERT"
      ];
      description = ''
        ClickHouse privileges granted to the user on every table of the
        database (`GRANT <these> ON <database>.*`). A log shipper wants
        [ "INSERT" ], a dashboard [ "SELECT" ].
      '';
    };

    schema = lib.mkOption {
      type = lib.types.attrsOf lib.types.lines;
      default = { };
      example = {
        "01-events.sql" = ''
          CREATE TABLE IF NOT EXISTS {database:Identifier}.events ON CLUSTER '{cluster}'
          (ts DateTime, message String)
          ENGINE = ReplicatedMergeTree ORDER BY ts
        '';
      };
      description = ''
        SQL files run after the database and user exist, in name order, as
        the server's administrator. `{database:Identifier}` is bound to the
        database name. Each file must be safe to run again.
      '';
    };

    password = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Literal password (development only). The plaintext lands in the Nix
        store and in the rendered Secret, so use passwordSource for
        anything real.
      '';
    };

    passwordSource = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "SOPS-encrypted file with a `password` key. Both Secrets are hydrated from it at deploy time.";
    };

    passwordHash = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Content hash of the decrypted password. Required with passwordSource; it is what makes a rotation a new bootstrap Job.";
    };

    image = kix.options.image {
      repository = "docker.io/clickhouse/clickhouse-server";
      tag = "26.3.33.24";
      digest = "sha256:810861a2e2d0188744f5f23b2d3ec9ff95812bcb9ddbb8fed13a377a7f305893";
    };
  };

  build =
    {
      self,
      config,
      clickhouse,
      scope,
      lib,
      kix,
      ...
    }:
    let
      _passwordCheck =
        if config.password == null && config.passwordSource == null then
          throw "clickhouse-database '${name}': set `password` (literal, development) or `passwordSource` (SOPS path)."
        else if config.password != null && config.passwordSource != null then
          throw "clickhouse-database '${name}': set `password` or `passwordSource`, not both."
        else if config.passwordSource != null && config.passwordHash == null then
          throw "clickhouse-database '${name}': `passwordHash` is required with `passwordSource`."
        else
          null;

      server = clickhouse.out;
      backendScope = scope.forService clickhouse;
      hasSchema = config.schema != { };

      bootstrapHash = builtins.substring 0 10 (
        builtins.hashString "sha256" (
          builtins.toJSON {
            inherit (config)
              database
              user
              privileges
              schema
              ;
            image = kix.image.ref config.image;
            script = bootstrapScript;
            sql = bootstrapSql;
            passwordFingerprint = if config.passwordHash != null then config.passwordHash else config.password;
          }
        )
      );

      labels = {
        "app.kubernetes.io/name" = "clickhouse-database";
        "app.kubernetes.io/instance" = name;
      };

      secretMeta = {
        classification = "credential";
        rotationPolicy = "manual";
      };

      # The SQL the package owns. Identifiers are typed options, so they are
      # safe inside backquotes; the password never enters the text, it is
      # bound as {password:String}.
      bootstrapSql = ''
        CREATE DATABASE IF NOT EXISTS `${config.database}` ON CLUSTER '{cluster}';
        CREATE USER IF NOT EXISTS `${config.user}` ON CLUSTER '{cluster}' IDENTIFIED WITH sha256_password BY {password:String};
        ALTER USER `${config.user}` ON CLUSTER '{cluster}' IDENTIFIED WITH sha256_password BY {password:String};
        GRANT ON CLUSTER '{cluster}' ${lib.concatStringsSep ", " config.privileges} ON `${config.database}`.* TO `${config.user}`;
      '';

      bootstrapScript = ''
        set -eu
        client() {
          clickhouse-client --host "$CH_HOST" --port "$CH_PORT" \
            --user "$CH_ADMIN_USER" --password "$CH_ADMIN_PASSWORD" "$@"
        }

        echo "waiting for clickhouse at $CH_HOST:$CH_PORT"
        for _ in $(seq 1 60); do
          if client --query "SELECT 1" >/dev/null 2>&1; then break; fi
          sleep 2
        done
        client --query "SELECT 1" >/dev/null

        echo "ensuring database ${config.database}, user ${config.user} and grants"
        client --multiquery --param_password="$NEW_PASSWORD" < /bootstrap/bootstrap.sql

        for file in /schema/*.sql; do
          [ -e "$file" ] || continue
          echo "running $file"
          client --multiquery --param_database="${config.database}" < "$file"
        done

        echo "clickhouse-database bootstrap complete for ${config.user}@${config.database}"
      '';
    in
    builtins.seq _passwordCheck {
      credentials = scope.mkSecret {
        name = "${name}-credentials";
        keys = [
          "username"
          "password"
          "database"
          "host"
          "httpPort"
          "nativePort"
        ];
        stringData = {
          username = config.user;
          database = config.database;
          host = server.host;
          httpPort = server.ports.http;
          nativePort = server.ports.native;
        }
        // lib.optionalAttrs (config.password != null) { inherit (config) password; };
        source = config.passwordSource;
        hash = config.passwordHash;
        inherit labels;
        meta = secretMeta;
      };

      bootstrapPassword = backendScope.mkSecret {
        name = "${name}-bootstrap-password";
        keys = [ "password" ];
        stringData = lib.optionalAttrs (config.password != null) { inherit (config) password; };
        source = config.passwordSource;
        hash = config.passwordHash;
        inherit labels;
        meta = secretMeta;
      };

      bootstrapFiles = backendScope.mkResource {
        apiVersion = "v1";
        kind = "ConfigMap";
        name = "${name}-bootstrap";
        inherit labels;
        data = {
          "bootstrap.sh" = bootstrapScript;
          "bootstrap.sql" = bootstrapSql;
        };
      };

      schemaFiles =
        if hasSchema then
          backendScope.mkResource {
            apiVersion = "v1";
            kind = "ConfigMap";
            name = "${name}-schema";
            inherit labels;
            data = config.schema;
          }
        else
          null;

      bootstrapMount = kix.mount.configMap self.bootstrapFiles {
        mountPath = "/bootstrap";
        readOnly = true;
      };
      schemaMount = kix.mount.configMap self.schemaFiles {
        mountPath = "/schema";
        readOnly = true;
      };
      # clickhouse-client keeps its history and scratch files under $HOME.
      homeMount = kix.mount.emptyDir {
        name = "home";
        mountPath = "/home/clickhouse";
        sizeLimit = "16Mi";
      };

      bootstrapJob =
        {
          name = "${name}-bootstrap-${bootstrapHash}";
          inherit labels;
          spec = {
            backoffLimit = 10;
            ttlSecondsAfterFinished = 86400;
            template = {
              metadata.labels = labels;
              spec = {
                restartPolicy = "OnFailure";
                automountServiceAccountToken = false;
                securityContext = {
                  runAsNonRoot = true;
                  runAsUser = 101;
                  runAsGroup = 101;
                  seccompProfile.type = "RuntimeDefault";
                };
                containers = [
                  {
                    name = "bootstrap";
                    image = kix.image.ref config.image;
                    imagePullPolicy = config.image.pullPolicy;
                    command = [
                      "/bin/sh"
                      "/bootstrap/bootstrap.sh"
                    ];
                    env = kix.mkEnvVars {
                      HOME = "/home/clickhouse";
                      CH_HOST = server.host;
                      CH_PORT = server.ports.native;
                      CH_ADMIN_USER = server.username;
                      CH_ADMIN_PASSWORD = server.authSecret.out.keyRef server.authPasswordKey;
                      NEW_PASSWORD = self.bootstrapPassword.out.keyRef "password";
                    };
                    resources = {
                      requests = {
                        cpu = "50m";
                        memory = "128Mi";
                      };
                      limits = {
                        cpu = "500m";
                        memory = "256Mi";
                      };
                    };
                    securityContext = {
                      runAsNonRoot = true;
                      allowPrivilegeEscalation = false;
                      readOnlyRootFilesystem = true;
                      capabilities.drop = [ "ALL" ];
                    };
                  }
                ];
              };
            };
          };
        }
        |> kix.withMounts [
          self.bootstrapMount
          self.schemaMount
          self.homeMount
        ]
        |> backendScope.mkJob;

      # The server's outputs with the bootstrap Job riding on every address,
      # so whoever reads `out.host` waits for the database to exist.
      ch = scope.forwardEdges clickhouse [ self.bootstrapJob ];

      root = {
        resource = self.credentials;
        # The database is ready when its bootstrap has run, not when its
        # Secret exists.
        requires = [ self.bootstrapJob ];
        out = {
          inherit (self.ch) httpUrl nativeEndpoint host;
          inherit (server) ports version;
          inherit (config) database privileges;
          username = config.user;
          credentials = self.credentials;
        };
      };
    };
}
