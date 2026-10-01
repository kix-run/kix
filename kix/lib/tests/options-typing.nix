# Tests for the typed option helpers (vocab/quantity.nix, the option and
# guard helpers in vocab/compose.nix), the option contract walker
# (eval/options.nix) and instance-config error locations (eval/resolve.nix).
# Imported by ./default.nix into the same test matrix.

{
  lib,
  eval,
  kixlib,
  mkCluster,
  manifests,
}:

let
  throws = v: !(builtins.tryEval (builtins.deepSeq v v)).success;

  # The value of one option `o` after the module system merges `defs`.
  optionValue =
    o: defs:
    (lib.evalModules {
      modules = [ { options.o = o; } ] ++ map (d: { config.o = d; }) defs;
    }).config.o;

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

  messagesMention =
    needle: vs: vs != [ ] && builtins.all (v: lib.hasInfix needle v.message) vs;

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
      && results == {
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
      ]
    )
    || throw "quantity: unparsed=${builtins.toJSON unparsed} results=${builtins.toJSON results}";

  lib-options-typing-parse-gi =
    let
      got = map kixlib.parseGi [
        "50Gi"
        "500Mi"
        "x"
      ];
    in
    got == [
      50
      0
      null
    ]
    || throw "parseGi: ${builtins.toJSON got}";

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
      && cleared == {
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
            rules.reliability = import ../rules/reliability.nix { inherit lib; };
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
    (
      builtins.length findings == 1
      && lib.hasInfix "missing resource settings: limits.cpu." message
    )
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
      && throws (optionValue env [
        { P = "x"; }
        { P = "y"; }
      ])
      && kixlib.mkEnvVars cfg.env == [ ]
      && optionValue env [ { F.valueFrom.fieldRef.fieldPath = "metadata.name"; } ] == {
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
      && throws (merge { DB_HOST = "x"; })
      && throws (merge { DB_HOST = null; })
      && throws (merge { API_KEY = "k"; })
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
      && check {
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
      && check {
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
      && map (v: v.head) vs == [
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
    && eval.checkOptionContract {
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
}
