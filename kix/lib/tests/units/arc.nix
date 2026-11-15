# Tests for kix/packages/experimental/arc and kix/packages/experimental/arc-runner-set: the CRD source
# tag, the image tag check, the runner set contract that
# out.mkAutoscalingRunnerSet builds, the parts that render only with a
# prometheus provider or an enforcer, and the refusals. The controller runs in
# namespace `arc-systems`, the runner set `linux` in `arc-runners`.
#
# builtins.tryEval drops the text of a `throw`, so message tests call the
# functions that compute a refusal (runner-set.nix `refusal`, arc-runner-set
# checks.nix, the package assertions) directly. Refusals that only a whole
# cluster build reaches use evalFails next to a configuration that builds.

{
  lib,
  kixKeys,
  mkCluster,
  netpolOn,
  manifests,
  ofKind,
  byName,
  evalFails,
  alertRulesOf,
  allSelect,
  prometheusStub,
  ...
}:

let
  arcPackage = import ../../../packages/experimental/arc;
  runnerSetPackage = import ../../../packages/experimental/arc-runner-set;
  secretRefPackage = import ../../../packages/stable/secret-ref;
  priorityClassPackage = import ../../../packages/stable/priority-class;

  # arc evaluated outside a cluster, for its assertions and meta.
  arcAlone = arcPackage {
    inherit lib;
    scope = { };
    kix = { };
    availability = "none";
  };

  clusterWith =
    {
      config ? { },
      arcConfig ? { },
      keys ? [ "github_token" ],
      modules ? [ ],
    }:
    mkCluster (
      [
        {
          instances.arc-systems.arc = {
            package = arcPackage;
            config = arcConfig;
          };
          instances.arc-runners.github-config = {
            package = secretRefPackage;
            aliases = [ "githubConfigSecret" ];
            config = { inherit keys; };
          };
          instances.arc-runners.linux = {
            package = runnerSetPackage;
            config = {
              githubConfigUrl = "https://github.com/example/example/";
              maxRunners = 2;
            }
            // config;
          };
        }
      ]
      ++ modules
    );

  cluster = clusterWith { };
  ms = manifests cluster;
  find = kind: name: byName name (ofKind kind ms);
  arcRaw = cluster.instances.arc-systems.arc.raw;
