# StackGres Database — provisions a logical database + role on a StackGres
# cluster, materializing application credentials in *this* (consumer)
# namespace. Designed to be the dep an app actually depends on, instead of
# depending on the raw stackgres-cluster.
#
# Why this exists:
#   K8s Secrets are namespace-scoped. The credentials Secret that StackGres
#   auto-creates lives next to the SGCluster, so an app in another namespace
#   can't read it via secretKeyRef. The (existing) reflector-based
#   replication of the *superuser* secret is brittle and gives apps far too
#   much privilege anyway. This package solves the real problem: each app
#   gets its own role + database, with credentials sitting in its own
#   namespace, no superuser exposure.
#
# How it works:
#   1. A kix-managed `credentials` Secret is created in this package's
#      (consumer) namespace, holding username/password/database/host/port.
#      This is what the consuming app wires into its pod.
#   2. A sibling `bootstrapPassword` Secret is materialized in the postgres
#      cluster's namespace via scope.forNamespace, holding just `password`,
#      so a Job in that namespace can mount it via secretKeyRef.
#   3. A `bootstrapJob` runs in the postgres namespace using a postgres
#      image, waits for the cluster to accept connections, and idempotently
#      creates the role, the database, optional ownership, GRANTs, and
#      requested extensions. Superuser credentials come from the SGCluster's
#      auto-created secret (also in the postgres namespace), referenced via
#      a local mkSecretRef. The Job carries the kix.dev/hook = "post-deploy"
#      annotation so it re-runs cleanly when its content changes (e.g.
#      password rotation).
#
# Same-namespace works too: if the consumer puts both the SGCluster and
# this database instance in one namespace, scope.forNamespace returns a
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

{
  scope,
  lib,
  kix,
}:

let
  name = scope.instanceName;
