# arc-runner-set: one GitHub Actions runner scale set, an AutoscalingRunnerSet
# that the `arc` controller turns into a listener and ephemeral runner pods.
#
# Jobs whose `runs-on` names the scale set run in this instance's namespace,
# one pod per job. The scale set is named after the instance unless
# `extraSpec.runnerScaleSetName` sets another name.
#
#   instances.arc-runners = {
#     github-config = {
#       package = packages.secret-ref;
#       aliases = [ "githubConfigSecret" ];
#       config.keys = [ "github_token" ];
#     };
#     linux = {
#       package = packages.experimental.arc-runner-set;
#       config = {
#         githubConfigUrl = "https://github.com/example-org";
#         maxRunners = 4;
#       };
#     };
#   };
#
# Dependencies:
#   arc (required)                 the controller; its out.mkAutoscalingRunnerSet
#                                  builds the runner set.
#   githubConfigSecret (required)  Secret in this namespace with `github_token`,
#                                  or `github_app_id`, `github_app_installation_id`,
#                                  and `github_app_private_key`.
#   priorityClass (optional)       PriorityClass of the runner pods.
#
# Network policy: with an enforcer the runner pods may reach DNS and any
# address outside the cluster on any port, and the API server when `rules` is
# set. Pods a job creates through `rules` are not covered by that policy.
#
# Removal: remove the runner set first, then its secret and arc in a later
# deploy (see the arc package).
#
# Not offered: container modes (dind, kubernetes) and `vaultConfig`. A
# privileged sidecar added through `extraSpec` is not seen by Kix's privilege
# checks, which do not read pod templates inside custom resources.
# Escape hatches: `extraSpec`, `env`, `partsOverlays`, `extra`.
#
# out.extraImages: the runner image, which only the runner set's pod template
# names.
#
# out.version: the actions-runner version `image.tag` names.
#
# root = the AutoscalingRunnerSet.

{
  scope,
  lib,
  kix,
}:

let
  # The actions-runner release: meta.version and image.tag.
  release = "2.337.0";

  name = scope.instanceName;
  ns = scope.namespaceName;
  who = "arc-runner-set ${ns}/${name}";

  # Paths of the runner set spec that options and dependencies set.
  locked = [
    [ "githubConfigUrl" ]
    [ "githubConfigSecret" ]
    [ "minRunners" ]
    [ "maxRunners" ]
    [
      "template"
      "spec"
      "serviceAccountName"
    ]
    [
      "template"
      "spec"
      "automountServiceAccountToken"
    ]
    [
      "template"
      "spec"
      "priorityClassName"
    ]
  ];
