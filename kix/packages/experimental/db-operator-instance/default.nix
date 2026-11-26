# db-operator-instance: one DB Operator DbInstance, which points the
# operator at a PostgreSQL server and the admin login it uses there.
#
# The DbInstance is cluster-scoped and named after the instance, so
# instance names are unique across namespaces: a second instance of the
# same name in another namespace fails evaluation as a duplicate. A
# db-operator-database in any namespace names it through its `dbInstance`
# dependency, and the operator creates that database and its user on the
# server with the admin login.
#
# The admin login stays in this instance's namespace. The DbInstance names
# that Secret and its namespace (`spec.auth`), and the operator reads it
# with its cluster-wide role. The admin must be able to create roles and
# databases, and to create the extensions a Database asks for: the
# operator runs CREATE USER, CREATE DATABASE, GRANT, and CREATE EXTENSION
# (pkg/utils/database/postgres.go upstream).
#
# Minimal instance, beside a cnpg-cluster `pg` whose superuser Secret the
# operator signs in with:
#
#   pg-superuser = {
#     package = packages.secret-ref;     # the Secret CloudNativePG writes
#     config = {
#       type = "kubernetes.io/basic-auth";
#       keys = [ "username" "password" ];
#     };
#   };
#   pg-instance = {
#     package = packages.experimental.db-operator-instance;
#     deps = {
#       postgres = ref.data.pg;
#       adminCredentials = ref.data.pg-superuser;
#     };
#   };
#
# clusters/test-db-operator.nix evaluates it, with `enableSuperuserAccess`
# set on the cnpg-cluster so CloudNativePG writes that Secret.
#
# Dependencies:
#   dbOperator (required)        the db-operator instance whose DbInstance
#                                handle the package builds from.
#   postgres (required)          the server: an instance with out.fqdn and
#                                out.port, such as a cnpg-cluster, a
#                                stackgres-cluster, a service-ref, or a
#                                `kix.mkImport` of a server outside the
#                                cluster. out.tls, when published, turns on
#                                TLS from the operator. An import of a server
#                                outside the cluster also sets
#                                `out.external = true`.
#   adminCredentials (required)  the admin login, a secret in this
#                                instance's namespace with the keys
#                                `auth.usernameKey` and `auth.passwordKey`.
#
# TLS: with `out.tls = true` on the server, the DbInstance sets
# `endpoint.sslConnection` to enabled with skip-verify, because DB Operator
# 2.47 takes no CA for a server and checks a certificate only against the
# system roots of its image. `extraSpec.endpoint.sslConnection` replaces it.
#
# Network policy: the operator's controller dials the server. For a server
# in the cluster, the address in the DbInstance carries the server
# Service's endpoint fact, and db-operator's factBehavior on DbInstance
# turns it into egress from the controller pods and ingress on the server's
# pods. For a server with `out.external = true`, the package renders a
# policy in the operator's namespace that lets the controller pods reach
# any address on the server's port, because a policy cannot name a host
# outside the cluster. Consumers of a db-operator-database on such a server
# get no egress to it from Kix.
#
# `out`:
#   out.name       the DbInstance's name.
#   out.engine     "postgres".
#   out.fqdn       the server's address, carrying the DbInstance, so a
#                  consumer waits until the operator has logged in, and the
#                  server Service's endpoint fact.
#   out.port       the server's port, as a string, carrying the same.
#   out.tls        the server's out.tls, or null.
#
# Removing or renaming: a Database looks up its DbInstance on every
# reconcile, including deletion (Reconcile in
# internal/controller/database_controller.go upstream). The Database's
# finalizer needs the DbInstance. `kix deploy --prune` deletes the Database
# before the DbInstance. With the controller running, the Database usually
# finishes first, but `kix deploy --prune` does not wait for it. If the
# controller is slow, restarting, or scaled to zero (as during an upgrade),
# the DbInstance disappears first and the Database stays in Terminating with
# finalizer `db.<instance>`, logging
# `DbInstance.kinda.rocks "<name>" not found` on every retry. If db-operator
# (the controller) is removed while Databases still exist, nothing removes
# their finalizers, so they also stay in Terminating. `kix status` omits a
# Database once it leaves the cluster definition. Remove the
# db-operator-database instances first, deploy with `--prune`, and wait until
# `kubectl get database -A` no longer lists them before removing this
# instance or db-operator. To recover, add whatever was removed (this
# instance, db-operator, or both) back to the cluster definition, deploy,
# wait until the Databases are gone (about 50 seconds, set by the
# controller's retry delay), and then remove it again and deploy with
# `--prune`. The controller also checks `namespaceFilters` before handling a
# deletion. Narrowing `extraSpec.namespaceFilters` and removing Databases in
# the excluded namespaces in one deploy leaves them in Terminating with
# "namespace <ns> is not allowed on the instance". To recover, widen the
# filters again, deploy, wait until the Databases are gone, and then narrow
# them. The webhook refuses a change to a Database's `spec.instance`, so
# renaming this instance while Databases name it fails at apply.
#
# Escape hatches: `extraSpec` (such as `namespaceFilters`, `grantRules`,
# `allowedPrivileges`, `instanceVars`, or `endpoint.sslConnection`), and the
# instance's `partsOverlays`.
#
# Limits: only PostgreSQL. DB Operator also serves MySQL and ClickHouse,
# which no package here wires. Any namespace may create databases on the
# instance unless `extraSpec.namespaceFilters` limits it. Each filter is a
# Go regular expression matched anywhere in the namespace name
# (CheckNamespaceFilter in internal/controller/helpers/dbinstance.go
# upstream), so `apps` also admits `myapps` and `apps-staging`; anchor it
# as `^apps$`. A Database in a namespace the filters exclude never becomes
# ready, and the deploy that applies it waits until it times out. An import
# of a server outside the cluster that leaves out `out.external = true`
# gets no egress, so under default deny its DbInstance never becomes ready.
# DB Operator 2.47 connects for its Database steps without TLS, whatever
# `endpoint.sslConnection` says, so on a server that refuses connections
# without TLS (common on managed PostgreSQL) the DbInstance becomes ready
# and every Database on it then fails.

