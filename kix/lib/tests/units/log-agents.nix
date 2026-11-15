# Tests for kix/packages/experimental/loki-logs, kix/packages/experimental/clickhouse-logs and the
# Vector agent they share (clickhouse-logs/vector-agent.nix): the locked
# `settings` paths, the refused flags and env variables, the deps.loki
# guard, the monitoring module's lokiLogs guard, the priorityClass
# dependency, and the one-letter flags kix.guardArgs refuses. loki-logs runs
# in namespace `logs` next to a loki instance, clickhouse-logs in `chlogs`.
#
# builtins.tryEval drops the text of a `throw`. To read a refusal's message,
# `caught` loads a file through builtins.scopedImport with `throw` bound to
# a function that returns `{ thrown = <message>; }`, and so does the
# `kix.fail` they call (see caught.nix). The packages are loaded
# that way and given a kix whose mergeGuarded, guardArgs and mergeEnv come
# from vocab/compose.nix loaded the same way, so a refusal renders its
# message into the manifests: the ConfigMap's vector.yaml becomes
# `{ "thrown": ... }`, a refused argument list becomes one `refused: ...`
# argument, and refused env becomes a `REFUSED` variable. Each refusal is
# also checked with evalFails against the unmodified packages.

{
  lib,
  eval,
  k8s,
  kixlib,
  kixKeys,
  mkCluster,
  manifests,
  ofKind,
  byName,
  evalFails,
  storageClassImport,
  ...
}:

