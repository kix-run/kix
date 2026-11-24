# Tests for the valkey package and the kix/lib behaviour it relies on: an
# import of a package whose `build` is a list, resolution errors that name
# the instance asking for the dependency, the package's checks on its
# config maps and options, and the rendered valkey.conf.

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
  valkeyPackage = import ../../../packages/stable/valkey;
  secretPackage = import ../../../packages/stable/secret;
  conf = import ../../../packages/stable/valkey/conf.nix {
    inherit lib;
    kix = kixlib;
  };

  # The package's top-level attributes. `options` and `assertions` read no
  # instance scope.
  valkeyAttrs = valkeyPackage {
    scope = {
      instanceName = "valkey";
      namespaceName = "cache";
    };
    inherit lib;
    kix = kixlib;
    availability = "none";
  };

  # A cluster with valkey in `cache` and a secret aliased valkeyPassword
  # that holds `secretData`.
  valkeyCluster =
    {
      config ? { },
      secretData ? {
        password = "pw";
      },
    }:
    mkCluster [
      {
        instances.cache = {
          valkey-password = {
            package = secretPackage;
            aliases = [ "valkeyPassword" ];
            config.stringData = secretData;
          };
          valkey = {
            package = valkeyPackage;
            inherit config;
          };
        };
      }
    ];

  valkeyConfOf =
    cluster: (byName "valkey-config" (ofKind "ConfigMap" (manifests cluster))).data."valkey.conf";

  # A package shaped like valkey: a main build entry with a Deployment and
  # its Service, and a kix.monitor entry.
  listBuildPackage =
    { scope, kix, ... }:
    {
      meta.version = "test";
      options.metrics = kix.options.monitor;
      build = [
        (
          { self, scope, ... }:
          {
            deployment = scope.mkDeployment {
              name = "cache";
              spec = {
                replicas = 1;
                selector.matchLabels = scope.selectorLabels;
                template = {
                  metadata.labels = scope.selectorLabels;
                  spec.containers = [
                    {
                      name = "cache";
                      image = "cache:1";
                      ports = [
                        {
                          name = "tcp";
                          containerPort = 6379;
                        }
                      ];
                    }
                  ];
                };
              };
            };
            service = self.deployment |> kix.service.fromWorkload { name = "cache"; } |> scope.mkResource;
            root = self.service;
          }
        )
        (kix.monitor { service = "service"; })
      ];
    };

  # Writes the address of its `cache` dependency into a ConfigMap.
  cacheConsumer = {
    meta.version = "test";
    build =
      {
        self,
        scope,
        cache,
        ...
      }:
      {
        cm = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "cache-consumer";
          extra.data = {
            host = cache.out.fqdn;
            port = cache.out.port;
          };
        };
        root = self.cm;
      };
  };

  # Requires `secretValue`, which nothing in the cluster provides.
  secretConsumer = {
    meta = {
      version = "test";
      defaultAliases = [ "cache" ];
    };
    build =
      {
        self,
        scope,
        secretValue,
        ...
      }:
      {
        cm = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "secret-consumer";
        };
        root = self.cm;
      };
  };
