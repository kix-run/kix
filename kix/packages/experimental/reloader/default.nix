# reloader: Stakater Reloader, which restarts a Deployment, DaemonSet, or
# StatefulSet when a Secret it names in `secret.reloader.stakater.com/reload`
# changes. `out.withReloadOn` writes that annotation for Secrets Kix does not
# build (scope.mkSecretRef, a secret-ref dependency). `out.version` is the
# Reloader version `image.tag` names. A workload rolls on a
# change to a Kix-built Secret or ConfigMap through a `checksum/<name>` pod
# annotation instead, which the deploy plan shows.
#
#   deployment = { name = "web"; spec = { ... }; }
#     |> reloader.out.withReloadOn [ self.apiToken ]
#     |> scope.mkDeployment;
#
# A minimal instance is `instances.<ns>.reloader.package = packages.experimental.reloader;`.
# It installs a ServiceAccount, the RBAC for Secrets and workloads, a
# leader-election Role and RoleBinding, and the Deployment, plus a
# PodDisruptionBudget at `node` and `zone`. The RBAC is a ClusterRole, or a
# Role in each namespace that `--namespaces=a,b` lists. With a `prometheus`
# dependency and `metrics.enabled`, it also installs a Service, a
# ServiceMonitor, and alerts.
#
# Each new leader replays every watched Secret and restarts the workloads
# whose Secret changed since reloader last acted, so a rotation made while no
# leader runs is applied when one starts. A workload reloader has not
# restarted before restarts once the first time a leader sees it. The replay
# issues about three LIST requests per watched Secret; `--namespaces` bounds
# it.
#
# Reloader ignores ConfigMaps, Jobs, and CronJobs here. It still honours a
# `reloader.stakater.com/auto` or `secret.reloader.stakater.com/auto`
# annotation written on a workload, for every Secret the workload reads, so
# a change to a Kix-built Secret restarts that workload twice.
#
# One instance per cluster: the annotation-domain index and `conflictsWith`
# each refuse a second instance whatever its aliases. The index runs first,
# so its message is the one shown.
#
# Escape hatches: `extraArgs` and `env` (the flags and variables the package
# sets are refused), and `partsOverlays` on `deployment` for placement.
#
# Upgrades: the flags, RBAC rules, Lease name, probe paths, and port are the
# same in 1.4.22 and 1.4.24, so the first deploy restarts the reloader pods
# once, and the new leader takes over the Lease about 15 to 20 seconds later.
# Reloader 1.4.24 no longer serves `/debug/pprof` on port 9090. The
# `--enable-pprof` flag serves it on port 6060 of each pod instead. To go
# back, deploy the previous Kix version: reloader 1.4.22 takes the Lease from
# 1.4.24 and restarts a workload when its Secret changes.

{
  scope,
  lib,
  kix,
  availability,
}:
let
  release = "v1.4.24";
  name = scope.instanceName;
  reloadAnnotation = "secret.reloader.stakater.com/reload";

  # Flags the package sets no value for and still owns.
  refusedFlags = [
    {
      names = [ "--auto-reload-all" ];
      reason = "--auto-reload-all would also restart workloads for Kix-built Secrets, which already roll through checksum/<name> pod annotations.";
    }
    {
      names = [ "--webhook-url" ];
      reason = "setting --webhook-url makes reloader send a webhook instead of restarting workloads.";
    }
    {
      names = [
        "--configmap-annotation"
        "--secret-annotation"
        "--auto-annotation"
        "--ignore-annotation"
        "--configmap-auto-annotation"
        "--secret-auto-annotation"
        "--auto-search-annotation"
        "--search-match-annotation"
        "--pause-deployment-annotation"
        "--pause-deployment-time-annotation"
      ];
      reason = "out.withReloadOn and Kix's annotation checks expect the default annotation names.";
    }
    # Flags the package neither sets nor supports: each needs RBAC the
    # package does not grant.
    {
      names = [ "--namespace-selector" ];
      reason = "--namespace-selector requires permission to read Namespaces, which this package's RBAC does not grant.";
    }
    {
      names = [ "--is-Argo-Rollouts" ];
      reason = "--is-Argo-Rollouts requires permission to update argoproj.io Rollouts, which this package's RBAC does not grant.";
    }
    {
      names = [ "--enable-csi-integration" ];
      reason = "--enable-csi-integration requires permission to watch secrets-store.csi.x-k8s.io resources, which this package's RBAC does not grant.";
    }
  ];

  # Flags whose values withReloadOn checks. Each is a pflag string slice:
  # repeats add to the list and each value is split on commas.
  readFlags = [
    "--namespaces"
    "--namespaces-to-ignore"
    "--resource-label-selector"
  ];
  valuesOf =
    extraArgs: flag:
    builtins.filter (v: v != "") (
      lib.concatMap (lib.splitString ",") (kix.argValues { parser = "gnu"; } flag extraArgs)
    );

  fieldRef = path: { valueFrom.fieldRef.fieldPath = path; };
