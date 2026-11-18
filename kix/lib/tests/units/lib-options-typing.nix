# Tests for the typed option helpers (vocab/quantity.nix, the option and
# guard helpers in vocab/compose.nix), the option contract walker
# (eval/options.nix), instance-config error locations (eval/resolve.nix),
# and the options the sweep retyped in the monitoring packages and module.
# Loaded by ../default.nix with the other files in this directory.

{
  lib,
  eval,
  kixlib,
  publicKix,
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

  pkg = name: (import ../../../packages/by-level.nix { inherit lib; }).byName.${name};

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
  # more than 18 significant digits, throws instead of becoming a float.
  # Leading and trailing zeros are not significant. `problem` names the
  # limit a value exceeds.
  lib-options-typing-quantity-exact-range =
    let
      throws = v: !(builtins.tryEval (builtins.deepSeq v true)).success;
      inherit (import ../../vocab/quantity.nix { inherit lib; }) problem;
      ei = kixlib.parseQuantity "memory" "7Ei";
      reasons = {
        magnitude = problem "cpu" "2Ei";
        digits = problem "memory" "1234567890123456789";
        fraction = problem "memory" "0.0000000000000000001";
        rounding = problem "memory" "7.5Ei";
      };
    in
    (
      ei == 7 * 1024 * 1024 * 1024 * 1024 * 1024 * 1024
      && builtins.isInt ei
      && kixlib.parseQuantity "cpu" "9223372036854775m" == 9223372036854775
      && kixlib.parseQuantity "cpu" "922337203685477580m" == 922337203685477580
      && kixlib.parseQuantity "memory" "0000000000000000001Gi" == 1024 * 1024 * 1024
      && kixlib.parseQuantity "memory" "1.500000000000000000000" == 1
      && kixlib.types.quantity.check "0000000000000000001Gi"
      && throws (kixlib.parseQuantity "memory" "8Ei")
      && throws (kixlib.parseQuantity "cpu" "2Ei")
      && throws (kixlib.parseQuantity "cpu" "9223372036854776")
      && throws (kixlib.parseQuantity "memory" "0.0000000000000000001")
      && throws (kixlib.parseQuantity "memory" "1234567890123456789")
      && problem "memory" "1Gi" == null
      && lib.hasInfix "largest signed 64-bit integer" reasons.magnitude
      && lib.hasInfix "18 significant digits" reasons.digits
      && lib.hasInfix "after the decimal point" reasons.fraction
      && lib.hasInfix "fewer digits after the decimal point" reasons.rounding
    )
    || throw "quantity range: 7Ei = ${builtins.toJSON ei}, reasons = ${builtins.toJSON reasons}";

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

  # An attrset of flags (a VictoriaMetrics CR's extraArgs) is refused on an
  # owned key, matched exactly after its leading dashes, and comes back
  # unchanged otherwise. The refusal names the option, the key as written,
  # and the reason.
  lib-options-typing-guard-args-attrset =
    let
      guardArgs = {
        who = "pkg ns/inst";
        option = "vmstorage.extraArgs";
        owned."dedup.minScrapeInterval" = "set scrapeInterval instead.";
      };
      guard = kixlib.guardArgs guardArgs;
      # compose.nix with `throw` replaced, so the message can be read.
      helpers = import ../caught.nix { inherit lib; };
      refusal =
        args:
        helpers.records (
          ((helpers.caught ../../vocab/compose.nix { inherit lib; }).guardArgs guardArgs args).thrown
        );
      allowed = {
        "dedup.minScrapeIntervalExtra" = "1m";
        "search.maxQueryDuration" = "60s";
      };
    in
    (
      guard allowed == allowed
      && guard { } == { }
      && throws (guard {
        "dedup.minScrapeInterval" = "1m";
      })
      && throws (guard {
        "-dedup.minScrapeInterval" = "1m";
      })
      && throws (guard {
        "--dedup.minScrapeInterval" = "1m";
      })
      &&
        refusal {
          "dedup.minScrapeInterval" = "1m";
        } == [
          {
            option = "vmstorage.extraArgs";
            message = "pkg ns/inst: vmstorage.extraArgs sets \"dedup.minScrapeInterval\", which this package does not accept: set scrapeInterval instead.";
          }
        ]
    )
    || throw "guardArgs attrset: ${
      builtins.toJSON (refusal {
        "dedup.minScrapeInterval" = "1m";
      })
    }";

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

  # Declarations the walker cannot read are violations: a default that
  # throws, an attrset default on a type no rule covers (a `coercedTo` whose
  # `coercedType` accepts the default, an `attrTag`), a default with a
  # `_type` that is not a module-system wrapper, a submodule that throws
  # when evaluated (reported for its field defaults and for its fields), a
  # non-option entry, and an option without `type` (merged as
  # `unspecified`, so Rule 1).
  lib-options-typing-contract-unreadable =
    let
      vs = violations {
        throwing = lib.mkOption {
          type = t.attrsOf t.str;
          default = throw "no default";
        };
        coerced = lib.mkOption {
          type = t.coercedTo (t.attrsOf t.str) (x: x) (t.attrsOf t.str);
          default.v = "x";
        };
        tagged = lib.mkOption {
          type = t.attrTag { x = lib.mkOption { type = t.str; }; };
          default.x = "1";
        };
        wrapped = lib.mkOption {
          type = t.attrsOf t.str;
          default = {
            _type = "custom";
            a = "1";
          };
        };
        brokenFields = lib.mkOption {
          type = t.submodule { config = throw "broken"; };
          default.x = 1;
        };
        notAnOption = 5;
        untyped = lib.mkOption { default.a = 1; };
      };
      byPath = lib.groupBy (v: lib.concatStringsSep "." v.path) vs;
      mentions = path: needle: builtins.any (v: lib.hasInfix needle v.message) byPath.${path};
    in
    (
      builtins.length vs == 8
      && mentions "throwing" "evaluating its default throws"
      && mentions "coerced" "no rule for that type"
      && mentions "tagged" "no rule for that type"
      && mentions "wrapped" "_type \"custom\""
      && mentions "brokenFields" "evaluating its fields"
      && mentions "brokenFields" "reading the fields of its type throws"
      && mentions "notAnOption" "is not an option declaration"
      && mentions "untyped" "has type `unspecified"
    )
    || throw "unreadable: ${builtins.toJSON vs}";

  # A recursive submodule type stops at the option that repeats a
  # declaration on its path, so a tree whose levels default to null passes,
  # and a lossy default inside it is reported once. A chain of distinct
  # declarations deeper than the bound is reported at the bound.
  lib-options-typing-contract-depth =
    let
      node =
        labels:
        t.submodule {
          options.child = lib.mkOption {
            type = t.nullOr (node labels);
            default = null;
          };
          options.labels = lib.mkOption {
            type = t.attrsOf t.str;
            default = labels;
          };
        };
      tree =
        labels:
        violations {
          tree = lib.mkOption {
            type = node labels;
            default = { };
          };
        };
      # Thirteen levels, each declaring its own field `c<n>`.
      chain =
        n:
        if n == 0 then
          t.str
        else
          t.submodule {
            options."c${toString n}" = lib.mkOption {
              type = t.nullOr (chain (n - 1));
              default = null;
            };
          };
      deep = violations {
        deep = lib.mkOption {
          type = chain 13;
          default = { };
        };
      };
      lossy = tree { team = "x"; };
    in
    (
      tree { } == [ ]
      &&
        map (v: lib.concatStringsSep "." v.path) lossy == [
          "tree.child.labels"
          "tree.labels"
        ]
      && builtins.length deep == 1
      && lib.hasInfix "option levels deep" (builtins.head deep).message
    )
    || throw "depth: ${builtins.toJSON { inherit lossy deep; }}";

  # A field default that reads a sibling with no default throws under
  # getSubOptions. The field's type takes no attrset, so its default is not
  # evaluated and nothing is reported.
  lib-options-typing-contract-sibling-default =
    let
      server =
        { config, ... }:
        {
          options.host = lib.mkOption { type = t.str; };
          options.port = lib.mkOption { type = t.port; };
          options.url = lib.mkOption {
            type = t.str;
            default = "http://${config.host}:${toString config.port}";
          };
          options.args = lib.mkOption {
            type = t.listOf t.str;
            default = [ "--host=${config.host}" ];
          };
        };
      vs = violations {
        servers = lib.mkOption {
          type = t.attrsOf (t.submodule server);
          default = { };
        };
        server = lib.mkOption {
          type = t.submodule server;
          default = { };
        };
      };
    in
    vs == [ ] || throw "sibling default: ${builtins.toJSON vs}";

  # A default wrapped in lib.mkDefault, lib.mkOverride, lib.mkOrder,
  # lib.mkMerge, or a true lib.mkIf is checked as the value it wraps, at the
  # top level and in a submodule field.
  lib-options-typing-contract-wrapped-defaults =
    let
      vs = violations {
        mkDefault = lib.mkOption {
          type = t.attrsOf t.str;
          default = lib.mkDefault { a = "1"; };
        };
        mkMerge = lib.mkOption {
          type = t.attrsOf t.str;
          default = lib.mkMerge [
            { }
            (lib.mkBefore { a = "1"; })
          ];
        };
        mkIf = lib.mkOption {
          type = t.attrsOf t.str;
          default = lib.mkIf true { a = "1"; };
        };
        mkIfFalse = lib.mkOption {
          type = t.attrsOf t.str;
          default = lib.mkIf false { a = "1"; };
        };
        sub = lib.mkOption {
          type = t.submodule {
            options.m = lib.mkOption {
              type = t.attrsOf t.str;
              default = lib.mkOverride 900 { x = "y"; };
            };
            options.a = lib.mkOption { type = t.str; };
          };
          default = lib.mkDefault { a = "1"; };
        };
      };
    in
    map (v: lib.concatStringsSep "." v.path) vs == [
      "mkDefault"
      "mkIf"
      "mkMerge"
      "sub"
      "sub.m"
    ]
    || throw "wrapped defaults: ${builtins.toJSON vs}";

  # A coercedTo whose coercedType rejects the default stores it as its
  # finalType, so the finalType's rule applies.
  lib-options-typing-contract-coerced =
    let
      fields = t.submodule {
        options.size = lib.mkOption {
          type = t.str;
          default = "1Gi";
        };
      };
      vs = violations {
        matching = lib.mkOption {
          type = t.coercedTo t.str (size: { inherit size; }) fields;
          default.size = "1Gi";
        };
        differing = lib.mkOption {
          type = t.coercedTo t.str (size: { inherit size; }) fields;
          default.size = "2Gi";
        };
        labels = lib.mkOption {
          type = t.coercedTo t.str (v: { app = v; }) (t.attrsOf t.str);
          default.app = "x";
        };
      };
    in
    (
      map (v: lib.concatStringsSep "." v.path) vs == [
        "differing"
        "labels"
      ]
      && lib.hasInfix "has the default \"1Gi\"" (builtins.head vs).message
      && messagesMention "lib.mkDefault" (lib.tail vs)
    )
    || throw "coercedTo: ${builtins.toJSON vs}";

  # kix.checkPackageOptions calls phase 1 at each availability level up to
  # the package's ceiling, and names the levels of a violation that does
  # not occur at all of them.
  lib-options-typing-check-package-levels =
    let
      levelPackage =
        ceiling:
        { availability, ... }:
        {
          meta = {
            version = "test";
          }
          // lib.optionalAttrs (ceiling != null) { availability.max = ceiling; };
          options.zones = lib.mkOption {
            type = t.attrsOf t.str;
            default = if availability == "zone" then { "topology.kubernetes.io/zone" = "a"; } else { };
          };
          build = _: { };
        };
      plain = {
        meta.version = "test";
        options.x = lib.mkOption {
          type = t.anything;
          default.a = 1;
        };
        build = _: { };
      };
      vs = publicKix.packageOptionViolations { package = levelPackage null; };
    in
    (
      map (v: v.levels) vs == [ [ "zone" ] ]
      && throws (publicKix.checkPackageOptions { package = levelPackage null; })
      && publicKix.checkPackageOptions { package = levelPackage "node"; } == null
      && map (v: v.levels) (publicKix.packageOptionViolations { package = plain; }) == [ [ "none" ] ]
    )
    || throw "package levels: ${builtins.toJSON vs}";

  # every-package-evaluates refuses a package that breaks the contract:
  # `names` asserts checkOptionContracts over the catalogue.
  lib-options-typing-package-eval-contract =
    let
      packageEval = import ../../../package-eval.nix {
        inherit lib;
        kix = publicKix;
      };
      good = {
        meta.version = "test";
        options.labels = lib.mkOption {
          type = t.attrsOf t.str;
          default = { };
        };
        build = _: { };
      };
      lossy = good // {
        options.labels = lib.mkOption {
          type = t.attrsOf t.str;
          default.app = "x";
        };
      };
    in
    (
      packageEval.checkOptionContracts { inherit good; }
      && throws (packageEval.checkOptionContracts { inherit good lossy; })
    )
    || throw "package-eval does not refuse a lossy package";

  lib-options-typing-check-throws =
    throws (
      eval.checkOptionContract {
        who = "kix/packages/stable/example";
        options.x = lib.mkOption {
          type = t.anything;
          default.a = 1;
        };
      }
    )
    &&
      eval.checkOptionContract {
        who = "kix/packages/stable/example";
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
        vmstorage.extraArgs.retentionPeriod = "1d";
      })
      && evalFails' (withConfig {
        vminsert.extraArgs.replicationFactor = "1";
      })
      && evalFails' (withConfig {
        vminsert.extraArgs.httpListenAddr = ":9000";
      })
      &&
        (vmSpec "VMCluster" (withConfig {
          vminsert.extraArgs."maxLabelsPerTimeseries" = "60";
        })).vminsert.extraArgs == {
          "maxLabelsPerTimeseries" = "60";
        }
      && evalFails' (withConfig {
        vmstorage.storage.storageClassName = "fast";
      })
    )
    || throw "vm-cluster owned fields: ${builtins.toJSON spec.vmstorage}";

  # vm-agent keeps its own flag beside an instance flag, and refuses an
  # extraSpec or an extraArgs entry that replaces the remote-write target
  # the vmCluster dependency gives it, or the scrape configuration the
  # operator writes.
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
      && evalFails' (agent {
        extraArgs."remoteWrite.url" = "http://elsewhere";
      })
      && evalFails' (agent {
        extraArgs."promscrape.config" = "/tmp/other.yaml";
      })
    )
    || throw "vm-agent extraArgs: ${builtins.toJSON spec.extraArgs}";

  # vm-operator sets its log level, leader election, and probe address
  # itself; extraArgs may not replace them in either flag spelling.
  lib-options-typing-vm-operator-args =
    let
      operator =
        extraArgs:
        vmCluster {
          vm-operator = {
            package = pkg "victoria-metrics-operator";
            config = {
              inherit extraArgs;
            };
          };
        };
      operatorArgs =
        ms:
        let
          deployment = lib.findFirst (m: m.kind == "Deployment" && m.metadata.name == "vm-operator") null ms;
        in
        (lib.findFirst (c: c.name == "operator") null deployment.spec.template.spec.containers).args;
    in
    (
      lib.take 3 (operatorArgs (operator [ ])) == [
        "--zap-log-level=info"
        "--leader-elect"
        "--health-probe-bind-address=:8081"
      ]
      && builtins.elem "--metrics-bind-address=:8080" (
        operatorArgs (operator [ "--metrics-bind-address=:8080" ])
      )
      && builtins.elem "--zap-log-level=debug" (operatorArgs (operator [ "--zap-log-level=debug" ]))
      && evalFails' (operator [ "-leader-elect=false" ])
      && evalFails' (operator [ "--health-probe-bind-address=:9000" ])
    )
    || throw "vm-operator extraArgs: ${builtins.toJSON (operatorArgs (operator [ ]))}";

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
      settings == import ../../../packages/stable/victoria-metrics-alert/alertmanager-default-settings.nix
      && evalFails' (alert {
        extraSpec.datasource.url = "http://elsewhere";
      })
    )
    || throw "vm-alert settings: ${builtins.toJSON settings}";

  # vm-alert's Alertmanager configuration has three routes: `settings`
  # renders a Secret classified as configuration; `configRawYaml` writes the
  # configuration into the CR and renders no Secret; two routes at once and
  # an inline credential are refused.
  lib-options-typing-vm-alert-config-routes =
    let
      kixKeys = (import ../../core/annotations.nix).keys;
      alert =
        config:
        vmCluster {
          vm-alert = {
            package = pkg "victoria-metrics-alert";
            inherit config;
          };
        };
      minimal = {
        route.receiver = "x";
        receivers = [ { name = "x"; } ];
      };
      configSecret =
        ms:
        lib.findFirst (
          m: m.kind == "Secret" && lib.hasSuffix "-alertmanager-config" m.metadata.name
        ) null ms;
      vmam = ms: lib.findFirst (m: m.kind == "VMAlertmanager") null ms;
      rendered = alert { alertmanager.settings = minimal; };
      raw = alert { alertmanager.configRawYaml = minimal; };
    in
    (
      (configSecret rendered).metadata.annotations.${kixKeys.classification} == "configuration"
      && (vmam rendered).spec ? configSecret
      && configSecret raw == null
      && !((vmam raw).spec ? configSecret)
      && (builtins.fromJSON (vmam raw).spec.configRawYaml).route.receiver == "x"
      && evalFails' (alert {
        alertmanager = {
          settings = minimal;
          configRawYaml = minimal;
        };
      })
      && evalFails' (alert {
        alertmanager.configRawYaml = minimal // {
          receivers = [
            {
              name = "x";
              slack_configs = [ { api_url = "https://hooks.slack.com/services/x"; } ];
            }
          ];
        };
      })
    )
    || throw "vm-alert config routes: ${builtins.toJSON (vmam raw).spec}";

  # An `alertmanagerConfig` secret dependency replaces the rendered
  # configuration Secret on both alertmanager packages: the custom resource
  # names the dependency's Secret and no Secret is classified
  # configuration.
  lib-options-typing-alertmanager-config-dependency =
    let
      kixKeys = (import ../../core/annotations.nix).keys;
      configDep = {
        package = pkg "secret";
        aliases = [ "alertmanagerConfig" ];
        config.stringData."alertmanager.yaml" = "{}";
      };
      vm = vmCluster {
        vm-alert.package = pkg "victoria-metrics-alert";
        am-config = configDep;
      };
      am = manifests (mkCluster [
        {
          instances.monitoring = {
            prometheus-operator.package = pkg "prometheus-operator";
            alertmanager.package = pkg "alertmanager";
            am-config = configDep;
          };
        }
      ]);
      depSecret =
        ms: lib.findFirst (m: m.kind == "Secret" && (m.stringData or { }) ? "alertmanager.yaml") null ms;
      classified =
        ms:
        builtins.filter (
          m: m.kind == "Secret" && (m.metadata.annotations or { }) ? ${kixKeys.classification}
        ) ms;
      usesDep =
        kind: ms:
        let
          cr = lib.findFirst (m: m.kind == kind) null ms;
        in
        cr.spec.configSecret == (depSecret ms).metadata.name && classified ms == [ ];
    in
    (usesDep "VMAlertmanager" vm && usesDep "Alertmanager" am)
    || throw "alertmanagerConfig dependency: ${
      builtins.toJSON (map (m: m.metadata.name) (classified vm ++ classified am))
    }";

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
      packages = import ../../../packages { inherit lib; };
      claim = lib.findFirst (m: m.kind == "PersistentVolumeClaim") null (
        manifests (mkCluster [
          ../../../modules/experimental/monitoring.nix
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
            instances.monitoring-system.grafana-admin = {
              package = pkg "secret";
              aliases = [ "grafanaAdmin" ];
              config.stringData = {
                admin-user = "admin";
                admin-password = "test-only";
              };
            };
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

  # Instance evaluation does not check the option contract (package CI
  # does, in kix/package-eval.nix): a package whose `settings` breaks Rule 1
  # evaluates, and the instance's partial value replaces the whole default.
  lib-options-typing-instance-eval-skips-contract =
    let
      lossyPackage = {
        meta.version = "test";
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
      cm = lib.findFirst (m: m.kind == "ConfigMap") null (
        manifests (mkCluster [
          {
            instances.appns.app = {
              package = lossyPackage;
              config.settings.a = "3";
            };
          }
        ])
      );
    in
    cm.data == { a = "3"; } || throw "instance eval: ${builtins.toJSON cm}";
}
