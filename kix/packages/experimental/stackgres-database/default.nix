# stackgres-database: a PostgreSQL role and database for one application,
# created on a StackGres cluster.
#
# The package creates a credentials Secret in its own namespace, the
# consumer's (keys `username`, `password`, `database`, `host`, `port`), and
# in the cluster's namespace a Secret with the role's password and a Job
# that creates or updates the role, creates the database, grants the role
# all privileges on it (and ownership with `owner`), and creates the
# requested extensions. The Job logs in with the superuser Secret StackGres
# creates next to the SGCluster. Its name carries a hash of its inputs, so a
# changed password or extension list runs a new Job.
#
# The app depends on this instance rather than on the cluster: a Secret is
# readable only in its own namespace, and the cluster's holds the superuser.
#
# Dependencies:
#   postgres (required)  a stackgres-cluster, or an import of an SGCluster
#                        whose out has name, fqdn, port, and extensions.
#                        The `extensions` option is added to its
#                        `extensions`.
#   password (required)  the role's password, a secret with the key
#                        `password` (kix.contracts.secret), in this
#                        instance's namespace.
#
# Where the password comes from decides what the package renders:
#
# - A `packages.secret` with a SOPS `source`: the package renders the
#   credentials Secret and the cluster-side Secret from that file, and the
#   deploy fills both.
# - Any other secret (`packages.secret-ref`, `packages.experimental.external-secret`,
#   a site's own source package): the package renders neither. The
#   dependency is the credentials Secret, so it must also hold `username`,
#   equal to `user`. The site writes the password into the cluster's
#   namespace too, as the Secret `<instance>-<namespace>-bootstrap-password`
#   with the key `password`, and the deploy waits for it.
#
# Minimal instance, beside an app that takes deps.database:
#
#   app-db = {
#     package = packages.experimental.stackgres-database;
#     deps.password = ref.apps.app-db-password;
#   };
#   app-db-password = {
#     package = packages.secret;
#     config = {
#       source = ./secrets/app-db.yaml;   # holds `password`
#       hash = "sha256-...";
#       keys = [ "password" ];
#     };
#   };
#
# A consumer reads:
#
#   env = kix.mkEnv {
#     DB_HOST = database.out.host;
#     DB_PORT = database.out.port;
#     DB_NAME = database.out.database;
#   } (database.out.credentials.out.mkEnv {
#     DB_USER = "username";
#     DB_PASSWORD = "password";
#   });
#
# Exposes the Postgres database contract (kix/contracts/stable/postgresDatabase.nix,
# `kix.contracts.postgresDatabase`), which root.out passes through `check`:
#   out.host, out.port      the cluster's primary Service. They carry the
#                           Job, so a consumer's workload waits for it and
#                           gets network policy to PostgreSQL.
#   out.database            the database name.
#   out.username            the role name.
#   out.extensions          the `extensions` option.
#   out.credentials         the credentials Secret, for `out.mkEnv`: the
#                           one this package renders, or the password
#                           dependency.
#   out.tls                 whether PostgreSQL serves TLS (the postgres
#                           dependency's `out.tls`), or null when it
#                           publishes none, as an import.
#
# root = the credentials Secret.
#
# Escape hatches: `bootstrap.image` and `bootstrap.resources` for the Job,
# and the instance's `partsOverlays`.
#
# Limits: Kix copies only a value it decrypts itself, so a password from any
# other source has to be delivered to both namespaces. With such a source a
# changed password runs no new Job, because the build cannot see the value;
# delete the last Job, or change another input, to set the new password.

{
  scope,
  lib,
  kix,
}:

let
  name = scope.instanceName;
  who = "stackgres-database ${scope.namespaceName}/${name}";

  # A plain name or `{ name; version; }`, as stackgres-cluster takes it.
  normalizeExtension =
    e:
    if builtins.isString e then
      { name = e; }
    else
      { inherit (e) name; } // lib.optionalAttrs (e.version != null) { inherit (e) version; };

  # PostgreSQL identifiers the bootstrap script quotes: double quotes in SQL,
  # single quotes in the shell. The pattern admits neither quote nor `$`.
  identifier = lib.types.strMatching "[A-Za-z_][A-Za-z0-9_-]{0,62}";
