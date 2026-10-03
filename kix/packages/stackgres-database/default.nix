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
# DI deps:
#   postgres (required)  a stackgres-cluster, or an import of an SGCluster
#                        whose out has name, fqdn, port, and extensions.
#                        The `extensions` option is added to its
#                        `extensions`.
#
# Config: one of `password` (a literal, for development) or
# `passwordSource` with `passwordHash` (a SOPS file).
#
# Minimal instance, beside an app that takes deps.database:
#
#   app-db = {
#     package = packages.stackgres-database;
#     config.passwordSource = ./secrets/app-db.yaml;
#     config.passwordHash = "...";
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
# Exposes the Postgres database contract (kix/lib/vocab/postgres-database.nix,
# `kix.contracts.postgresDatabase`), which root.out passes through `check`:
#   out.host, out.port      the cluster's primary Service. They carry the
#                           Job, so a consumer's workload waits for it and
#                           gets network policy to PostgreSQL.
#   out.database            the database name.
#   out.username            the role name.
#   out.extensions          the `extensions` option.
#   out.credentials         the credentials Secret, for `out.mkEnv`.
#   out.tls                 whether PostgreSQL serves TLS (the postgres
#                           dependency's `out.tls`), or null when it
#                           publishes none, as an import.
#
# root = the credentials Secret.
#
# Escape hatches: `bootstrap.image` and `bootstrap.resources` for the Job,
# and the instance's `partsOverlays`.
#
# Limits: the role's password is an option rather than a secret
# dependency, because the same value has to reach a Secret in each of two
# namespaces. A literal `password` lands in the Nix store.

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
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Literal password (development only). Mutually exclusive with
        passwordSource. The plaintext lands in the Nix store and the
        rendered K8s Secret manifest, so use SOPS for anything real.
      '';
    };

    passwordSource = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path to a SOPS-encrypted file containing a `password` key. The kix
        deploy CLI hydrates the credentials Secret and the bootstrap Secret
        from this same source at apply time.
      '';
    };

    passwordHash = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Content hash of the SOPS-decrypted password. Required when
        passwordSource is set; used by kix-deploy for change detection
        (and embedded into the bootstrap Job name so password rotation
        triggers a fresh Job).
      '';
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

      _passwordCheck =
        if config.password == null && config.passwordSource == null then
          throw "${who}: neither password nor passwordSource is set. Set password (a literal, for development) or passwordSource (a SOPS file) with passwordHash."
        else if config.password != null && config.passwordSource != null then
          throw "${who}: both password and passwordSource are set. Remove one."
        else if config.passwordSource != null && config.passwordHash == null then
          throw "${who}: passwordSource is set without passwordHash, which the deploy compares to find a changed password. Set passwordHash."
        else
          null;

      # These carry the context of the cluster's Service reference, so the
      # resources built from them depend on the SGCluster.
      clusterName = postgres.out.name;
      clusterFqdn = postgres.out.fqdn;
      clusterPort = postgres.out.port;

      # The cluster's namespace, for the Job and the Secrets it reads.
      backendScope = scope.forService postgres;

      # A Job's pod template is immutable, so a changed input (the
      # password, the extensions, `owner`) gets a Job with a new name.
      bootstrapInputs = builtins.toJSON {
        inherit dbName userName;
        owner = config.owner;
        extensions = config.extensions;
        passwordFingerprint = if config.passwordHash != null then config.passwordHash else config.password;
      };
      bootstrapHash = builtins.substring 0 10 (builtins.hashString "sha256" bootstrapInputs);

      labels = {
        "app.kubernetes.io/name" = "stackgres-database";
        "app.kubernetes.io/instance" = name;
        ${kix.keys.dbCluster} = clusterName;
      };

      # In the consumer's namespace. With passwordSource, the deploy fills
      # `password` from the SOPS file.
      credentials = scope.mkSecret {
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
        }
        // lib.optionalAttrs (config.password != null) {
          password = config.password;
        };
        source = config.passwordSource;
        hash = config.passwordHash;
        labels = labels;
        meta = {
          classification = "credential";
          rotationPolicy = "manual";
        };
      };

      # The role's password in the cluster's namespace, from the same
      # source as `credentials`, so the Job reads it by secretKeyRef.
      bootstrapPassword = backendScope.mkSecret {
        name = "${name}-bootstrap-password";
        keys = [ "password" ];
        stringData = lib.optionalAttrs (config.password != null) {
          password = config.password;
        };
        source = config.passwordSource;
        hash = config.passwordHash;
        labels = labels;
        meta = {
          classification = "credential";
          rotationPolicy = "manual";
        };
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
        name = "${name}-bootstrap-${bootstrapHash}";
        labels = labels;
        spec = {
          backoffLimit = 20;
          ttlSecondsAfterFinished = 86400;
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
    builtins.seq _passwordCheck (
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
