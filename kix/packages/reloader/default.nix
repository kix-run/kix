# reloader: Stakater Reloader, which restarts a Deployment, DaemonSet, or
# StatefulSet when a Secret it names in `secret.reloader.stakater.com/reload`
# changes. `out.withReloadOn` writes that annotation for Secrets Kix does not
# build (scope.mkSecretRef, a secret-ref dependency). A workload rolls on a
# change to a Kix-built Secret or ConfigMap through a `checksum/<name>` pod
# annotation instead, which the deploy plan shows.
#
#   deployment = { name = "web"; spec = { ... }; }
#     |> reloader.out.withReloadOn [ self.apiToken ]
#     |> scope.mkDeployment;
#
# A minimal instance is `instances.<ns>.reloader.package = packages.reloader;`.
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
# One instance per cluster: the annotation-domain index refuses a second
# instance whatever its aliases. `conflictsWith` also refuses one while
# either instance has the alias `reloader`, but the index runs first, so its
# message is the one shown.
#
# Escape hatches: `extraArgs` and `env` (the flags and variables the package
# sets are refused), and `partsOverlays` on `deployment` for placement.

{
  scope,
  lib,
  kix,
  availability,
}:
let
  release = "v1.4.22";
  name = scope.instanceName;
  who = "reloader ${scope.namespaceName}/${name}";
  reloadAnnotation = "secret.reloader.stakater.com/reload";

  # Reasons follow guardArgs' "which the package owns: ".
  replay = "the package sets it so that each new leader replays every Secret and restarts only the workloads whose Secret changed. Remove it.";
  annotationName = "withReloadOn and meta.annotationDomains use the default annotation names. Remove it.";
  ownedFlags = {
    "--enable-ha" =
      "every replica is a leader-election candidate, so only the leader restarts workloads. Remove it.";
    "--reload-strategy" = replay;
    "--reload-on-create" = replay;
    "--sync-after-restart" = replay;
    "--ignored-workload-types" =
      "a reload of a CronJob would run a Job at every replay, and Job pods read the Secret when they start. Remove it.";
    "--resources-to-ignore" =
      "the package watches Secrets only; a Kix-built ConfigMap rolls its workload through a checksum/<name> pod annotation. Remove it.";
    "--auto-reload-all" =
      "the package leaves it off, because it would also restart workloads for Kix-built Secrets, which roll through a checksum/<name> pod annotation. Remove it.";
    "--webhook-url" =
      "the package leaves it unset, because with it reloader sends a webhook instead of restarting workloads. Remove it.";
    "--configmap-annotation" = annotationName;
    "--secret-annotation" = annotationName;
    "--auto-annotation" = annotationName;
    "--ignore-annotation" = annotationName;
    "--configmap-auto-annotation" = annotationName;
    "--secret-auto-annotation" = annotationName;
    "--auto-search-annotation" = annotationName;
    "--search-match-annotation" = annotationName;
    "--pause-deployment-annotation" = annotationName;
    "--pause-deployment-time-annotation" = annotationName;
  };
  unsupportedFlags = {
    "--namespace-selector" =
      "reloader then reads Namespaces, which the package's RBAC does not allow. Remove it.";
    "--is-Argo-Rollouts" =
      "reloader then updates argoproj.io Rollouts, which the package's RBAC does not allow. Remove it.";
    "--enable-csi-integration" =
      "reloader then watches secrets-store.csi.x-k8s.io resources, which the package's RBAC does not allow. Remove it.";
  };
  # Matches a flag as kix.guardArgs does: the bare flag or "<flag>=...".
  refuseUnsupported =
    extraArgs:
    let
      flagOf =
        arg:
        lib.findFirst (flag: arg == flag || lib.hasPrefix "${flag}=" arg) null (
          builtins.attrNames unsupportedFlags
        );
      lines = lib.concatMap (
        arg:
        let
          flag = flagOf arg;
        in
        lib.optional (flag != null)
          "${who}: extraArgs sets \"${arg}\", which this package does not support: ${unsupportedFlags.${flag}}"
      ) extraArgs;
    in
    if lines != [ ] then throw (lib.concatStringsSep "\n" lines) else extraArgs;

  # Flags whose values withReloadOn checks. Each is a pflag string slice:
  # repeats add to the list and each value is split on commas.
  readFlags = [
    "--namespaces"
    "--namespaces-to-ignore"
    "--resource-label-selector"
  ];
  valuesOf =
    extraArgs: flag:
    let
      bare = builtins.filter (arg: arg == flag) extraArgs;
      set = builtins.filter (lib.hasPrefix "${flag}=") extraArgs;
    in
    if bare != [ ] then
      throw "${who}: extraArgs passes ${flag} without \"=\"; write ${flag}=<a,b>."
    else
      builtins.filter (v: v != "") (
        lib.concatMap (arg: lib.splitString "," (lib.removePrefix "${flag}=" arg)) set
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
    # The domains of the annotations this configuration reads. The index
    # matches a domain exactly, so each subdomain is listed.
    annotationDomains = [
      "reloader.stakater.com"
      "secret.reloader.stakater.com"
      "secrets.exclude.reloader.stakater.com"
      "deployment.reloader.stakater.com"
    ];
  };

  options = {
    image = kix.options.image {
      repository = "ghcr.io/stakater/reloader";
      tag = release;
      digest = "sha256:def2480040adc164b3a57340e77674eadfd88fb7f0593df25e93297f29c7fd7c";
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
        `--namespaces` and `--namespaces-to-ignore` cannot be combined, and
        these three flags take their value after "=".

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

        # With --sync-after-restart and --reload-on-create, the leader's
        # initial list counts as a change to every Secret. The env-vars
        # strategy then restarts only workloads whose stored
        # STAKATER_<NAME>_SECRET hash differs from the Secret's.
        baseArgs = [
          "--log-format=json"
          "--enable-ha=true"
          "--reload-strategy=env-vars"
          "--reload-on-create=true"
          "--sync-after-restart=true"
          # A reload of a CronJob creates a Job and stores no hash, so every
          # replay would run it again. Job pods read the Secret when they
          # start.
          "--ignored-workload-types=jobs,cronjobs"
          "--resources-to-ignore=configmaps"
        ];
        args =
          baseArgs
          ++ kix.guardArgs {
            inherit who;
            owned = ownedFlags;
          } (refuseUnsupported config.extraArgs);

        read = lib.genAttrs readFlags (valuesOf config.extraArgs);
        watched = lib.unique read."--namespaces";
        ignored = read."--namespaces-to-ignore";
        labelSelector = read."--resource-label-selector";
        # Forces every read flag, so a bare one fails the build even when no
        # workload calls withReloadOn.
        _flagsCheck = builtins.deepSeq read (
          if watched != [ ] && ignored != [ ] then
            throw "${who}: extraArgs sets both --namespaces and --namespaces-to-ignore; reloader ignores --namespaces-to-ignore when --namespaces is set. Remove one."
          else
            null
        );

        # The flags in baseArgs, ownedFlags, and the RBAC rules follow
        # `release`; another release may lack a flag or need other rules.
        imageTag = builtins.unsafeDiscardStringContext config.image.tag;
        imageRef =
          if
            lib.versions.majorMinor (lib.removePrefix "v" imageTag)
            == lib.versions.majorMinor (lib.removePrefix "v" release)
          then
            kix.image.ref config.image
          else
            throw "${who}: image.tag \"${imageTag}\" is not a ${lib.versions.majorMinor (lib.removePrefix "v" release)} release, and the flags and RBAC rules of this package follow reloader ${release}. To move to another release, change `release` in kix/packages/reloader/default.nix and check the flags against that release's internal/pkg/util/util.go and the rules against its chart clusterrole.yaml.";

        env = kix.mkEnvVars (
          kix.mergeEnv {
            inherit who;
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
            throw "${prefix} got ${kind} '${r.out.name or "?"}', whose content is part of the build. Put \"checksum/<name>\" = <ref>.out.identityHash on the pod template instead, so the rollout appears in the deploy plan; reloader would restart the workload a second time."
          else if !(kind == "PackageInstance" && r ? out.keyRef) then
            throw "${prefix} takes Secrets from scope.mkSecretRef or a secret-ref dependency; got ${
              if kind != null then kind else r._type or (builtins.typeOf r)
            }."
          else if labelSelector != [ ] then
            throw "${prefix}: reloader watches only Secrets labelled ${lib.concatStringsSep "," labelSelector}, and Kix cannot check that Secret ${shown}, created outside Kix, carries them. Remove --resource-label-selector to use withReloadOn."
          else if (watched != [ ] && !builtins.elem namespace watched) || builtins.elem namespace ignored then
            throw "${prefix}: Secret ${shown} is in a namespace this reloader does not watch (extraArgs ${
              if watched != [ ] then
                "--namespaces=${lib.concatStringsSep "," watched}"
              else
                "--namespaces-to-ignore=${lib.concatStringsSep "," ignored}"
            }). ${
              if watched != [ ] then
                "Add ${namespace} to --namespaces."
              else
                "Remove ${namespace} from --namespaces-to-ignore."
            }"
          else
            r.out.name;

        # Errors name the workload from `args.name`, since the mistake is in
        # the consumer's build.
        withReloadOn =
          refs: args:
          let
            prefix = "${who}: withReloadOn for '${args.name or "?"}'";
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
            throw "${prefix} needs a non-empty list of Secrets."
          else if args ? _type then
            throw "${prefix} takes builder args; pipe them through it before scope.mkDeployment."
          else if args ? spec.jobTemplate || restartPolicy == "Never" || restartPolicy == "OnFailure" then
            throw "${prefix}: Job and CronJob pods read the Secret when they start; this reloader ignores them (--ignored-workload-types)."
          else if !(args ? spec.template) then
            throw "${prefix}: reloader restarts only Deployments, DaemonSets, and StatefulSets, and these args have no spec.template. Pass the builder args of one of those kinds."
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
                    image = imageRef;
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
          out = { inherit withReloadOn; };
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
