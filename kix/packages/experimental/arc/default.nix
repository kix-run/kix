# arc: the GitHub Actions Runner Controller (gha-runner-scale-set-controller),
# which reconciles AutoscalingRunnerSets into a listener pod per runner set and
# ephemeral runner pods for queued jobs.
#
# The package renders the controller Deployment, its RBAC, and the four
# actions.github.com custom resource definitions. Runner sets come from the
# `arc-runner-set` package, or from `out.mkAutoscalingRunnerSet` in a package
# of your own.
#
# A cluster runs one instance: the CRDs and the ClusterRole are cluster-wide,
# and runner sets in any namespace find the controller through the `arc`
# alias. A second instance, including one auto-instantiated in another
# namespace, fails evaluation with an error naming both.
#
#   instances.arc-systems.arc.package = packages.experimental.arc;
#
# Listener pods run in this instance's namespace and connect to GitHub on TCP
# 443; runner pods run in the runner set's namespace. With an enforcer the
# package adds a policy for the listeners (`listenerEgress`); each runner set
# adds one for its runners.
#
# Removal: remove the runner sets first, then their secrets and this
# instance in a later deploy. A runner set's finalizer needs the controller
# and the GitHub credentials to deregister the scale set, and prune deletes
# without waiting for finalizers, so removing them together leaves the
# AutoscalingRunnerSet and its supporting objects Terminating. Every ARC
# kind names the controller Deployment as its `controller`, so a prune
# deletes the runner sets before the controller and waits for them, but it
# does not order the credentials Secret.
#
# Changing `release` to another minor version: the new controller deletes
# every AutoscalingRunnerSet that still carries the old version label, and
# the same deploy applies the relabelled one. When the deletion runs last,
# the runner set is gone after a successful deploy. Run
# `kix deploy --reconcile` after that deploy to re-create the runner sets
# and the finalizers on their supporting objects.
#
# Upgrades: 0.15.1 takes over what 0.14.2 left behind: the CRDs keep the
# v1alpha1 version, and the controller reconciles existing runner sets.
# The move from 0.14 is a minor version change, so the paragraph above
# applies. Going back to 0.14.2 is also a minor version change. Deploy the
# older package, then run `kix deploy --reconcile`. Upstream documents no
# upgrade path between minor versions and no way back. GitHub supports
# only the latest release.
#
# Not modelled: `--watch-single-namespace` and image pull secrets for the
# listener. Escape hatches: `extraArgs`, `env`, `partsOverlays`, `extra`.
#
# Dependencies:
#   prometheus (optional)  metrics Service, ServiceMonitor `<name>`,
#                          PodMonitor `<name>-listeners`, and alerts.
#
# Alerts: with a prometheus dependency and `metrics.enabled`, a
# PrometheusRule `<instance>-alerts` selects the controller's metrics
# Service. The controller's own series carry the runner set's namespace as
# `exported_namespace`, because the scrape keeps the target's `namespace`.
#   ArcControllerDown (warning)             the controller answers no
#                                           scrape. Running jobs finish; no
#                                           runner set scales, and no new
#                                           runner starts.
#   ArcControllerReconcileErrors (warning)  reconciles fail, such as a
#                                           GitHub API error or a refused
#                                           credential.
#   ArcEphemeralRunnersFailed (warning)     a runner set holds failed
#                                           ephemeral runners. The
#                                           controller keeps them until they
#                                           are deleted, and they count
#                                           against `maxRunners`.
# A listener that crash-loops is left to prometheus-default-rules
# (KubePodCrashLooping). The listeners' job metrics (`gha_*`) are scraped
# for dashboards; queue time against capacity is the site's to judge.
#
# `out`:
#   out.mkAutoscalingRunnerSet consumerScope { name; spec; }
#       The AutoscalingRunnerSet and the three objects the controller expects
#       beside it; see runner-set.nix.
#   out.crds.{AutoscalingRunnerSet,AutoscalingListener,EphemeralRunnerSet,
#             EphemeralRunner}
#   out.operandSelectors.runner <runner set name>, out.operandSelectors.listener
#       Labels the controller puts on runner pods and listener pods.
#   out.version
#       The controller version `image.tag` names.
#
# root = the controller Deployment.

