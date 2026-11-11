# Tests for the n8n package: the variables `env` and `runners.env` may not
# set, the password of an imported valkey, the request body limit, the
# refusal of a Sentinel valkey import, and the metrics variables.
#
# tryEval drops the message of a throw, so the refusal tests check that the
# build fails with the setting and builds without it. The messages were
# read in probes.

{
  lib,
  eval,
  kixlib,
  mkCluster,
  manifests,
  ofKind,
  byName,
  evalFails,
  ...
}:

let
  n8nPackage = import ../../../packages/experimental/n8n;
  valkeyPackage = import ../../../packages/stable/valkey;
  secretPackage = import ../../../packages/stable/secret;

  # The package's top-level attributes. `deps` and `config` read no
  # instance scope.
  n8nAttrs = n8nPackage {
    scope = {
      instanceName = "n8n";
      namespaceName = "n8n";
    };
    inherit lib;
    kix = kixlib;
    availability = "none";
  };

  # Publishes what n8n reads from a stackgres-database, without the
  # StackGres operator and cluster behind one.
  databaseStub =
    { ... }:
    {
      meta.version = "test";
      build =
        { self, scope, ... }:
        {
          credentials = scope.mkSecret {
            name = "database-credentials";
            keys = [
              "username"
              "password"
            ];
            stringData = {
              username = "n8n";
              password = "test";
            };
          };
          root = {
            resource = self.credentials;
            out = {
              host = "postgres.n8n.svc";
              port = "5432";
              database = "n8n";
              credentials = self.credentials;
            };
          };
        };
    };

  managedValkey.instances.n8n = {
    valkey.package = valkeyPackage;
    valkey-password = {
      package = secretPackage;
      aliases = [ "valkeyPassword" ];
      config.stringData.password = "test";
    };
  };

  # An import without a password is cluster-scoped, so n8n resolves it
  # from another namespace.
  importedValkey = out: {
    instances.cache.redis.package = eval.mkImport {
      from = valkeyPackage;
      out = {
        host = "valkey.example.net";
        port = "6379";
      }
      // out;
    };
  };

  # An import with a password sits in n8n's namespace beside its secret.
  importedValkeyWithPassword =
    { ref, ... }:
    {
      instances.n8n = {
        valkey-login = {
          package = secretPackage;
          config.stringData.password = "test";
        };
        redis.package = eval.mkImport {
          scope = "namespace";
          out = {
            host = "valkey.example.net";
            port = "6379";
            tls = true;
            credentials = ref.n8n.valkey-login;
          };
        };
      };
    };

  n8nCluster =
    {
      config ? { },
      valkey ? managedValkey,
    }:
    mkCluster [
      {
        instances.n8n = {
          n8n = {
            package = n8nPackage;
            inherit config;
          };
          database.package = databaseStub;
          n8n-encryption-key = {
            package = secretPackage;
            aliases = [ "encryptionKey" ];
            config.stringData.key = "0123456789abcdef0123456789abcdef";
          };
        };
      }
      valkey
    ];

  builds = cluster: !(evalFails cluster);

  deploymentOf = cluster: name: byName name (ofKind "Deployment" (manifests cluster));
  containerOf =
    cluster: deployment: container:
    lib.findFirst (c: c.name == container) null
      (deploymentOf cluster deployment).spec.template.spec.containers;
  envOf =
    cluster: deployment: container:
    builtins.listToAttrs (
      map (e: {
        inherit (e) name;
        value = e.value or e.valueFrom;
      }) ((containerOf cluster deployment container).env or [ ])
    );

  base = n8nCluster { };
