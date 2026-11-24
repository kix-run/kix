# db-operator-database: a PostgreSQL database and login role for one
# application, created by the DB Operator on the server of a DbInstance.
#
# The package renders one kinda.rocks Database in its own namespace, the
# consumer's. The operator creates the database as the admin login, so the
# admin owns it. It creates a login role and grants it all privileges on the
# database, `public`, and each schema in `postgres.schemas`. The role can
# create tables in those schemas without owning the database or schemas.
# The operator generates the role's password and writes the login into a
# Secret and a ConfigMap named `<instance>-credentials` in the same
# namespace. The package references that Secret, so a consumer's pod waits
# until the operator has written it with every key below.
#
# The operator names the database and the role `<namespace>-<instance>`
# (GenerateDatabaseSecretData in internal/helpers/database/database.go
# upstream), and the package publishes those names. PostgreSQL cuts a name
# at 63 bytes, so a longer one is refused.
#
# The Secret holds `POSTGRES_DB`, `POSTGRES_USER`, and `POSTGRES_PASSWORD`,
# which the operator always writes, `username` and `password`, which the
# package renders from them with upstream's credential templates
# (`spec.credentials.templates`) so the Secret answers
# `kix.contracts.postgresDatabase`, and one key for each entry of
# `templates`. The ConfigMap holds `DB_CONN`, `DB_PORT`, and `SSL_MODE`,
# which nothing in Kix reads: consumers take the server's address from
# `out.host` and `out.port`.
#
# Minimal instance, beside an app that takes deps.database, with a
# db-operator-instance `pg-instance` in the namespace `data`:
#
#   app-db = {
#     package = packages.experimental.db-operator-database;
#     deps.dbInstance = ref.data.pg-instance;
#   };
#
# A consumer reads the same `out` as from cnpg-database:
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
# Dependencies:
#   dbInstance (required)  the db-operator-instance whose server holds the
#                          database. An import must publish out.name,
#                          out.fqdn, out.port, and out.engine = "postgres".
#   dbOperator (required)  the db-operator whose Database handle the
#                          package builds from.
#
# `out`:
#   out.host, out.port   the server's address from the DbInstance. They
#                        carry the Database, so a consumer's workload waits
#                        until the operator reports it ready, and the
#                        server Service's endpoint fact, so it gets network
#                        policy to the server's pods.
#   out.database         the database name, `<namespace>-<instance>`.
#   out.username         the role name, the same.
#   out.extensions       the extension names the Database asks for.
#   out.credentials      the operator's Secret, for `out.mkEnv`.
#   out.tls              the DbInstance's out.tls.
#
# root = the reference to the operator's Secret.
#
# Escape hatches: `extraSpec` (such as `postgres.schemas`,
# `postgres.dropPublicSchema`, `extraGrants`, `cleanup`, or
# `credentials.metadata`), and the instance's `partsOverlays`.
#
# Limits: the package sets `deletionProtected = true` by default. Removing
# an instance and deploying with `--prune` deletes the Database object.
# The PostgreSQL database, the role, and the data stay on the server. The
# `<instance>-credentials` Secret keeps all its keys (including `templates`
# keys), and the ConfigMap also stays. The operator removes only its
# `kinda.rocks/used-by-kind` and `kinda.rocks/used-by-name` labels from
# the Secret (handleDbDelete in internal/controller/database_controller.go
# upstream). Adding the same instance back later adopts that Secret and
# keeps the password, so the application finds its old data. Set
# `extraSpec.deletionProtected = false` to make the operator drop the
# database and the role when the Database is deleted.
#
# Names can collide: instance `c` in namespace `a-b` and instance `b-c` in
# namespace `a` on the same DbInstance both get database and role `a-b-c`.
# Both Databases share one PostgreSQL database and one role, and each
# application can read the other's tables (createDatabase and
# createOrUpdateUser in pkg/utils/database/postgres.go upstream). Each
# Database's Secret holds a different password. Each reconcile of either
# Database sets the role's password to the one in its own Secret, so the
# application whose Database reconciled last can log in and the other gets
# "password authentication failed". Which one wins changes, for example
# after the controller restarts. Both Databases report ready the whole
# time. Kix cannot detect this when evaluating the cluster, so keep
# colliding names off the same DbInstance.
#
# Renaming or moving an instance gives the application a new, empty
# database, and the old one stays on the server. The webhook refuses a
# change to `spec.instance`, so repointing `deps.dbInstance` at another
# DbInstance fails at apply. The operator adopts a Secret named
# `<instance>-credentials` that already exists, and then takes the database
# and role names from its POSTGRES_DB and POSTGRES_USER, so `out.database`
# and `out.username` are wrong if that Secret predates the Database. A
# Database whose DbInstance or operator is removed first stays stuck on
# its finalizer; db-operator-instance's header gives the order to remove
# them in. A Database in a namespace the DbInstance's `namespaceFilters`
# exclude never becomes ready, and the deploy waits until it times out.
#
# DB Operator creates an extension at the server's default version. Kix
# does not see the Secret's content, so a changed password does not
# restart the consumer's pods. DB Operator 2.47 connects to the database
# for its own steps without TLS, whatever the DbInstance says, so a server
# that refuses connections without TLS fails them.

