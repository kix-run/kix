# Tests for kix/packages/stable/immich and immich-machine-learning, and the
# kix/lib behaviour they rely on: kix.monitor gives each extra endpoint the
# instance's scrape interval and the default scheme and path; the env
# groups, settings paths, release check, and chown guard refuse what the
# package owns; and a worker in another namespace is not bound.
#
# The server runs in namespace `photos` against kix.mkImport stand-ins for
# its database, valkey, and library claim. tryEval drops a throw's message,
# so build throws are checked with evalFails beside a passing control, and
# message text is checked where the package returns it (the database
# assertion).

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
  immichPackage = import ../../../packages/stable/immich;
  mlPackage = import ../../../packages/stable/immich-machine-learning;
  secretPackage = import ../../../packages/stable/secret;
  rules = import ../../rules { inherit lib; };

  databaseOut = {
    host = "db.example.net";
    port = "5432";
    database = "immich";
    credentials.out.keyRef = key: {
      valueFrom.secretKeyRef = {
        name = kixlib.untrackedRef {
          name = "immich-db";
          kind = "Secret";
        };
        inherit key;
      };
    };
  };

  # immich in `photos` with `config`; `extra` adds instances to `photos`,
  # and `modules` adds cluster modules.
  immichCluster =
    {
      config ? { },
      extra ? { },
      modules ? [ ],
    }:
    mkCluster (
      [
        {
          instances.photos = {
            immich = {
              package = immichPackage;
              inherit config;
            };
            immich-db = {
              package = eval.mkImport { out = databaseOut; };
              aliases = [ "database" ];
            };
            valkey = {
              package = eval.mkImport {
                out = {
                  host = "valkey.example.net";
                  port = "6379";
                };
              };
              aliases = [ "valkey" ];
            };
            library = {
              package = eval.mkImport {
                out = {
                  name = kixlib.untrackedRef {
                    name = "library";
                    kind = "PersistentVolumeClaim";
                  };
                  size = "100Gi";
                };
              };
              aliases = [ "storage" ];
            };
          }
          // extra;
        }
      ]
      ++ modules
    );

  serverEnv =
    cluster:
    let
      d = byName "immich-server" (ofKind "Deployment" (manifests cluster));
    in
    lib.listToAttrs (
      map (e: {
        inherit (e) name;
        value = e.value or e.valueFrom;
      }) (builtins.head d.spec.template.spec.containers).env
    );

  # immich with an SMTP server in its namespace whose `tls` is `tls`, with
  # a login when `login` is true.
  immichMailCluster =
    {
      tls ? "implicit",
      login ? true,
      config ? { },
    }:
    immichCluster {
      inherit config;
      modules = [
        (
          { ref, ... }:
          {
            instances.photos = {
              smtp-login = {
                package = secretPackage;
                config.stringData = {
                  username = "immich";
                  password = "mail-pw";
                };
              };
              smtp.package = eval.mkImport {
                scope = "namespace";
                out = {
                  host = "smtp.example.org";
                  port = if tls == "implicit" then "465" else "587";
                  inherit tls;
                  from = "photos@example.org";
                }
                // lib.optionalAttrs login { credentials = ref.photos.smtp-login; };
              };
            };
          }
        )
      ];
    };

  serverConfig =
    cluster:
    builtins.fromJSON
      (byName "immich-config" (ofKind "ConfigMap" (manifests cluster))).data."immich-config.json";
  serverContainer =
    cluster:
    builtins.head (byName "immich-server" (ofKind "Deployment" (manifests cluster)))
      .spec.template.spec.containers;

  # The database assertion's failed messages for a dependency publishing
  # databaseOut with `out` over it.
  databaseMessages =
    out:
    let
      attrs = immichPackage {
        scope = {
          instanceName = "immich";
          namespaceName = "photos";
        };
        inherit lib;
        kix = kixlib;
      };
    in
    map (a: a.message) (
      builtins.filter (a: !a.assertion) (attrs.deps.database.assertions { out = databaseOut // out; })
    );

  # The ServiceMonitor endpoints kix.monitor builds for `metrics`, with a
  # prometheus stub whose builder returns the arguments it was given.
  endpointsOf =
    metrics:
    let
      parts =
        kixlib.monitor
          {
            service = "service";
            port = "metrics-api";
            extraEndpoints = [ { port = "metrics-ms"; } ];
          }
          {
            inherit lib;
            self.service.out.selector.app = "immich";
            config.metrics = metrics;
            scope = {
              instanceName = "immich";
              namespaceName = "photos";
            };
            prometheus.out.mkServiceMonitor = _scope: monitorArgs: monitorArgs;
          };
    in
    parts.serviceMonitor.spec.endpoints;

  endpoint = port: {
    inherit port;
    path = "/metrics";
    scheme = "http";
  };
in
{
  # metrics.interval = "30s" renders interval, scheme, and path on both
  # endpoints; without an interval neither endpoint has one.
  immich-monitor-extra-endpoint-interval =
    let
      timed = endpointsOf {
        enabled = true;
        interval = "30s";
      };
      untimed = endpointsOf {
        enabled = true;
        interval = null;
      };
    in
    (
      timed == [
        (endpoint "metrics-api" // { interval = "30s"; })
        (endpoint "metrics-ms" // { interval = "30s"; })
      ]
      &&
        untimed == [
          (endpoint "metrics-api")
          (endpoint "metrics-ms")
        ]
    )
    || throw "kix.monitor extra endpoints: with interval ${builtins.toJSON timed}, without ${builtins.toJSON untimed}";

  # Without a machineLearning dependency the server turns machine learning
  # off; a numeric port from an import renders as a string.
  immich-defaults =
    let
      env = serverEnv (immichCluster { });
    in
    (
      env.IMMICH_MACHINE_LEARNING_ENABLED or null == "false"
      && !(env ? IMMICH_MACHINE_LEARNING_URL)
      && env.DB_PORT or null == "5432"
      && env.REDIS_PORT or null == "6379"
      && env.DB_DATABASE_NAME or null == "immich"
    )
    || throw "immich defaults: env ${builtins.toJSON env}";

  # env refuses one key from each owned group, also when set to null;
  # IMMICH_TELEMETRY_INCLUDE and an unowned key pass.
  immich-env-owned-groups =
    let
      fails =
        env:
        evalFails (immichCluster {
          config.env = env;
        });
    in
    (
      fails { DB_HOSTNAME = "x"; }
      && fails { DB_HOSTNAME = null; }
      && fails { REDIS_URL = "redis://x"; }
      && fails { IMMICH_MACHINE_LEARNING_URL = "http://x:3003"; }
      && fails { IMMICH_CONFIG_FILE = "/x"; }
      && fails { IMMICH_MEDIA_LOCATION = "/x"; }
      && fails { IMMICH_PORT = "1"; }
      && !fails { TZ = "UTC"; }
      && !fails { IMMICH_TELEMETRY_INCLUDE = "api"; }
    )
    || throw "immich env: an owned key passed or an unowned key failed";

  # settings refuses the machineLearning paths that follow the dependency and
  # accepts the rest of that subtree.
  immich-settings-owned-paths =
    let
      fails =
        settings:
        evalFails (immichCluster {
          config = { inherit settings; };
        });
    in
    (
      fails { machineLearning.urls = [ "http://x:3003" ]; }
      && fails { machineLearning.enabled = true; }
      && !fails { machineLearning.clip.enabled = false; }
    )
    || throw "immich settings: the owned paths passed or a free path failed";

  # A worker at another release fails the build; the same release passes and
  # sets the URL.
  immich-ml-version-mismatch =
    let
      withWorker =
        tag:
        immichCluster {
          extra.machine-learning = {
            package = mlPackage;
            config.image.tag = tag;
          };
        };
      release = (import ../../../packages/stable/immich/release.nix).tag;
      url = (serverEnv (withWorker release)).IMMICH_MACHINE_LEARNING_URL or "";
    in
    (
      evalFails (withWorker "v0.0.1")
      && lib.hasPrefix "http://machine-learning.photos.svc." url
      && lib.hasSuffix ":3003" url
    )
    || throw "immich ml release: a mismatched worker passed or a matching one was not bound";

  # An import standing in for the worker may give a numeric port; one
  # without an fqdn fails the build.
  immich-ml-import =
    let
      withImport =
        out:
        immichCluster {
          extra.ml = {
            package = eval.mkImport { inherit out; };
            aliases = [ "machineLearning" ];
          };
        };
      url =
        (serverEnv (withImport {
          fqdn = "ml.example.net";
          port = 3003;
        })).IMMICH_MACHINE_LEARNING_URL or null;
    in
    (
      url == "http://ml.example.net:3003"
      && evalFails (withImport {
        port = 3003;
      })
    )
    || throw "immich ml import: url ${builtins.toJSON url}";

  # A worker in another namespace is not bound automatically, and an
  # explicit reference to it is refused.
  immich-ml-other-namespace =
    let
      worker = {
        instances.other.ml.package = mlPackage;
      };
      env = serverEnv (immichCluster {
        modules = [ worker ];
      });
    in
    (
      env.IMMICH_MACHINE_LEARNING_ENABLED or null == "false"
      && !(env ? IMMICH_MACHINE_LEARNING_URL)
      && evalFails (immichCluster {
        modules = [
          worker
          (
            { ref, ... }:
            {
              instances.photos.immich.deps.machineLearning = ref.other.ml;
            }
          )
        ];
      })
    )
    || throw "immich ml in another namespace: env ${builtins.toJSON env}";

  # initChownData fails the build while security.nonRoot is an error, and
  # passes with the namespace override its message names.
  immich-chown-guard =
    let
      withSeverity =
        severity:
        immichCluster {
          config.initChownData = true;
          modules = [
            {
              scorecard = {
                enable = true;
                maxSeverity = "error";
                rules.security = { inherit (rules.security) nonRoot; };
              };
            }
          ]
          ++ lib.optional (severity != null) {
            scorecard.ruleOverrides.byNamespace.photos."security.nonRoot".severity = severity;
          };
        };
    in
    (evalFails (withSeverity null) && !evalFails (withSeverity "warning"))
    || throw "immich chown guard: did not fail under an error severity, or failed with the override";

  # The database assertion names both remedies, and stays silent when the
  # dependency publishes no extensions or all of them.
  immich-database-extensions =
    let
      partial = databaseMessages {
        extensions = [
          "vchord"
          "cube"
        ];
      };
    in
    (
      builtins.length partial == 1
      && lib.hasInfix "missing: uuid-ossp, earthdistance, unaccent, pg_trgm." (builtins.head partial)
      && lib.hasInfix "out.extensions" (builtins.head partial)
      && databaseMessages { } == [ ]
      &&
        databaseMessages {
          extensions = [
            "vchord"
            "uuid-ossp"
            "cube"
            "earthdistance"
            "unaccent"
            "pg_trgm"
          ];
        } == [ ]
    )
    || throw "immich database assertion: ${builtins.toJSON partial}";

  # With smtp wired, the config file carries the server and sender, and the
  # login reaches the file at start from the secret.
  immich-mail =
    let
      c = immichMailCluster { };
      smtp = (serverConfig c).notifications.smtp;
      env = serverEnv c;
      args = builtins.head (serverContainer c).args;
      plain = serverConfig (immichMailCluster {
        tls = "starttls";
        login = false;
        config.mail.from = "me@example.org";
      });
    in
    (
      smtp == {
        enabled = true;
        from = "photos@example.org";
        transport = {
          host = "smtp.example.org";
          port = 465;
          secure = true;
          ignoreCert = false;
        };
      }
      && env.SMTP_PASSWORD.secretKeyRef.key == "password"
      && env.SMTP_USERNAME.secretKeyRef.key == "username"
      && env.IMMICH_CONFIG_FILE == "/run/immich/immich-config.json"
      && lib.hasInfix "SMTP_USERNAME" args
      && plain.notifications.smtp.transport.secure == false
      && plain.notifications.smtp.from == "me@example.org"
      && !(
        serverEnv (immichMailCluster {
          login = false;
        }) ? SMTP_PASSWORD
      )
    )
    || throw "immich mail: ${builtins.toJSON smtp}, env ${builtins.toJSON env}";

  # STARTTLS with a login, a password in settings, and a setting the smtp
  # dependency owns each fail the build.
  immich-mail-refusals =
    !(evalFails (immichMailCluster { }))
    && evalFails (immichMailCluster {
      tls = "starttls";
    })
    && evalFails (immichCluster {
      config.settings.notifications.smtp.transport.password = "pw";
    })
    && !(evalFails (immichCluster {
      config.settings.notifications.smtp.transport.host = "mail";
    }))
    && evalFails (immichMailCluster {
      config.settings.notifications.smtp.transport.host = "mail";
    });
}