in
{
  # Each variable a group owns is refused in `env`, also when null, and
  # each sidecar variable the package owns is refused in `runners.env`.
  n8n-env-refusals =
    let
      refusedEnv = {
        # the database dependency, and a `_FILE` twin of one of its variables
        DB_POSTGRESDB_HOST = "elsewhere";
        DB_POSTGRESDB_PASSWORD_FILE = "/run/secrets/db";
        # the valkey dependency, while it publishes a password
        QUEUE_BULL_REDIS_PASSWORD = "test";
        # the encryptionKey dependency
        N8N_ENCRYPTION_KEY_FILE = "/run/secrets/key";
        # queue mode and task-runner wiring; the worker's names are refused
        # on the main instance too
        EXECUTIONS_MODE = null;
        N8N_RUNNERS_MODE = "internal";
        N8N_RUNNERS_AUTH_TOKEN = "token";
        # the deprecated webhook URL name
        WEBHOOK_URL = "https://n8n.example.com/";
      };
      refusedRunnerEnv = {
        N8N_RUNNERS_TASK_BROKER_URI = "http://127.0.0.1:1";
        N8N_RUNNERS_AUTH_TOKEN = "token";
        N8N_RUNNERS_AUTH_TOKEN_FILE = "/tmp/token";
      };
      accepted =
        lib.filter (
          n:
          builds (n8nCluster {
            config.env.${n} = refusedEnv.${n};
          })
        ) (lib.attrNames refusedEnv)
        ++ map (n: "runners.env.${n}") (
          lib.filter (
            n:
            builds (n8nCluster {
              config.runners.env.${n} = refusedRunnerEnv.${n};
            })
          ) (lib.attrNames refusedRunnerEnv)
        );
    in
    (builds base && accepted == [ ]) || throw "n8n env refusals accepted: ${toString accepted}";

  # A managed valkey's password reaches both n8n containers from its
  # Secret, and neither pod gets Service environment variables.
  n8n-managed-valkey-password =
    let
      password = cluster: deployment: (envOf cluster deployment "n8n").QUEUE_BULL_REDIS_PASSWORD or null;
      serviceLinks = map (d: (deploymentOf base d).spec.template.spec.enableServiceLinks or null) [
        "n8n"
        "n8n-worker"
      ];
    in
    (
      (password base "n8n").secretKeyRef.key or null == "password"
      && (password base "n8n-worker").secretKeyRef.key or null == "password"
      &&
        serviceLinks == [
          false
          false
        ]
    )
    || throw "n8n valkey password ${builtins.toJSON (password base "n8n")}, enableServiceLinks ${builtins.toJSON serviceLinks}";

  # An import without credentials sets no password, and `env` may supply
  # one. An import whose credentials name a secret sets the password from
  # it, and its `tls` turns TLS on.
  n8n-imported-valkey-password =
    let
      bare = n8nCluster { valkey = importedValkey { }; };
      withCredentials = n8nCluster { valkey = importedValkeyWithPassword; };
      tlsOf = cluster: (envOf cluster "n8n" "n8n").QUEUE_BULL_REDIS_TLS or null;
      withPassword = n8nCluster {
        valkey = importedValkey { };
        config.env.QUEUE_BULL_REDIS_PASSWORD.valueFrom.secretKeyRef = {
          name = kixlib.untrackedRef "valkey-auth";
          key = "password";
        };
      };
      password = cluster: deployment: (envOf cluster deployment "n8n").QUEUE_BULL_REDIS_PASSWORD or null;
      supplied = map (password withPassword) [
        "n8n"
        "n8n-worker"
      ];
    in
    (
      password bare "n8n" == null
      && builtins.all (p: p.secretKeyRef.key or null == "password") supplied
      && (password withCredentials "n8n").secretKeyRef.key or null == "password"
      && tlsOf bare == null
      && tlsOf withCredentials == "true"
    )
    || throw "n8n imported valkey: without env ${builtins.toJSON (password bare "n8n")}, with env ${builtins.toJSON supplied}, with credentials ${builtins.toJSON (password withCredentials "n8n")}, tls ${builtins.toJSON (tlsOf withCredentials)}";

  # An import that publishes a Sentinel port fails the build; the
  # assertion's message asks for a standalone valkey.
  n8n-sentinel-import-refused =
    let
      messages =
        dep: map (a: a.message) (lib.filter (a: !a.assertion) (n8nAttrs.deps.redis.assertions dep));
      plain = {
        host = "valkey.example.net";
        port = "6379";
      };
      sentinel = messages {
        out = plain // {
          sentinel = {
            port = "26379";
            primarySet = "primary";
          };
        };
      };
    in
    (
      messages { out = plain; } == [ ]
      &&
        messages {
          out = plain // {
            sentinel = null;
          };
        } == [ ]
      && builtins.any (lib.hasInfix "standalone valkey") sentinel
      && evalFails (n8nCluster {
        valkey = importedValkey {
          sentinel = {
            port = "26379";
            primarySet = "primary";
          };
        };
      })
    )
    || throw "n8n Sentinel import: messages ${builtins.toJSON sentinel}";

  # `env` sizes that are not whole MiB fail the build; the ingress-nginx
  # body limit is the larger of the two request limits.
  n8n-body-size =
    let
      annotation =
        env:
        (n8nAttrs.config {
          config = {
            inherit env;
            image.tag = "test";
          };
        }).ingress.annotations."nginx.ingress.kubernetes.io/proxy-body-size".content;
      sizes = map annotation [
        { }
        { N8N_FORMDATA_FILE_SIZE_MAX = "500"; }
        { N8N_PAYLOAD_SIZE_MAX = "300"; }
      ];
    in
    (
      sizes == [
        "200m"
        "500m"
        "300m"
      ]
      && evalFails (n8nCluster {
        config.env.N8N_FORMDATA_FILE_SIZE_MAX = "16mb";
      })
    )
    || throw "n8n proxy-body-size: ${builtins.toJSON sizes}";

  # metrics.enabled turns on /metrics on the main instance whether or not a
  # prometheus provider exists, so adding one later does not change the
  # pod template. Without a provider there is no ServiceMonitor.
  n8n-metrics-without-prometheus =
    let
      on = n8nCluster { config.metrics.enabled = true; };
      mainEnv = envOf on "n8n" "n8n";
      baseEnv = envOf base "n8n" "n8n";
    in
    (
      mainEnv.N8N_METRICS or null == "true"
      && mainEnv.N8N_METRICS_INCLUDE_QUEUE_METRICS or null == "true"
      && !(baseEnv ? N8N_METRICS)
      && ofKind "ServiceMonitor" (manifests on) == [ ]
    )
    || throw "n8n metrics env ${builtins.toJSON mainEnv}";
}
