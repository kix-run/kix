# snapshot-controller: the Kubernetes VolumeSnapshot API
# (snapshot.storage.k8s.io) and the CSI snapshot controller that serves it.
# root = the Deployment.
#
# Installs the VolumeSnapshotClass, VolumeSnapshotContent and VolumeSnapshot
# CRDs; a ServiceAccount; ClusterRole and ClusterRoleBinding
# <name>-<namespace> for the volumes, claims, snapshots, and Events the
# controller reads and writes; a Role and RoleBinding <name>-leader-election
# for its Lease; and the Deployment. With the optional `prometheus` dep and
# `metrics.enabled`, also Service <name>-metrics and a ServiceMonitor.
#
# The instance claims the `snapshotController` role, so a cluster runs one.
# A CSI driver package takes the role as an optional dependency and builds
# its VolumeSnapshotClasses from out.crds:
#
#   instances.storage.snapshot-controller.package = packages.experimental.snapshot-controller;
#
# An environment that runs its own controller (RKE2) binds the role
# `exclusive` and provides the API through a platform import, so this
# package is refused there at evaluation.
#
# The CRDs carry CEL validation rules (x-kubernetes-validations), which
# replace the validating webhook of releases before v8; no webhook is
# deployed. Group snapshots (groupsnapshot.storage.k8s.io) stay off: their
# CRDs are not installed and the feature gate keeps its default.
#
# out.crds.<Kind>: handles for VolumeSnapshotClass, VolumeSnapshotContent,
#   and VolumeSnapshot, passed to `scope.mkCR`.
#
# Alerts: with a prometheus dependency and `metrics.enabled`, a
# PrometheusRule `<instance>-alerts` selects the metrics Service's series.
#   SnapshotControllerDown (warning)  the controller answers no scrape.
#                                     VolumeSnapshots are neither created
#                                     nor deleted, so backups that take
#                                     snapshots stall.
# The controller records an operation's duration only when it succeeds
# (pkg/metrics/metrics.go upstream), so its metrics show no failed
# snapshot. A snapshot that never becomes ready is the CSI driver's fault
# to report, and its consumer's (a backup tool) to alert on.
#
# Escape hatches: `extraArgs` (the leader election and HTTP endpoint flags
# are refused), `env`, and `partsOverlays`.

{
  scope,
  lib,
  kix,
  availability,
}:
let
  # meta.version and image.tag read this; crds/sources.txt names the same tag.
  release = "8.6.0";

  name = scope.instanceName;
  ns = scope.namespaceName;
  who = "snapshot-controller ${ns}/${name}";
  httpPort = 8080;

  vendored = file: builtins.fromJSON (builtins.readFile ./crds/${file});

  # The apiserver refuses a CRD in a *.k8s.io group unless it carries the
  # api-approved.kubernetes.io annotation, so the upstream value goes with
  # the spec.
  approvedCrd =
    file:
    let
      crd = vendored file;
    in
    scope.mkCRD {
      inherit (crd) spec;
      annotations."api-approved.kubernetes.io" = crd.metadata.annotations."api-approved.kubernetes.io";
      # A snapshot, class, or content object runs no pods.
      usesAtLeast = _: { };
    };

  # The CRDs come from `release`; a controller of another minor release may
  # not serve the same schema.
  minorOf = tag: builtins.match "v?([0-9]+)\\.([0-9]+)\\..*" tag;
  releaseMinor = minorOf release;
  checkedRef =
    image:
    let
      tag = builtins.unsafeDiscardStringContext image.tag;
    in
    if minorOf tag != releaseMinor then
      throw (
        "${who}: image.tag \"${tag}\" is not a ${lib.concatStringsSep "." releaseMinor} release, "
        + "and the CRDs under kix/packages/experimental/snapshot-controller/crds are vendored from v${release}. "
        + "To move to another release, change release in kix/packages/experimental/snapshot-controller/default.nix "
        + "and run uv run scripts/vendor-crds.py snapshot-controller."
      )
    else
      kix.image.ref image;
