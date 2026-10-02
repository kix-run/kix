# StackGres Database: provisions a logical database + role on a StackGres
# cluster, materializing application credentials in *this* (consumer)
# namespace. Designed to be the dep an app actually depends on, instead of
# depending on the raw stackgres-cluster.
#
# Why this exists:
#   K8s Secrets are namespace-scoped. The credentials Secret that StackGres
#   auto-creates lives next to the SGCluster, so an app in another namespace
#   can't read it via secretKeyRef, and it holds the superuser. Each app gets
#   its own role and database instead, with credentials in its own
#   namespace.
#
# How it works:
#   1. A kix-managed `credentials` Secret is created in this package's
#      (consumer) namespace, holding username/password/database/host/port.
#      This is what the consuming app wires into its pod.
#   2. A sibling `bootstrapPassword` Secret is materialized in the postgres
#      cluster's namespace via `scope.forService postgres`, holding just
#      `password`, so a Job in that namespace can mount it via secretKeyRef.
#   3. A `bootstrapJob` runs in the postgres namespace using a postgres
#      image, waits for the cluster to accept connections, and idempotently
#      creates the role, the database, optional ownership, GRANTs, and
#      requested extensions. Superuser credentials come from the Secret
#      StackGres creates next to the SGCluster: `postgres.out.superuserSecret`
#      on a stackgres-cluster, or the Secret named after the cluster on an
#      import. The Job's name carries a hash of its inputs, so a change
#      (e.g. password rotation) is a new Job, not a patch of the old one;
#      the old one is reaped by its TTL.
#
# Same-namespace works too: if the consumer puts both the SGCluster and
# this database instance in one namespace, `scope.forService` returns a
# scope rooted in that same namespace and everything still works.
#
# root = credentials Secret (in consumer namespace).
# Consumers use:
#   db = packages.stackgres-database;  # via DI alias "database"
#   build = { database, ... }: {
#     env = kix.mkEnv {
#       DB_HOSTNAME    = database.out.host;
#       DB_PORT        = database.out.port;
#       DB_DATABASENAME = database.out.database;
#     } (database.out.credentials.out.mkEnv {
#       DB_USERNAME = "username";
#       DB_PASSWORD = "password";
#     });
#   };
#
# `out.tls` is the postgres dependency's `out.tls` (whether PostgreSQL
# serves TLS), or null when it publishes none, such as an import.

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

  # Forward this database's `extensions` (which a consumer like immich
  # injects via `deps.database.config.extensions`) up to the underlying
  # postgres cluster, so the operator installs them on the postgres image.
  # Function-shaped injection: receives this instance's evaluated config
  # so the forwarding picks up whatever extensions consumers requested.
  # Entries can be plain strings or `{ name, version? }` attrsets; both
  # shapes are normalized to the attrset form expected by SGCluster.
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

      # --- Validate password configuration ---------------------------------
      # Exactly one of `password` or `passwordSource` must be set. The hash
      # is required for the SOPS path so the deploy CLI can detect changes.
      _passwordCheck =
        if config.password == null && config.passwordSource == null then
          throw "stackgres-database '${name}': either `password` (literal) or `passwordSource` (SOPS path) must be set."
        else if config.password != null && config.passwordSource != null then
          throw "stackgres-database '${name}': set `password` OR `passwordSource`, not both."
        else if config.passwordSource != null && config.passwordHash == null then
          throw "stackgres-database '${name}': `passwordHash` is required when `passwordSource` is set."
        else
          null;

      # --- Resolve postgres backend identity -------------------------------
      # `postgres.out.*` values carry Nix string context pointing at the
      # SGCluster's postgresService ServiceRef marker (selector, ports,
      # readiness) and transitively the SGCluster itself. We keep the
      # context on every value. k8s.mkResource strips it only for the
      # toFile filename, so markers and refs built below automatically
      # pick up the SGCluster edge without any `requires` plumbing.
      clusterName = postgres.out.name;
      clusterFqdn = postgres.out.fqdn;
      clusterPort = postgres.out.port;

      # --- A scope rooted in the postgres namespace ------------------------
      # `scope.forService` reads the dep's `_meta.namespaceName` and hands
      # back a scope bound to it, so Secret + Job resources land next to
      # the SGCluster while this package's primary scope (and the
      # consumer-facing credentials Secret) stay in the consumer's namespace.
      backendScope = scope.forService postgres;

      # --- Hash for the bootstrap Job name ---------------------------------
      # K8s Jobs are immutable in many spec fields. Embedding a content
      # hash in the name means a meaningful change (password rotation,
      # extension list, ownership flag) produces a fresh Job that can run
      # without trying (and failing) to mutate the existing one. Use the
      # passwordHash if provided (SOPS), otherwise hash the literal.
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

      # --- 1. Credentials Secret (consumer namespace) ----------------------
      # Authoritative connection info for the consuming app. Carries the
      # literal username/host/port/database always; the password is either
      # inlined (literal mode) or hydrated from the SOPS source at deploy
      # time. Keys are explicitly declared so build-time mkEnv validation
      # catches typos in the consumer.
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

      # --- 2. Bootstrap password Secret (postgres namespace) ---------------
      # The Job below mounts this via secretKeyRef so the password never
      # appears in the Job's manifest. Same source as `credentials`, so the
      # value stays in lockstep across both materializations.
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

      # --- 3. Superuser Secret (postgres namespace) ------------------------
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

      # --- 4. Bootstrap Job (postgres namespace) ---------------------------
      # Idempotent psql script: waits for the cluster, creates/updates the
      # role, creates the database, sets ownership + grants, and creates
      # extensions. The `database` and `user` option types admit no quote
      # and no `$`, so interpolating them into the script is safe; the
      # password goes through psql's `:'name'` literal substitution, which
      # quotes any content.
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
        # psql -c does NOT process variable substitution (:'var'); the string
        # is sent to the server as-is. Pipe SQL via stdin so psql's lexer
        # runs and substitutes :'newpw' with a properly quoted literal.
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
                    # psql writes no files; /tmp covers the shell's here-documents.
                    securityContext.readOnlyRootFilesystem = true;
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

        # --- Forwarded postgres service ------------------------------------
        # `scope.forwardEdges` bundles two concerns into one intent:
        #
        #   a) Stamp the bootstrap Job onto the postgres service edge.
        #      `postgres.out.{fqdn,port,name}` already carry the
        #      postgresService ServiceRef marker context (selector, ports,
        #      readiness poll); forwardEdges packs `bootstrapJob`'s
        #      store-path into each string value's context so consumers
        #      traversing `database.out.host` / `.port` automatically pick
        #      up the Job in their forward closure: no chain hop through
        #      the Job, no duplicate selector/ports declaration, no new
        #      marker. Wave ordering follows: the consumer's Deployment
        #      hash includes the Job's hash → deploy gates on Job-Complete.
        #
        #   b) Re-expose the upstream postgres ServiceRef marker as a
        #      folder-shaped typed child so `collectTypedAttrs` picks it
        #      up when building the consumer's DI-direct netpol registry.
        #      Without this re-exposure, the marker's outPath would be
        #      present in `database.out.host`'s string context but
        #      invisible to `buildWorkloadCnps` (which only indexes
        #      resources from the consumer's direct deps), and the
        #      consumer's egress CNP would never emit a rule targeting
        #      postgres, producing a CONNECT_TIMEOUT under default-deny.
        #
        # `pg` lives in `parts` as a plain attrset (no `_type`), so
        # mkPackageView treats it as a folder and collectTypedAttrs
        # descends one level into it to find the re-exposed marker.
        # Consumers read `self.pg.fqdn` / `self.pg.port`.
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

          out = {
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
