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
#   password (required)      the role's password, a secret with the key
#                            `password` (kix.contracts.secret), in this
#                            instance's namespace.
#
# Where the password comes from decides what the package renders:
#
# - A `packages.secret` with a SOPS `source`: the package renders the
#   credentials Secret and the role's password Secret in the cluster's
#   namespace from that file, and the deploy fills both.
# - Any other secret (`packages.secret-ref`, `packages.experimental.external-secret`,
#   a site's own source package): the package renders neither. The
#   dependency is the credentials Secret, so it must also hold `username`,
#   equal to `user`. The site writes the role's password into the cluster's
#   namespace too, as the kubernetes.io/basic-auth Secret
#   `<namespace>-<instance>-role` with the keys `username` (equal to `user`)
#   and `password`, and the deploy waits for it.
#
# Minimal instance, beside an app that takes deps.database:
#
#   app-db = {
#     package = packages.experimental.cnpg-database;
#     deps.password = ref.apps.app-db-password;
#   };
#   app-db-password = {
#     package = packages.secret;
#     config = {
#       source = ./secrets/app-db.yaml;   # holds `password`
#       keys = [ "password" ];
#     };
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
#   out.credentials         the credentials Secret, for `out.mkEnv`: the
#                           one this package renders, or the password
#                           dependency.
#   out.tls                 whether PostgreSQL serves TLS (the postgres
#                           dependency's `out.tls`).
#
# root = the credentials Secret.
#
# Escape hatch: the instance's `partsOverlays`.
#
# Limits: Kix copies only a value it decrypts itself, so a password from any
# other source has to be delivered to both namespaces. The instance manager
# reads the role's Secret again when it changes, so a changed password there
# reaches the role without a new deploy.
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
          scope.fail {
            package = "cnpg-database";
            message = "extension ${extName} is requested at versions ${lib.concatStringsSep " and " versions}, by the instance's `extensions` and a consumer's deps.database.config.extensions.";
            fix = "Request one version, or none to take the operand image's default.";
          }
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
  };

  build =
    {
      self,
      config,
      postgres,
      cnpgOperator,
      # Optional only so that a build with the removed options reaches
      # _passwordCheck and its message; a missing one fails below.
      password ? null,
      ...
    }:
    let
      dbName = config.database;
      userName = config.user;

      cluster =
        if postgres.out ? clusterName then
          postgres.out
        else
          scope.fail {
            package = "cnpg-database";
            message = "the postgres dependency publishes no out.clusterName, as with an import or a stackgres-cluster. This package creates a DatabaseRole and a Database for a cnpg-cluster.";
            fix = "Wire one, or a cnpg-pooler in front of one, with deps.postgres = ref.<namespace>.<instance>.";
          };
      crds =
        if cnpgOperator.out ? crds then
          cnpgOperator.out.crds
        else
          scope.fail {
            package = "cnpg-database";
            message = "the cnpgOperator dependency publishes no out.crds, as with an import.";
            fix = "Wire a managed cnpg-operator instance with deps.cnpgOperator = ref.<namespace>.<instance>.";
          };

      passwordAdvice = "Give the password as the dependency `password`: a packages.secret instance in this namespace with source set to a SOPS file that holds `password`, and keys = [ \"password\" ], wired with deps.password = ref.<namespace>.<instance>.";

      _passwordCheck =
        if config.password != null then
          scope.fail {
            id = "K9503";
            package = "cnpg-database";
            option = "config.password";
            message = "password was removed, because it put the password in plain text in Kix's local store and in the built Secrets.";
            fix = passwordAdvice;
          }
        else if config.passwordSource != null || config.passwordHash != null then
          scope.fail {
            id = "K6023";
            package = "cnpg-database";
            option = "config.passwordSource";
            message = "passwordSource and passwordHash were removed.";
            fix = "${passwordAdvice} Use the same file.";
          }
        else if password == null then
          scope.fail {
            package = "cnpg-database";
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
            scope.fail {
              package = "cnpg-database";
              message = "deps.password resolved to secret \"${dep.out.name}\", which Kix does not fill from a SOPS file, so it is also the credentials Secret the app reads.";
              fix = "Add `username` (equal to user, \"${userName}\") to that secret and to its keys, or use a packages.secret with a SOPS source.";
            }
        );

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

      secretMeta = {
        classification = "credential";
        rotationPolicy = "manual";
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
              host = cluster.fqdn;
              port = cluster.port;
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

      # CloudNativePG reads a role's password from a basic-auth Secret
      # whose `username` is the role name: rendered from the same SOPS file
      # as `credentials`, or written there by the site.
      rolePassword =
        if fromSops then
          backendScope.mkSecret {
            name = "${backendName}-role";
            type = "kubernetes.io/basic-auth";
            keys = [
              "username"
              "password"
            ];
            stringData = {
              username = userName;
            };
            inherit (sops) source;
            inherit labels;
            meta = secretMeta;
          }
        else
          backendScope.mkSecretRef {
            name = "${backendName}-role";
            type = "kubernetes.io/basic-auth";
            keys = [
              "username"
              "password"
            ];
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
    builtins.seq passwordDep {
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
