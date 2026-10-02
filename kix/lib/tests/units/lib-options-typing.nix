# Tests for the typed option helpers (vocab/quantity.nix, the option and
# guard helpers in vocab/compose.nix), the option contract walker
# (eval/options.nix), instance-config error locations (eval/resolve.nix),
# and the options the sweep retyped in the monitoring packages and module.
# Loaded by ../default.nix with the other files in this directory.

{
  lib,
  eval,
  kixlib,
  mkCluster,
  manifests,
  storageClassImport,
  ...
}:

let
  throws = v: !(builtins.tryEval (builtins.deepSeq v v)).success;
  evalFails' = ms: throws ms;

  # The value of one option `o` after the module system merges `defs`.
  optionValue =
    o: defs:
    (lib.evalModules {
      modules = [ { options.o = o; } ] ++ map (d: { config.o = d; }) defs;
    }).config.o;

  pkg = name: import (../../../packages + "/${name}");

  # The VictoriaMetrics operator plus one instance of `package` in
  # monitoring-system, with `config`.
  vmCluster =
    instances:
    manifests (mkCluster [
      {
        instances.monitoring-system = {
          vm-operator.package = pkg "victoria-metrics-operator";
          vm-cluster.package = pkg "victoria-metrics-cluster";
        }
        // instances;
      }
    ]);
  vmSpec = kind: ms: (lib.findFirst (m: m.kind == kind) { spec = null; } ms).spec;

  resourcesOption = kixlib.options.resources {
    requests = {
      cpu = "100m";
      memory = "128Mi";
    };
    limits.memory = "256Mi";
  };

  # A Deployment whose container takes `config.resources` as is.
  resourcesPackage = {
    meta.version = "test";
    options.resources = kixlib.options.resources {
      requests = {
        cpu = "100m";
        memory = "128Mi";
      };
    };
    build =
      {
        self,
        scope,
        config,
        ...
      }:
      {
        root = self.deployment;
        deployment = scope.mkDeployment {
          name = "web";
          spec = {
            replicas = 1;
            selector.matchLabels = scope.selectorLabels;
            template = {
              metadata.labels = scope.selectorLabels;
              spec.containers = [
                {
                  name = "web";
                  image = "example/web:1";
                  inherit (config) resources;
                }
              ];
            };
          };
        };
      };
  };

  secretDep = keys: {
    out = {
      name = "creds";
      inherit keys;
    };
  };

  violations = options: eval.optionContractViolations { inherit options; };

  messagesMention = needle: vs: vs != [ ] && builtins.all (v: lib.hasInfix needle v.message) vs;

  t = lib.types;
