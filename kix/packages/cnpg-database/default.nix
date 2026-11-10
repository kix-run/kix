# cnpg-database: a PostgreSQL role and database for one application,
# created on a CloudNativePG cluster.
#
# The package creates a credentials Secret in its own namespace, the
# consumer's (keys `username`, `password`, `database`, `host`, `port`), and
# in the cluster's namespace a kubernetes.io/basic-auth Secret with the
# role's name and password, a DatabaseRole for the role, and a Database
# owned by it with the requested extensions. The instance manager on the
# primary creates and updates the role and the database; when the Secret's
# password changes, it sets the new one.
#
# The app depends on this instance rather than on the cluster: a Secret is
# readable only in its own namespace, and CloudNativePG reads a role's
# password, a DatabaseRole, and a Database only in the Cluster's namespace.
#
# Dependencies:
#   postgres (required)      a cnpg-cluster, or a cnpg-pooler in front of
#                            one. The package reads its Service and its
#                            Cluster's name, so an import without
#                            out.clusterName is refused. With a pooler,
#                            `out.host` is the pooler's Service and the
#                            role and database are created on its
#                            Cluster.
#   cnpgOperator (required)  the cnpg-operator whose DatabaseRole and
#                            Database handles the package builds from.
#
# Config: `passwordSource` with `passwordHash` (a SOPS file), or the
# deprecated `password` (a literal), which Kix 0.10 removes.
#
# Minimal instance, beside an app that takes deps.database:
#
#   app-db = {
#     package = packages.cnpg-database;
#     config.passwordSource = ./secrets/app-db.yaml;
#     config.passwordHash = "...";
#   };
#
# A consumer reads the same `out` as from stackgres-database:
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
# `out`:
#   out.host, out.port      the postgres dependency's Service: the
#                           cluster's -rw Service, or the pooler's. They
#                           carry the Database, so a consumer's workload
#                           waits until the operator reports it applied
#                           and gets network policy to that Service's
#                           pods.
#   out.database            the database name.
#   out.username            the role name.
#   out.extensions          the `extensions` option.
#   out.credentials         the credentials Secret, for `out.mkEnv`.
#   out.tls                 whether PostgreSQL serves TLS (the postgres
#                           dependency's `out.tls`).
#
# root = the credentials Secret.
#
# Escape hatch: the instance's `partsOverlays`.
#
# Limits: the role's password comes from options rather than a secret
# dependency, because the same value has to reach a Secret in each of two
# namespaces. CloudNativePG reads the role's password in the Cluster's
# namespace. A literal `password` lands in the Nix store, so the package
# warns when it is set. The password should come from a secret dependency
# with a declared `password` key, as in other packages. That needs Kix to
# copy a dependency's Secret into a second namespace, which Kix cannot do
# yet.
#
# The role always owns the database. Removing the instance leaves the role
# and the database in PostgreSQL (the operator's reclaim policy `retain`).
# An extension must ship in the cluster's operand image; the operator
# reports a missing one in the Database's status, and the deploy waits for
# it.

{
  scope,
  lib,
  kix,
}:

let
  name = scope.instanceName;
  ns = scope.namespaceName;
  who = "cnpg-database ${ns}/${name}";

  # A plain name or `{ name; version; }`, as stackgres-database takes it.
  normalizeExtension =
    e:
    if builtins.isString e then
      { name = e; }
    else
      { inherit (e) name; } // lib.optionalAttrs (e.version != null) { inherit (e) version; };

  # A consumer's `deps.database.config.extensions` is concatenated with the
  # instance's own list, so one name can arrive twice (metabase asks for
  # citext). CloudNativePG's webhook refuses a Database that lists a name
  # twice, so entries merge by name; two different versions of one name
  # cannot be merged.
  uniqueExtensions =
    exts:
    let
      normalized = map normalizeExtension exts;
      pick =
        extName:
        let
          versions = lib.unique (
            lib.concatMap (e: lib.optional (e.name == extName && e ? version) e.version) normalized
          );
        in
        if builtins.length versions > 1 then
          throw "${who}: extension ${extName} is requested at versions ${lib.concatStringsSep " and " versions}, by the instance's `extensions` and a consumer's deps.database.config.extensions. Request one version, or none to take the operand image's default."
        else
          { name = extName; } // lib.optionalAttrs (versions != [ ]) { version = builtins.head versions; };
    in
    map pick (lib.unique (map (e: e.name) normalized));

  # The PostgreSQL identifiers stackgres-database admits, so an instance
  # moves between the two packages unchanged.
  identifier = lib.types.strMatching "[A-Za-z_][A-Za-z0-9_-]{0,62}";

  # Role names CloudNativePG reserves (DatabaseRoleSpec validations in
  # api/v1/databaserole_types.go upstream).
  reservedRole =
    user:
    builtins.elem user [
      "postgres"
      "streaming_replica"
    ]
    || lib.hasPrefix "pg_" user
    || lib.hasPrefix "cnpg_" user;