in
{
  # `kix.mkImport { from = listBuildPackage; }` runs both build entries; a
  # consumer reads the imported Service's fqdn and port.
  valkey-import-list-build =
    let
      cluster = mkCluster [
        {
          instances.cache.cache.package = eval.mkImport { from = listBuildPackage; };
          instances.app.consumer.package = cacheConsumer;
        }
      ];
      cm = byName "cache-consumer" (ofKind "ConfigMap" (manifests cluster));
      data = if cm == null then { } else cm.data;
    in
    (data.host or null == "cache.cache.svc.cluster.local" && data.port or null == "6379")
    || throw "import of a list build: consumer data ${builtins.toJSON data}";

  # A missing dependency fails the build for a declared requester and for
  # one that auto-instantiation added. tryEval drops the message, so
  # lib-eval-messages checks its text through resolveArg.
  valkey-missing-dep-fails-declared-and-added =
    let
      direct = mkCluster [ { instances.app.cache.package = secretConsumer; } ];
      auto = mkCluster [
        {
          availablePackages.cache.package = secretConsumer;
          instances.app.consumer.package = cacheConsumer;
        }
      ];
    in
    (evalFails direct && evalFails auto) || throw "a missing dependency evaluated";

  # Each refused directive gets one error that names the option and the
  # directive's path; an ordinary directive passes.
  valkey-reserved-directives =
    let
      settingsOf = conf.refusals "settings" (conf.reservedSettings 6379);
      primaryOf = conf.refusals "sentinel.primarySettings" conf.reservedPrimarySettings;
      got = {
        port = settingsOf { port = 1; };
        PORT = settingsOf { PORT = 1; };
        bind = settingsOf { bind = "127.0.0.1"; };
        masteruser = settingsOf { masteruser = "x"; };
        rename = settingsOf { rename-command = "PING \"\""; };
        upper = settingsOf { Appendonly = "no"; };
        notName = settingsOf { "appendonly yes\nport" = "7000"; };
        monitor = primaryOf { monitor = "x"; };
        primaryRename = primaryOf { rename-command = "x"; };
        ordinary = settingsOf {
          maxmemory-policy = "allkeys-lru";
          save = [ "900 1" ];
        };
      };
      says =
        phrase: errors: builtins.length errors == 1 && lib.hasInfix phrase (builtins.head errors).message;
    in
    (
      says "settings.port cannot be set here because the Services and probes use port 6379." got.port
      && (builtins.head got.port).fix == "Remove `port` from `settings`."
      && (builtins.head got.port).option == "settings"
      && (builtins.head got.monitor).option == "sentinel.primarySettings"
      && says "settings.PORT cannot be set here" got.PORT
      && says "settings.bind cannot be set here" got.bind
      && says "settings.masteruser cannot be set here because replicas authenticate" got.masteruser
      && says "settings.rename-command cannot be set here" got.rename
      && says "settings.Appendonly must be lowercase" got.upper
      && (builtins.head got.upper).fix == "Rename `Appendonly` to `appendonly` in `settings`."
      && says ''settings."appendonly yes\nport" is not a valid Valkey directive name'' got.notName
      && says "sentinel.primarySettings.monitor cannot be set here" got.monitor
      && says "sentinel.primarySettings.rename-command cannot be set here" got.primaryRename
      && got.ordinary == [ ]
    )
    || throw "valkey refusals: ${builtins.toJSON got}";

  # A string value with a line break would write a second directive, so
  # the option types refuse it in both maps.
  valkey-settings-line-breaks =
    let
      valueOf =
        option: def:
        (lib.evalModules {
          modules = [
            { options.v = option; }
            { v = def; }
          ];
        }).config.v;
      accepts = option: def: (builtins.tryEval (builtins.deepSeq (valueOf option def) true)).success;
      settings = valkeyAttrs.options.settings;
      primarySettings = valkeyAttrs.options.sentinel.primarySettings;
      results = {
        plain = accepts settings { appendonly = "yes"; };
        list = accepts settings { save = [ "900 1" ]; };
        newline = accepts settings { appendonly = "yes\nport 7000"; };
        listNewline = accepts settings { save = [ "900 1\nport 7000" ]; };
        carriageReturn = accepts settings { appendonly = "yes\rport 7000"; };
        primaryNewline = accepts primarySettings { failover-timeout = "1\nmonitor x"; };
        primaryInt = accepts primarySettings { failover-timeout = 20000; };
      };
    in
    results == {
      plain = true;
      list = true;
      newline = false;
      listNewline = false;
      carriageReturn = false;
      primaryNewline = false;
      primaryInt = true;
    }
    || throw "valkey line breaks: ${builtins.toJSON results}";

  # The three topology assertions fail with their messages and fixes; the
  # default shapes pass.
  valkey-assertions =
    let
      failing =
        sentinel: replicas: quorum:
        map (a: a.message) (
          builtins.filter (a: !a.assertion) (
            valkeyAttrs.assertions {
              config = {
                inherit replicas;
                sentinel = {
                  enabled = sentinel;
                  inherit quorum;
                };
              };
            }
          )
        );
      standaloneTwo = failing false 2 2;
      sentinelTwo = failing true 2 1;
      quorumAll = failing true 3 3;
    in
    (
      failing false 1 2 == [ ]
      && failing true 3 2 == [ ]
      &&
        standaloneTwo == [
          "replicas is 2 with sentinel.enabled = false; standalone Valkey runs one pod. Set replicas = 1, or sentinel.enabled = true for a primary with replicas and failover."
        ]
      &&
        sentinelTwo == [
          "replicas is 2 with Sentinel on; a failover needs a quorum of Sentinels after the primary's pod is lost, which takes at least 3 pods. Set replicas = 3 or more, or sentinel.enabled = false for one standalone pod."
        ]
      && builtins.length quorumAll == 1
      && lib.hasInfix "Set sentinel.quorum to at most 2, or raise replicas." (builtins.head quorumAll)
    )
    || throw "valkey assertions: ${builtins.toJSON { inherit standaloneTwo sentinelTwo quorumAll; }}";

  # The built-in maxmemory is 70% of the memory limit and absent without
  # one; the rendered valkey.conf carries it. A secret without the
  # `password` key fails the build.
  valkey-maxmemory-and-password-key =
    let
      defaultConf = valkeyConfOf (valkeyCluster { });
      noLimitConf = valkeyConfOf (valkeyCluster {
        config.resources.limits.memory = null;
      });
    in
    (
      conf.maxmemoryFor "512Mi" == "375809638"
      && conf.maxmemoryFor "1Gi" == "751619276"
      && conf.maxmemoryFor null == null
      && defaultConf == "appendonly yes\nmaxmemory 375809638\n"
      && noLimitConf == "appendonly yes\n"
      && evalFails (valkeyCluster {
        secretData.pass = "pw";
      })
    )
    || throw "valkey maxmemory: default ${builtins.toJSON defaultConf}, no limit ${builtins.toJSON noLimitConf}";
}