{
  scope,
  lib,
  kix,
}:

let
  name = scope.instanceName;
  ns = scope.namespaceName;
  who = "db-operator-database ${ns}/${name}";

  # The database and its role (GenerateDatabaseSecretData and
  # GenerateDatabaseUsername upstream).
  dbName = "${ns}-${name}";

  # The keys the operator always writes for a PostgreSQL database, which a
  # credential template may not name (internal/utils/templates upstream).
  operatorKeys = [
    "POSTGRES_DB"
    "POSTGRES_USER"
    "POSTGRES_PASSWORD"
  ];
  # The other engines' keys, which upstream's template renderer also
  # refuses.
  blockedKeys = operatorKeys ++ [
    "DB"
    "USER"
    "PASSWORD"
    "CLICKHOUSE_DB"
    "CLICKHOUSE_USER"
    "CLICKHOUSE_PASSWORD"
  ];
  # The keys the package renders for kix.contracts.postgresDatabase.
  contractTemplates = {
    username = "{{ .Username }}";
    password = "{{ .Password }}";
  };

  # The fields and functions DB Operator's webhook admits in a credential
  # template (internal/webhook/v1beta1/webhook.go upstream).
  templateFields = [
    "Protocol"
    "Hostname"
    "Port"
    "Username"
    "Password"
    "Database"
    "Secret"
    "ConfigMap"
    "Query"
    "InstanceVar"
  ];
  # The `.Field` names a template uses, found as the webhook's regular
  # expression finds them.
  fieldsOf =
    template:
    map builtins.head (
      builtins.filter builtins.isList (builtins.split "\\{\\{[[:space:]]*\\.([[:alnum:]_.]+)" template)
    );

  # A plain name or `{ name; version; }`, as cnpg-database takes it.
  extensionName = e: if builtins.isString e then e else e.name;
  versioned = e: !(builtins.isString e) && e.version != null;