in
{
  # Every URL in crds/sources.txt fetches from the chart tag of the
  # package's release, so the vendored CRDs match meta.version.
  arc-sources =
    let
      version =
        (arcPackage {
          inherit lib;
          scope = { };
          kix = { };
          availability = "none";
        }).meta.version;
      urls = builtins.filter (l: l != "" && !lib.hasPrefix "#" l) (
        lib.splitString "\n" (builtins.readFile ../../../packages/experimental/arc/crds/sources.txt)
      );
    in
    (builtins.length urls == 4 && builtins.all (lib.hasInfix "/gha-runner-scale-set-${version}/") urls)
    || throw "arc sources: crds/sources.txt does not fetch every CRD from gha-runner-scale-set-${version}: ${builtins.toJSON urls}";

  # The runner set carries the controller's version and names its three
  # supporting objects; those carry the cleanup finalizer and bind the
  # controller's ServiceAccount.
  arc-runner-set-contract =
    let
      ars = find "AutoscalingRunnerSet" "linux";
      sa = find "ServiceAccount" "linux-runner";
      role = find "Role" "linux-manager";
      binding = find "RoleBinding" "linux-manager";
      finalized = m: (m.metadata.finalizers or [ ]) == [ "actions.github.com/cleanup-protection" ];
      annotations = ars.metadata.annotations;
    in
    (
      ars.metadata.labels."app.kubernetes.io/version" == "0.14.2"
      && annotations."actions.github.com/cleanup-manager-role-binding" == "linux-manager"
      && annotations."actions.github.com/cleanup-manager-role-name" == "linux-manager"
      && annotations."actions.github.com/cleanup-no-permission-service-account-name" == "linux-runner"
      &&
        annotations.${kixKeys.readiness} == builtins.toJSON {
          path = "/status/phase";
          equals = "Running";
        }
      && ars.spec.githubConfigUrl == "https://github.com/example/example"
      && ars.spec.githubConfigSecret == "github-config"
      && ars.spec.template.spec.serviceAccountName == "linux-runner"
      && ars.spec.template.spec.automountServiceAccountToken == false
      && builtins.all finalized [
        sa
        role
        binding
      ]
      &&
        binding.subjects == [
          {
            kind = "ServiceAccount";
            name = "arc";
            namespace = "arc-systems";
          }
        ]
      && find "Role" "linux-runner" == null
    )
    || throw "arc runner set contract: ${builtins.toJSON { inherit ars sa binding; }}";

  # The metrics Service and the listener PodMonitor need a prometheus
  # provider; the listener and runner policies need an enforcer.
  arc-gated-parts =
    let
      enforced = manifests (clusterWith {
        modules = [ netpolOn ];
      });
      operandPolicies = builtins.filter (
        m: m.metadata.labels.${kixKeys.policyType} or null == "operator-managed-workload"
      ) enforced;
    in
    (
      arcRaw.metricsService == null
      && arcRaw.listenerPodMonitor == null
      && arcRaw.listenerEgress == null
      &&
        lib.sort lib.lessThan (map (m: m.metadata.name) operandPolicies) == [
          "arc-listener-egress"
          "linux-runner-egress"
        ]
    )
    || throw "arc gated parts: ${builtins.toJSON (map (m: m.metadata.name) operandPolicies)}";

  # `rules` adds a Role for the runner ServiceAccount and mounts its token.
  arc-runner-set-rules =
    let
      c = clusterWith {
        config.rules = [
          {
            apiGroups = [ "" ];
            resources = [ "pods" ];
            verbs = [ "get" ];
          }
        ];
      };
      cms = manifests c;
      role = byName "linux-runner" (ofKind "Role" cms);
      ars = byName "linux" (ofKind "AutoscalingRunnerSet" cms);
    in
    (
      role.rules == [
        {
          apiGroups = [ "" ];
          resources = [ "pods" ];
          verbs = [ "get" ];
        }
      ]
      && ars.spec.template.spec.automountServiceAccountToken
    )
    || throw "arc runner set rules: ${builtins.toJSON { inherit role; }}";

  # The image tag must parse the way the controller's parseSemver does and
  # share the release's major.minor.
  arc-image-tag =
    let
      check = tag: builtins.head (arcAlone.assertions { config.image.tag = tag; });
      accepted = tag: (check tag).assertion;
      unparsable =
        tag:
        !(check tag).assertion
        && lib.hasPrefix "image.tag \"${tag}\" is not a version the controller can parse" (check tag)
        .message;
      otherMinor =
        tag:
        !(check tag).assertion
        && lib.hasPrefix "image.tag \"${tag}\" is not a 0.14 release, and the CRDs under kix/packages/experimental/arc/crds are vendored from 0.14.2." (check tag)
        .message;
    in
    (
      builtins.all accepted [
        "0.14.2"
        "0.14.9"
        "0.14.2-rc.1"
      ]
      && builtins.all unparsable [
        "v0.14.2"
        "0.14.x"
        "0.14.02"
        "latest"
      ]
      && builtins.all otherMinor [
        "0.15.0"
        "1.14.2"
      ]
    )
    || throw "arc image tag: ${
      builtins.toJSON (
        map check [
          "0.14.2"
          "v0.14.2"
          "0.15.0"
        ]
      )
    }";

  # Each constraint of out.mkAutoscalingRunnerSet, checked by message.
  arc-builder-refusals =
    let
      builder = import ../../../packages/experimental/arc/runner-set.nix {
        inherit lib;
        who = "arc arc-systems/arc";
        ns = "arc-systems";
        self = { };
        config = { };
      };
      spec = {
        githubConfigUrl = "https://github.com/example/example/";
        githubConfigSecret = "github-config";
        minRunners = 0;
        maxRunners = 2;
        template.spec.containers = [ { name = "runner"; } ];
      };
      refusal =
        {
          name ? "linux",
          change ? { },
          drop ? [ ],
        }:
        builder.refusal {
          namespace = "arc-runners";
          inherit name;
          spec = removeAttrs (lib.recursiveUpdate spec change) drop;
        };
      refuses = prefix: args: lib.hasPrefix prefix (toString (refusal args));
    in
    (
      refusal { } == null
      && refusal { name = lib.fixedWidthString 45 "a" ""; } == null
      &&
        refuses
          "spec.template.spec.serviceAccountName is set. The runner pods use the ServiceAccount linux-runner"
          {
            change.template.spec.serviceAccountName = "x";
          }
      &&
        refuses
          "the name has 46 characters. The controller names the listener <name>-<hash of up to 8 characters>-listener, which must fit in 63 characters"
          {
            name = lib.fixedWidthString 46 "a" "";
          }
      && refuses "spec.githubConfigUrl is missing or not a string." { drop = [ "githubConfigUrl" ]; }
      &&
        refuses
          "spec.githubConfigUrl must be http(s)://<host>/ followed by <org>, <org>/<repo>, or enterprises/<name>; got \"https://github.com/a/b/c\"."
          {
            change.githubConfigUrl = "https://github.com/a/b/c";
          }
      &&
        refuses
          "spec.githubConfigSecret is missing or not a string. Pass the out.name of a Secret in arc-runners."
          {
            drop = [ "githubConfigSecret" ];
          }
      && refuses "spec.minRunners (3) is greater than spec.maxRunners (2)." { change.minRunners = 3; }
      && refuses "spec.template.spec.containers has no container named runner." {
        change.template.spec.containers = [ { name = "job"; } ];
      }
    )
    || throw "arc builder refusals: ${
      builtins.toJSON {
        base = refusal { };
        long = refusal { name = lib.fixedWidthString 46 "a" ""; };
      }
    }";

  # Each arc-runner-set option refusal, checked by message. An extraSpec path
  # that an option sets is left to kix.mergeGuarded.
  arc-runner-set-option-refusals =
    let
      check = import ../../../packages/experimental/arc-runner-set/checks.nix {
        inherit lib;
        name = "linux";
      };
      base = {
        githubConfigUrl = "https://github.com/example/example";
        minRunners = 0;
        maxRunners = 2;
        extraSpec = { };
      };
      problem = change: check (lib.recursiveUpdate base change);
      refuses = prefix: change: lib.hasPrefix prefix (toString (problem change));
      containers = cs: { extraSpec.template.spec.containers = cs; };
    in
    (
      problem { } == null
      && problem { extraSpec.minRunners = 1; } == null
      &&
        problem (containers [
          {
            name = "runner";
            command = [ ];
          }
        ]) == null
      && refuses "minRunners (3) is greater than maxRunners (2)." { minRunners = 3; }
      && refuses "githubConfigUrl must be http(s)://<host>/" { githubConfigUrl = "github.com/x"; }
      && refuses "extraSpec sets githubConfigSecret. It is the Secret of deps.githubConfigSecret" {
        extraSpec.githubConfigSecret = "x";
      }
      &&
        refuses
          "extraSpec sets template.spec.serviceAccountName. The runner pods use the ServiceAccount linux-runner"
          {
            extraSpec.template.spec.serviceAccountName = "x";
          }
      &&
        refuses
          "extraSpec sets template.spec.automountServiceAccountToken. The token is mounted when `rules` is set"
          {
            extraSpec.template.spec.automountServiceAccountToken = true;
          }
      &&
        refuses
          "extraSpec sets template.spec.priorityClassName. It is the PriorityClass of deps.priorityClass"
          {
            extraSpec.template.spec.priorityClassName = "x";
          }
      && refuses "extraSpec.template.spec.containers must be a list" {
        extraSpec.template.spec.containers = { };
      }
      && refuses "extraSpec.template.spec.containers has an entry without a name." (containers [
        { image = "x"; }
      ])
      &&
        problem (containers [
          {
            name = "runner";
            image = "x";
          }
        ])
        == "extraSpec.template.spec.containers.runner sets `image`, which the `image` option sets; use the option."
      &&
        problem (containers [
          {
            name = "runner";
            image = "x";
            env = [ ];
          }
        ])
        == "extraSpec.template.spec.containers.runner sets `image` and `env`, which the `image` and `env` options set; use the options."
    )
    || throw "arc runner set option refusals: ${
      builtins.toJSON (problem {
        minRunners = 3;
      })
    }";

  # The refusals a whole build reaches: arc-runner-set's checks run before
  # the builder, kix.mergeGuarded guards option-owned extraSpec paths,
  # checkSecretKeys reads the secret's keys, and arc owns its flags and env
  # vars. The base cluster building is the control.
  arc-build-refusals =
    let
      fails = args: evalFails (clusterWith args);
    in
    (
      !(evalFails cluster)
      && fails {
        config = {
          minRunners = 3;
          maxRunners = 1;
        };
      }
      && fails { config.extraSpec.minRunners = 1; }
      && fails { keys = [ "github_app_id" ]; }
      && !(fails {
        keys = [
          "github_app_id"
          "github_app_installation_id"
          "github_app_private_key"
        ];
      })
      && fails { arcConfig.extraArgs = [ "--metrics-addr=:9090" ]; }
      && fails { arcConfig.extraArgs = [ "--enable-leader-election=false" ]; }
      && fails { arcConfig.env.CONTROLLER_MANAGER_POD_NAMESPACE = "x"; }
      && fails { arcConfig.image.tag = "0.15.0"; }
      && fails { modules = [ { instances.other.arc.package = arcPackage; } ]; }
    )
    || throw "arc build refusals: a refused configuration evaluated, or the base cluster failed";

  # extraArgs follow the package's flags, so a repeated --log-level wins;
  # extra env vars render beside the owned ones.
  arc-extra-args-and-env =
    let
      deployment = byName "arc" (
        ofKind "Deployment" (
          manifests (clusterWith {
            arcConfig = {
              extraArgs = [ "--log-level=debug" ];
              env.HTTPS_PROXY = "http://proxy:3128";
            };
          })
        )
      );
      manager = builtins.head deployment.spec.template.spec.containers;
      envNames = map (e: e.name) manager.env;
    in
    (
      lib.last manager.args == "--log-level=debug"
      && builtins.elem "--log-level=info" manager.args
      && builtins.elem "HTTPS_PROXY" envNames
      && builtins.elem "CONTROLLER_MANAGER_POD_NAMESPACE" envNames
    )
    || throw "arc extra args and env: ${builtins.toJSON { inherit (manager) args env; }}";

  # With a prometheus provider: the metrics Service, ServiceMonitor `arc`,
  # and PodMonitor `arc-listeners` selecting the listener labels on the port
  # number, which the derived scrape egress needs. With metrics.enabled =
  # false, none of them.
  arc-metrics =
    let
      withPrometheus =
        arcConfig:
        manifests (clusterWith {
          inherit arcConfig;
          modules = [ { instances.monitoring.prometheus.package = prometheusStub; } ];
        });
      on = withPrometheus { };
      off = withPrometheus { metrics.enabled = false; };
      podMonitor = byName "arc-listeners" (ofKind "PodMonitor" on);
    in
    (
      byName "arc-metrics" (ofKind "Service" on) != null
      && byName "arc" (ofKind "ServiceMonitor" on) != null
      && podMonitor.spec.selector.matchLabels == arcRaw.root.out.operandSelectors.listener
      && podMonitor.spec.namespaceSelector.matchNames == [ "arc-systems" ]
      && (builtins.head podMonitor.spec.podMetricsEndpoints).portNumber == 8080
      && byName "arc-metrics" (ofKind "Service" off) == null
      && ofKind "ServiceMonitor" off == [ ]
      && ofKind "PodMonitor" off == [ ]
    )
    || throw "arc metrics: ${builtins.toJSON { inherit podMonitor; }}";

  # The alerts render under `arc-alerts` with a prometheus provider and
  # metrics.enabled, and every expression selects the controller's Service.
  arc-alerts =
    let
      rulesOf =
        {
          arcConfig ? { },
          modules ? [ { instances.monitoring.prometheus.package = prometheusStub; } ],
        }:
        alertRulesOf "PrometheusRule" "arc" (
          manifests (clusterWith {
            inherit arcConfig modules;
          })
        );
      rules = rulesOf { };
    in
    (
      allSelect ''namespace="arc-systems",service="arc-metrics"'' rules
      &&
        builtins.attrNames rules == [
          "ArcControllerDown"
          "ArcControllerReconcileErrors"
          "ArcEphemeralRunnersFailed"
        ]
      && rulesOf { modules = [ ]; } == null
      && rulesOf { arcConfig.metrics.enabled = false; } == null
    )
    || throw "arc alerts: ${builtins.toJSON (builtins.attrNames rules)}";

  # arc publishes the runner pod labels; the runner set's policy selects
  # them.
  arc-operand-selectors =
    let
      policy = byName "linux-runner-egress" (
        manifests (clusterWith {
          modules = [ netpolOn ];
        })
      );
      runner = arcRaw.root.out.operandSelectors.runner "linux";
    in
    (
      runner == {
        "actions.github.com/scale-set-name" = "linux";
        "app.kubernetes.io/component" = "runner";
      }
      && lib.hasInfix (builtins.toJSON runner) (builtins.toJSON policy.spec)
    )
    || throw "arc operand selectors: ${builtins.toJSON { inherit runner policy; }}";

  # A priorityClass dependency names the runner pods' class; the runner
  # entry of extraSpec containers merges over the package's container and
  # other entries are appended.
  arc-runner-set-template =
    let
      ars = byName "linux" (
        ofKind "AutoscalingRunnerSet" (
          manifests (clusterWith {
            config.extraSpec.template.spec.containers = [
              {
                name = "runner";
                command = [ ];
              }
              {
                name = "sidecar";
                image = "busybox";
              }
            ];
            modules = [
              {
                instances.arc-runners.runner-priority = {
                  package = priorityClassPackage;
                  aliases = [ "priorityClass" ];
                  config.value = 100;
                };
              }
            ];
          })
        )
      );
      podSpec = ars.spec.template.spec;
      runner = builtins.head podSpec.containers;
    in
    (
      podSpec.priorityClassName == "runner-priority"
      &&
        map (c: c.name) podSpec.containers == [
          "runner"
          "sidecar"
        ]
      && runner.command == [ ]
      && lib.hasPrefix "ghcr.io/actions/actions-runner:2.337.0@sha256:" runner.image
    )
    || throw "arc runner set template: ${builtins.toJSON podSpec}";
}