{
  scope,
  lib,
  kix,
  availability,
}:

let
  # The upstream release: meta.version, image.tag, and the chart tag in
  # crds/sources.txt.
  release = "0.15.1";

  name = scope.instanceName;
  ns = scope.namespaceName;

  metricsPort = 8080;
  healthPort = 8081;

  # Return whether the controller's parseSemver (apis/actions.github.com/
  # v1alpha1/version.go) accepts a tag. It rejects tags such as "v0.15.1"
  # or "0.15.x". The tag becomes every runner set's version label, and the
  # controller deletes a runner set whose label it cannot parse.
  controllerParses =
    t: builtins.match "(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(\\.(0|[1-9][0-9]*)([^0-9].*)?)?" t != null;

  # GitHub's API and the Actions service. `meta.network.intents` cannot read
  # the instance's config, so under an enforcer the controller cannot reach a
  # GitHub Enterprise Server on another port; the listeners' `listenerEgress`
  # part can be changed with partsOverlays.
  githubEgress = [
    {
      to = "world";
      ports = [
        {
          port = 443;
          protocol = "TCP";
        }
      ];
    }
  ];

  # Labels the controller puts on every listener pod, and on the runner pods
  # of the AutoscalingRunnerSet named `setName` (resourcebuilder.go).
  listenerSelector = {
    "app.kubernetes.io/part-of" = "gha-runner-scale-set";
    "app.kubernetes.io/component" = "runner-scale-set-listener";
  };
  runnerSelector = setName: {
    "actions.github.com/scale-set-name" = setName;
    "app.kubernetes.io/component" = "runner";
  };

  # The controller copies an AutoscalingRunnerSet's labels onto the objects
  # it creates from it. Without these exclusions the listeners and runners
  # carry Kix's instance labels, `kix gc` reports them, and this instance's
  # selectors match them. A prefix also drops controller-written keys that
  # start with it, so none may prefix app.kubernetes.io/{part-of,component,
  # version}, actions.github.com/*, runner-template-hash, pod-template-hash,
  # or kubernetes.io/os.
  excludedLabelPrefixes = [
    "app.kubernetes.io/name"
    "app.kubernetes.io/instance"
    "app.kubernetes.io/managed-by"
  ];

  vendored =
    plural: (builtins.fromJSON (builtins.readFile ./crds/${plural}.actions.github.com.json)).spec;

  inherit (scope.rbac)
    group
    core
    grant
    full
    allow
    sub
    ;
  actions = group "actions.github.com" [
    "autoscalingrunnersets"
    "autoscalinglisteners"
    "ephemeralrunnersets"
    "ephemeralrunners"
  ];
  actionResources = builtins.attrValues (removeAttrs actions [ "__functor" ]);
  rbacGroup = group "rbac.authorization.k8s.io" [
    "rolebindings"
    "roles"
  ];
  coordination = group "coordination.k8s.io" [ "leases" ];

  # manager_cluster_role.yaml, manager_listener_role.yaml and
  # leader_election_role.yaml of the gha-runner-scale-set-controller chart.
  clusterRules = grant [
    (
      [
        core.pods
        core.serviceaccounts
      ]
      |> allow [
        "list"
        "watch"
      ]
    )
    (actionResources |> full)
    (
      map (sub "finalizers") actionResources
      |> allow [
        "patch"
        "update"
      ]
    )
    (
      map (sub "status") actionResources
      |> allow [
        "get"
        "patch"
        "update"
      ]
    )
    (
      rbacGroup.rolebindings
      |> allow [
        "list"
        "watch"
      ]
    )
    (
      rbacGroup.roles
      |> allow [
        "list"
        "watch"
        "patch"
      ]
    )
  ];
  listenerRules = grant [
    (
      core.pods
      |> allow [
        "create"
        "delete"
        "get"
        "patch"
      ]
    )
    (core "pods/status" |> allow [ "get" ])
    (
      [
        core.secrets
        core.serviceaccounts
      ]
      |> allow [
        "create"
        "delete"
        "get"
        "patch"
        "update"
      ]
    )
  ];
  leaderElectionRules = grant [
    (coordination.leases |> full)
    (
      core.events
      |> allow [
        "create"
        "patch"
      ]
    )
  ];