in
{
  meta = {
    version = release;
    description = "Kubernetes CSI snapshot controller and the VolumeSnapshot API (snapshot.storage.k8s.io)";
    owner = "platform";
    # The role admits one managed claimant per cluster, which also keeps a
    # second set of the cluster-scoped CRDs out.
    roles = [ "snapshotController" ];
    # The CRDs' x-kubernetes-validations rules need CEL.
    k8s.minVersion = "1.25";
  };

  options = {
    image = kix.options.image {
      repository = "registry.k8s.io/sig-storage/snapshot-controller";
      tag = "v${release}";
      digest = "sha256:81e79f205083f105e573ba2ebfe5964ede7f69a154e8627f53ebbbccd3ed9f70";
      description = "Image of the snapshot controller. Its major.minor must match the vendored CRDs.";
    };

    resources = kix.options.resources {
      requests = {
        cpu = "10m";
        memory = "32Mi";
      };
      limits = {
        cpu = "200m";
        memory = "128Mi";
      };
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "--worker-threads=20" ];
      description = "Flags appended after the package's own, which include `--v=2` (a later `--v` wins). `--leader-election`, `--leader-election-namespace`, `--http-endpoint`, and `--metrics-path` are refused.";
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
          restrictTo
          mkClusterRoleSet
          mkRoleSet
          ;
        snapshots = group "snapshot.storage.k8s.io" [
          "volumesnapshotclasses"
          "volumesnapshotcontents"
          "volumesnapshots"
        ];
        coordination = group "coordination.k8s.io" [ "leases" ];

        # The Lease name is fixed in the binary (cmd/snapshot-controller).
        leaseName = "snapshot-controller-leader";

        subjects = [
          {
            kind = "ServiceAccount";
            name = self.serviceAccount.out.name;
            namespace = scope.namespaceName;
          }
        ];

        args = [
          "--v=2"
          "--leader-election=true"
          "--http-endpoint=:${toString httpPort}"
        ]
        ++ kix.guardArgs {
          inherit who;
          owned = {
            "--leader-election" =
              "leader election keeps one active controller while the instance's availability level runs several; remove it.";
            "--leader-election-namespace" =
              "the Role that lets the controller manage its Lease exists only in the instance's namespace; remove it.";
            "--http-endpoint" = "the probes and the metrics Service use :${toString httpPort}; remove it.";
            "--metrics-path" = "the ServiceMonitor scrapes /metrics; remove it.";
          };
        } config.extraArgs;

        crds = [
          self.crds.volumeSnapshotClasses
          self.crds.volumeSnapshotContents
          self.crds.volumeSnapshots
        ];
      in
      {
        crds = {
          volumeSnapshotClasses = approvedCrd "volumesnapshotclasses.snapshot.storage.k8s.io.json";
          volumeSnapshotContents = approvedCrd "volumesnapshotcontents.snapshot.storage.k8s.io.json";
          volumeSnapshots = approvedCrd "volumesnapshots.snapshot.storage.k8s.io.json";
        };

        serviceAccount = scope.mkResource {
          apiVersion = "v1";
          kind = "ServiceAccount";
          inherit name;
        };

        deployment = scope.mkDeployment {
          inherit name;
          requires = crds;
          spec = {
            # Leader election makes the extra replicas standbys.
            replicas = kix.availability.pick availability {
              none = 1;
              pod = 1;
              node = 2;
              zone = 2;
            };
            selector.matchLabels = scope.selectorLabels;
            # The controller exits when the snapshot CRDs are not served
            # within --retry-crd-interval-max (30s by default). Waiting 35s
            # keeps a new pod that is about to exit from counting as
            # available during a rollout.
            minReadySeconds = 35;
            template.spec = {
              serviceAccount = self.serviceAccount;
              terminationGracePeriodSeconds = 30;
              securityContext = {
                runAsNonRoot = true;
                runAsUser = 65532;
                seccompProfile.type = "RuntimeDefault";
              };
              containers = [
                {
                  name = "snapshot-controller";
                  image = checkedRef config.image;
                  imagePullPolicy = config.image.pullPolicy;
                  inherit args;
                  env = kix.mkEnvVars (kix.mergeEnv { inherit who; } config.env);
                  ports = [ (kix.port "http" httpPort) ];
                  # The endpoint fails only while this replica holds the Lease
                  # and cannot renew it; a standby reports healthy.
                  livenessProbe = {
                    httpGet = {
                      path = "/healthz/leader-election";
                      port = "http";
                    };
                    initialDelaySeconds = 10;
                    periodSeconds = 20;
                    timeoutSeconds = 10;
                    failureThreshold = 3;
                  };
                  readinessProbe = {
                    httpGet = {
                      path = "/healthz/leader-election";
                      port = "http";
                    };
                    periodSeconds = 10;
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
        };

        metricsService =
          if config.metrics.enabled && prometheus != null then
            self.deployment |> kix.service.fromWorkload { name = "${name}-metrics"; } |> scope.mkResource
          else
            null;

        root = {
          resource = self.deployment;
          requires = crds;
          out.crds = {
            VolumeSnapshotClass = self.crds.volumeSnapshotClasses;
            VolumeSnapshotContent = self.crds.volumeSnapshotContents;
            VolumeSnapshot = self.crds.volumeSnapshots;
          };
        };
      }
      // mkClusterRoleSet scope {
        inherit subjects;
        labels = scope.selectorLabels;
        # external-snapshotter v8.6.0
        # deploy/kubernetes/snapshot-controller/rbac-snapshot-controller.yaml,
        # without the groupsnapshot.storage.k8s.io rules.
        roles."${name}-${scope.namespaceName}" = grant [
          (
            core.persistentvolumes
            |> allow [
              "get"
              "list"
              "watch"
            ]
          )
          (
            core.persistentvolumeclaims
            |> allow [
              "get"
              "list"
              "watch"
              "update"
            ]
          )
          (
            core.events
            |> allow [
              "list"
              "watch"
              "create"
              "update"
              "patch"
            ]
          )
          (snapshots.volumesnapshotclasses |> watch)
          (
            snapshots.volumesnapshotcontents
            |> allow [
              "create"
              "get"
              "list"
              "watch"
              "update"
              "delete"
              "patch"
            ]
          )
          (snapshots "volumesnapshotcontents/status" |> allow [ "patch" ])
          (
            snapshots.volumesnapshots
            |> allow [
              "create"
              "get"
              "list"
              "watch"
              "update"
              "patch"
              "delete"
            ]
          )
          (
            snapshots "volumesnapshots/status"
            |> allow [
              "update"
              "patch"
            ]
          )
        ];
      }
      // mkRoleSet scope {
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
            ]
          )
        ];
      }
    )

    (
      let
        sel = ''namespace="${ns}",service="${name}-metrics"'';
      in
      kix.monitor {
        service = "metricsService";
        port = "http";
        alerts.SnapshotControllerDown = {
          expr = "sum by (namespace, service) (up{${sel}}) == 0 or absent(up{${sel}})";
          "for" = "10m";
          severity = "warning";
          summary = "The CSI snapshot controller is down.";
          description = "The snapshot controller ${ns}/${name} has not answered a scrape for 10 minutes. VolumeSnapshots are neither created nor deleted while it is down, so backups that take snapshots stall. Check its Deployment in ${ns}.";
        };
      }
    )
  ];
}
