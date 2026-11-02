# volsync: the VolSync operator, which copies the contents of
# PersistentVolumeClaims to object storage or to another cluster on a
# schedule (ReplicationSource) and restores them (ReplicationDestination).
#
# Installs the ReplicationSource and ReplicationDestination CRDs, a
# ServiceAccount, the operator's ClusterRole (rbac/, vendored from
# upstream) and its binding, a Role and RoleBinding <name>-leader-election
# for its Lease, and the Deployment. With the optional `prometheus`
# dependency and `metrics.enabled`, also Service <name>-metrics and a
# ServiceMonitor. For each custom resource, the operator starts mover Jobs
# in that resource's namespace, which run this release's image.
#
# The operator watches every namespace and creates ServiceAccounts, Roles,
# RoleBindings, Secrets, and claims in them, so a cluster runs one instance
# (`conflictsWith`).
#
# Minimal instance:
#
#   instances.volsync.volsync.package = packages.volsync;
#
# Dependencies:
#   snapshotController (required)  the VolumeSnapshot API. The operator
#                                  watches VolumeSnapshots whatever the
#                                  copy method, and does not start
#                                  without their CRD. A snapshot-controller
#                                  instance, or the platform import of a
#                                  flavour that ships the API (rke2).
#   prometheus (optional)          metrics Service and ServiceMonitor.
#
# Backing up a claim with restic, in a package that takes `volsync` as a
# dependency:
#
#   backup = volsync.out.mkReplicationSource scope {
#     name = "data";
#     claim = self.claim;              # or a storage dependency
#     schedule = "0 3 * * *";
#     copyMethod = "Snapshot";
#     restic = {
#       repository = resticRepository; # a secret dependency
#       endpointService = s3;          # an in-cluster S3 store, or null
#     };
#   };
#
# `restic.repository` holds the keys VolSync's restic mover reads from one
# Secret: RESTIC_REPOSITORY (`s3:<store URL>/<bucket>/<path>`),
# RESTIC_PASSWORD, AWS_ACCESS_KEY_ID, and AWS_SECRET_ACCESS_KEY. The mover
# takes no other Secret, so the store's credentials go in this one, and
# Kix cannot check that RESTIC_REPOSITORY names `endpointService`.
# clusters/test-volsync.nix shows the whole wiring.
#
# Readiness: a ReplicationSource or ReplicationDestination is ready once
# its latest mover run reports `Successful`. VolSync runs the first sync as
# soon as the resource is created, so the deploy waits for the first
# backup or restore. Syncthing movers and rsync destinations report no
# mover result, so the deploy times out on them; the CRD's readiness
# applies to every resource of its kind and cannot be overridden per
# resource.
#
# Network policy: the mover pods of a ReplicationSource carry
# `batch.kubernetes.io/job-name: volsync-src-<name>` (`dst` for a
# ReplicationDestination). The CRDs declare that the movers dial the
# Services a resource names, so the resource built with an
# `endpointService` gives its movers egress to the store and the store
# ingress from them. Without one, mkReplicationSource adds a policy that
# lets the movers reach DNS and TCP `restic.storePort` (443 by default)
# outside the cluster. A resource name longer than 51 characters is
# refused, because VolSync then hashes the Job name.
#
# `out`:
#   out.mkReplicationSource scope { name; claim; schedule; copyMethod;
#                                   restic; extraSpec ? { }; requires ? [ ]; }
#       A folder of two parts: `replicationSource`, the custom resource, and
#       `egress`, the movers' policy to a store outside the cluster (null
#       with an `endpointService` or without an enforcer). Add the folder
#       as one part and `replicationSource` to `root.requires`.
#   out.crds.{ReplicationSource,ReplicationDestination}
#       For `scope.mkCR`, with the readiness and mover selectors above.
#   out.extraImages  the operator and mover image.
#
# Escape hatches: `extraArgs` and `env` for the operator, `extraSpec` on
# mkReplicationSource (`restic.retain`, `restic.pruneIntervalDays`,
# `restic.moverSecurityContext`, and the rest of the restic spec), and the
# instance's `partsOverlays`.
#
# Limits: mkReplicationSource writes restic to S3 only. Movers run in the
# image's user unless `restic.moverSecurityContext` sets the application's.
#
# Alerts: with a prometheus dependency and `metrics.enabled`, a
# PrometheusRule `<instance>-alerts` selects the metrics Service's series.
#   VolSyncOperatorDown (warning)       the operator answers no scrape. No
#                                       sync starts, and the out-of-sync
#                                       alert below cannot fire.
#   VolSyncVolumeOutOfSync (warning)    a ReplicationSource or
#                                       ReplicationDestination has not
#                                       completed a sync since it was
#                                       created, or missed its schedule's
#                                       deadline, for an hour. The operator
#                                       sets the gauge on the first missed
#                                       deadline, so a daily schedule fires
#                                       after one failed run.
# A mover Job that fails is left to prometheus-default-rules
# (KubeJobFailed); VolSync starts the next one itself. Reconcile errors
# need no alert of their own: a sync they block shows as out of sync.
#
# root = the Deployment.