in
{
  # parse and the type share one grammar: every value the type accepts
  # parses to a number, so the limits-versus-requests check never skips it.
  lib-options-typing-quantity-parse =
    let
      samples = [
        "1.5Gi"
        "500k"
        ".5"
        "250m"
        "0"
        "1"
        64
        "007Mi"
        "1.05"
        "2Ei"
        "1E"
        "128mb"
        "1gi"
        "1K"
        "1e3"
        "-1"
        "1."
        "m"
      ];
      accepted = builtins.filter kixlib.types.quantity.check samples;
      unparsed = builtins.filter (q: kixlib.parseQuantity "memory" q == null) accepted;
      results = {
        a = kixlib.parseQuantity "memory" "1.5Gi";
        b = kixlib.parseQuantity "memory" "500k";
        c = kixlib.parseQuantity "cpu" ".5";
        d = kixlib.parseQuantity "cpu" "250m";
        e = kixlib.parseQuantity "cpu" "1.05";
        f = kixlib.parseQuantity "memory" "1K";
      };
    in
    (
      unparsed == [ ]
      &&
        results == {
          a = 1610612736;
          b = 500000;
          c = 500;
          d = 250;
          e = 1050;
          f = null;
        }
      && builtins.all (q: !(kixlib.types.quantity.check q)) [
        "128mb"
        "1gi"
        "1K"
        "1e3"
        "-1"
        "1."
        "8Ei"
        "1234567890123456789"
      ]
    )
    || throw "quantity: unparsed=${builtins.toJSON unparsed} results=${builtins.toJSON results}";

  # Results stay integers: a value past the signed 64-bit range, or with
  # more than 18 digits, throws instead of becoming a float.
  lib-options-typing-quantity-exact-range =
    let
      throws = v: !(builtins.tryEval (builtins.deepSeq v true)).success;
      ei = kixlib.parseQuantity "memory" "7Ei";
    in
    (
      ei == 7 * 1024 * 1024 * 1024 * 1024 * 1024 * 1024
      && builtins.isInt ei
      && kixlib.parseQuantity "cpu" "9223372036854775m" == 9223372036854775
      && throws (kixlib.parseQuantity "memory" "8Ei")
      && throws (kixlib.parseQuantity "cpu" "2Ei")
      && throws (kixlib.parseQuantity "cpu" "9223372036854776")
      && throws (kixlib.parseQuantity "memory" "0.0000000000000000001")
      && throws (kixlib.parseQuantity "memory" "1234567890123456789")
    )
    || throw "quantity range: 7Ei = ${builtins.toJSON ei}";

  # Setting one leaf keeps the other defaults; null removes a default and
  # leaves no empty `limits` and no null `claims`.
  lib-options-typing-resources-keep-siblings =
    let
      one = optionValue resourcesOption [ { limits.cpu = "1"; } ];
      cleared = optionValue resourcesOption [ { limits.memory = null; } ];
    in
    (
      one == {
        requests = {
          cpu = "100m";
          memory = "128Mi";
        };
        limits = {
          cpu = "1";
          memory = "256Mi";
        };
      }
      &&
        cleared == {
          requests = {
            cpu = "100m";
            memory = "128Mi";
          };
        }
    )
    || throw "resources: one=${builtins.toJSON one} cleared=${builtins.toJSON cleared}";

  lib-options-typing-resources-names =
    let
      extended = optionValue resourcesOption [
        {
          limits."nvidia.com/gpu" = "1";
          limits.hugepages-2Mi = "1Gi";
        }
      ];
    in
    (
      extended.limits ? "nvidia.com/gpu"
      && extended.limits ? hugepages-2Mi
      && throws (optionValue resourcesOption [ { limits.memroy = "1Gi"; } ])
      && builtins.all (q: throws (optionValue resourcesOption [ { limits.memory = q; } ])) [
        "128mb"
        "1gi"
        "1K"
      ]
      && throws (kixlib.options.resources { requests.gpu = "1"; })
    )
    || throw "resources names: ${builtins.toJSON extended}";

  # The rendered container carries exactly the fields the instance left
  # set, so the scorecard sees a missing CPU limit.
  lib-options-typing-resources-scorecard-sees-missing-limit =
    let
      cluster = mkCluster [
        {
          scorecard = {
            enable = true;
            rules.reliability = import ../../rules/reliability.nix { inherit lib; };
          };
          instances.appns.web = {
            package = resourcesPackage;
            config.resources.limits.memory = "1Gi";
          };
        }
      ];
      findings = builtins.filter (f: lib.hasSuffix "boundedResources" (f.rule or "")) (
        (cluster.scorecardReport or { findings = [ ]; }).findings
      );
      message = (builtins.head findings).message;
    in
    (builtins.length findings == 1 && lib.hasInfix "missing resource settings: limits.cpu." message)
    || throw "boundedResources findings: ${builtins.toJSON findings}";

  lib-options-typing-env-type =
    let
      env = kixlib.options.env;
      cfg = eval.evaluateInstanceConfig {
        packageOptions.env = env;
        packageConfig.env.FOO = lib.mkDefault "x";
        instCfg.config.imports = [ { env.FOO = null; } ];
      };
    in
    (
      throws (optionValue env [ { PORT = 8080; } ])
      && throws (
        optionValue env [
          { P = "x"; }
          { P = "y"; }
        ]
      )
      && kixlib.mkEnvVars cfg.env == [ ]
      &&
        optionValue env [ { F.valueFrom.fieldRef.fieldPath = "metadata.name"; } ] == {
          F.valueFrom.fieldRef.fieldPath = "metadata.name";
        }
    )
    || throw "env: ${builtins.toJSON cfg.env}";

  lib-options-typing-merge-env =
    let
      merge = kixlib.mergeEnv {
        who = "pkg ns/inst";
        defaults.LOG = "info";
        owned = [
          {
            vars.DB_HOST = "db";
            from = "the database dependency";
            fix = "Remove it.";
          }
          {
            names = [ "API_KEY" ];
            from = "the apiKey dependency";
            fix = "Remove it.";
          }
        ];
      };
    in
    (
      merge { LOG = "debug"; } == {
        LOG = "debug";
        DB_HOST = "db";
      }
      && throws (merge {
        DB_HOST = "x";
      })
      && throws (merge {
        DB_HOST = null;
      })
      && throws (merge {
        API_KEY = "k";
      })
    )
    || throw "mergeEnv: ${builtins.toJSON (merge { })}";

  lib-options-typing-guard-args =
    let
      guard = kixlib.guardArgs {
        who = "pkg ns/inst";
        owned."--ingress-class" = "remove it.";
      };
    in
    (
      guard [ "--ingress-class-by-name=true" ] == [ "--ingress-class-by-name=true" ]
      && throws (guard [ "--ingress-class=x" ])
      && throws (guard [ "--ingress-class" ])
      && throws (guard [
        "--ingress-class=x"
        "--ingress-class"
      ])
    )
    || throw "guardArgs passed or refused the wrong arguments";

  lib-options-typing-check-secret-keys =
    let
      check =
        args:
        kixlib.checkSecretKeys (
          {
            who = "pkg ns/inst";
            arg = "creds";
          }
          // args
        );
      both = secretDep [
        "a"
        "b"
      ];
      groups = [
        [ "t" ]
        [
          "id"
          "key"
        ]
      ];
    in
    (
      check {
        dep = both;
        keys = [
          "a"
          "b"
        ];
      } == both
      && throws (check {
        dep = secretDep [ "a" ];
        keys = [
          "a"
          "b"
        ];
      })
      &&
        check {
          dep = secretDep [
            "id"
            "key"
          ];
          anyOf = groups;
        } != null
      && throws (check {
        dep = secretDep [ "id" ];
        anyOf = groups;
      })
      && throws (check {
        dep = secretDep null;
        keys = [ "a" ];
      })
      &&
        check {
          dep = null;
          keys = [ "a" ];
        } == null
    )
    || throw "checkSecretKeys passed or refused the wrong secrets";

  lib-options-typing-contract-rule1 =
    let
      vs = violations {
        hpa = lib.mkOption {
          type = t.anything;
          default.maxReplicas = 3;
        };
        a.b = lib.mkOption {
          type = t.attrsOf t.anything;
          default.x = 1;
        };
      };
    in
    (
      map (v: lib.concatStringsSep "." v.path) vs == [
        "a.b"
        "hpa"
      ]
      &&
        map (v: v.head) vs == [
          "a"
          "hpa"
        ]
      && messagesMention "kix.options.resources" vs
      && lib.hasInfix "option `a.b` has type" (builtins.head vs).message
    )
    || throw "rule 1: ${builtins.toJSON vs}";

  lib-options-typing-contract-rule2 =
    let
      vs = violations {
        selector = lib.mkOption {
          type = t.attrsOf t.str;
          default.app = "x";
        };
        sub = lib.mkOption {
          type = t.submodule {
            options.labels = lib.mkOption {
              type = t.attrsOf t.str;
              default.team = "y";
            };
          };
          default = { };
        };
      };
    in
    (
      map (v: lib.concatStringsSep "." v.path) vs == [
        "selector"
        "sub.labels"
      ]
      && messagesMention "lib.mkDefault" vs
    )
    || throw "rule 2: ${builtins.toJSON vs}";

  lib-options-typing-contract-rule3 =
    let
      sizeField = {
        options.size = lib.mkOption {
          type = t.nullOr t.str;
          default = null;
        };
      };
      vs = violations {
        persistence = lib.mkOption {
          type = t.submodule sizeField;
          default.size = "1Gi";
        };
        maybe = lib.mkOption {
          type = t.nullOr (t.submodule sizeField);
          default.size = "1Gi";
        };
        noDefault = lib.mkOption {
          type = t.submodule { options.x = lib.mkOption { type = t.str; }; };
          default.x = "a";
        };
        free = lib.mkOption {
          type = t.submodule { freeformType = t.attrsOf t.str; };
          default.provider = "aws";
        };
      };
      byPath = lib.listToAttrs (
        map (v: {
          name = lib.concatStringsSep "." v.path;
          value = v.message;
        }) vs
      );
    in
    (
      builtins.length vs == 4
      && lib.hasInfix "has the default null" byPath.persistence
      && lib.hasInfix "has the default null" byPath.maybe
      && lib.hasInfix "has no default" byPath.noDefault
      && lib.hasInfix "is not a declared field" byPath.free
    )
    || throw "rule 3: ${builtins.toJSON vs}";

  lib-options-typing-contract-passes =
    let
      vs = violations {
        image = kixlib.options.image {
          repository = "docker.io/library/nginx";
          tag = "1.27";
        };
        resources = kixlib.options.resources { requests.cpu = "1"; };
        env = kixlib.options.env;
        empty = lib.mkOption {
          type = t.anything;
          default = { };
        };
        none = lib.mkOption {
          type = t.nullOr t.anything;
          default = null;
        };
        list = lib.mkOption {
          type = t.listOf t.anything;
          default = [ { a = 1; } ];
        };
      };
    in
    vs == [ ] || throw "expected no violations: ${builtins.toJSON vs}";

  lib-options-typing-check-throws =
    throws (
      eval.checkOptionContract {
        who = "ns/inst";
        options.x = lib.mkOption {
          type = t.anything;
          default.a = 1;
        };
      }
    )
    &&
      eval.checkOptionContract {
        who = "ns/inst";
        options = { };
      } == null;

  # With the instance's names, an option's location is
  # `instances.<ns>.<instance>.config.<option>`, and each definition names
  # the file that set it or the dependency that injected it. The probe
  # type's merge returns what the module system passes it.
  lib-options-typing-instance-option-location =
    let
      probeType = lib.mkOptionType {
        name = "probe";
        merge = loc: defs: {
          loc = lib.showOption loc;
          files = map (d: d.file) defs;
        };
      };
      cfg = eval.evaluateInstanceConfig {
        namespaceName = "echo";
        instanceName = "echo-server";
        packageOptions.probe = lib.mkOption { type = probeType; };
        instCfg.config.imports = [
          {
            _file = "cluster.nix";
            imports = [ { probe = "x"; } ];
          }
        ];
        configInjections = [
          {
            source = "web/app";
            config.probe = "y";
          }
        ];
      };
    in
    (
      cfg.probe.loc == "instances.echo.echo-server.config.probe"
      && builtins.elem "cluster.nix" cfg.probe.files
      && builtins.elem "config injected into echo/echo-server by web/app" cfg.probe.files
    )
    || throw "instance option location: ${builtins.toJSON cfg.probe}";

  # vm-cluster derives -dedup.minScrapeInterval from scrapeInterval and the
  # claim class from vmstorage.storageClassName; the escape hatches that
  # reach the same fields are refused.
  lib-options-typing-vm-cluster-owned-fields =
    let
      withConfig =
        config:
        vmCluster {
          vm-cluster.package = pkg "victoria-metrics-cluster";
          vm-cluster.config = config;
        };
      spec = vmSpec "VMCluster" (withConfig {
        vmstorage.storageClassName = "fast";
        vmstorage.storage.resources.requests.storage = "50Gi";
      });
    in
    (
      spec.vmstorage.storage.volumeClaimTemplate.spec == {
        resources.requests.storage = "50Gi";
        storageClassName = "fast";
      }
      && spec.vmselect.extraArgs."dedup.minScrapeInterval" == "30s"
      && evalFails' (withConfig {
        vmselect.extraArgs."dedup.minScrapeInterval" = "1m";
      })
      && evalFails' (withConfig {
        vmstorage.storage.storageClassName = "fast";
      })
    )
    || throw "vm-cluster owned fields: ${builtins.toJSON spec.vmstorage}";

  # vm-agent keeps its own flag beside an instance flag, and refuses an
  # extraSpec that replaces the remote-write target the vmCluster
  # dependency gives it.
  lib-options-typing-vm-agent-args =
    let
      agent =
        config:
        vmCluster {
          vm-agent = {
            package = pkg "victoria-metrics-agent";
            inherit config;
          };
        };
      spec = vmSpec "VMAgent" (agent {
        extraArgs."promscrape.maxScrapeSize" = "32MiB";
      });
    in
    (
      spec.extraArgs == {
        "promscrape.streamParse" = "true";
        "promscrape.maxScrapeSize" = "32MiB";
      }
      && evalFails' (agent {
        extraSpec.remoteWrite = [ { url = "http://elsewhere"; } ];
      })
      && evalFails' (agent {
        extraSpec.scrapeInterval = "10s";
      })
    )
    || throw "vm-agent extraArgs: ${builtins.toJSON spec.extraArgs}";

  # vm-alert renders the shared default Alertmanager settings when none are
  # set, and refuses an extraSpec that replaces its datasource.
  lib-options-typing-vm-alert-settings =
    let
      alert =
        config:
        vmCluster {
          vm-alert = {
            package = pkg "victoria-metrics-alert";
            inherit config;
          };
        };
      secret = lib.findFirst (
        m: m.kind == "Secret" && lib.hasSuffix "-alertmanager-config" m.metadata.name
      ) null (alert { });
      settings = builtins.fromJSON secret.stringData."alertmanager.yaml";
    in
    (
      settings == import ../../../packages/alertmanager/default-settings.nix
      && evalFails' (alert {
        extraSpec.datasource.url = "http://elsewhere";
      })
    )
    || throw "vm-alert settings: ${builtins.toJSON settings}";

  # A selector an instance sets replaces the package's default selector as
  # a whole. The stub DaemonSet gives the selector a pod to match.
  lib-options-typing-default-rules-selector-replaces =
    let
      proxyPackage = {
        meta.version = "test";
        build =
          { self, scope, ... }:
          {
            root = self.daemonset;
            daemonset = scope.mkDaemonSet {
              name = "proxy";
              spec = {
                selector.matchLabels.component = "proxy";
                template.spec.containers = [
                  {
                    name = "proxy";
                    image = "registry.example/proxy:1";
                  }
                ];
              };
            };
          };
      };
      ms = manifests (mkCluster [
        {
          instances.kube-system.proxy.package = proxyPackage;
          instances.monitoring-system = {
            prometheus-operator.package = pkg "prometheus-operator";
            rules = {
              package = pkg "prometheus-default-rules";
              config.monitors.kubeProxy.selector.component = "proxy";
            };
          };
        }
      ]);
      service = lib.findFirst (
        m: m.kind == "Service" && lib.hasInfix "kube-proxy" (m.metadata.name or "")
      ) null ms;
    in
    (service != null && service.spec.selector == { component = "proxy"; })
    || throw "kube-proxy bridge Service: ${builtins.toJSON service}";

  # node-exporter keeps its host paths, and an instance flag replaces the
  # package's value of the same filesystem flag.
  lib-options-typing-node-exporter-args =
    let
      argsOf =
        config:
        (lib.findFirst (m: m.kind == "DaemonSet") null (
          manifests (mkCluster [
            {
              instances.monitoring-system.node-exporter = {
                package = pkg "node-exporter";
                inherit config;
              };
            }
          ])
        )).spec.template.spec.containers;
      args =
        (builtins.head (argsOf {
          extraArgs = [ "--collector.filesystem.fs-types-exclude=^tmpfs$" ];
        })).args;
    in
    (
      builtins.elem "--path.sysfs=/host/sys" args
      && builtins.elem "--collector.filesystem.fs-types-exclude=^tmpfs$" args
      &&
        builtins.length (builtins.filter (lib.hasPrefix "--collector.filesystem.fs-types-exclude") args)
        == 1
      && builtins.any (lib.hasPrefix "--collector.filesystem.mount-points-exclude") args
      && throws (argsOf {
        extraArgs = [ "--path.sysfs=/sys" ];
      })
    )
    || throw "node-exporter args: ${builtins.toJSON args}";

  # The monitoring module passes grafana.persistence to the claim it
  # creates, a byte count included.
  lib-options-typing-monitoring-grafana-persistence =
    let
      packages = lib.genAttrs [
        "alertmanager"
        "grafana"
        "kube-state-metrics"
        "loki"
        "loki-logs"
        "node-exporter"
        "persistent-volume-claim"
        "priority-class"
        "prometheus"
        "prometheus-default-rules"
        "prometheus-operator"
      ] pkg;
      claim = lib.findFirst (m: m.kind == "PersistentVolumeClaim") null (
        manifests (mkCluster [
          ../../modules/monitoring.nix
          {
            _module.args.packages = packages;
            monitoring = {
              enabled = true;
              grafana.persistence = {
                size = 10737418240;
                storageClassName = "fast";
              };
            };
            instances.monitoring-system.fast-class = storageClassImport "fast";
          }
        ])
      );
    in
    (claim.spec.storageClassName == "fast" && claim.spec.resources.requests.storage == "10737418240")
    || throw "grafana claim: ${builtins.toJSON claim}";

  # A collection option keeps no default keys once an instance sets it: the
  # instance value replaces the package's `lib.mkDefault` as a whole.
  lib-options-typing-instance-value-replaces-collection-default =
    let
      cfg = eval.evaluateInstanceConfig {
        packageOptions.issuers = lib.mkOption {
          type = lib.types.attrsOf (
            lib.types.submodule { options.kind = lib.mkOption { type = lib.types.str; }; }
          );
          default = { };
        };
        packageConfig.issuers = lib.mkDefault {
          production.kind = "acme";
          staging.kind = "acme";
        };
        instCfg.config.imports = [ { issuers.local.kind = "selfSigned"; } ];
      };
    in
    cfg.issuers == { local.kind = "selfSigned"; } || throw "issuers: ${builtins.toJSON cfg.issuers}";

  # A package whose `settings` default an instance value would partly
  # discard (Rule 1), rendered into a ConfigMap. `grants` is its meta.unsafe.
  lib-options-typing-build-enforces-contract =
    let
      lossyPackage = grants: {
        meta = {
          version = "test";
          unsafe = grants;
        };
        options.settings = lib.mkOption {
          type = t.anything;
          default = {
            a = "1";
            b = "2";
          };
        };
        build =
          {
            self,
            scope,
            config,
            ...
          }:
          {
            root = self.cm;
            cm = scope.mkResource {
              apiVersion = "v1";
              kind = "ConfigMap";
              name = "settings";
              data = config.settings;
            };
          };
      };
      build =
        grants:
        mkCluster [
          {
            instances.appns.app = {
              package = lossyPackage grants;
              config.settings.a = "3";
            };
          }
        ];
      refused = builtins.tryEval (builtins.deepSeq (manifests (build [ ])) true);
      granted = lib.findFirst (m: m.kind == "ConfigMap") null (
        manifests (build [ "lossy-option-defaults" ])
      );
    in
    (!refused.success && granted.data == { a = "3"; })
    || throw "contract: refused=${builtins.toJSON refused.success} granted=${builtins.toJSON granted}";
}