let
  helpers = import ../caught.nix { inherit lib; };
  inherit (helpers) loadCaught;
  caught = helpers.caughtSentences;

  compose = caught ../../vocab/compose.nix { inherit lib; };
  renderingKix = {
    mergeGuarded = compose.mergeGuarded;
    guardArgs =
      args: extraArgs:
      let
        r = compose.guardArgs args extraArgs;
      in
      if builtins.isAttrs r then [ "refused: ${r.thrown}" ] else r;
    mergeEnv =
      args: env:
      let
        r = compose.mergeEnv args env;
      in
      if r ? thrown then { REFUSED = r.thrown; } else r;
  };
  # The package in `dir`, with its own throws and the three kix helpers
  # above rendering their messages. `scope.fail` still throws, so a cluster
  # that builds it with `rendered = true` uses `evalCaught`.
  rendering =
    dir:
    {
      scope,
      lib,
      kix,
    }:
    caught dir {
      inherit scope lib;
      kix = kix // renderingKix;
    };

  # The evaluator loaded so that `scope.fail` and `kix.fail` return
  # `{ thrown = ...; }` instead of throwing.
  evalCaught = loadCaught ../../eval {
    inherit lib k8s;
    self = ../../../..;
  };
  mkClusterCaught =
    modules:
    evalCaught.buildCluster {
      name = "test";
      inherit modules;
    };

  lokiLogsDir = ../../../packages/experimental/loki-logs;
  clickhouseLogsDir = ../../../packages/experimental/clickhouse-logs;
  lokiLogsPackage = import lokiLogsDir;
  clickhouseLogsPackage = import clickhouseLogsDir;
  pvcPackage = import ../../../packages/stable/persistent-volume-claim;
  secretPackage = import ../../../packages/stable/secret;

  # loki-logs in `logs` with a loki to ship to. `loki` replaces the loki
  # instance's package, `instance` is merged into loki-logs' instance, and
  # `extra` adds instances to the namespace.
  lokiLogsCluster =
    {
      package ? lokiLogsPackage,
      rendered ? false,
      config ? { },
      loki ? import ../../../packages/experimental/loki,
      instance ? { },
      extra ? { },
    }:
    (if rendered then mkClusterCaught else mkCluster) [
      {
        instances.logs = {
          loki.package = loki;
          storage = {
            package = pvcPackage;
            config = {
              size = "1Gi";
              storageClassName = "standard";
            };
          };
          standard-class = storageClassImport "standard";
          loki-logs = {
            inherit package config;
          }
          // instance;
        }
        // extra;
      }
    ];

  clickhouseLogsCluster =
    {
      package ? clickhouseLogsPackage,
      rendered ? false,
      config ? { },
    }:
    (if rendered then mkClusterCaught else mkCluster) [
      (
        { ref, ... }:
        {
          instances.chlogs = {
            clickhouse.package = import ../../../packages/experimental/clickhouse;
            storage = {
              package = pvcPackage;
              config = {
                size = "1Gi";
                storageClassName = "standard";
              };
            };
            standard-class = storageClassImport "standard";
            credentials = {
              package = secretPackage;
              aliases = [ "credentials" ];
              config.stringData.password = "password";
            };
            clickhouse-database = {
              package = import ../../../packages/experimental/clickhouse-database;
              deps.password = ref.chlogs.clickhouse-database-password;
            };
            clickhouse-database-password = {
              package = secretPackage;
              config = {
                source = ./log-agents.nix;
                keys = [ "password" ];
              };
            };
            clickhouse-logs = {
              inherit package config;
            };
          };
        }
      )
    ];

  vectorConfigOf =
    name: cluster:
    builtins.fromJSON
      (byName "${name}-config" (ofKind "ConfigMap" (manifests cluster))).data."vector.yaml";
  daemonSetOf = name: cluster: byName name (ofKind "DaemonSet" (manifests cluster));
  containerOf = name: cluster: builtins.head (daemonSetOf name cluster).spec.template.spec.containers;

  # The message `config` makes the package refuse, read from the rendering
  # package, or null when the rendering package accepts it.
  lokiLogsRefusal =
    config:
    let
      cluster = lokiLogsCluster {
        package = rendering lokiLogsDir;
        rendered = true;
        inherit config;
      };
      container = containerOf "loki-logs" cluster;
      settings = vectorConfigOf "loki-logs" cluster;
      refusedArg = lib.findFirst (lib.hasPrefix "refused: ") null container.args;
      refusedEnv = lib.findFirst (e: e.name == "REFUSED") null container.env;
    in
    if settings ? thrown then
      settings.thrown
    else if refusedArg != null then
      lib.removePrefix "refused: " refusedArg
    else if refusedEnv != null then
      refusedEnv.value
    else
      null;

  # True when `config` fails to build with the unmodified package and the
  # rendered refusal contains every fragment.
  lokiLogsRefuses =
    fragments: config:
    let
      message = lokiLogsRefusal config;
    in
    evalFails (lokiLogsCluster {
      inherit config;
    })
    && message != null
    && builtins.all (f: lib.hasInfix f message) fragments;

  clickhouseLogsRefuses =
    fragments: config:
    let
      settings = vectorConfigOf "clickhouse-logs" (clickhouseLogsCluster {
        package = rendering clickhouseLogsDir;
        rendered = true;
        inherit config;
      });
    in
    evalFails (clickhouseLogsCluster {
      inherit config;
    })
    && settings ? thrown
    && builtins.all (f: lib.hasInfix f settings.thrown) fragments;

  lokiWho = "loki-logs logs/loki-logs: ";
  lockedMessage =
    what: "${lokiWho}settings overrides ${what}, which the package sets for correctness.";