{
  scope,
  lib,
  kix,
}:

let
  name = scope.instanceName;
  ns = scope.namespaceName;

  # Secret data keys, as Kubernetes admits them.
  secretKey = lib.types.strMatching "[-._a-zA-Z0-9]+";
in
{
  meta = {
    description = "DB Operator DbInstance that registers a PostgreSQL server and its admin credentials";
    owner = "platform";
    defaultAliases = [ "dbInstance" ];
    # A db-operator-database in any namespace uses the one DbInstance by
    # name, and the package hands out no Secret.
    scope = "cluster";
  };

  options = {
    auth = {
      usernameKey = lib.mkOption {
        type = secretKey;
        default = "username";
        description = "Secret key in `deps.adminCredentials` that holds the PostgreSQL admin username.";
      };
      passwordKey = lib.mkOption {
        type = secretKey;
        default = "password";
        description = "Secret key in `deps.adminCredentials` that holds the PostgreSQL admin password.";
      };
    };

    extraSpec = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      example = {
        namespaceFilters = [ "^apps$" ];
      };
      description = ''
        Additional fields merged into the `DbInstance` `spec`, such as
        `namespaceFilters` or `endpoint.sslConnection`. Each entry in
        `namespaceFilters` is a Go regular expression matched anywhere in the
        namespace name, so anchor exact names like `"^apps$"`. Kix rejects `engine`,
        `auth`, `endpoint.host`, and `endpoint.port` here because this package sets
        them.
      '';
    };
  };

  build =
    {
      self,
      config,
      dbOperator,
      postgres,
      adminCredentials,
      ...
    }:
    let
      crds =
        dbOperator.out.crds or (scope.fail {
          dependency = "dbOperator";
          message = "deps.dbOperator is missing out.crds (for example, because it uses kix.mkImport instead of packages.experimental.db-operator), so Kix cannot create the DbInstance resource.";
          fix = "Point deps.dbOperator at a packages.experimental.db-operator instance: deps.dbOperator = ref.<namespace>.<instance>.";
        });

      server =
        if postgres.out ? fqdn && postgres.out ? port then
          postgres.out
        else
          scope.fail {
            dependency = "postgres";
            message = "deps.postgres is missing out.fqdn or out.port, so Kix cannot configure the DbInstance endpoint.";
            fix = "Point deps.postgres at a PostgreSQL server instance (such as cnpg-cluster, stackgres-cluster, or service-ref), or at a kix.mkImport that sets out.fqdn and out.port.";
          };
      port = toString server.port;
      tls = server.tls or null;
      external = server.external or false;

      _external =
        if builtins.isBool external then
          null
        else
          scope.fail {
            dependency = "postgres";
            message = "deps.postgres sets out.external to ${builtins.toJSON external} instead of true or false, so Kix rejected this DbInstance.";
            fix = "Set out.external = true on kix.mkImport for a PostgreSQL server outside the cluster, or set out.external = false (or omit it) for a server in the cluster.";
          };

      portNumber =
        if builtins.match "[0-9]+" port != null then
          lib.toInt port
        else
          scope.fail {
            dependency = "postgres";
            message = "deps.postgres sets out.port to \"${port}\", which is not a TCP port number, so Kix rejected this DbInstance.";
            fix = "Set out.port on deps.postgres to an integer or a numeric string, such as 5432 or \"5432\".";
          };

      admin = kix.contracts.secret.helpers.use {
        inherit scope;
        arg = "adminCredentials";
        dep = adminCredentials;
        keys = [
          config.auth.usernameKey
          config.auth.passwordKey
        ];
      };

      secretValue = key: {
        valueFrom.secret = {
          namespace = ns;
          name = admin.out.name;
          inherit key;
        };
      };

      baseSpec = {
        engine = "postgres";
        auth = {
          username = secretValue config.auth.usernameKey;
          password = secretValue config.auth.passwordKey;
        };
        endpoint = {
          host.value = server.fqdn;
          port.value = port;
          sslConnection = {
            enabled = tls == true;
            skip-verify = tls == true;
          };
        };
      };

      spec = kix.mergeGuarded {
        inherit scope;
        option = "extraSpec";
        locked = [
          [ "engine" ]
          [ "auth" ]
          [
            "endpoint"
            "host"
          ]
          [
            "endpoint"
            "port"
          ]
        ];
      } baseSpec config.extraSpec;

      netpol = scope.networkPolicyEnforcer.netpol;
    in
    builtins.seq _external (
      builtins.seq portNumber {
        dbInstance = scope.mkCR crds.DbInstance {
          inherit name spec;
          # The operator logs in before it reports the DbInstance ready.
          requires = builtins.filter (r: r != null) [ self.operatorEgress ];
        };

        # The server's out with the DbInstance added to each value, and its
        # Service reference as a part, so a consumer of out.fqdn waits for the
        # DbInstance and gets egress to the server (scope.forwardEdges).
        server = scope.forwardEdges postgres [ self.dbInstance ];

        operatorEgress =
          if external then
            kix.operandPolicy {
              scope = scope.forService dbOperator;
              # The DbInstance's name is unique in the cluster.
              name = "${name}-db-operator-egress";
              selector = dbOperator.out.podSelector;
              egress =
                (netpol.translateIntentRules {
                  intents.server.egress = [
                    {
                      to = "world";
                      ports = [
                        {
                          port = portNumber;
                          protocol = "TCP";
                        }
                      ];
                    }
                  ];
                }).egressRules;
            }
          else
            null;

        root = {
          resource = self.dbInstance;
          out = {
            name = self.dbInstance.out.name;
            engine = "postgres";
            inherit (self.server) fqdn;
            port = toString self.server.port;
            inherit tls;
          };
        };
      }
    );
}
