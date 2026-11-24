# ClickHouse database: one database and one user on a ClickHouse server,
# with the user's credentials in the consumer's own namespace. The package
# an application depends on; it never depends on the server directly.
#
# Works against either implementation of the `clickhouse` contract
# (`kix.contracts.experimental.clickhouse`), because everything it runs is replicated DDL
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
#      username, password, database, host, and ports. Without a SOPS
#      password it is the password dependency (see below).
#   2. `bootstrapPassword`, the same password in the server's namespace
#      (`scope.forService clickhouse`), so the Job there can take it by
#      secretKeyRef.
#   3. `schemaFiles`, a ConfigMap in the server's namespace holding the
#      consumer's `schema` files, when there are any.
#   4. `bootstrapJob`, in the server's namespace, logged in as the server's
#      administrator from `clickhouse.out.credentials`. It creates the
#      database and the user, sets the password, grants the privileges, and
#      then runs the schema files in name order. Every statement is
#      idempotent. The Job carries `kix.run/rerun: on-change`, so the deploy
#      runs it again when its own content changes. Its pod template carries
#      the content hashes of what it reads, so a new SOPS file, a changed
#      option or schema file, or a changed server runs it again. That is
#      why each schema file must be safe to run again.
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
# Dependencies:
#   clickhouse (required)  anything honouring the clickhouse contract
#   password (required)    the user's password, a secret with the key
#                          `password` (kix.contracts.secret), in this
#                          instance's namespace.
#
# Where the password comes from decides what the package renders:
#
# - A `packages.secret` with a SOPS `source`: the package renders the
#   credentials Secret and `bootstrapPassword` in the server's namespace
#   from that file, and the deploy fills both.
# - Any other secret (`packages.secret-ref`, `packages.experimental.external-secret`,
#   a site's own source package): the package renders neither. The
#   dependency is the credentials Secret, so it must also hold `username`,
#   equal to `user`, and it holds no `database`, `host`, `httpPort`, or
#   `nativePort`. The site writes the password into the server's namespace
#   too, as the Secret `<instance>-<namespace>-bootstrap-password` with the
#   key `password`, and the deploy waits for it.
#
# Minimal instance, beside an app that takes deps.clickhouseDatabase:
#
#   app-ch = {
#     package = packages.experimental.clickhouse-database;
#     deps.password = ref.apps.app-ch-password;
#   };
#   app-ch-password = {
#     package = packages.secret;
#     config = {
#       source = ./secrets/app-ch.yaml;   # holds `password`
#       keys = [ "password" ];
#     };
#   };
#
# `out`:
#   out.httpUrl, out.nativeEndpoint, out.host, out.ports
#                       the server's, carrying an edge to the bootstrap Job
#                       so a consumer starts after its database exists
#   out.database        database name
#   out.username        user name
#   out.privileges      what the user was granted, so a consumer can refuse
#                       a database it could not use
#   out.grants          what the user was granted outside its database
#   out.credentials     the credentials Secret: the one this package
#                       renders, with keys username, password, database,
#                       host, httpPort, and nativePort, or the password
#                       dependency, with username and password
#   out.version         the server version, forwarded from the
#                       contract, for a consumer with a requirement of its own
#   out.replicas        the shard's replica count, forwarded from the
#                       contract
#   out.replicaHosts    one address per replica, forwarded from the
#                       contract with the bootstrap Job's edge
#
# root = credentials Secret.
#
# Limits: Kix copies only a value it decrypts itself, so a password from any
# other source has to be delivered to both namespaces. With such a source a
# changed password does not run the Job again, because the build cannot see
# the value. Delete the Job and deploy again to set the new password.

{
  scope,
  lib,
  kix,
}:
let
  name = scope.instanceName;
  # The default database and user name. A ClickHouse server is shared
  # across namespaces, so the name carries the namespace: two instances
  # named alike in two namespaces get a database and a user each.
  defaultIdentifier = lib.replaceStrings [ "-" ] [ "_" ] "${scope.namespaceName}_${name}";

  # Both end up inside backquoted identifiers in SQL the Job runs as the
  # administrator.
  identifier = lib.types.strMatching "[A-Za-z_][A-Za-z0-9_]*";

  contract = kix.contracts.experimental.clickhouse;

  # The bootstrap SQL and the probe were written against 26.3 and verified
  # against 26.3 and 26.8.
  # Nothing older than this has been tried, and an untried server is
  # refused rather than assumed to work. Raise it when something the Job
  # runs needs a newer server; lower it only after running the fixture
  # against the older one.
  supportedFrom = "25.3";