in
{
  meta = {
    description = "Logical database + role provisioned on a CloudNativePG cluster";
    owner = "platform";
    lifecycle = "stateful"; # other packages depend on this database existing
    scope = "namespace";
    defaultAliases = [ "database" ];
  };

  assertions =
    { config, ... }:
    [
      {
        # The Database CRD's validation rules on spec.name.
        assertion =
          !builtins.elem config.database [
            "postgres"
            "template0"
            "template1"
          ];
        message = "database \"${config.database}\" is reserved by PostgreSQL (postgres, template0, and template1), and CloudNativePG refuses a Database of that name. Set database to another name; it defaults to the instance name.";
      }
      {
        assertion = !reservedRole config.user;
        message = "user \"${config.user}\" is reserved by CloudNativePG (postgres, streaming_replica, and names starting with pg_ or cnpg_). Choose another role name.";
      }
    ];

  warnings =
    { config, ... }:
    lib.optional (config.password != null)
      "`password` puts the password in plain text in Kix's local store and in the built Secrets. This build still uses it, but Kix 0.10 removes the option. Set `passwordSource` to a SOPS-encrypted file with a `password` key, and `passwordHash` to the content hash of the decrypted password.";

  options = {
    database = lib.mkOption {
      type = identifier;
      default = name;
      defaultText = lib.literalMD "the instance name";
      description = "PostgreSQL database name to create: a letter or underscore, then up to 62 letters, digits, underscores, or hyphens. postgres, template0, and template1 are refused.";
    };

    user = lib.mkOption {
      type = identifier;
      default = name;
      defaultText = lib.literalMD "the instance name";
      description = "PostgreSQL role name to create, which owns the database: a letter or underscore, then up to 62 letters, digits, underscores, or hyphens. CloudNativePG's reserved names are refused.";
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
                description = "Extension version to create. Null takes the image's default version.";
              };
            };
          }
        )
      );
      default = [ ];
      description = ''
        Extensions to create on the new database (the Database's
        `spec.extensions`), as a name or `{ name; version; }`. They must ship
        in the cluster's operand image.
      '';
    };

    password = lib.mkOption {
      type = lib.types.nullOr lib.types.nonEmptyStr;
      default = null;
      description = ''
        Deprecated, and Kix 0.10 removes it. Literal password. Mutually
        exclusive with passwordSource. The plaintext lands in Kix's local
        store and the rendered Secrets, so the build warns. Use
        passwordSource with passwordHash instead.
      '';
    };

    passwordSource = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path to a SOPS-encrypted file containing a `password` key. The Kix
        deploy CLI hydrates the credentials Secret and the role's password
        Secret from this same source at apply time.
      '';
    };

    passwordHash = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Content hash of the SOPS-decrypted password. Required when
        passwordSource is set; the deploy compares it to find a changed
        password.
      '';
    };
  };

  build =
    {
      self,
      config,
      postgres,
      cnpgOperator,
      ...
    }:
    let
      dbName = config.database;
      userName = config.user;

      cluster =
        if postgres.out ? clusterName then
          postgres.out
        else
          throw "${who}: the postgres dependency publishes no out.clusterName, as with an import or a stackgres-cluster. This package creates a DatabaseRole and a Database for a cnpg-cluster; wire one, or a cnpg-pooler in front of one, with deps.postgres = ref.<namespace>.<instance>.";
      crds =
        if cnpgOperator.out ? crds then
          cnpgOperator.out.crds
        else
          throw "${who}: the cnpgOperator dependency publishes no out.crds, as with an import. Wire a managed cnpg-operator instance with deps.cnpgOperator = ref.<namespace>.<instance>.";

      _passwordCheck =
        if config.password == null && config.passwordSource == null then
          throw "${who}: neither password nor passwordSource is set. Set password (a literal, for development) or passwordSource (a SOPS file) with passwordHash."
        else if config.password != null && config.passwordSource != null then
          throw "${who}: both password and passwordSource are set. Remove one."
        else if config.passwordSource != null && config.passwordHash == null then
          throw "${who}: passwordSource is set without passwordHash, which the deploy compares to find a changed password. Set passwordHash."
        else
          null;

      # The cluster's namespace, for the role, the database, and the
      # password Secret the role reads.
      backendScope = scope.forService postgres;

      # Unique in the cluster's namespace across consumer namespaces.
      backendName = "${ns}-${name}";

      labels = {
        "app.kubernetes.io/name" = "cnpg-database";
        "app.kubernetes.io/instance" = name;
        ${kix.keys.dbCluster} = cluster.clusterName;
      };

      passwordData = lib.optionalAttrs (config.password != null) {
        password = config.password;
      };
      secretMeta = {
        classification = "credential";
        rotationPolicy = "manual";
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
          host = cluster.fqdn;
          port = cluster.port;
        }
        // passwordData;
        source = config.passwordSource;
        hash = config.passwordHash;
        inherit labels;
        meta = secretMeta;
      };

      # CloudNativePG reads a role's password from a basic-auth Secret
      # whose `username` is the role name.
      rolePassword = backendScope.mkSecret {
        name = "${backendName}-role";
        type = "kubernetes.io/basic-auth";
        keys = [
          "username"
          "password"
        ];
        stringData = {
          username = userName;
        }
        // passwordData;
        source = config.passwordSource;
        hash = config.passwordHash;
        inherit labels;
        meta = secretMeta;
      };

      role = backendScope.mkCR crds.DatabaseRole {
        name = backendName;
        inherit labels;
        spec = {
          cluster.name = cluster.clusterName;
          name = userName;
          login = true;
          passwordSecret.name = self.rolePassword.out.name;
        };
      };

      database = backendScope.mkCR crds.Database {
        name = backendName;
        inherit labels;
        # The owner must exist before the instance manager creates the
        # database.
        requires = [ self.role ];
        spec = {
          cluster.name = cluster.clusterName;
          name = dbName;
          owner = userName;
        }
        // lib.optionalAttrs (config.extensions != [ ]) {
          extensions = map (e: e // { ensure = "present"; }) (uniqueExtensions config.extensions);
        };
      };
    in
    builtins.seq _passwordCheck {
      inherit
        credentials
        rolePassword
        role
        database
        ;

      # The postgres dependency's out with the Database added to each
      # value, and its Service reference as a part, so a consumer of
      # out.host waits for the Database and gets egress to PostgreSQL
      # (scope.forwardEdges).
      pg = scope.forwardEdges postgres [ self.database ];

      # region:postgresDatabaseCheck
      root = {
        resource = credentials;
        # `postHooks` puts the Database, and the role and Secret it
        # requires, in this instance's own closure even when no consumer
        # reads `out.host`. `credentials` does not reference them and can be
        # applied first.
        postHooks = [ self.database ];

        out = kix.contracts.postgresDatabase.check who {
          host = self.pg.fqdn;
          port = self.pg.port;
          database = dbName;
          username = userName;
          extensions = config.extensions;
          inherit credentials;
          tls = postgres.out.tls or null;
        };
      };
      # endregion:postgresDatabaseCheck
    };
}