in
{
  meta = {
    description = "Logical database + role provisioned on a StackGres cluster";
    owner = "platform";
    lifecycle = "stateful"; # other packages depend on this database existing
    scope = "namespace";
    defaultAliases = [ "database" ];
  };

  # Adds this instance's extensions, including those a consumer injects
  # through deps.database.config.extensions, to the postgres dependency's
  # `extensions`, so the operator installs them.
  deps.postgres.config = consumerConfig: {
    extensions = map normalizeExtension consumerConfig.extensions;
  };

  options = {
    database = lib.mkOption {
      type = identifier;
      default = name;
      defaultText = lib.literalMD "the instance name";
      description = "PostgreSQL database name to create: a letter or underscore, then up to 62 letters, digits, underscores, or hyphens.";
    };

    user = lib.mkOption {
      type = identifier;
      default = name;
      defaultText = lib.literalMD "the instance name";
      description = "PostgreSQL role name to create: a letter or underscore, then up to 62 letters, digits, underscores, or hyphens.";
    };

    owner = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Make the role the owner of the database (in addition to GRANT ALL).";
    };

    extensions = lib.mkOption {
      type = lib.types.listOf (
        lib.types.either lib.types.str (
          lib.types.submodule {
            options = {
              name = lib.mkOption {
                type = lib.types.nonEmptyStr;
                description = "Extension name.";
              };
              version = lib.mkOption {
                type = lib.types.nullOr lib.types.nonEmptyStr;
                default = null;
                description = "Extension version the cluster installs. Null takes the repository's default.";
              };
            };
          }
        )
      );
      default = [ ];
      description = ''
        Extensions to CREATE EXTENSION IF NOT EXISTS on the new database, as
        a name or `{ name; version; }`. They are added to the postgres
        dependency's `extensions`, so a stackgres-cluster installs them. An
        imported cluster must already have them and list them in its
        `out.extensions`.
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

    bootstrap.resources = kix.options.resources {
      requests = {
        cpu = "10m";
        memory = "32Mi";
      };
      limits = {
        cpu = "500m";
        memory = "128Mi";
      };
    };

    bootstrap.image = kix.options.image {
      repository = "docker.io/library/postgres";
      tag = "18.6-alpine";
      digest = "sha256:77f585114c32fbca283dc835b0596f4e52b51b4c6662d7810b2f4084f60a1873";
      pullPolicy = null;
      description = "Image of the bootstrap Job. It must contain `psql` and `pg_isready`, and run as uid 70, the `postgres` user of the official Alpine images.";
    };
  };

  build =
    {
      self,
      config,
      postgres,
      # Optional only so that a build with the removed options reaches
      # _passwordCheck and its message; a missing one fails below.
      password ? null,
      scope,
      lib,
      kix,
      ...
    }:
    let
      dbName = config.database;
      userName = config.user;
      extensionNames = map (e: (normalizeExtension e).name) config.extensions;

      _extensionsCheck =
        let
          published = postgres.out.extensions or [ ];
          missing = builtins.filter (n: !(builtins.elem n published)) extensionNames;
        in
        if missing != [ ] then
          throw "${who}: needs extensions ${lib.concatStringsSep ", " missing} on its postgres dependency, which publishes out.extensions = [ ${lib.concatStringsSep " " published} ]. On a stackgres-cluster they are forwarded automatically; on an import, install them and list them in its out.extensions."
        else
          null;

      passwordAdvice = "Give the password as the dependency `password`: a packages.secret instance in this namespace with source set to a SOPS file that holds `password`, hash set to its content hash, and keys = [ \"password\" ], wired with deps.password = ref.<namespace>.<instance>.";

      _passwordCheck =
        if config.password != null then
          scope.fail {
            id = "K9503";
            package = "stackgres-database";
            option = "config.password";
            message = "password was removed, because it put the password in plain text in Kix's local store and in the built Secrets.";
            fix = passwordAdvice;
          }
        else if config.passwordSource != null || config.passwordHash != null then
          scope.fail {
            id = "K6023";
            package = "stackgres-database";
            option = "config.passwordSource";
            message = "passwordSource and passwordHash were removed.";
            fix = "${passwordAdvice} Use the same file and hash.";
          }
        else if password == null then
          scope.fail {
            package = "stackgres-database";
            message = "has no `password` dependency.";
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
              inherit who;
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
            throw "${who}: deps.password resolved to secret \"${dep.out.name}\", which Kix does not fill from a SOPS file, so it is also the credentials Secret the app reads. Add `username` (equal to user, \"${userName}\") to that secret and to its keys, or use a packages.secret with a SOPS source."
        );

      # These carry the context of the cluster's Service reference, so the
      # resources built from them depend on the SGCluster.
      clusterName = postgres.out.name;
      clusterFqdn = postgres.out.fqdn;
      clusterPort = postgres.out.port;

      # The cluster's namespace, for the Job and the Secrets it reads.
      backendScope = scope.forService postgres;
      # Instances in different namespaces may share a name and a cluster, so
      # what this package puts in the cluster's namespace carries its own.
      serverSideName = "${name}-${scope.namespaceName}";

      # A Job's pod template is immutable, so a changed input (the
      # password, the extensions, `owner`) gets a Job with a new name.
      bootstrapInputs = builtins.toJSON {
        inherit dbName userName;
        owner = config.owner;
        extensions = config.extensions;
        passwordFingerprint = if fromSops then sops.hash else null;
      };
      bootstrapHash = builtins.substring 0 10 (builtins.hashString "sha256" bootstrapInputs);

      labels = {
        "app.kubernetes.io/name" = "stackgres-database";
        "app.kubernetes.io/instance" = name;
        ${kix.keys.dbCluster} = clusterName;
      };

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
              "port"
            ];
            stringData = {
              username = userName;
              database = dbName;
              host = clusterFqdn;
              port = clusterPort;
            };
            inherit (sops) source hash;
            labels = labels;
            meta = {
              classification = "credential";
              rotationPolicy = "manual";
            };
          }
        else
          scope.mkSecretRef {
            name = passwordDep.out.name;
            keys = [
              "username"
              "password"
            ];
          };

      # The role's password in the cluster's namespace, so the Job reads it
      # by secretKeyRef: rendered from the same SOPS file as `credentials`,
      # or written there by the site.
      bootstrapPassword =
        if fromSops then
          backendScope.mkSecret {
            name = "${serverSideName}-bootstrap-password";
            keys = [ "password" ];
            inherit (sops) source hash;
            labels = labels;
            meta = {
              classification = "credential";
              rotationPolicy = "manual";
            };
          }
        else
          backendScope.mkSecretRef {
            name = "${serverSideName}-bootstrap-password";
            keys = [ "password" ];
          };

      # A stackgres-cluster publishes the Secret StackGres creates for it.
      # An import does not, so this references the Secret StackGres names
      # after the cluster, in the cluster's namespace.
      importedSuperuser =
        if postgres.out ? superuserSecret then
          null
        else
          backendScope.mkSecretRef {
            name = clusterName;
            keys = [
              "superuser-username"
              "superuser-password"
            ];
          };
      superuser = if importedSuperuser == null then postgres.out.superuserSecret else importedSuperuser;

      # Each step is idempotent, so a retried or repeated Job converges. The
      # `database` and `user` option types admit no quote and no `$`, so
      # the script interpolates them; the password goes through psql's
      # `:'name'` substitution, which quotes any content.
      bootstrapScript = ''
        set -eu

        echo "waiting for postgres at $PGHOST:$PGPORT (user $PGUSER)..."
        for i in $(seq 1 120); do
          if pg_isready -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d postgres >/dev/null 2>&1; then
            break
          fi
          sleep 2
        done
        pg_isready -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d postgres

        echo "ensuring role \"${userName}\" exists with current password..."
        ROLE_EXISTS=$(psql -tAc "SELECT 1 FROM pg_roles WHERE rolname = '${userName}'")
        # psql -c sends its string without variable substitution, so the
        # statement goes through stdin, where psql substitutes :'newpw'.
        if [ "$ROLE_EXISTS" = "1" ]; then
          echo "ALTER ROLE \"${userName}\" WITH LOGIN PASSWORD :'newpw'" \
            | psql -v ON_ERROR_STOP=1 -v newpw="$NEW_PASSWORD"
        else
          echo "CREATE ROLE \"${userName}\" WITH LOGIN PASSWORD :'newpw'" \
            | psql -v ON_ERROR_STOP=1 -v newpw="$NEW_PASSWORD"
        fi

        echo "ensuring database \"${dbName}\" exists..."
        DB_EXISTS=$(psql -tAc "SELECT 1 FROM pg_database WHERE datname = '${dbName}'")
        if [ "$DB_EXISTS" != "1" ]; then
          psql -v ON_ERROR_STOP=1 -c "CREATE DATABASE \"${dbName}\""
        fi

        ${lib.optionalString config.owner ''
          echo "setting database \"${dbName}\" owner to \"${userName}\"..."
          psql -v ON_ERROR_STOP=1 -c "ALTER DATABASE \"${dbName}\" OWNER TO \"${userName}\""
        ''}

        echo "granting privileges on \"${dbName}\" to \"${userName}\"..."
        psql -v ON_ERROR_STOP=1 \
          -c "GRANT ALL PRIVILEGES ON DATABASE \"${dbName}\" TO \"${userName}\""

        ${lib.optionalString (config.extensions != [ ]) ''
            echo "ensuring extensions on \"${dbName}\"..."
            psql -v ON_ERROR_STOP=1 -d "${dbName}" <<'SQL'
          ${lib.concatMapStringsSep "\n" (
            n: "CREATE EXTENSION IF NOT EXISTS \"${n}\" CASCADE;"
          ) extensionNames}
          SQL
        ''}

        echo "stackgres-database bootstrap complete for ${userName}@${dbName}"
      '';

      bootstrapJob = backendScope.mkJob {
        name = "${serverSideName}-bootstrap-${bootstrapHash}";
        labels = labels;
        spec = {
          backoffLimit = 20;
          template = {
            metadata.labels = labels;
            spec = {
              restartPolicy = "OnFailure";
              # The Job runs psql, a client, which needs no root. 70 is the
              # `postgres` user of the official Alpine postgres images.
              securityContext = {
                runAsNonRoot = true;
                runAsUser = 70;
                runAsGroup = 70;
                seccompProfile.type = "RuntimeDefault";
              };
              containers = [
                (
                  {
                    name = "bootstrap";
                    image = kix.image.ref config.bootstrap.image;
                    command = [
                      "/bin/sh"
                      "-c"
                    ];
                    args = [ bootstrapScript ];
                    resources = config.bootstrap.resources;
                    # psql writes no files; /tmp covers the shell's here-documents.
                    securityContext = {
                      allowPrivilegeEscalation = false;
                      capabilities.drop = [ "ALL" ];
                      readOnlyRootFilesystem = true;
                    };
                    volumeMounts = [
                      {
                        name = "tmp";
                        mountPath = "/tmp";
                      }
                    ];
                    env = [
                      {
                        name = "PGHOST";
                        value = clusterFqdn;
                      }
                      {
                        name = "PGPORT";
                        value = clusterPort;
                      }
                      {
                        name = "PGDATABASE";
                        value = "postgres";
                      }
                    ]
                    ++ (superuser.out.mkEnv {
                      PGUSER = "superuser-username";
                      PGPASSWORD = "superuser-password";
                    })
                    ++ (bootstrapPassword.out.mkEnv {
                      NEW_PASSWORD = "password";
                    });
                  }
                  // lib.optionalAttrs (config.bootstrap.image.pullPolicy != null) {
                    imagePullPolicy = config.bootstrap.image.pullPolicy;
                  }
                )
              ];
              volumes = [
                {
                  name = "tmp";
                  emptyDir = { };
                }
              ];
            };
          };
        };
      };
    in
    builtins.seq passwordDep (
      builtins.seq _extensionsCheck {
        inherit
          credentials
          bootstrapPassword
          bootstrapJob
          importedSuperuser
          ;

        # The postgres dependency's out with the Job added to each value,
        # and its Service reference as a part, so a consumer of out.host
        # waits for the Job and gets egress to PostgreSQL (scope.forwardEdges).
        pg = scope.forwardEdges postgres [ bootstrapJob ];

        root = {
          resource = credentials;
          # The Job reaches this instance by two routes, and each covers a
          # case the other does not. `pg` above carries it to consumers, so a
          # consumer's workload waits for the Job and gets egress to postgres.
          # `postHooks` puts the Job, and what it references (bootstrapPassword,
          # the superuser Secret, its network policies), in this instance's own forward
          # closure, so the PackageInstance depends on the Job even when no
          # consumer reads `out.host`. `credentials` does not reference the Job
          # and can be applied before the Job runs.
          postHooks = [ bootstrapJob ];

          out = kix.contracts.postgresDatabase.check who {
            host = self.pg.fqdn;
            port = self.pg.port;
            database = dbName;
            username = userName;
            extensions = config.extensions;
            credentials = credentials;
            tls = postgres.out.tls or null;
          };
        };
      }
    );
}