in
{
  meta = {
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
        contractProblems = contract.assertions dep;
      in
      if contractProblems != [ ] then
        contractProblems
      else
        lib.optional (lib.versionOlder dep.out.version supportedFrom) {
          assertion = false;
          message = "This instance needs ClickHouse ${supportedFrom} or newer for the SQL its bootstrap runs, and the clickhouse instance it resolved to is ${dep.out.version}.";
        };
  };

  options = {
    database = lib.mkOption {
      type = identifier;
      default = defaultIdentifier;
      defaultText = lib.literalExpression ''"<namespace>_<instance>", dashes as underscores'';
      description = "Database to create. Defaults to the namespace and the instance name, joined by an underscore, with dashes as underscores.";
    };

    user = lib.mkOption {
      type = identifier;
      default = defaultIdentifier;
      defaultText = lib.literalExpression ''"<namespace>_<instance>", dashes as underscores'';
      description = "User to create. Defaults to the namespace and the instance name, joined by an underscore, with dashes as underscores.";
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

    grants = lib.mkOption {
      # Keys go into the GRANT statement unquoted, so they are limited to
      # `*` or a plain identifier on each side of the dot.
      type = lib.types.attrsOf (lib.types.listOf (lib.types.strMatching "[A-Z][A-Z ]*"));
      default = { };
      example = {
        "*.*" = [ "CREATE FUNCTION" ];
        "system.replicas" = [ "SELECT" ];
      };
      description = ''
        ClickHouse privileges granted to the user on objects outside its
        database, keyed by `<database>.<table>` with `*` for any
        (`GRANT <these> ON <key>`): SQL user-defined functions belong to no
        database (`*.*`), and reading a system table needs its own grant.
        A consumer that needs one injects it through its dependency's
        config.
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
      type = lib.types.nullOr lib.types.anything;
      default = null;
      visible = false;
      description = "Removed. Setting it fails the build with a message that names the `password` dependency.";
    };
    passwordSource = lib.mkOption {
      type = lib.types.nullOr lib.types.anything;
      default = null;
      visible = false;
      description = "Removed. Setting it fails the build with a message that names the `password` dependency.";
    };
    passwordHash = lib.mkOption {
      type = lib.types.nullOr lib.types.anything;
      default = null;
      visible = false;
      description = "Removed. Setting it fails the build with a message that names the `password` dependency.";
    };

    image = kix.options.image {
      repository = "docker.io/clickhouse/clickhouse-server";
      tag = "26.8.40.7";
      digest = "sha256:6d462904f276dc6c1fa531d887cac02d4ef7a8f212d6142377d36608c2330d59";
    };
  };

  build =
    {
      self,
      config,
      clickhouse,
      # Optional only so that a build with the removed options reaches
      # _passwordCheck and its message; a missing one fails below.
      password ? null,
      scope,
      lib,
      kix,
      ...
    }:
    let

      passwordAdvice = "Give the password as the dependency `password`: a packages.secret instance in this namespace with source set to a SOPS file that holds `password`, and keys = [ \"password\" ], wired with deps.password = ref.<namespace>.<instance>. A secret that Kix does not fill from a SOPS file, such as a secret-ref or an external-secret, must also hold `username`, equal to the database's user, and list it in keys.";

      _passwordCheck =
        if config.password != null then
          scope.fail {
            id = "K9503";
            option = "password";
            message = "password was removed, because it put the password in plain text in Kix's local store and in the built Secrets.";
            fix = passwordAdvice;
          }
        else if config.passwordSource != null || config.passwordHash != null then
          scope.fail {
            id = "K6023";
            option = "passwordSource";
            message = "passwordSource and passwordHash were removed.";
            fix = "${passwordAdvice} Use the same file.";
          }
        else if password == null then
          scope.fail {
            message = "This instance has no `password` dependency.";
            fix = passwordAdvice;
          }
        else
          null;

      # With a SOPS file Kix decrypts the password itself, so it renders the
      # Secrets in both namespaces. Otherwise the site delivers both.
      sops = (passwordDep.out.sops or null);
      fromSops = sops != null;
      passwordDep =
        let
          dep = builtins.seq _passwordCheck (
            kix.contracts.secret.helpers.use {
              inherit scope;
              arg = "password";
              dep = password;
              keys = [ "password" ];
            }
          );
          declared = dep.out.keys or [ ];
        in
        (
          if dep.out ? sops || builtins.elem "username" declared then
            dep
          else
            scope.fail {
              message = "deps.password resolved to secret \"${dep.out.name}\", which Kix does not fill from a SOPS file, so it is also the credentials Secret the app reads.";
              fix = "Add `username` (equal to user, \"${config.user}\") to that secret and to its keys, or use a packages.secret with a SOPS source.";
            }
        );

      badGrantKeys = builtins.filter (
        k: builtins.match "(\\*|[A-Za-z_][A-Za-z0-9_]*)\\.(\\*|[A-Za-z_][A-Za-z0-9_]*)" k == null
      ) (builtins.attrNames config.grants);
      _grantsCheck =
        if badGrantKeys != [ ] then
          scope.fail {
            option = "grants";
            message = "grants keys must be `<database>.<table>`, each side `*` or a plain identifier, and these are not: ${lib.concatStringsSep ", " badGrantKeys}.";
          }
        else
          null;

      server = clickhouse.out;
      backendScope = scope.forService clickhouse;
      # Instances in different namespaces may share a name and a server, so
      # what this package puts in the server's namespace carries its own.
      serverSideName = "${name}-${scope.namespaceName}";
      hasSchema = config.schema != { };

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
      ''
      + lib.concatStrings (
        lib.mapAttrsToList (
          object: privileges:
          lib.optionalString (privileges != [ ]) ''
            GRANT ON CLUSTER '{cluster}' ${lib.concatStringsSep ", " privileges} ON ${object} TO `${config.user}`;
          ''
        ) config.grants
      );

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
    builtins.seq passwordDep (
      builtins.seq _grantsCheck {
        # In the consumer's namespace. From a SOPS file, the deploy fills
        # `password`. Otherwise the password dependency is the credentials.
        credentials =
          if fromSops then
            scope.mkSecret {
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
              };
              inherit (sops) source;
              inherit labels;
              meta = secretMeta;
            }
          else
            scope.mkSecretRef {
              name = passwordDep.out.name;
              keys = [
                "username"
                "password"
              ];
            };

        # The user's password in the server's namespace, so the Job reads it
        # by secretKeyRef: rendered from the same SOPS file as `credentials`,
        # or written there by the site.
        bootstrapPassword =
          if fromSops then
            backendScope.mkSecret {
              name = "${serverSideName}-bootstrap-password";
              keys = [ "password" ];
              inherit (sops) source;
              inherit labels;
              meta = secretMeta;
            }
          else
            backendScope.mkSecretRef {
              name = "${serverSideName}-bootstrap-password";
              keys = [ "password" ];
            };

        bootstrapFiles = backendScope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "${serverSideName}-bootstrap";
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
              name = "${serverSideName}-schema";
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
            name = "${serverSideName}-bootstrap";
            inherit labels;
            spec = {
              backoffLimit = 10;
              template = {
                metadata = {
                  inherit labels;
                  # The deploy reruns the Job when its content or the content
                  # of a Kix-built Secret or ConfigMap it reads changes. The
                  # server is reached over the network, so its checksum
                  # annotation reruns the Job when the server changes. An
                  # imported server has no content hash.
                  annotations = lib.filterAttrs (_: v: v != null) {
                    "checksum/server" = server.contentHash or null;
                  };
                };
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
                        CH_ADMIN_PASSWORD = server.credentials.out.keyRef "password";
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
            inherit (server) ports version replicas;
            replicaHosts = map (scope.augmentEdge [ self.bootstrapJob ]) server.replicaHosts;
            inherit (config) database privileges grants;
            username = config.user;
            credentials = self.credentials;
          };
        };
      }
    );
}