{
  scope,
  lib,
  kix,
  availability,
}:
let
  # meta.version and image.tag read this; crds/sources.txt and
  # rbac/sources.txt name the tag v<release>.
  release = "0.16.0";

  name = scope.instanceName;
  ns = scope.namespaceName;
  who = "volsync ${ns}/${name}";

  healthPort = 8081;
  metricsPort = 8080;

  readJSON = file: builtins.fromJSON (builtins.readFile file);
  vendored = file: (readJSON ./crds/${file}).spec;

  minorOf = tag: lib.versions.majorMinor (lib.removePrefix "v" tag);

  # The Lease name compiled into the operator (cmd/main.go).
  leaseName = "b95b3104.backube";

  sourceChecks = import ./checks.nix { inherit lib; };
  inherit (sourceChecks) maxNameLength;

  # The Job controller labels a mover Job's pods with the Job's name.
  moverSelector =
    dir: crName:
    if builtins.stringLength crName > maxNameLength then
      throw "${who}: the VolSync resource \"${crName}\" has a name longer than ${toString maxNameLength} characters, so VolSync hashes its mover Job's name and Kix cannot select the mover pods for network policy. Shorten the name."
    else
      {
        "app.kubernetes.io/created-by" = "volsync";
        "batch.kubernetes.io/job-name" = "volsync-${dir}-${crName}";
      };

  # A mover run's result; both kinds report it under
  # status.latestMoverStatus (api/v1alpha1/common_types.go).
  readiness = {
    path = "/status/latestMoverStatus/result";
    equals = "Successful";
  };

  movers = [
    "rclone"
    "restic"
    "rsync"
    "rsync-tls"
    "syncthing"
  ];

  tcp = port: {
    inherit port;
    protocol = "TCP";
  };
