# Tests for the Postgres database contract (kix/contracts/stable/postgresDatabase.nix):
# `check` on the provider side, `assertions` on the consumer side, the
# `deps.database.assertions` of every package that consumes it, and a
# cluster whose database provider publishes a misshapen field.

{
  lib,
  eval,
  kixlib,
  mkCluster,
  manifests,
  ofKind,
  evalFails,
  ...
}:

let
  contract = kixlib.contracts.postgresDatabase;
  # A consumer or provider scope whose `fail` throws.
  scope.fail = kixlib.fail;
  secretPackage = import ../../../packages/stable/secret;

  # A credentials Secret as mkSecret publishes it.
  credentials = keys: {
    out = {
      inherit keys;
      keyRef = key: {
        valueFrom.secretKeyRef = {
          name = "app-db-credentials";
          inherit key;
        };
      };
    };
  };

  # What a kix.mkImport stand-in must publish.
  importOut = {
    host = "db.example.net";
    port = "5432";
    database = "app";
    credentials = credentials [
      "username"
      "password"
    ];
  };

  # What a provider package publishes.
  providerOut = importOut // {
    username = "app";
    extensions = [
      "citext"
      {
        name = "vector";
        version = "0.8.0";
      }
    ];
    tls = true;
  };

  depOf = out: {
    inherit out;
    _meta = {
      namespaceName = "data";
      instanceName = "app-db";
    };
  };

  messagesOf = assertions: map (a: a.message) (builtins.filter (a: !a.assertion) assertions);

  # Each package that reads deps.database, with the arguments its top level
  # takes.
  consumers = lib.genAttrs [ "harbor" "immich" "keycloak" "metabase" "n8n" "vaultwarden" ] (
    pname:
    let
      package = (import ../../../packages/by-level.nix { inherit lib; }).byName.${pname};
    in
    eval.callPackagePhase1 {
      inherit package;
      scope = {
        instanceName = pname;
        namespaceName = "apps";
      };
    }
  );

  # A `database` provider publishing `out`, for a metabase cluster.
  stubPackage =
    out:
    { ... }:
    {
      meta = {
        version = "test";
        description = "database stub";
        owner = "test";
        defaultAliases = [ "database" ];
      };
      options.extensions = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
      };
      build =
        { self, scope, ... }:
        {
          credentials = scope.mkSecret {
            name = "db-credentials";
            keys = [
              "username"
              "password"
            ];
            stringData = {
              username = "metabase";
              password = "pw";
            };
          };
          root = {
            resource = self.credentials;
            out = {
              host = "db.bi.svc";
              database = "metabase";
              credentials = self.credentials;
            }
            // out;
          };
        };
    };

  metabaseCluster =
    out:
    mkCluster [
      {
        instances.bi = {
          metabase.package = import ../../../packages/experimental/metabase;
          metabase-db.package = stubPackage out;
          metabase-key = {
            package = secretPackage;
            aliases = [ "encryptionKey" ];
            config.stringData.key = "0123456789abcdef";
          };
        };
      }
    ];
in
{
  # A provider out with every field passes `check` unchanged; one without
  # `username` or `tls` is refused, since only an import may omit them.
  postgres-database-check-requires-every-field =
    contract.check scope providerOut == providerOut
    && !(builtins.tryEval (contract.check scope importOut)).success
    && !(builtins.tryEval (contract.check scope (providerOut // { tls = "yes"; }))).success
    && contract.check scope (providerOut // { tls = null; }) ? tls;

  # A consumer's assertion accepts an import with only the connection
  # fields, and refuses one without `credentials` with a message naming the
  # provider instance and the field. Kix names the consumer on the record.
  # A `who` text in place of the dependency is refused with the change
  # record id.
  postgres-database-assertions-name-instance-and-field =
    let
      missing = messagesOf (
        contract.assertions (depOf (builtins.removeAttrs importOut [ "credentials" ]))
      );
    in
    messagesOf (contract.assertions (depOf importOut)) == [ ]
    && messagesOf (contract.assertions (depOf providerOut)) == [ ]
    && builtins.length missing == 1
    && lib.hasInfix "data/app-db" (builtins.head missing)
    && lib.hasInfix "credentials is missing" (builtins.head missing)
    && !(builtins.tryEval (contract.assertions "metabase bi/metabase")).success;

  # An optional field is still checked when present, and a credentials
  # Secret that declares keys must declare username and password.
  postgres-database-assertions-check-present-fields =
    let
      one = out: messagesOf (contract.assertions (depOf out));
    in
    builtins.length (one (importOut // { tls = "yes"; })) == 1
    && lib.hasInfix "tls is not" (builtins.head (one (importOut // { tls = "yes"; })))
    && lib.hasInfix "extensions is not" (builtins.head (one (importOut // { extensions = "citext"; })))
    && lib.hasInfix "credentials is not" (
      builtins.head (one (importOut // { credentials = credentials [ "password" ]; }))
    )
    # An undeclared key list (an untracked Secret) passes.
    && one (importOut // { credentials = credentials null; }) == [ ];

  # Every package that reads deps.database holds it to the contract.
  postgres-database-consumers-assert-contract = lib.all (
    pname:
    let
      # Only the contract's messages: immich adds its own extension check.
      contractMessages =
        out:
        builtins.filter (lib.hasInfix "Postgres database contract") (
          messagesOf (consumers.${pname}.deps.database.assertions (depOf out))
        );
      noHost = contractMessages (builtins.removeAttrs providerOut [ "host" ]);
    in
    contractMessages providerOut == [ ]
    && builtins.length noHost == 1
    && lib.hasInfix "host is missing" (builtins.head noHost)
  ) (builtins.attrNames consumers);

  # Harbor reads the role from out.credentials, so an import without
  # out.username satisfies it.
  postgres-database-harbor-takes-import =
    messagesOf (consumers.harbor.deps.database.assertions (depOf importOut)) == [ ];

  # Metabase calls toString on the port, so its build succeeds on an
  # integer port and only the contract refuses it. Metabase's assertion
  # reports the port, and the cluster with that provider fails while the
  # same cluster with a string port builds.
  postgres-database-cluster-refuses-misshapen-provider =
    let
      portMessages = messagesOf (
        consumers.metabase.deps.database.assertions (depOf (importOut // { port = 5432; }))
      );
    in
    builtins.length portMessages == 1
    && lib.hasInfix "port is not the PostgreSQL port as a string" (builtins.head portMessages)
    && lib.hasInfix "toString" (builtins.head portMessages)
    &&
      ofKind "Deployment" (
        manifests (metabaseCluster {
          port = "5432";
        })
      ) != [ ]
    && evalFails (metabaseCluster {
      port = 5432;
    });
}