in
{
  meta = {
    version = "0.1.0";
    description = "Logical database + role provisioned on a StackGres cluster";
    lifecycle = "stateful"; # other packages depend on this database existing
    scope = "namespace";
    provides = [ "sql-database" ];
    defaultAliases = [ "database" ];
    maintainer = "platform";
  };

  # Forward this database's `extensions` (which a consumer like immich
  # injects via `deps.database.config.extensions`) up to the underlying
  # postgres cluster, so the operator installs them on the postgres image.
  # Function-shaped injection — receives this instance's evaluated config
  # so the forwarding picks up whatever extensions consumers requested.
  deps.postgres.config = consumerConfig: {
    extensions = map (n: { name = n; }) consumerConfig.extensions;
  };

  options = {
    database = lib.mkOption {
      type = lib.types.str;
      default = name;
      description = "PostgreSQL database name to create. Defaults to the instance name.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = name;
      description = "PostgreSQL role name to create. Defaults to the instance name.";
    };

    owner = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Make the role the owner of the database (in addition to GRANT ALL).";
    };

    extensions = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Extensions to CREATE EXTENSION IF NOT EXISTS on the new database.
        Note: the extension must already be available in the cluster — declare
        it on the stackgres-cluster instance's `extensions` option so the
        operator installs it on the underlying postgres image.
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

    psqlImage = lib.mkOption {
      type = lib.types.str;
      default = "postgres:16-alpine";
      description = "Image used by the bootstrap Job. Must contain `psql` and `pg_isready`.";
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
      # The dep `postgres` is a stackgres-cluster instance view. We need the
      # cluster's namespace (so we can target it with scope.forNamespace),
      # the cluster's resource name (which is also the operator-created
      # superuser-secret name), and connection details.
      #
      # `_meta.namespaceName` is exposed by lib/eval/view.nix and is the
      # standard handle for "the namespace this dep lives in".
      postgresNamespace = postgres._meta.namespaceName;
      # `postgres.out.name` carries Nix string context (a dependency edge to
      # the SGCluster store path) — that's what we want everywhere except
      # the few places that pipe through `builtins.toFile` (which forbids
      # store-path references in its name argument). Strip context only at
      # those exact sites; keep it everywhere else so the dep edges land in
      # labels, env values, and the final manifest.
      clusterName = postgres.out.name;
      clusterFqdn = postgres.out.fqdn;
      clusterPort = postgres.out.port;

      # --- A scope rooted in the postgres namespace ------------------------
      # Lets us emit Secret + Job resources next to the SGCluster while this
      # package's primary scope (and credentials Secret) stay in the
      # consumer's namespace.
      backendScope = scope.forNamespace postgresNamespace;

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
        "kix.dev/db-cluster" = clusterName;
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

      # --- 3. Superuser secret reference (postgres namespace) --------------
      # The StackGres operator auto-creates a Secret named after the cluster
      # holding `superuser-username` / `superuser-password`. mkSecretRef in
      # the backend scope lets us pull those into the Job's env without any
      # cross-namespace shenanigans, and gives us deploy-time validation
      # that the secret actually exists before the Job runs.
      #
      # `name` here flows through `builtins.toFile` (via the marker
      # PackageInstance path), so we have to hand it a context-free string.
      # The dep edge to the SGCluster store path is preserved everywhere
      # else `clusterName` is used (labels, env values, etc.).
      superuserRef = backendScope.mkSecretRef {
        name = builtins.unsafeDiscardStringContext clusterName;
        keys = [
          "superuser-username"
          "superuser-password"
        ];
      };

      # --- 4. Bootstrap Job (postgres namespace) ---------------------------
      # Idempotent psql script: waits for the cluster, creates/updates the
      # role, creates the database, sets ownership + grants, and creates
      # extensions. Username and database name are kix-controlled strings
      # (no user-supplied content), so shell interpolation is safe; the
      # password goes through psql's `:'name'` literal substitution which
      # quotes correctly regardless of contents.
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
            ext: "CREATE EXTENSION IF NOT EXISTS \"${ext}\" CASCADE;"
          ) config.extensions}
          SQL
        ''}

        echo "stackgres-database bootstrap complete for ${userName}@${dbName}"
      '';

      bootstrapJob = backendScope.mkResource {
        apiVersion = "batch/v1";
        kind = "Job";
        name = "${name}-bootstrap-${bootstrapHash}";
        labels = labels;
        annotations = {
          # Treat as a post-deploy hook so the deploy engine deletes the
          # previous instance before creating a new one when the spec
          # changes (e.g. password rotation produces a new hash → new name).
          "kix.dev/hook" = "post-deploy";
          "kix.dev/hook-delete-policy" = "before-hook-creation,hook-succeeded";
        };
        spec = {
          backoffLimit = 20;
          ttlSecondsAfterFinished = 86400;
          template = {
            metadata.labels = labels;
            spec = {
              restartPolicy = "OnFailure";
              containers = [
                {
                  name = "bootstrap";
                  image = config.psqlImage;
                  command = [
                    "/bin/sh"
                    "-c"
                  ];
                  args = [ bootstrapScript ];
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
                  ++ (superuserRef.out.mkEnv {
                    PGUSER = "superuser-username";
                    PGPASSWORD = "superuser-password";
                  })
                  ++ (bootstrapPassword.out.mkEnv {
                    NEW_PASSWORD = "password";
                  });
                }
              ];
            };
          };
        };
      };

      # --- Consumer-facing helper -----------------------------------------
      # Returns a list of K8s env entries with the connection info under a
      # given prefix. Saves consumers from wiring 5 fields by hand.
      mkConnectionEnv =
        prefix:
        (kix.mkEnvVars {
          "${prefix}HOSTNAME" = clusterFqdn;
          "${prefix}PORT" = clusterPort;
          "${prefix}DATABASENAME" = dbName;
        })
        ++ (credentials.out.mkEnv {
          "${prefix}USERNAME" = "username";
          "${prefix}PASSWORD" = "password";
        });
    in
    builtins.seq _passwordCheck {
      inherit
        credentials
        bootstrapPassword
        bootstrapJob
        ;

      root = {
        resource = credentials;
        # bootstrapPassword is referenced by the Job (via secretKeyRef
        # context), so listing it explicitly would be redundant — kix's
        # forward closure picks it up. The Job itself is not referenced
        # from `credentials`, so it needs to live in either `requires`
        # (in-band, blocks readiness) or `postHooks` (runs after package
        # is otherwise deployed). We use `postHooks` so the credentials
        # Secret can be applied immediately and immich's wave waits on
        # the Job's success readiness rather than coupling the two.
        postHooks = [ bootstrapJob ];

        out = {
          host = clusterFqdn;
          port = clusterPort;
          database = dbName;
          username = userName;
          extensions = config.extensions;
          credentials = credentials;
          connectionEnv = mkConnectionEnv;
        };
      };
    };
}