in
{
  meta = {
    version = release;
    description = "VolSync, which replicates PersistentVolumeClaims to object storage or another cluster (ReplicationSource, ReplicationDestination)";
    owner = "platform";
    defaultAliases = [ "volsync" ];
    # One instance per cluster; see the header.
    conflictsWith = [ "cluster:volsync" ];
    # The mover policies select pods by the batch.kubernetes.io/job-name
    # label, which the Job controller sets from 1.27.
    k8s.minVersion = "1.27";
  };

  assertions =
    { config, ... }:
    let
      imageTag = builtins.unsafeDiscardStringContext config.image.tag;
    in
    [
      {
        assertion = minorOf imageTag == minorOf release;
        message = "image.tag \"${imageTag}\" is not a ${minorOf release} release, and the CRDs and ClusterRole under kix/packages/volsync/{crds,rbac} are vendored from v${release}. Set image.tag to a ${minorOf release}.x tag. To move to another release, change release in kix/packages/volsync/default.nix and the tag in crds/sources.txt and rbac/sources.txt, then run uv run scripts/vendor-crds.py volsync.";
      }
    ];

  options = {
    image = kix.options.image {
      repository = "quay.io/backube/volsync";
      tag = release;
      digest = "sha256:0d03a6aad57569eba2c0eaa0848cf4a908d9744b372ff2224bb291a320f36d76";
      description = "Image of the operator and of every mover it starts. Its major.minor must match the vendored CRDs and ClusterRole.";
    };

    # Upstream's chart values.
    resources = kix.options.resources {
      requests = {
        cpu = "100m";
        memory = "64Mi";
      };
      limits = {
        cpu = "1";
        memory = "1Gi";
      };
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "--zap-log-level=debug" ];
      description = "Flags appended after the package's own. The leader election, probe, and metrics flags and the mover image flags are refused.";
    };

    env = kix.options.env;

    metrics = kix.options.monitor;
  };

  build = [
    (
      {
        self,
        config,
        snapshotController,
        prometheus ? null,
        ...
      }:
      let
        inherit (scope.rbac)
          core
          group
          grant
          allow
          emit
          restrictTo
          mkClusterRoleSet
          mkRoleSet
          ;
        coordination = group "coordination.k8s.io" [ "leases" ];

        image = kix.image.ref config.image;

        subjects = [
          {
            kind = "ServiceAccount";
            name = self.serviceAccount.out.name;
            namespace = scope.namespaceName;
          }
        ];

        snapshotCrd =
          snapshotController.out.crds.VolumeSnapshot
            or (throw "${who}: the snapshotController dependency has no out.crds.VolumeSnapshot. Wire a snapshot-controller instance, or an import that claims the snapshotController role with its crds.");

        args = [
          "--leader-elect"
          "--health-probe-bind-address=:${toString healthPort}"
          "--metrics-bind-address=:${toString metricsPort}"
          # The operator's HTTPS metrics use a self-signed certificate;
          # the ServiceMonitor scrapes plain HTTP.
          "--metrics-secure=false"
        ]
        ++ map (m: "--${m}-container-image=${image}") movers
        ++ kix.guardArgs {
          inherit who;
          owned = {
            "--leader-elect" =
              "leader election keeps one active operator while the instance's availability level runs several; remove it.";
            "--health-probe-bind-address" = "the probes use :${toString healthPort}; remove it.";
            "--metrics-bind-address" = "the metrics Service uses :${toString metricsPort}; remove it.";
            "--metrics-secure" = "the ServiceMonitor scrapes plain HTTP; remove it.";
          }
          // lib.genAttrs (map (m: "--${m}-container-image") movers) (
            _: "the movers run the image option, which out.extraImages lists; set image instead."
          );
        } config.extraArgs;

        crds = [
          self.crds.replicationSources
          self.crds.replicationDestinations
        ];

        mkReplicationSource =
          consumerScope:
          {
            name,
            claim,
            schedule,
            copyMethod,
            restic,
            extraSpec ? { },
            requires ? [ ],
          }:
          let
            what = "ReplicationSource ${consumerScope.namespaceName}/${name}";
            fail = msg: throw "${who}: ${what}: ${msg}";

            problem = sourceChecks.replicationSourceProblem {
              inherit
                name
                schedule
                copyMethod
                restic
                extraSpec
                ;
            };
            checks = if problem != null then fail problem else null;
            endpointService = restic.endpointService or null;
            storePort = restic.storePort or null;
            inherit (restic) repository;

            # The store's address carried on the repository's name, so
            # the movers get network policy to the store and the resource
            # waits for it.
            repositoryName =
              if endpointService == null then
                repository.out.name
              else
                kix.facts.connect (builtins.getContext endpointService.out.fqdn) repository.out.name;

            spec = kix.mergeGuarded {
              who = "${who}: ${what}";
              locked = [
                [ "sourcePVC" ]
                [ "trigger" ]
                [
                  "restic"
                  "repository"
                ]
                [
                  "restic"
                  "copyMethod"
                ]
              ];
            } base extraSpec;
            base = {
              sourcePVC = claim.out.name;
              trigger.schedule = schedule;
              restic = {
                repository = repositoryName;
                inherit copyMethod;
              };
            };

            netpol = consumerScope.networkPolicyEnforcer.netpol;
            egress =
              if endpointService != null then
                null
              else
                kix.operandPolicy {
                  scope = consumerScope;
                  name = "${name}-restic-egress";
                  spec = {
                    endpointSelector.matchLabels = moverSelector "src" name;
                    egress = [
                      netpol.dnsEgressRule
                    ]
                    ++ (netpol.translateIntentRules {
                      intents.store.egress = [
                        {
                          to = "world";
                          ports = [ (tcp (if storePort != null then storePort else 443)) ];
                        }
                      ];
                    }).egressRules;
                  };
                };
          in
          builtins.seq checks {
            replicationSource = consumerScope.mkCR self.crds.replicationSources {
              inherit name spec;
              requires = requires ++ lib.optional (egress != null) egress;
            };
            inherit egress;
          };
      in
      {
        crds = {
          replicationSources = scope.mkCRD {
            spec = vendored "replicationsources.volsync.backube.json";
            inherit readiness;
            factBehavior = {
              endpoint = "terminate";
              podSelector = cr: moverSelector "src" cr.metadata.name;
            };
          };
          replicationDestinations = scope.mkCRD {
            spec = vendored "replicationdestinations.volsync.backube.json";
            inherit readiness;
            factBehavior = {
              endpoint = "terminate";
              podSelector = cr: moverSelector "dst" cr.metadata.name;
            };
          };
        };

        serviceAccount = scope.mkResource {
          apiVersion = "v1";
          kind = "ServiceAccount";
          inherit name;
        };

        clusterRbac = mkClusterRoleSet scope {
          inherit subjects;
          labels = scope.selectorLabels;
          roles.${name} = (readJSON ./rbac/clusterrole-manager-role.json).rules;
        };

        leaderElectionRbac = mkRoleSet scope {
          inherit subjects;
          labels = scope.selectorLabels;
          roles."${name}-leader-election" = grant [
            (coordination.leases |> allow [ "create" ])
            (
              coordination.leases
              |> restrictTo [ leaseName ]
              |> allow [
                "get"
                "update"
                "patch"
              ]
            )
            (core.events |> emit)
          ];
        };

        deployment = scope.mkDeployment {
          inherit name;
          requires =
            crds
            ++ [ snapshotCrd ]
            ++ builtins.attrValues self.clusterRbac
            ++ builtins.attrValues self.leaderElectionRbac;
          spec = {
            # Leader election makes the extra replicas standbys.
            replicas = kix.availability.pick availability {
              none = 1;
              pod = 1;
              node = 2;
              zone = 2;
            };
            selector.matchLabels = scope.selectorLabels;
            template.spec = {
              serviceAccount = self.serviceAccount;
              # Upstream's chart; the operator holds no state to drain.
              terminationGracePeriodSeconds = 10;
              securityContext = {
                runAsNonRoot = true;
                runAsUser = 65534;
                runAsGroup = 65534;
                seccompProfile.type = "RuntimeDefault";
              };
              containers = [
                {
                  name = "manager";
                  inherit image;
                  imagePullPolicy = config.image.pullPolicy;
                  command = [ "/manager" ];
                  inherit args;
                  env = kix.mkEnvVars (
                    kix.mergeEnv {
                      inherit who;
                      owned = [
                        {
                          vars.VOLSYNC_NAMESPACE = scope.namespaceName;
                          from = "the instance's namespace";
                          fix = "Remove it.";
                        }
                      ];
                    } config.env
                  );
                  ports = [
                    (kix.port "health" healthPort)
                    (kix.port "metrics" metricsPort)
                  ];
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
                  inherit (config) resources;
                  securityContext = {
                    allowPrivilegeEscalation = false;
                    readOnlyRootFilesystem = true;
                    capabilities.drop = [ "ALL" ];
                  };
                  volumeMounts = [
                    {
                      name = "tmp";
                      mountPath = "/tmp";
                    }
                  ];
                }
              ];
              # controller-runtime writes temporary files under /tmp.
              volumes = [
                {
                  name = "tmp";
                  emptyDir.medium = "Memory";
                }
              ];
            };
          };
        };

        metricsService =
          if config.metrics.enabled && prometheus != null then
            self.deployment
            |> kix.service.fromWorkload {
              name = "${name}-metrics";
              ports = [
                {
                  name = "metrics";
                  port = metricsPort;
                  targetPort = "metrics";
                  protocol = "TCP";
                }
              ];
            }
            |> scope.mkResource
          else
            null;

        root = {
          resource = self.deployment;
          requires = crds;
          out = {
            crds = {
              ReplicationSource = self.crds.replicationSources;
              ReplicationDestination = self.crds.replicationDestinations;
            };
            inherit mkReplicationSource;
            extraImages = [ image ];
          };
        };
      }
    )
    (
      let
        sel = ''namespace="${ns}",service="${name}-metrics"'';
      in
      kix.monitor {
        service = "metricsService";
        port = "metrics";
        alerts = {
          VolSyncOperatorDown = {
            expr = "sum by (namespace, service) (up{${sel}}) == 0 or absent(up{${sel}})";
            "for" = "10m";
            severity = "warning";
            summary = "The VolSync operator is down.";
            description = "The VolSync operator ${ns}/${name} has not answered a scrape for 10 minutes. No backup or restore starts while it is down, and VolSyncVolumeOutOfSync cannot fire. Check the operator Deployment in ${ns}.";
          };
          # The operator sets the gauge to 1 until a resource's first sync
          # completes and whenever a scheduled sync passes its deadline
          # (internal/controller/statemachine/machine.go upstream). An hour
          # leaves room for a first sync of a large claim.
          VolSyncVolumeOutOfSync = {
            expr = "max by (namespace, service, obj_namespace, obj_name, role) (volsync_volume_out_of_sync{${sel}}) == 1";
            "for" = "1h";
            severity = "warning";
            summary = "A VolSync replication is out of sync.";
            description = "The VolSync {{ $labels.role }} {{ $labels.obj_namespace }}/{{ $labels.obj_name }} has not completed a sync since it was created, or missed its schedule, for an hour, so its copy is older than the schedule promises. Read the resource's status conditions and the log of its latest mover Job in {{ $labels.obj_namespace }}.";
          };
        };
      }
    )
  ];
}