in
{
  meta = {
    version = release;
    description = "Stakater Reloader, which restarts workloads when a Secret they reference changes outside Kix";
    owner = "platform";
    defaultAliases = [ "reloader" ];
    # One instance per cluster; see the header.
    conflictsWith = [ "cluster:reloader" ];
    # The README's Compatibility section states an open range.
    k8s = {
      minVersion = "1.19";
      reason = "[K8986] reloader ${release} supports Kubernetes 1.19 or later. Move the cluster to Kubernetes 1.19 or later, or use a Kix release whose reloader package still accepts it";
    };
    # The domains of the annotations this configuration reads. The index
    # matches a domain exactly, so each subdomain is listed.
    annotationDomains = [
      "reloader.stakater.com"
      "secret.reloader.stakater.com"
      "secrets.exclude.reloader.stakater.com"
      "deployment.reloader.stakater.com"
    ];
  };

  # The flags in args, refusedFlags, and the RBAC rules follow `release`,
  # and another release may lack a flag or need other rules.
  assertions =
    { config, ... }:
    [
      (kix.image.checkRelease {
        inherit (config) image;
        inherit release;
        reason = "this package's flags and RBAC rules are written for Reloader ${release}";
        fix = "To update this package to another version, change release in kix/packages/experimental/reloader/default.nix and check its flags against internal/pkg/util/util.go and its RBAC rules against the chart's clusterrole.yaml for that version.";
      })
    ];

  options = {
    image = kix.options.image {
      repository = "ghcr.io/stakater/reloader";
      tag = release;
      digest = "sha256:3ab43d3eb96c59798644bf826b0444a846c0197d22ab4b6c101c4da3e1d6ef23";
    };

    # The informer caches every Secret in the watched namespaces.
    resources = kix.options.resources {
      requests = {
        cpu = "10m";
        memory = "64Mi";
      };
      limits = {
        cpu = "200m";
        memory = "256Mi";
      };
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "--log-level=debug"
        "--namespaces=apps,jobs"
      ];
      description = ''
        Flags appended after the package's own, which include
        `--log-format=json` (a later one wins). `--namespaces=a,b` limits
        reloader to those namespaces, each of which must be a namespace of
        the cluster, and replaces the ClusterRole with a Role in each.
        `--namespaces-to-ignore=a,b` skips namespaces. `withReloadOn`
        refuses a Secret outside what this reloader watches, and refuses
        every Secret while `--resource-label-selector` is set.
        `--namespaces` and `--namespaces-to-ignore` cannot be combined.

        Refused: the flags that set the reload strategy (`--enable-ha`,
        `--reload-strategy`, `--reload-on-create`, `--sync-after-restart`,
        `--ignored-workload-types`, `--resources-to-ignore`),
        `--auto-reload-all`, `--webhook-url`, the `--*-annotation` flags,
        and `--namespace-selector`, `--is-Argo-Rollouts`, and
        `--enable-csi-integration`, which need access the package does not
        grant.
      '';
    };

    env = kix.options.env;

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
        inherit (scope.rbac)
          core
          group
          grant
          watch
          allow
          emit
          restrictTo
          mkClusterRoleSet
          mkRoleSet
          ;
        apps = group "apps" [
          "deployments"
          "daemonsets"
          "statefulsets"
        ];
        coordination = group "coordination.k8s.io" [ "leases" ];

        subjects = [
          {
            kind = "ServiceAccount";
            name = self.serviceAccount.out.name;
            namespace = scope.namespaceName;
          }
        ];

        # reloader parses flags with cobra and pflag
        # (internal/pkg/cmd/reloader.go upstream).
        args = kix.mergeArgs {
          inherit scope;
          parser = "gnu";
          args = [
            "--log-format=json"
            {
              flags = [ "--enable-ha=true" ];
              reason = "leader election keeps one replica restarting workloads when multiple replicas run.";
            }
            # With --sync-after-restart and --reload-on-create, the leader's
            # initial list counts as a change to every Secret. The env-vars
            # strategy then restarts only workloads whose stored
            # STAKATER_<NAME>_SECRET hash differs from the Secret's.
            {
              flags = [
                "--reload-strategy=env-vars"
                "--reload-on-create=true"
                "--sync-after-restart=true"
              ];
              reason = "these flags let a new leader replay every Secret while restarting only workloads whose Secret changed.";
            }
            # A reload of a CronJob creates a Job and stores no hash, so
            # every replay would run it again. Job pods read the Secret when
            # they start.
            {
              flags = [ "--ignored-workload-types=jobs,cronjobs" ];
              reason = "reloading a CronJob starts an extra Job on every leader replay, and Job pods already read the current Secret when they start.";
            }
            {
              flags = [ "--resources-to-ignore=configmaps" ];
              reason = "this package watches Secrets only; Kix-built ConfigMaps roll their workloads through checksum/<name> pod annotations.";
            }
          ]
          ++ refusedFlags;
        } config.extraArgs;

        read = lib.genAttrs readFlags (valuesOf config.extraArgs);
        watched = lib.unique read."--namespaces";
        ignored = read."--namespaces-to-ignore";
        labelSelector = read."--resource-label-selector";
        _flagsCheck =
          if watched != [ ] && ignored != [ ] then
            scope.fail {
              option = "extraArgs";
              message = "extraArgs sets both --namespaces and --namespaces-to-ignore. reloader ignores --namespaces-to-ignore when --namespaces is set.";
              fix = "Remove one.";
            }
          else
            null;

        env = kix.mkEnvVars (
          kix.mergeEnv {
            inherit scope;
            owned = [
              {
                vars = {
                  POD_NAME = fieldRef "metadata.name";
                  POD_NAMESPACE = fieldRef "metadata.namespace";
                };
                from = "the pod's own metadata, which leader election reads";
                fix = "Remove it.";
              }
              {
                vars.GOMEMLIMIT.valueFrom.resourceFieldRef = {
                  containerName = "reloader";
                  resource = "limits.memory";
                };
                from = "the container's memory limit";
                fix = "Change resources.limits.memory instead.";
              }
              {
                names = [ "RELOADER_NAMESPACE" ];
                from = "the package, and the package leaves it unset so that reloader writes no reloader-meta-info ConfigMap, which its RBAC does not allow";
                fix = "Remove it.";
              }
              {
                names = [ "KUBERNETES_NAMESPACE" ];
                from = "the package, and the package leaves it unset because it limits reloader to one namespace that neither withReloadOn nor the RBAC follows";
                fix = "Use extraArgs = [ \"--namespaces=<ns>\" ] instead.";
              }
            ];
          } config.env
        );

        # The Secret behind a withReloadOn element: a scope.mkSecretRef marker,
        # or the root of a dependency instance.
        unwrap =
          r:
          if (r._type or null) == "k8s-instance" then
            if r ? raw then r.raw.root.resource or r.raw.root else r.root
          else
            r;

        secretName =
          prefix: r:
          let
            res = unwrap r;
            kind = res.kind or null;
            namespace = res.rawManifest.metadata.namespace or r._meta.namespaceName or scope.namespaceName;
            shown = "'${namespace}/${r.out.name or "?"}'";
          in
          if kind == "Secret" || kind == "ConfigMap" then
            scope.fail {
              message = "${prefix} got ${kind} '${r.out.name or "?"}', whose content is part of the build.";
              fix = "Put \"checksum/<name>\" = <ref>.out.contentHash on the pod template instead, so the rollout appears in the deploy plan. reloader would restart the workload a second time.";
            }
          else if !(kind == "PackageInstance" && r ? out.keyRef) then
            scope.fail {
              message = "${prefix} takes Secrets from scope.mkSecretRef or a secret-ref dependency; got ${
                if kind != null then kind else r._type or (builtins.typeOf r)
              }.";
            }
          else if labelSelector != [ ] then
            scope.fail {
              option = "extraArgs";
              message = "${prefix}: reloader watches only Secrets labelled ${lib.concatStringsSep "," labelSelector}, and Kix cannot check that Secret ${shown}, created outside Kix, carries them.";
              fix = "Remove --resource-label-selector to use withReloadOn.";
            }
          else if (watched != [ ] && !builtins.elem namespace watched) || builtins.elem namespace ignored then
            scope.fail {
              option = "extraArgs";
              message = "${prefix}: Secret ${shown} is in a namespace this reloader does not watch (extraArgs ${
                if watched != [ ] then
                  "--namespaces=${lib.concatStringsSep "," watched}"
                else
                  "--namespaces-to-ignore=${lib.concatStringsSep "," ignored}"
              }).";
              fix =
                if watched != [ ] then
                  "Add ${namespace} to --namespaces."
                else
                  "Remove ${namespace} from --namespaces-to-ignore.";
            }
          else
            r.out.name;

        # Errors name the workload from `args.name`, since the mistake is in
        # the consumer's build.
        withReloadOn =
          refs: args:
          let
            prefix = "withReloadOn for '${args.name or "?"}'";
            existing = (args.annotations or { }).${reloadAnnotation} or null;
            existingNames = lib.optionals (existing != null) (
              lib.splitString "," (builtins.unsafeDiscardStringContext existing)
            );
            names = builtins.filter (n: !builtins.elem n existingNames) (
              lib.unique (map (secretName prefix) refs)
            );
            restartPolicy = args.spec.template.spec.restartPolicy or null;
          in
          if !builtins.isList refs || refs == [ ] then
            scope.fail {
              message = "${prefix} needs a non-empty list of Secrets.";
            }
          else if args ? _type then
            scope.fail {
              message = "${prefix} takes builder args; pipe them through it before scope.mkDeployment.";
            }
          else if args ? spec.jobTemplate || restartPolicy == "Never" || restartPolicy == "OnFailure" then
            scope.fail {
              message = "${prefix}: Job and CronJob pods read the Secret when they start; this reloader ignores them (--ignored-workload-types).";
            }
          else if !(args ? spec.template) then
            scope.fail {
              message = "${prefix}: reloader restarts only Deployments, DaemonSets, and StatefulSets, and these args have no spec.template.";
              fix = "Pass the builder args of one of those kinds.";
            }
          else
            args
            // {
              annotations = (args.annotations or { }) // {
                ${reloadAnnotation} = lib.concatStringsSep "," (lib.optional (existing != null) existing ++ names);
              };
            };

        workloadRules = grant [
          (core.secrets |> watch)
          (
            [
              apps.deployments
              apps.daemonsets
              apps.statefulsets
            ]
            |> allow [
              "list"
              "get"
              "update"
              "patch"
            ]
          )
          (core.events |> emit)
        ];
        # With --namespaces, reloader starts its controllers only in the
        # listed namespaces, so a Role in each replaces the ClusterRole. The
        # parts are named `<instance>-in-<namespace>` and
        # `<instance>-binding-in-<namespace>`.
        workloadRbac =
          if watched == [ ] then
            mkClusterRoleSet scope {
              inherit subjects;
              labels = scope.selectorLabels;
              roles.${name} = workloadRules;
            }
          else
            lib.foldl' (
              acc: ns:
              acc
              // lib.mapAttrs' (part: lib.nameValuePair "${part}-in-${ns}") (
                mkRoleSet (scope.forNamespace ns) {
                  inherit subjects;
                  labels = scope.selectorLabels;
                  roles.${name} = workloadRules;
                }
              )
            ) { } watched;
      in
      builtins.seq _flagsCheck {
        serviceAccount = scope.mkResource {
          apiVersion = "v1";
          kind = "ServiceAccount";
          inherit name;
        };

        deployment =
          {
            inherit name;
            spec = {
              # With the replay, a crash at `pod` delays a restart until the
              # pod is back but does not lose it. A standby at `node` and
              # `zone` takes the lease without waiting for a reschedule.
              replicas = kix.availability.pick availability {
                none = 1;
                pod = 1;
                node = 2;
                zone = 2;
              };
              selector.matchLabels = scope.selectorLabels;
              template.spec = {
                serviceAccount = self.serviceAccount;
                # The binary exits on SIGTERM without releasing its Lease, so
                # a standby takes over when the Lease expires
                # (--leader-election-lease-duration, 15s by default). 30 is the
                # Kubernetes default, written out because the
                # reliability.gracefulShutdown scorecard rule reports a pod
                # spec without the field.
                terminationGracePeriodSeconds = 30;
                securityContext = {
                  runAsNonRoot = true;
                  runAsUser = 65532;
                  runAsGroup = 65532;
                  seccompProfile.type = "RuntimeDefault";
                };
                containers = [
                  {
                    name = "reloader";
                    image = kix.image.ref config.image;
                    imagePullPolicy = config.image.pullPolicy;
                    inherit args env;
                    ports = [ (kix.port "http" 9090) ];
                    # A follower serves both endpoints too, so every replica
                    # is Ready.
                    livenessProbe = {
                      httpGet = {
                        path = "/live";
                        port = "http";
                      };
                      periodSeconds = 10;
                      failureThreshold = 5;
                    };
                    readinessProbe = {
                      httpGet = {
                        path = "/metrics";
                        port = "http";
                      };
                      periodSeconds = 10;
                      failureThreshold = 5;
                    };
                    inherit (config) resources;
                    securityContext = {
                      allowPrivilegeEscalation = false;
                      readOnlyRootFilesystem = true;
                      capabilities.drop = [ "ALL" ];
                    };
                  }
                ];
              };
            };
          }
          |> scope.mkDeployment;

        service =
          if config.metrics.enabled && prometheus != null then
            self.deployment |> kix.service.fromWorkload { inherit name; } |> scope.mkResource
          else
            null;

        root = {
          resource = self.deployment;
          out = {
            inherit withReloadOn;
            version = kix.image.version config.image;
          };
        };
      }
      // workloadRbac
      // mkRoleSet scope {
        inherit subjects;
        labels = scope.selectorLabels;
        roles."${name}-leader-election" = grant [
          (coordination.leases |> allow [ "create" ])
          # The binary names its Lease with the constant LockName.
          (
            coordination.leases
            |> restrictTo [ "stakater-reloader-lock" ]
            |> allow [
              "get"
              "update"
            ]
          )
        ];
      }
    )

    (kix.monitor {
      service = "service";
      port = "http";
      alerts =
        let
          # The Service the scrape goes through is named after the instance.
          selector = ''namespace="${scope.namespaceName}",service="${name}"'';
        in
        {
          # No `for`: the 15-minute window already spans a restart.
          ReloaderReloadFailed = {
            expr = ''increase(reloader_reload_executed_total{success="false",${selector}}[15m]) > 0'';
            "for" = "0m";
            severity = "warning";
            summary = "reloader ${scope.namespaceName}/${name} failed to restart a workload after a Secret change";
            description = "Reloader in ${scope.namespaceName} failed to restart a workload in the last 15 minutes ({{ $value | humanize }} failures), so a workload may still run with an old Secret or ConfigMap. Check the reloader pod's log for the workload it names.";
          };
          ReloaderDown = {
            expr = "sum by (namespace, service) (up{${selector}}) == 0 or absent(up{${selector}})";
            "for" = "10m";
            severity = "warning";
            summary = "no reloader pod in ${scope.namespaceName}/${name} is up; Secret rotations are applied once one is";
            description = "Prometheus has scraped no reloader target of {{ $labels.namespace }}/{{ $labels.service }} for 10 minutes. Workloads are not restarted after a Secret or ConfigMap changes until reloader runs again. Check Deployment ${scope.namespaceName}/${name}.";
          };
        };
    })
  ];
}