in
{
  meta = {
    description = "PostgreSQL database, login role, and credentials Secret for one application, created by DB Operator";
    owner = "platform";
    lifecycle = "stateful"; # other packages depend on this database existing
    scope = "namespace";
    defaultAliases = [ "database" ];
  };

  assertions =
    { config, ... }:
    let
      taken = builtins.filter (k: builtins.elem k (blockedKeys ++ builtins.attrNames contractTemplates)) (
        builtins.attrNames config.templates
      );
      pinned = map extensionName (builtins.filter versioned config.extensions);
      unknownFields = lib.concatLists (
        lib.mapAttrsToList (
          key: template:
          map (field: "${key} uses .${field}") (
            builtins.filter (field: !(builtins.elem field templateFields)) (fieldsOf template)
          )
        ) config.templates
      );
    in
    [
      {
        assertion = builtins.stringLength dbName <= 63;
        message = "PostgreSQL database and role name \"${dbName}\" is ${toString (builtins.stringLength dbName)} bytes long, over PostgreSQL's 63-byte limit. DB Operator names both <namespace>-<instance>, so Kix rejected this Database.";
        fix = "Shorten the instance name or move it to a namespace with a shorter name so \"<namespace>-<instance>\" is at most 63 bytes.";
      }
      {
        assertion = taken == [ ];
        message = "templates uses reserved Secret keys (${lib.concatStringsSep ", " taken}), so Kix rejected this Database. The credentials Secret already includes POSTGRES_DB, POSTGRES_USER, POSTGRES_PASSWORD, username, and password, and DB Operator reserves DB, USER, PASSWORD, CLICKHOUSE_DB, CLICKHOUSE_USER, and CLICKHOUSE_PASSWORD.";
        fix = "Rename ${lib.concatStringsSep ", " taken} in templates, or read the built-in keys (POSTGRES_DB, POSTGRES_USER, POSTGRES_PASSWORD, username, and password) directly.";
        option = "templates";
      }
      {
        assertion = unknownFields == [ ];
        message = "templates references unsupported template fields (${lib.concatStringsSep "; " unknownFields}). DB Operator's admission webhook rejects unknown fields, so Kix rejected this Database.";
        fix = "Use only supported fields (.Protocol, .Hostname, .Port, .Username, .Password, .Database) and functions (.Secret, .ConfigMap, .Query, .InstanceVar) in templates.";
        option = "templates";
      }
      {
        assertion = pinned == [ ];
        message = "extensions pins a version for ${lib.concatStringsSep ", " pinned}, so Kix rejected this Database. DB Operator always installs the PostgreSQL server's default extension version and cannot pin a specific version. Either this instance sets version in extensions, or an application using this database requires a pinned version (for example, immich pins vchord).";
        fix = "If you set version in extensions on this instance, list the extension by name only (or set version = null). If an application requires a pinned extension version, use cnpg-database or stackgres-database.";
        option = "extensions";
      }
    ];

  options = {
    extensions = lib.mkOption {
      type = lib.types.listOf (
        lib.types.either lib.types.str (
          lib.types.submodule {
            options = {
              name = lib.mkOption {
                type = lib.types.nonEmptyStr;
                description = "PostgreSQL extension name.";
              };
              version = lib.mkOption {
                type = lib.types.nullOr lib.types.nonEmptyStr;
                default = null;
                description = "Extension version. Must be `null`; Kix rejects non-null versions because DB Operator always installs the server's default version.";
              };
            };
          }
        )
      );
      default = [ ];
      description = ''
        PostgreSQL extensions to enable in this database (`spec.postgres.extensions`).
        Write each entry as an extension name such as `"citext"` (or
        `{ name = "citext"; version = null; }`, which application packages may pass
        automatically). Every listed extension must be installed on the PostgreSQL
        server. Kix rejects non-null `version` values because DB Operator always
        installs the server's default version.
      '';
    };

    templates = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = {
        DATABASE_URL = "postgresql://{{ .Username }}:{{ .Password }}@{{ .Hostname }}:{{ .Port }}/{{ .Database }}";
      };
      description = ''
        Extra keys for DB Operator to render into the `<instance>-credentials` Secret.
        Each value is a Go template that can use the fields `.Username`, `.Password`,
        `.Hostname`, `.Port`, `.Database`, and `.Protocol`, and the functions
        `.Secret`, `.ConfigMap`, `.Query`, and `.InstanceVar`. Kix rejects any other
        template field, as well as key names already provided or reserved (`POSTGRES_DB`,
        `POSTGRES_USER`, `POSTGRES_PASSWORD`, `username`, `password`, `DB`, `USER`,
        `PASSWORD`, `CLICKHOUSE_DB`, `CLICKHOUSE_USER`, and `CLICKHOUSE_PASSWORD`). DB
        Operator inserts values without escaping, so special characters in a generated
        password can break a URL template.
      '';
    };

    extraSpec = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      example = {
        postgres.schemas = [ "app" ];
      };
      description = ''
        Additional fields merged into the `Database` resource's `spec`, such as
        `postgres.schemas` or `deletionProtected` (which defaults to `true`). Kix
        rejects `instance`, `secretName`, `existingUser`, `credentials.templates`,
        `secretsTemplates`, and `postgres.extensions` here because this package sets
        them from its dependencies and options.
      '';
    };
  };

  build =
    {
      self,
      config,
      dbInstance,
      dbOperator,
      ...
    }:
    let
      crds =
        dbOperator.out.crds or (scope.fail {
          package = "db-operator-database";
          dependency = "dbOperator";
          message = "deps.dbOperator does not publish out.crds (as happens when it uses kix.mkImport), so Kix cannot create the Database resource.";
          fix = "Point deps.dbOperator at a db-operator package instance: deps.dbOperator = ref.<namespace>.<instance>.";
        });

      instance =
        if
          dbInstance.out ? name
          && dbInstance.out ? fqdn
          && dbInstance.out ? port
          && (dbInstance.out.engine or null) == "postgres"
        then
          dbInstance
        else
          scope.fail {
            package = "db-operator-database";
            dependency = "dbInstance";
            message = "deps.dbInstance is missing out.name, out.fqdn, out.port, or out.engine = \"postgres\", so Kix rejected this Database.";
            fix = "Point deps.dbInstance at the db-operator-instance that registers your PostgreSQL server: deps.dbInstance = ref.<namespace>.<instance>.";
          };

      extensions = lib.unique (map extensionName config.extensions);

      secretName = "${name}-credentials";

      templates = lib.mapAttrsToList (key: template: {
        name = key;
        inherit template;
        secret = true;
      }) (contractTemplates // config.templates);

      baseSpec = {
        inherit secretName;
        instance = instance.out.name;
        deletionProtected = true;
        credentials.templates = templates;
      }
      // lib.optionalAttrs (extensions != [ ]) {
        postgres.extensions = extensions;
      };

      spec = kix.mergeGuarded {
        inherit scope;
        option = "extraSpec";
        locked = [
          [ "instance" ]
          [ "secretName" ]
          [ "existingUser" ]
          [
            "credentials"
            "templates"
          ]
          [ "secretsTemplates" ]
          [
            "postgres"
            "extensions"
          ]
        ];
      } baseSpec config.extraSpec;
    in
    {
      database = scope.mkCR crds.Database {
        inherit name spec;
      };

      # The operator writes this Secret once the database and its role
      # exist, and the deploy waits until it holds every key.
      credentials = scope.mkSecretRef {
        name = secretName;
        keys = operatorKeys ++ builtins.attrNames contractTemplates ++ builtins.attrNames config.templates;
        requires = [ self.database ];
      };

      # The DbInstance's out with the Database added to each value, so a
      # consumer of out.host waits for the Database and gets egress to the
      # server (scope.forwardEdges).
      server = scope.forwardEdges instance [ self.database ];

      # region:dbOperatorDatabaseCheck
      root = {
        resource = self.credentials;
        requires = [ self.database ];

        out = kix.contracts.postgresDatabase.check who {
          host = self.server.fqdn;
          port = self.server.port;
          database = dbName;
          username = dbName;
          inherit extensions;
          credentials = self.credentials;
          tls = instance.out.tls or null;
        };
      };
      # endregion:dbOperatorDatabaseCheck
    };
}