in
{
  meta = {
    version = release;
    description = "One GitHub Actions runner scale set (an AutoscalingRunnerSet) for the arc controller";
    owner = "platform";
  };

  options = {
    githubConfigUrl = lib.mkOption {
      type = lib.types.str;
      example = "https://github.com/example-org";
      description = "URL of the organization, repository (`<org>/<repo>`), or enterprise (`enterprises/<name>`) the runners register with.";
    };

    minRunners = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 0;
      description = "Idle runners kept ready for new jobs.";
    };

    maxRunners = lib.mkOption {
      type = lib.types.ints.unsigned;
      description = "Upper bound on runner pods. Upstream leaves it unbounded.";
    };

    image = kix.options.image {
      repository = "ghcr.io/actions/actions-runner";
      tag = release;
      digest = "sha256:e5496277be5d09bc968b3d64911b74e219ac4a3f2edce956a3ecf9271bea1ef4";
      description = "Image of the runner container. The controller turns off the runner's self-update, and GitHub stops sending jobs to a runner more than 30 days behind the latest runner release, so keep the tag current. A runner set whose phase is `Outdated` has hit that limit.";
    };

    env = kix.options.env;

    resources = kix.options.resources {
      description = "Requests and limits of the runner container. No defaults, because jobs vary; null fields are left out.";
    };

    rules = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            apiGroups = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              description = "API groups, `\"\"` for the core group.";
            };
            resources = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              description = "Resource names, such as `pods`.";
            };
            verbs = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              description = "Verbs, such as `get` and `create`.";
            };
            resourceNames = lib.mkOption {
              type = lib.types.nullOr (lib.types.listOf lib.types.str);
              default = null;
              description = "Object names the rule is limited to. Null covers every object.";
            };
          };
        }
      );
      default = [ ];
      example = [
        {
          apiGroups = [ "kubevirt.io" ];
          resources = [ "virtualmachines" ];
          verbs = [
            "create"
            "delete"
            "get"
          ];
        }
      ];
      description = "Role rules in this namespace for the runner pods' ServiceAccount. With none, the runner pods get no API token.";
    };

    extraSpec = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      example = {
        runnerScaleSetName = "linux-x64";
      };
      description = ''
        Merged over the AutoscalingRunnerSet spec the package builds.
        `githubConfigUrl`, `githubConfigSecret`, `minRunners`, `maxRunners`,
        and `template.spec.{serviceAccountName,automountServiceAccountToken,priorityClassName}`
        are refused. Entries of `template.spec.containers` are matched by
        name: the `runner` entry is merged over the package's runner
        container (except `image`, `env`, and `resources`, which have
        options), and other entries are added as further containers.
      '';
    };
  };

  build =
    {
      self,
      config,
      arc,
      githubConfigSecret,
      priorityClass ? null,
      ...
    }:
    let
      creds = kix.contracts.secret.helpers.use {
        inherit who;
        arg = "githubConfigSecret";
        dep = githubConfigSecret;
        anyOf = [
          [ "github_token" ]
          [
            "github_app_id"
            "github_app_installation_id"
            "github_app_private_key"
          ]
        ];
      };

      env = kix.mkEnvVars (kix.mergeEnv { inherit who; } config.env);
      runner = {
        name = "runner";
        image = kix.image.ref config.image;
        command = [ "/home/runner/run.sh" ];
      }
      // lib.optionalAttrs (config.image.pullPolicy != null) {
        imagePullPolicy = config.image.pullPolicy;
      }
      // lib.optionalAttrs (env != [ ]) { inherit env; }
      // lib.optionalAttrs (config.resources != { }) { inherit (config) resources; };

      problem = import ./checks.nix { inherit lib name; } config;

      extra = config.extraSpec;
      extraContainers = lib.attrByPath [ "template" "spec" "containers" ] [ ] extra;
      extraWithoutContainers =
        if lib.hasAttrByPath [ "template" "spec" "containers" ] extra then
          extra
          // {
            template = extra.template // {
              spec = removeAttrs extra.template.spec [ "containers" ];
            };
          }
        else
          extra;
      runnerOverride = lib.findFirst (c: c.name == "runner") { } extraContainers;
      containers = [
        (lib.recursiveUpdate runner runnerOverride)
      ]
      ++ builtins.filter (c: c.name != "runner") extraContainers;

      baseSpec = {
        inherit (config) githubConfigUrl minRunners maxRunners;
        githubConfigSecret = creds.out.name;
        template.spec = {
          restartPolicy = "Never";
          automountServiceAccountToken = config.rules != [ ];
        }
        // lib.optionalAttrs (priorityClass != null) { priorityClassName = priorityClass.out.name; };
      };

      spec = lib.recursiveUpdate (kix.mergeGuarded {
        inherit who locked;
      } baseSpec extraWithoutContainers) { template.spec = { inherit containers; }; };

      parts =
        if problem != null then
          scope.fail problem
        else
          arc.out.mkAutoscalingRunnerSet scope { inherit name spec; };

      runnerRbac = scope.rbac.mkRoleSet scope {
        subjects = [
          {
            kind = "ServiceAccount";
            name = parts.runnerServiceAccount.out.name;
            namespace = ns;
          }
        ];
        roles."${name}-runner" = map (r: lib.filterAttrs (_: v: v != null) r) config.rules;
      };
    in
    parts
    // lib.optionalAttrs (config.rules != [ ]) {
      runnerRole = runnerRbac."${name}-runner";
      runnerRoleBinding = runnerRbac."${name}-runner-binding";
    }
    // {
      # Jobs reach arbitrary hosts and protocols. Cilium's `world` entity
      # excludes the API server, which needs its own rule.
      runnerEgress = kix.operandPolicy {
        inherit scope;
        name = "${name}-runner-egress";
        spec =
          let
            netpol = scope.networkPolicyEnforcer.netpol;
          in
          netpol.mkEndpointSelector (arc.out.operandSelectors.runner name)
          // {
            egress =
              (netpol.translateIntentRules {
                intents.runner.egress = [
                  { to = "dns"; }
                  { to = "world"; }
                ]
                ++ lib.optional (config.rules != [ ]) { to = "apiserver"; };
              }).egressRules;
          };
      };

      root = {
        resource = self.autoscalingRunnerSet;
        requires = [
          self.runnerServiceAccount
          self.managerRoleBinding
        ]
        ++ lib.optional (config.rules != [ ]) self.runnerRoleBinding
        ++ lib.optional (self.runnerEgress != null) self.runnerEgress;
        out.extraImages = [ (kix.image.ref config.image) ];
        out.version = kix.image.version config.image;
      };
    };
}