in
{
  meta = {
    version = release;
    description = "GitHub Actions Runner Controller (gha-runner-scale-set-controller), which reconciles AutoscalingRunnerSets into listener pods and ephemeral runner pods";
    owner = "platform";
    defaultAliases = [ "arc" ];
    # One instance per cluster; see the header.
    conflictsWith = [ "cluster:arc" ];
    annotationDomains = [ "actions.github.com" ];
    network.intents.github.egress = githubEgress;
  };

  assertions =
    { config, ... }:
    [
      (
        let
          imageTag = builtins.unsafeDiscardStringContext config.image.tag;
        in
        {
          assertion = controllerParses imageTag;
          message = "image.tag \"${imageTag}\" is not a version the controller can parse. Kix rejected it because the controller writes this tag to every runner set's version label and deletes any runner set whose label it cannot parse. Set image.tag to a major.minor.patch version without a \"v\" prefix or leading zeros (such as \"${release}\"), or remove image.tag to use the default.";
        }
      )
      (kix.image.checkRelease {
        inherit (config) image;
        inherit release;
        reason = "the CRDs in kix/packages/experimental/arc/crds come from ${release}";
        fix = "To update this package to another version, change release in kix/packages/experimental/arc/default.nix and run uv run scripts/vendor-crds.py arc.";
      })
    ];

  options = {
    image = kix.options.image {
      repository = "ghcr.io/actions/gha-runner-scale-set-controller";
      tag = release;
      digest = "sha256:4b51a20db717b194e2f3fa96cfe2ddcb21602811f79053c75fd1a383517b9f90";
      description = "Image of the controller, which the listener pods also run. Its major.minor must match the vendored CRDs, and it becomes the version label of every runner set.";
    };

    resources = kix.options.resources {
      requests = {
        cpu = "200m";
        memory = "256Mi";
      };
      limits = {
        cpu = "1";
        memory = "512Mi";
      };
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "--log-level=debug" ];
      description = "Flags appended after the package's. A repeated `--log-level` or `--log-format` overrides the package's `info` and `text`, because the last value wins. Flags that set the metrics addresses or endpoint, the health address, leader election, or `--auto-scaling-runner-set-only` are refused.";
    };

    env = kix.options.env // {
      description = "Extra environment variables for the controller, such as HTTPS_PROXY. A value is a string, a `fieldRef` source, or a `secretKeyRef` source naming a Secret managed outside Kix with `kix.untrackedRef`. CONTROLLER_MANAGER_CONTAINER_IMAGE and CONTROLLER_MANAGER_POD_NAMESPACE are set by the package and refused.";
    };

    metrics = kix.options.monitor;
  };

  build = [
    (
      {
        self,
        config,
        prometheus ? null,
        ...
      }:
      let
        hasMetrics = config.metrics.enabled && prometheus != null;

        subjects = [
          {
            kind = "ServiceAccount";
            name = self.serviceAccount.out.name;
            namespace = ns;
          }
        ];
        clusterRbac = scope.rbac.mkClusterRoleSet scope {
          inherit subjects;
          roles.${name} = clusterRules;
        };
        namespaceRbac = scope.rbac.mkRoleSet scope {
          inherit subjects;
          roles = {
            "${name}-listener" = listenerRules;
            "${name}-leader-election" = leaderElectionRules;
          };
        };

        # The controller parses flags with Go's flag package (main.go
        # upstream).
        args = kix.mergeArgs {
          inherit scope;
          parser = "go";
          id = "K8006";
          args = [
            {
              flags = [ "--auto-scaling-runner-set-only" ];
              reason = "the controller's RBAC grants permissions for AutoscalingRunnerSets only.";
            }
            {
              flags = [ "--enable-leader-election" ];
              reason = "leader election keeps one controller active when multiple replicas run.";
            }
            {
              flags = [ "--leader-election-id=${name}" ];
              reason = "the leader-election Role in namespace \"${ns}\" grants access to Lease \"${name}\" only.";
            }
            "--log-level=info"
            "--log-format=text"
            {
              flags = [ "--metrics-addr=:${toString metricsPort}" ];
              reason = "the metrics Service and ServiceMonitor use port ${toString metricsPort}.";
            }
            {
              flags = [ "--listener-metrics-addr=:${toString metricsPort}" ];
              reason = "the listener PodMonitor scrapes port ${toString metricsPort}.";
            }
            {
              flags = [ "--listener-metrics-endpoint=/metrics" ];
              reason = "the listener PodMonitor scrapes /metrics.";
            }
            {
              flags = [ "--health-probe-bind-address=:${toString healthPort}" ];
              reason = "the liveness and readiness probes use port ${toString healthPort}.";
            }
          ]
          ++ map (p: "--exclude-label-propagation-prefix=${p}") excludedLabelPrefixes;
        } config.extraArgs;

        env = kix.mkEnvVars (
          kix.mergeEnv {
            inherit scope;
            owned = [
              {
                vars.CONTROLLER_MANAGER_CONTAINER_IMAGE = kix.image.ref config.image;
                from = "the image option, which the listener pods also run";
                fix = "Set the image option instead.";
              }
              {
                vars.CONTROLLER_MANAGER_POD_NAMESPACE.valueFrom.fieldRef.fieldPath = "metadata.namespace";
                from = "the pod's namespace, where the controller creates the listener pods";
                fix = "Remove it.";
              }
            ];
          } config.env
        );

        listenerEgress = kix.operandPolicy {
          inherit scope;
          name = "${name}-listener-egress";
          spec =
            let
              netpol = scope.networkPolicyEnforcer.netpol;
            in
            netpol.mkEndpointSelector listenerSelector
            // {
              egress =
                (netpol.translateIntentRules {
                  intents.listener.egress = [
                    { to = "dns"; }
                    { to = "apiserver"; }
                  ]
                  ++ githubEgress;
                }).egressRules;
            };
        };

        runnerSet = import ./runner-set.nix {
          inherit
            lib
            ns
            self
            config
            ;
        };
      in
      {
        serviceAccount = scope.mkResource {
          apiVersion = "v1";
          kind = "ServiceAccount";
          inherit name;
        };

        clusterRole = clusterRbac.${name};
        clusterRoleBinding = clusterRbac."${name}-binding";
        listenerRole = namespaceRbac."${name}-listener";
        listenerRoleBinding = namespaceRbac."${name}-listener-binding";
        leaderElectionRole = namespaceRbac."${name}-leader-election";
        leaderElectionRoleBinding = namespaceRbac."${name}-leader-election-binding";

        # The controller watches all four kinds at start and crash-loops with
        # `no matches for kind` while one is missing. Runners keep no data.
        crds = {
          autoscalingListeners = scope.mkCRD {
            spec = vendored "autoscalinglisteners";
            controller = self.deployment;
            holdsData = false;
          };
          # The controller writes `Pending` when it first sees the runner set
          # and again after every spec change, and `Running` once the scale
          # set is registered with GitHub, its EphemeralRunnerSet is current,
          # and its listener exists. Bad credentials or a wrong URL keep it at
          # `Pending`, so the deploy fails. `Running` sets
          # `status.observedGeneration` to the spec's generation, and Kix
          # waits until it has caught up, so a deploy does not read the
          # `Running` of the previous spec. `Outdated` (a runner image GitHub
          # no longer accepts) holds until the runner spec changes, but is not
          # declared as a failed state. Before the first `Running` the status
          # has no observedGeneration, so Kix cannot tell a new `Outdated`
          # from an old one while a new controller waits for its leader lease.
          autoscalingRunnerSets = scope.mkCRD {
            spec = vendored "autoscalingrunnersets";
            controller = self.deployment;
            holdsData = false;
            readiness = {
              path = "/status/phase";
              equals = "Running";
            };
            # The runner pods dial the addresses in the runner template. The
            # listener's own egress is `listenerEgress`.
            factBehavior = {
              endpoint = "terminate";
              podSelector = cr: runnerSelector cr.metadata.name;
            };
            # Count the minimum idle runner pods (`spec.minRunners`, default 0,
            # capped by `spec.maxRunners`), each with every container in
            # `spec.template`, such as `runner` and a `dind` sidecar. The
            # listener pod runs in the controller's namespace rather than the
            # runner set's namespace.
            usesAtLeast =
              cr:
              kix.usage.times (lib.min (cr.spec.minRunners or 0) (
                cr.spec.maxRunners or (cr.spec.minRunners or 0)
              )) (kix.usage.ofPod (cr.spec.template.spec.containers or [ ]));
          };
          ephemeralRunnerSets = scope.mkCRD {
            spec = vendored "ephemeralrunnersets";
            controller = self.deployment;
            holdsData = false;
          };
          ephemeralRunners = scope.mkCRD {
            spec = vendored "ephemeralrunners";
            controller = self.deployment;
            holdsData = false;
          };
        };

        deployment = scope.mkDeployment {
          inherit name;
          requires = builtins.attrValues self.crds ++ [
            self.clusterRoleBinding
            self.listenerRoleBinding
            self.leaderElectionRoleBinding
          ];
          spec = {
            # Leader-elected: one replica reconciles. From `node` up a
            # standby takes over the lease (controller-runtime's 15 s
            # default) when the leader's node is lost.
            replicas = kix.availability.pick availability {
              none = 1;
              pod = 1;
              node = 2;
              zone = 2;
            };
            selector.matchLabels = scope.selectorLabels;
            template.spec = {
              serviceAccount = self.serviceAccount;
              # Above controller-runtime's 30 second graceful shutdown, so
              # reconciles in flight finish before the kubelet kills the
              # process (the chart's default).
              terminationGracePeriodSeconds = 35;
              securityContext = {
                runAsNonRoot = true;
                seccompProfile.type = "RuntimeDefault";
              };
              containers = [
                {
                  name = "manager";
                  image = kix.image.ref config.image;
                  imagePullPolicy = config.image.pullPolicy;
                  command = [ "/manager" ];
                  inherit args env;
                  ports = [
                    (kix.port "metrics" metricsPort)
                    (kix.port "health" healthPort)
                  ];
                  # Both endpoints are controller-runtime pings (main.go):
                  # they show the process serves HTTP, not that it holds
                  # the lease.
                  livenessProbe = {
                    httpGet = {
                      path = "/healthz";
                      port = "health";
                    };
                    initialDelaySeconds = 15;
                    periodSeconds = 20;
                  };
                  readinessProbe = {
                    httpGet = {
                      path = "/readyz";
                      port = "health";
                    };
                    initialDelaySeconds = 5;
                    periodSeconds = 10;
                  };
                  resources = config.resources;
                  # The image runs as 65532 and writes only to /tmp.
                  securityContext = {
                    allowPrivilegeEscalation = false;
                    capabilities.drop = [ "ALL" ];
                    readOnlyRootFilesystem = true;
                  };
                  volumeMounts = [
                    {
                      name = "tmp";
                      mountPath = "/tmp";
                    }
                  ];
                }
              ];
              volumes = [
                {
                  name = "tmp";
                  emptyDir = { };
                }
              ];
            };
          };
        };

        metricsService =
          if hasMetrics then
            self.deployment
            |> kix.service.fromWorkload {
              name = "${name}-metrics";
              ports = [
                {
                  name = "metrics";
                  port = metricsPort;
                  targetPort = metricsPort;
                  protocol = "TCP";
                }
              ];
            }
            |> scope.mkResource
          else
            null;

        # Listeners run in this namespace and name their metrics port
        # `metrics`.
        listenerPodMonitor =
          if hasMetrics then
            prometheus.out.mkPodMonitor scope {
              name = "${name}-listeners";
              spec = {
                namespaceSelector.matchNames = [ ns ];
                selector.matchLabels = listenerSelector;
                podMetricsEndpoints = [
                  (
                    {
                      # The listener pods are the controller's, so Kix cannot
                      # resolve their port name; the scrape egress rule needs
                      # the number set by --listener-metrics-addr.
                      portNumber = metricsPort;
                      path = "/metrics";
                    }
                    // lib.optionalAttrs (config.metrics.interval != null) { inherit (config.metrics) interval; }
                  )
                ];
              };
            }
          else
            null;

        inherit listenerEgress;

        root = {
          resource = self.deployment;
          requires = [
            self.serviceAccount
          ]
          ++ builtins.attrValues self.crds
          ++ builtins.filter (r: r != null) [
            self.metricsService
            self.listenerEgress
          ];
          out = {
            version = kix.image.version config.image;
            crds = {
              AutoscalingRunnerSet = self.crds.autoscalingRunnerSets;
              AutoscalingListener = self.crds.autoscalingListeners;
              EphemeralRunnerSet = self.crds.ephemeralRunnerSets;
              EphemeralRunner = self.crds.ephemeralRunners;
            };
            inherit (runnerSet) mkAutoscalingRunnerSet;
            operandSelectors = {
              runner = runnerSelector;
              listener = listenerSelector;
            };
          };
        };
      }
    )

    (
      let
        sel = ''namespace="${ns}",service="${name}-metrics"'';
        controller = "Actions Runner Controller ${ns}/${name}";
      in
      kix.monitor {
        service = "metricsService";
        alerts = {
          ArcControllerDown = {
            expr = "sum by (namespace, service) (up{${sel}}) == 0 or absent(up{${sel}})";
            "for" = "10m";
            severity = "warning";
            summary = "The Actions Runner Controller is down.";
            description = "The ${controller} has not answered a scrape for 10 minutes. Running jobs finish, but no runner set scales and no new runner starts, so queued jobs wait. Check the controller Deployment in ${ns}.";
          };
          ArcControllerReconcileErrors = kix.reconcileErrorsAlert {
            selector = sel;
            operator = controller;
            summary = "The Actions Runner Controller fails to reconcile runner sets.";
            impact = "runner sets may not scale";
            nextStep = "Check the controller logs for the error. Common causes are GitHub API errors or rejected credentials.";
          };
          # The gauge counts EphemeralRunners in phase Failed. The runner
          # set counts them with its pending and running runners
          # (ephemeralrunnerset_controller.go upstream).
          ArcEphemeralRunnersFailed = {
            expr = "max by (namespace, service, exported_namespace, name) (gha_controller_failed_ephemeral_runners{${sel}}) > 0";
            "for" = "15m";
            severity = "warning";
            summary = "A GitHub Actions runner set holds failed runners.";
            description = "Runner set {{ $labels.exported_namespace }}/{{ $labels.name }} has held {{ $value | humanize }} failed ephemeral runners for 15 minutes. They stay until deleted and count against the set's maximum, so fewer jobs can run. Read the events of the failed EphemeralRunners in {{ $labels.exported_namespace }}, then delete them.";
          };
        };
      }
    )
  ];
}