in
{
  # The default instance pushes to the loki instance's out.serviceUrl,
  # mounts its config where --config points, and names its ClusterRole and
  # read-position directory `<namespace>.<instance>`.
  log-agents-loki-logs-default =
    let
      cluster = lokiLogsCluster { };
      ms = manifests cluster;
      settings = vectorConfigOf "loki-logs" cluster;
      ds = daemonSetOf "loki-logs" cluster;
      container = builtins.head ds.spec.template.spec.containers;
      dataVolume = lib.findFirst (v: v.name == "data") null ds.spec.template.spec.volumes;
      configMount = lib.findFirst (
        m: lib.hasPrefix "/etc/vector" m.mountPath
      ) null container.volumeMounts;
    in
    (
      settings.sinks.loki.endpoint == cluster.instances.logs.loki.out.serviceUrl
      && settings.sources.kubernetes_logs.ignore_older_secs == 518400
      &&
        container.args == [
          "--config"
          "/etc/vector/vector.yaml"
        ]
      && configMount.mountPath == "/etc/vector"
      && dataVolume.hostPath.path == "/var/lib/vector/logs.loki-logs"
      && byName "logs.loki-logs" (ofKind "ClusterRole" ms) != null
      && !(ds.spec.template.spec ? priorityClassName)
      && ds.metadata.labels."app.kubernetes.io/name" or "loki-logs" == "loki-logs"
    )
    || throw "loki-logs default: ${builtins.toJSON { inherit settings container dataVolume; }}";

  # Each locked loki-logs settings path is refused, also when an ancestor
  # is replaced. The keys next to the locked leaves stay open.
  log-agents-loki-logs-locked-settings =
    let
      accepted = vectorConfigOf "loki-logs" (lokiLogsCluster {
        config.settings = {
          sinks.metrics.flush_period_secs = 30;
          sources.internal_metrics.scrape_interval_secs = 5;
          sinks.loki.labels.stream = null;
          sinks.loki.tenant_id = "a";
        };
      });
    in
    (
      lokiLogsRefuses [ (lockedMessage "sinks.loki.endpoint") ] {
        settings.sinks.loki.endpoint = "http://x:1";
      }
      && lokiLogsRefuses [ (lockedMessage "sinks.loki.type") ] {
        settings.sinks.loki.type = "http";
      }
      && lokiLogsRefuses [ (lockedMessage "sinks.metrics.address") ] {
        settings.sinks.metrics.address = "0.0.0.0:9000";
      }
      && lokiLogsRefuses [ (lockedMessage "sinks.metrics.inputs") ] {
        settings.sinks.metrics.inputs = [ ];
      }
      && lokiLogsRefuses [ (lockedMessage "data_dir") ] {
        settings.data_dir = "/tmp";
      }
      && lokiLogsRefuses [
        (lockedMessage "sources.internal_metrics.type (replaced by `sources.internal_metrics = null`)")
      ] { settings.sources.internal_metrics = null; }
      &&
        lokiLogsRefuses [ "${lokiWho}settings overrides sinks.loki.type (replaced by `sinks.loki = null`)" ]
          {
            settings.sinks.loki = null;
          }
      && accepted.sinks.metrics.flush_period_secs == 30
      && accepted.sources.internal_metrics.scrape_interval_secs == 5
      && accepted.sinks.loki.tenant_id == "a"
      && !(accepted.sinks.loki.labels ? stream)
    )
    || throw "loki-logs locked settings: ${
      builtins.toJSON {
        endpoint = lokiLogsRefusal { settings.sinks.loki.endpoint = "http://x:1"; };
        internalMetrics = lokiLogsRefusal { settings.sources.internal_metrics = null; };
        inherit accepted;
      }
    }";

  # `sinks = null` replaces every locked sink path, and the message lists
  # each of them.
  log-agents-loki-logs-sinks-null =
    let
      message = lokiLogsRefusal { settings.sinks = null; };
    in
    lokiLogsRefuses [
      "${lokiWho}settings overrides "
      "sinks.metrics.type (replaced by `sinks = null`)"
      "sinks.metrics.address (replaced by `sinks = null`)"
      "sinks.loki.endpoint (replaced by `sinks = null`)"
    ] { settings.sinks = null; }
    || throw "loki-logs sinks = null: ${builtins.toJSON message}";

  # Vector's config-source flags are refused, the one-letter form with an
  # attached value included; other flags are appended after --config.
  log-agents-loki-logs-extra-args =
    let
      threads =
        (containerOf "loki-logs" (lokiLogsCluster {
          config.extraArgs = [
            "--threads"
            "2"
          ];
        })).args;
    in
    (
      lokiLogsRefuses [ "${lokiWho}extraArgs sets \"--config-dir\", which this package does not accept" ]
        {
          extraArgs = [
            "--config-dir"
            "/x"
          ];
        }
      && lokiLogsRefuses [ "${lokiWho}extraArgs sets \"-c=/x\", which this package does not accept" ] {
        extraArgs = [ "-c=/x" ];
      }
      && lokiLogsRefuses [ "${lokiWho}extraArgs sets \"-c/x\", which this package does not accept" ] {
        extraArgs = [ "-c/x" ];
      }
      &&
        threads == [
          "--config"
          "/etc/vector/vector.yaml"
          "--threads"
          "2"
        ]
    )
    || throw "loki-logs extraArgs: ${
      builtins.toJSON {
        dir = lokiLogsRefusal {
          extraArgs = [
            "--config-dir"
            "/x"
          ];
        };
        inherit threads;
      }
    }";

  # The node name and the config-source variables are the package's; other
  # variables pass through.
  log-agents-loki-logs-env =
    let
      env =
        (containerOf "loki-logs" (lokiLogsCluster {
          config.env.VECTOR_LOG = "debug";
        })).env;
    in
    (
      lokiLogsRefuses [
        "${lokiWho}env sets VECTOR_CONFIG_DIR, which comes from the package's settings, Vector's only config source. Put configuration in settings."
      ] { env.VECTOR_CONFIG_DIR = "/x"; }
      && lokiLogsRefuses [ "${lokiWho}env sets VECTOR_SELF_NODE_NAME, which comes from the pod's node" ] {
        env.VECTOR_SELF_NODE_NAME = "x";
      }
      && builtins.any (e: e.name == "VECTOR_LOG" && e.value == "debug") env
    )
    || throw "loki-logs env: ${
      builtins.toJSON {
        configDir = lokiLogsRefusal { env.VECTOR_CONFIG_DIR = "/x"; };
        inherit env;
      }
    }";

  # A loki dependency without out.serviceUrl has no push address, and the
  # package says so instead of rendering an empty endpoint.
  log-agents-loki-logs-loki-without-service-url =
    let
      loki = eval.mkImport { out.fqdn = "loki.example"; };
      message =
        (vectorConfigOf "loki-logs" (lokiLogsCluster {
          package = rendering lokiLogsDir;
          rendered = true;
          inherit loki;
        })).sinks.loki.endpoint.thrown or null;
    in
    (
      evalFails (lokiLogsCluster {
        inherit loki;
      })
      && message != null
      && lib.hasInfix "deps.loki resolved to an instance with no out.serviceUrl" message
      && lib.hasInfix "Point deps.loki at a loki instance." message
    )
    || throw "loki-logs deps.loki guard: ${builtins.toJSON message}";

  # A priority-class dependency names the pods' class and adds the
  # PriorityClass to the DaemonSet's depends-on annotation.
  log-agents-loki-logs-priority-class =
    let
      ship = {
        package = import ../../../packages/stable/priority-class;
        config.value = 1000;
      };
      dependsOn =
        cluster:
        lib.filter (s: s != "") (
          lib.splitString "," (
            ((daemonSetOf "loki-logs" cluster).metadata.annotations or { }).${kixKeys.dependsOn} or ""
          )
        );
      unwired = lokiLogsCluster { extra.ship = ship; };
      wired = mkCluster [
        (
          { ref, ... }:
          {
            instances.logs = {
              loki.package = import ../../../packages/experimental/loki;
              storage = {
                package = pvcPackage;
                config = {
                  size = "1Gi";
                  storageClassName = "standard";
                };
              };
              standard-class = storageClassImport "standard";
              inherit ship;
              loki-logs = {
                package = lokiLogsPackage;
                deps.priorityClass = ref.logs.ship;
              };
            };
          }
        )
      ];
      added = lib.subtractLists (dependsOn unwired) (dependsOn wired);
    in
    (
      (daemonSetOf "loki-logs" wired).spec.template.spec.priorityClassName == "ship"
      && !((daemonSetOf "loki-logs" unwired).spec.template.spec ? priorityClassName)
      && builtins.length added == 1
    )
    || throw "loki-logs priorityClass: ${
      builtins.toJSON {
        unwired = dependsOn unwired;
        wired = dependsOn wired;
      }
    }";

  # The monitoring module refuses lokiLogs without its Loki. The message is
  # read from the module loaded through `caught`. With the real module the
  # build fails, and builds once lokiLogs is off too.
  log-agents-monitoring-loki-logs-without-loki =
    let
      # Grafana is off because its claim needs a StorageClass this cluster
      # does not have.
      monitoring = {
        enabled = true;
        grafana.enabled = false;
        loki.enabled = false;
        lokiLogs.enabled = true;
      };
      module = caught ../../../modules/experimental/monitoring.nix {
        inherit lib;
        kix = { };
        packages = { };
        ref = { };
        config.monitoring = monitoring // {
          namespace = "monitoring-system";
        };
      };
      message = module.config.content.instances.monitoring-system.loki-logs.content.deps.loki.thrown;
      packages = import ../../../packages { inherit lib; };
      withModule =
        monitoring:
        mkCluster [
          ../../../modules/experimental/monitoring.nix
          {
            _module.args.packages = packages;
            inherit monitoring;
          }
        ];
    in
    (
      message
      == "monitoring.lokiLogs.enabled is true but monitoring.loki.enabled is false, so there is no Loki to ship to. Enable monitoring.loki, or turn lokiLogs off and declare a loki-logs instance with deps.loki pointing at your Loki."
      && evalFails (withModule monitoring)
      && !evalFails (withModule (monitoring // { lokiLogs.enabled = false; }))
    )
    || throw "monitoring lokiLogs without loki: ${builtins.toJSON message}";

  # clickhouse-logs' own locked paths, on top of the shared ones; its batch
  # settings stay open.
  log-agents-clickhouse-logs-locked-settings =
    let
      who = "clickhouse-logs chlogs/clickhouse-logs: settings overrides ";
      accepted = vectorConfigOf "clickhouse-logs" (clickhouseLogsCluster {
        config.settings.sinks.clickhouse.batch.timeout_secs = 7;
      });
    in
    (
      clickhouseLogsRefuses [ "${who}sinks.clickhouse.endpoint," ] {
        settings.sinks.clickhouse.endpoint = "http://x:1";
      }
      && clickhouseLogsRefuses [ "${who}sinks.clickhouse.table," ] {
        settings.sinks.clickhouse.table = "t";
      }
      && clickhouseLogsRefuses [ "${who}sinks.clickhouse.auth," ] {
        settings.sinks.clickhouse.auth.password = "p";
      }
      && clickhouseLogsRefuses [ "${who}sinks.clickhouse.database," ] {
        settings.sinks.clickhouse.database = "d";
      }
      && clickhouseLogsRefuses [ "${who}secret.credentials," ] {
        settings.secret.credentials.path = "/x";
      }
      && clickhouseLogsRefuses [ "${who}sinks.metrics.address," ] {
        settings.sinks.metrics.address = "0.0.0.0:1";
      }
      && accepted.sinks.clickhouse.batch.timeout_secs == 7
    )
    || throw "clickhouse-logs locked settings: ${builtins.toJSON accepted.sinks.clickhouse}";

  # The clickhouseDatabase check names the privileges the resolved user has
  # and the one to add; the lib prefixes the instance.
  log-agents-clickhouse-logs-insert-privilege =
    let
      package = clickhouseLogsPackage {
        inherit lib;
        scope = {
          instanceName = "clickhouse-logs";
          namespaceName = "chlogs";
        };
        kix = kixlib;
      };
      messagesFor =
        privileges:
        map (a: a.message) (package.deps.clickhouseDatabase.assertions { out = { inherit privileges; }; });
    in
    (
      messagesFor [ "INSERT" ] == [ ]
      && messagesFor [ "ALL" ] == [ ]
      &&
        messagesFor [ "SELECT" ] == [
          "deps.clickhouseDatabase resolved to a clickhouse-database instance whose user has only SELECT, and the agent inserts rows. Add \"INSERT\" to that instance's privileges."
        ]
      &&
        messagesFor [ ] == [
          "deps.clickhouseDatabase resolved to a clickhouse-database instance whose user has no privileges, and the agent inserts rows. Add \"INSERT\" to that instance's privileges."
        ]
    )
    || throw "clickhouse-logs privileges: ${builtins.toJSON (messagesFor [ "SELECT" ])}";

  # A one-letter owned flag also refuses its attached-value form; a long
  # flag that starts with the same letter, and the other letter case, pass.
  log-agents-guard-args-short-flags =
    let
      guard = compose.guardArgs {
        who = "pkg ns/inst";
        owned."-c" = "remove it.";
      };
      passes =
        args:
        kixlib.guardArgs {
          who = "pkg ns/inst";
          owned."-c" = "remove it.";
        } args == args;
    in
    (
      guard [ "-c/etc/x" ] == {
        thrown = "pkg ns/inst: extraArgs sets \"-c/etc/x\", which this package does not accept: remove it.";
      }
      && builtins.isAttrs (guard [ "-c" ])
      && builtins.isAttrs (guard [ "-c=/x" ])
      && passes [ "--cache" ]
      && passes [ "-C/x" ]
      && passes [ "-v" ]
    )
    || throw "guardArgs short flags: ${builtins.toJSON (guard [ "-c/etc/x" ])}";
}
