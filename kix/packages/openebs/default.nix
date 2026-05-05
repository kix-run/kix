# OpenEBS storage platform kix package.
#
# Implements the full OpenEBS stack for the NW1 cluster:
#   - Mayastor (replicated block storage): io-engine, agent-core, api-rest,
#     operator-diskpool, csi-controller, csi-node, agent-ha-node, etcd, NATS
#   - ZFS LocalPV: controller + node DaemonSet + CSIDriver
#   - LVM LocalPV: controller + node DaemonSet + CSIDriver
#   - LocalPV Provisioner (hostpath, optional)
#
# Each subsystem has its own ServiceAccount + RBAC. Mayastor components share
# a single SA (openebs-service-account) per the upstream chart convention.
#
# root = api-rest Service (primary Mayastor interface)
# Everything else pulled in via requires chain.

{
  scope,
  lib,
  kix,
}:

let
  name = scope.instanceName;

  ns = scope.namespaceName;

  # --- Shared labels ---
  mayastorLabels = {
    "app.kubernetes.io/name" = "openebs";
    "app.kubernetes.io/instance" = name;
    "app.kubernetes.io/component" = "mayastor";
    "openebs.io/release" = name;
    "openebs.io/version" = "2.8.0";
  };

  zfsVersion = "2.7.1";
  zfsLabels = {
    "app.kubernetes.io/name" = "openebs";
    "app.kubernetes.io/instance" = name;
    "app.kubernetes.io/component" = "zfs-localpv";
  };

  # Labels for ZFS controller-side resources
  zfsControllerLabels = zfsLabels // {
    "openebs.io/component-name" = "openebs-zfs-controller";
    "openebs.io/version" = zfsVersion;
    role = "openebs-zfs";
  };

  # Labels for ZFS node-side resources
  zfsNodeLabels = zfsLabels // {
    name = "openebs-zfs-node";
    "openebs.io/component-name" = "openebs-zfs-node";
    "openebs.io/version" = zfsVersion;
    role = "openebs-zfs";
  };

  lvmVersion = "1.6.1";
  lvmLabels = {
    "app.kubernetes.io/name" = "openebs";
    "app.kubernetes.io/instance" = name;
    "app.kubernetes.io/component" = "lvm-localpv";
  };

  # Labels for LVM controller-side resources
  lvmControllerLabels = lvmLabels // {
    "openebs.io/component-name" = "openebs-lvm-controller";
    "openebs.io/version" = lvmVersion;
    role = "openebs-lvm";
  };

  # Labels for LVM node-side resources
  lvmNodeLabels = lvmLabels // {
    name = "openebs-lvm-node";
    "openebs.io/component-name" = "openebs-lvm-node";
    "openebs.io/version" = lvmVersion;
    role = "openebs-lvm";
  };

  localPvLabels = {
    "app.kubernetes.io/name" = "openebs";
    "app.kubernetes.io/instance" = name;
    "app.kubernetes.io/component" = "localpv-provisioner";
  };

  # --- Selector helpers ---
  mayastorSelector = app: {
    "app" = app;
    "openebs.io/release" = name;
  };

  # --- Toleration for unreachable/not-ready nodes (Mayastor control plane) ---
  controlPlaneTolerations = [
    {
      effect = "NoExecute";
      key = "node.kubernetes.io/unreachable";
      operator = "Exists";
      tolerationSeconds = 5;
    }
    {
      effect = "NoExecute";
      key = "node.kubernetes.io/not-ready";
      operator = "Exists";
      tolerationSeconds = 5;
    }
  ];

  # --- RBAC DSL ---
  inherit (scope.rbac)
    group
    core
    grant
    full
    watch
    emit
    allow
    mkClusterRoleSet
    ;
  openebsGrp = group "openebs.io" [
    "mayastorpools"
    "diskpools"
  ];
  storage = group "storage.k8s.io" [
    "storageclasses"
    "volumeattachments"
    "csinodes"
  ];
  snap = group "snapshot.storage.k8s.io" [
    "volumesnapshotclasses"
    "volumesnapshotcontents"
    "volumesnapshots"
  ];
  coord = group "coordination.k8s.io" [ "leases" ];
  apiext = group "apiextensions.k8s.io" [ "customresourcedefinitions" ];
  appsGrp = group "apps" [ "deployments" ];
  zfsAll = group "zfs.openebs.io" [
    "zfsvolumes"
    "zfssnapshots"
    "zfsbackups"
    "zfsrestores"
    "zfsnodes"
  ];
  lvmAll = group "local.openebs.io" [
    "lvmvolumes"
    "lvmsnapshots"
    "lvmnodes"
  ];

in
{
  meta = {
    version = "v2.8.0";
  };

  options = {
    mayastor = lib.mkOption {
      type = lib.types.anything;
      default = {
        enabled = true;
        version = "2.8.0";
        image = {
          ioEngine = "docker.io/openebs/mayastor-io-engine:v2.8.0";
          agentCore = "docker.io/openebs/mayastor-agent-core:v2.8.0";
          agentHaCluster = "docker.io/openebs/mayastor-agent-ha-cluster:v2.8.0";
          agentHaNode = "docker.io/openebs/mayastor-agent-ha-node:v2.8.0";
          apiRest = "docker.io/openebs/mayastor-api-rest:v2.8.0";
          csiController = "docker.io/openebs/mayastor-csi-controller:v2.8.0";
          csiNode = "docker.io/openebs/mayastor-csi-node:v2.8.0";
          operatorDiskpool = "docker.io/openebs/mayastor-operator-diskpool:v2.8.0";
          metricsExporter = "docker.io/openebs/mayastor-metrics-exporter-io-engine:v2.8.0";
          alpineSh = "docker.io/openebs/alpine-sh:4.1.0";
          alpineBash = "docker.io/openebs/alpine-bash:4.1.0";
        };
        etcd = {
          replicaCount = 3;
          image = "docker.io/bitnami/etcd:3.5.6-debian-11-r10";
          persistence = {
            size = "2Gi";
            storageClass = "mayastor-etcd-localpv";
          };
        };
        nats = {
          replicaCount = 3;
          image = "nats:2.9.17-alpine";
          reloaderImage = "natsio/nats-server-config-reloader:0.10.1";
          exporterImage = "natsio/prometheus-nats-exporter:0.11.0";
        };
        csiController = {
          replicas = 1;
          csiProvisioner = "registry.k8s.io/sig-storage/csi-provisioner:v3.5.0";
          csiAttacher = "registry.k8s.io/sig-storage/csi-attacher:v4.3.0";
          csiSnapshotter = "registry.k8s.io/sig-storage/csi-snapshotter:v6.3.3";
          snapshotController = "registry.k8s.io/sig-storage/snapshot-controller:v6.3.3";
          csiResizer = "registry.k8s.io/sig-storage/csi-resizer:v1.9.3";
        };
        ioEngine = {
          # Production: set cpuCount based on node capacity. Each CPU core
          # dedicated to SPDK reactor. Default 1 matches chart 4.2.0.
          cpuCount = 1;
          resources = {
            requests = {
              cpu = "1";
              memory = "1Gi";
              "hugepages-2Mi" = "2Gi";
            };
            limits = {
              cpu = "1";
              memory = "1Gi";
              "hugepages-2Mi" = "2Gi";
            };
          };
        };
        csiNodeRegistrar = "registry.k8s.io/sig-storage/csi-node-driver-registrar:v2.10.0";
      };
    };
    zfsLocalPv = lib.mkOption {
      type = lib.types.anything;
      default = {
        enabled = true;
        image = "openebs/zfs-driver:2.7.1";
        csiProvisioner = "registry.k8s.io/sig-storage/csi-provisioner:v3.5.0";
        csiResizer = "registry.k8s.io/sig-storage/csi-resizer:v1.8.0";
        csiSnapshotter = "registry.k8s.io/sig-storage/csi-snapshotter:v6.2.2";
        snapshotController = "registry.k8s.io/sig-storage/snapshot-controller:v6.2.2";
        csiNodeRegistrar = "registry.k8s.io/sig-storage/csi-node-driver-registrar:v2.8.0";
        encrKeysDir = "/home/keys";
      };
    };
    lvmLocalPv = lib.mkOption {
      type = lib.types.anything;
      default = {
        enabled = true;
        image = "openebs/lvm-driver:1.6.1";
        csiProvisioner = "registry.k8s.io/sig-storage/csi-provisioner:v3.5.0";
        csiResizer = "registry.k8s.io/sig-storage/csi-resizer:v1.8.0";
        csiSnapshotter = "registry.k8s.io/sig-storage/csi-snapshotter:v6.2.2";
        snapshotController = "registry.k8s.io/sig-storage/snapshot-controller:v6.2.2";
        csiNodeRegistrar = "registry.k8s.io/sig-storage/csi-node-driver-registrar:v2.8.0";
      };
    };
    localPvProvisioner = lib.mkOption {
      type = lib.types.anything;
      default = {
        enabled = false;
        image = "openebs/provisioner-localpv:4.2.0";
        # OPENEBS_IO_HELPER_IMAGE: image used for short-lived helper pods
        # (cleanup, hostpath init). Older charts shipped a separate
        # `linux-utils` image; newer ones reuse the provisioner. null →
        # fall back to `image`.
        helperImage = null;
        basePath = "/var/openebs/local";
      };
    };
    diskPools = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            name = lib.mkOption { type = lib.types.str; };
            node = lib.mkOption { type = lib.types.str; };
            disks = lib.mkOption { type = lib.types.listOf lib.types.str; };
          };
        }
      );
      default = [ ];
      description = "DiskPool custom resources for Mayastor";
    };
  };

  build =
    {
      self,
      config,
      clusterConfig,
    }:
    let
      # --- CPU list for io-engine (e.g. "1,2" for cpuCount=2) ---
      cpuList =
        let
          indices = lib.genList (i: toString (i + 1)) config.mayastor.ioEngine.cpuCount;
        in
        builtins.concatStringsSep "," indices;

      # ── Mayastor RBAC ────────────────────────────────────────
      mayastorClusterRoles =
        if config.mayastor.enabled then
          mkClusterRoleSet scope {
            subjects = [
              {
                kind = "ServiceAccount";
                name = self.mayastorSa.out.name;
                namespace = ns;
              }
            ];
            labels = mayastorLabels;
            roles = {
              "${name}-cluster-role" = grant [
                (
                  apiext.customresourcedefinitions
                  |> allow [
                    "create"
                    "get"
                    "update"
                    "list"
                    "patch"
                    "replace"
                  ]
                )
                (
                  apiext "customresourcedefinitions/status"
                  |> allow [
                    "get"
                    "update"
                    "patch"
                  ]
                )
                (
                  openebsGrp.mayastorpools
                  |> allow [
                    "get"
                    "list"
                    "patch"
                    "delete"
                    "deletecollection"
                  ]
                )
                (
                  openebsGrp.diskpools
                  |> allow [
                    "get"
                    "list"
                    "watch"
                    "update"
                    "replace"
                    "patch"
                    "create"
                  ]
                )
                (
                  openebsGrp "diskpools/status"
                  |> allow [
                    "update"
                    "patch"
                  ]
                )
                (
                  core.configmaps
                  |> allow [
                    "create"
                    "get"
                    "update"
                    "patch"
                  ]
                )
                (
                  appsGrp.deployments
                  |> allow [
                    "get"
                    "list"
                  ]
                )
                (core.persistentvolumes |> full)
                (
                  core.nodes
                  |> allow [
                    "get"
                    "list"
                    "watch"
                    "patch"
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
                (storage.storageclasses |> watch)
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
                (core.pods |> watch)
                (core "persistentvolumeclaims/status" |> allow [ "patch" ])
                (snap.volumesnapshotclasses |> watch)
                (snap.volumesnapshotcontents |> full)
                (
                  snap "volumesnapshotcontents/status"
                  |> allow [
                    "update"
                    "patch"
                  ]
                )
                (
                  snap.volumesnapshots
                  |> allow [
                    "get"
                    "list"
                    "watch"
                    "update"
                    "patch"
                    "delete"
                  ]
                )
                (
                  snap "volumesnapshots/status"
                  |> allow [
                    "update"
                    "patch"
                  ]
                )
                (
                  storage.volumeattachments
                  |> allow [
                    "get"
                    "list"
                    "watch"
                    "update"
                    "patch"
                  ]
                )
                (storage "volumeattachments/status" |> allow [ "patch" ])
                (storage.csinodes |> watch)
                (core.secrets |> watch)
              ];
            };
          }
        else
          { };

      # ── ZFS LocalPV RBAC ────────────────────────────────────
      zfsControllerRoles =
        if config.zfsLocalPv.enabled then
          mkClusterRoleSet scope {
            subjects = [
              {
                kind = "ServiceAccount";
                name = self.zfsControllerSa.out.name;
                namespace = ns;
              }
            ];
            labels = zfsControllerLabels;
            roles = {
              "${name}-zfs-provisioner-role" = grant [
                (
                  core.secrets
                  |> allow [
                    "get"
                    "list"
                  ]
                )
                (core.namespaces |> allow [ "*" ])
                (
                  [
                    core.persistentvolumes
                    core.services
                  ]
                  |> full
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
                  core "persistentvolumeclaims/status"
                  |> allow [
                    "update"
                    "patch"
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
                (core.nodes |> watch)
                (
                  core.pods
                  |> allow [
                    "get"
                    "list"
                    "watch"
                    "update"
                    "patch"
                  ]
                )
                (
                  [
                    zfsAll.zfsvolumes
                    zfsAll.zfssnapshots
                    zfsAll.zfsbackups
                    zfsAll.zfsrestores
                    zfsAll.zfsnodes
                  ]
                  |> allow [ "*" ]
                )
                (
                  coord.leases
                  |> allow [
                    "get"
                    "watch"
                    "list"
                    "delete"
                    "update"
                    "create"
                  ]
                )
                (
                  [
                    storage.storageclasses
                    storage.csinodes
                  ]
                  |> watch
                )
                (storage "csistoragecapacities" |> allow [ "*" ])
              ];
              "${name}-zfs-snapshotter-role" = grant [
                (snap.volumesnapshotclasses |> watch)
                (snap.volumesnapshotcontents |> full)
                (
                  snap "volumesnapshotcontents/status"
                  |> allow [
                    "update"
                    "patch"
                  ]
                )
                (
                  snap.volumesnapshots
                  |> allow [
                    "get"
                    "list"
                    "watch"
                    "update"
                    "patch"
                  ]
                )
                (
                  snap "volumesnapshots/status"
                  |> allow [
                    "update"
                    "patch"
                  ]
                )
              ];
            };
          }
        else
          { };

      zfsNodeRoles =
        if config.zfsLocalPv.enabled then
          mkClusterRoleSet scope {
            subjects = [
              {
                kind = "ServiceAccount";
                name = self.zfsNodeSa.out.name;
                namespace = ns;
              }
            ];
            labels = zfsNodeLabels;
            roles = {
              "${name}-zfs-driver-registrar-role" = grant [
                (
                  core.events
                  |> allow [
                    "get"
                    "list"
                    "watch"
                    "create"
                    "update"
                    "patch"
                  ]
                )
                (
                  [
                    core.persistentvolumes
                    core.nodes
                    core.services
                  ]
                  |> allow [
                    "get"
                    "list"
                  ]
                )
                (
                  [
                    zfsAll.zfsvolumes
                    zfsAll.zfssnapshots
                    zfsAll.zfsbackups
                    zfsAll.zfsrestores
                    zfsAll.zfsnodes
                  ]
                  |> allow [
                    "get"
                    "list"
                    "watch"
                    "create"
                    "update"
                    "patch"
                  ]
                )
              ];
            };
          }
        else
          { };

      # ── LVM LocalPV RBAC ───────────────────────────────────
      lvmControllerRoles =
        if config.lvmLocalPv.enabled then
          mkClusterRoleSet scope {
            subjects = [
              {
                kind = "ServiceAccount";
                name = self.lvmControllerSa.out.name;
                namespace = ns;
              }
            ];
            labels = lvmControllerLabels;
            roles = {
              "${name}-lvm-provisioner-role" = grant [
                (core.namespaces |> watch)
                (
                  [
                    core.persistentvolumes
                    core.services
                  ]
                  |> full
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
                  core "persistentvolumeclaims/status"
                  |> allow [
                    "update"
                    "patch"
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
                (core.nodes |> watch)
                (
                  core.pods
                  |> allow [
                    "get"
                    "list"
                    "watch"
                    "update"
                    "patch"
                  ]
                )
                (
                  coord.leases
                  |> allow [
                    "get"
                    "watch"
                    "list"
                    "delete"
                    "update"
                    "create"
                  ]
                )
                (
                  [
                    lvmAll.lvmvolumes
                    lvmAll.lvmsnapshots
                    lvmAll.lvmnodes
                  ]
                  |> allow [ "*" ]
                )
                (
                  [
                    storage.storageclasses
                    storage.csinodes
                  ]
                  |> watch
                )
                (storage "csistoragecapacities" |> allow [ "*" ])
              ];
              "${name}-lvm-snapshotter-role" = grant [
                (snap.volumesnapshotclasses |> watch)
                (snap.volumesnapshotcontents |> full)
                (
                  snap "volumesnapshotcontents/status"
                  |> allow [
                    "update"
                    "patch"
                  ]
                )
                (
                  snap.volumesnapshots
                  |> allow [
                    "get"
                    "list"
                    "watch"
                    "update"
                    "patch"
                  ]
                )
                (
                  snap "volumesnapshots/status"
                  |> allow [
                    "update"
                    "patch"
                  ]
                )
              ];
            };
          }
        else
          { };

      lvmNodeRoles =
        if config.lvmLocalPv.enabled then
          mkClusterRoleSet scope {
            subjects = [
              {
                kind = "ServiceAccount";
                name = self.lvmNodeSa.out.name;
                namespace = ns;
              }
            ];
            labels = lvmNodeLabels;
            roles = {
              "${name}-lvm-driver-registrar-role" = grant [
                (
                  core.events
                  |> allow [
                    "get"
                    "list"
                    "watch"
                    "create"
                    "update"
                    "patch"
                  ]
                )
                (
                  [
                    core.persistentvolumes
                    core.nodes
                    core.services
                  ]
                  |> allow [
                    "get"
                    "list"
                  ]
                )
                (
                  [
                    lvmAll.lvmvolumes
                    lvmAll.lvmsnapshots
                    lvmAll.lvmnodes
                  ]
                  |> allow [
                    "get"
                    "list"
                    "watch"
                    "create"
                    "update"
                    "patch"
                  ]
                )
              ];
            };
          }
        else
          { };

      # ── LocalPV Provisioner RBAC ────────────────────────────
      localPvClusterRoles =
        if config.localPvProvisioner.enabled then
          mkClusterRoleSet scope {
            subjects = [
              {
                kind = "ServiceAccount";
                name = self.localPvSa.out.name;
                namespace = ns;
              }
            ];
            labels = localPvLabels // {
              "openebs.io/component-name" = "${name}-localpv-provisioner";
            };
            roles = {
              "${name}-localpv-provisioner" = grant [
                (core.nodes |> watch)
                (
                  core.persistentvolumes
                  |> allow [
                    "get"
                    "list"
                    "watch"
                    "create"
                    "delete"
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
                (storage.storageclasses |> watch)
                (core.events |> emit)
              ];
            };
          }
        else
          { };
    in
    {

      # ==========================================================================
      #  MAYASTOR — Replicated Block Storage
      # ==========================================================================

      # --- ServiceAccount (shared by all Mayastor components) ---
      mayastorSa =
        if config.mayastor.enabled then
          (scope.mkResource {
            apiVersion = "v1";
            kind = "ServiceAccount";
            name = "${name}-service-account";
            labels = mayastorLabels;
          })
        else
          null;

      # --- PriorityClass (cluster-critical for Mayastor control plane) ---
      priorityClass =
        if config.mayastor.enabled then
          (scope.mkClusterResource {
            apiVersion = "scheduling.k8s.io/v1";
            kind = "PriorityClass";
            name = "${name}-cluster-critical";
            labels = mayastorLabels;
            extra = {
              value = 1000000000;
              preemptionPolicy = "PreemptLowerPriority";
              description = "Used for critical pods that must run in the cluster, which can be moved to another node if necessary.";
            };
          })
        else
          null;

      # --- etcd (coordination store for Mayastor) ---

      etcdHeadlessService =
        if config.mayastor.enabled then
          (scope.mkResource {
            apiVersion = "v1";
            kind = "Service";
            name = "${name}-etcd-headless";
            labels = {
              "app.kubernetes.io/name" = "etcd";
              "app.kubernetes.io/instance" = name;
              "app.kubernetes.io/component" = "etcd";
            };
            annotations = {
              "service.alpha.kubernetes.io/tolerate-unready-endpoints" = "true";
            };
            spec = {
              type = "ClusterIP";
              clusterIP = "None";
              publishNotReadyAddresses = true;
              selector = {
                "app.kubernetes.io/name" = "etcd";
                "app.kubernetes.io/instance" = name;
              };
              ports = [
                {
                  name = "client";
                  port = 2379;
                  targetPort = "client";
                  protocol = "TCP";
                }
                {
                  name = "peer";
                  port = 2380;
                  targetPort = "peer";
                  protocol = "TCP";
                }
              ];
            };
          })
        else
          null;

      etcdService =
        if config.mayastor.enabled then
          (scope.mkResource {
            apiVersion = "v1";
            kind = "Service";
            name = "${name}-etcd";
            labels = {
              "app.kubernetes.io/name" = "etcd";
              "app.kubernetes.io/instance" = name;
              "app.kubernetes.io/component" = "etcd";
            };
            spec = {
              type = "ClusterIP";
              sessionAffinity = "None";
              selector = self.etcdStatefulSet.out.selector;
              ports = [
                {
                  name = "client";
                  port = 2379;
                  targetPort = "client";
                  protocol = "TCP";
                }
                {
                  name = "peer";
                  port = 2380;
                  targetPort = "peer";
                  protocol = "TCP";
                }
              ];
            };
          })
        else
          null;

      etcdStatefulSet =
        if config.mayastor.enabled then
          (scope.mkResource {
            apiVersion = "apps/v1";
            kind = "StatefulSet";
            name = "${name}-etcd";
            labels = {
              "app.kubernetes.io/name" = "etcd";
              "app.kubernetes.io/instance" = name;
              "app.kubernetes.io/component" = "etcd";
            };
            spec = {
              replicas = config.mayastor.etcd.replicaCount;
              serviceName = "${name}-etcd-headless";
              podManagementPolicy = "Parallel";
              selector.matchLabels = {
                "app.kubernetes.io/name" = "etcd";
                "app.kubernetes.io/instance" = name;
              };
              updateStrategy.type = "RollingUpdate";
              template = {
                metadata.labels = {
                  "app.kubernetes.io/name" = "etcd";
                  "app.kubernetes.io/instance" = name;
                  app = "etcd";
                  "openebs.io/logging" = "true";
                };
                spec = {
                  affinity.podAntiAffinity.requiredDuringSchedulingIgnoredDuringExecution = [
                    {
                      labelSelector.matchLabels = {
                        "app.kubernetes.io/name" = "etcd";
                        "app.kubernetes.io/instance" = name;
                      };
                      topologyKey = "kubernetes.io/hostname";
                    }
                  ];
                  serviceAccountName = "default";
                  securityContext = {
                    fsGroup = 1001;
                  };
                  initContainers = [
                    {
                      name = "volume-permissions";
                      image = config.mayastor.image.alpineBash;
                      imagePullPolicy = "IfNotPresent";
                      command = [
                        "/bin/bash"
                        "-ec"
                        "chown -R 1001:1001 /bitnami/etcd\n"
                      ];
                      securityContext.runAsUser = 0;
                      volumeMounts = [
                        {
                          name = "data";
                          mountPath = "/bitnami/etcd";
                        }
                      ];
                    }
                  ];
                  containers = [
                    {
                      name = "etcd";
                      image = config.mayastor.etcd.image;
                      imagePullPolicy = "IfNotPresent";
                      securityContext = {
                        allowPrivilegeEscalation = false;
                        runAsNonRoot = true;
                        runAsUser = 1001;
                      };
                      env = [
                        {
                          name = "BITNAMI_DEBUG";
                          value = "false";
                        }
                        {
                          name = "MY_POD_IP";
                          valueFrom.fieldRef.fieldPath = "status.podIP";
                        }
                        {
                          name = "MY_POD_NAME";
                          valueFrom.fieldRef.fieldPath = "metadata.name";
                        }
                        {
                          name = "MY_STS_NAME";
                          value = "${name}-etcd";
                        }
                        {
                          name = "ETCDCTL_API";
                          value = "3";
                        }
                        {
                          name = "ETCD_ON_K8S";
                          value = "yes";
                        }
                        {
                          name = "ETCD_START_FROM_SNAPSHOT";
                          value = "no";
                        }
                        {
                          name = "ETCD_DISASTER_RECOVERY";
                          value = "no";
                        }
                        {
                          name = "ETCD_NAME";
                          value = "$(MY_POD_NAME)";
                        }
                        {
                          name = "ETCD_DATA_DIR";
                          value = "/bitnami/etcd/data";
                        }
                        {
                          name = "ETCD_LOG_LEVEL";
                          value = "info";
                        }
                        {
                          name = "ALLOW_NONE_AUTHENTICATION";
                          value = "yes";
                        }
                        {
                          name = "ETCD_ADVERTISE_CLIENT_URLS";
                          value = "http://$(MY_POD_NAME).${name}-etcd-headless.${ns}.svc.cluster.local:2379,http://${name}-etcd.${ns}.svc.cluster.local:2379";
                        }
                        {
                          name = "ETCD_LISTEN_CLIENT_URLS";
                          value = "http://0.0.0.0:2379";
                        }
                        {
                          name = "ETCD_INITIAL_ADVERTISE_PEER_URLS";
                          value = "http://$(MY_POD_NAME).${name}-etcd-headless.${ns}.svc.cluster.local:2380";
                        }
                        {
                          name = "ETCD_LISTEN_PEER_URLS";
                          value = "http://0.0.0.0:2380";
                        }
                        {
                          name = "ETCD_AUTO_COMPACTION_MODE";
                          value = "revision";
                        }
                        {
                          name = "ETCD_AUTO_COMPACTION_RETENTION";
                          value = "100";
                        }
                        {
                          name = "ETCD_INITIAL_CLUSTER_TOKEN";
                          value = "etcd-cluster-k8s";
                        }
                        {
                          name = "ETCD_INITIAL_CLUSTER_STATE";
                          value = "new";
                        }
                        {
                          name = "ETCD_INITIAL_CLUSTER";
                          value = builtins.concatStringsSep "," (
                            lib.genList (
                              i:
                              "${name}-etcd-${toString i}=http://${name}-etcd-${toString i}.${name}-etcd-headless.${ns}.svc.cluster.local:2380"
                            ) config.mayastor.etcd.replicaCount
                          );
                        }
                        {
                          name = "ETCD_CLUSTER_DOMAIN";
                          value = "${name}-etcd-headless.${ns}.svc.cluster.local";
                        }
                        {
                          name = "ETCD_QUOTA_BACKEND_BYTES";
                          value = "8589934592";
                        }
                        {
                          name = "ETCD_AUTH_TOKEN";
                          value = "jwt,priv-key=/opt/bitnami/etcd/certs/token/jwt-token.pem,sign-method=RS256,ttl=10m";
                        }
                      ];
                      ports = [
                        {
                          name = "client";
                          containerPort = 2379;
                          protocol = "TCP";
                        }
                        {
                          name = "peer";
                          containerPort = 2380;
                          protocol = "TCP";
                        }
                      ];
                      livenessProbe = {
                        exec.command = [ "/opt/bitnami/scripts/etcd/healthcheck.sh" ];
                        initialDelaySeconds = 60;
                        periodSeconds = 30;
                        timeoutSeconds = 5;
                        failureThreshold = 5;
                      };
                      readinessProbe = {
                        exec.command = [ "/opt/bitnami/scripts/etcd/healthcheck.sh" ];
                        initialDelaySeconds = 60;
                        periodSeconds = 10;
                        timeoutSeconds = 5;
                        failureThreshold = 5;
                      };
                      volumeMounts = [
                        {
                          name = "data";
                          mountPath = "/bitnami/etcd";
                        }
                        {
                          name = "etcd-jwt-token";
                          mountPath = "/opt/bitnami/etcd/certs/token";
                          readOnly = true;
                        }
                      ];
                    }
                  ];
                  volumes = [
                    {
                      name = "etcd-jwt-token";
                      secret = {
                        # Created by the openebs operator at runtime, not by kix.
                        secretName = kix.untrackedRef "${name}-etcd-jwt-token-custom";
                        defaultMode = 256; # 0400
                      };
                    }
                  ];
                };
              };
              volumeClaimTemplates = [
                {
                  metadata.name = "data";
                  spec = {
                    accessModes = [ "ReadWriteOnce" ];
                    resources.requests.storage = config.mayastor.etcd.persistence.size;
                    storageClassName = config.mayastor.etcd.persistence.storageClass;
                  };
                }
              ];
            };
            requires = [
              self.etcdHeadlessService
              self.etcdStorageClass
            ];
          })
        else
          null;

      # StorageClass for etcd local PV
      #
      # Matches the mayastor helm chart's localpv-storageclass.yaml: cas-type
      # and CAS config are emitted as annotations (legacy openebs convention),
      # no mayastorLabels are applied, and BasePath lives under
      # /var/local/openebs/localpv-hostpath/etcd.
      etcdStorageClass =
        if config.mayastor.enabled then
          (scope.mkClusterResource {
            apiVersion = "storage.k8s.io/v1";
            kind = "StorageClass";
            name = "mayastor-etcd-localpv";
            annotations = {
              "cas.openebs.io/config" = ''
                - name: StorageType
                  value: "hostpath"
                - name: BasePath
                  value: "/var/local/openebs/localpv-hostpath/etcd"
              '';
              "openebs.io/cas-type" = "local";
            };
            extra = {
              provisioner = "openebs.io/local";
              volumeBindingMode = "WaitForFirstConsumer";
              reclaimPolicy = "Delete";
            };
          })
        else
          null;

      # --- PodDisruptionBudget for etcd (chart 4.2.0 emits this) ---
      etcdPdb =
        if config.mayastor.enabled then
          (scope.mkResource {
            apiVersion = "policy/v1";
            kind = "PodDisruptionBudget";
            name = "${name}-etcd";
            labels = {
              "app.kubernetes.io/name" = "etcd";
              "app.kubernetes.io/instance" = name;
            };
            spec = {
              minAvailable = "51%";
              selector.matchLabels = {
                "app.kubernetes.io/name" = "etcd";
                "app.kubernetes.io/instance" = name;
              };
            };
          })
        else
          null;

      # --- NATS (messaging for Mayastor events) ---

      natsConfigMap =
        if config.mayastor.enabled then
          (scope.mkResource {
            apiVersion = "v1";
            kind = "ConfigMap";
            name = "${name}-nats-config";
            labels = {
              "app.kubernetes.io/name" = "nats";
              "app.kubernetes.io/instance" = name;
              "app.kubernetes.io/component" = "nats";
            };
            data."nats.conf" =
              let
                routes = builtins.concatStringsSep "," (
                  lib.genList (
                    i: "nats://${name}-nats-${toString i}.${name}-nats.${ns}:6222"
                  ) config.mayastor.nats.replicaCount
                );
              in
              ''
                # NATS Clients Port
                port: 4222

                # PID file shared with configuration reloader.
                pid_file: "/var/run/nats/nats.pid"

                ###############
                #             #
                # Monitoring  #
                #             #
                ###############
                http: 8222
                server_name:$POD_NAME
                ###################################
                #                                 #
                # NATS JetStream                  #
                #                                 #
                ###################################
                jetstream {
                  max_mem: 5Mi
                }
                ###################################
                #                                 #
                # NATS Full Mesh Clustering Setup #
                #                                 #
                ###################################
                cluster {
                  port: 6222
                  name: nats

                  routes = [
                    ${routes},

                  ]
                  cluster_advertise: $CLUSTER_ADVERTISE

                  connect_retries: 120
                }
                lame_duck_grace_period: 10s
                lame_duck_duration: 30s
              '';
          })
        else
          null;

      natsSa =
        if config.mayastor.enabled then
          (scope.mkResource {
            apiVersion = "v1";
            kind = "ServiceAccount";
            name = "${name}-nats";
            labels = {
              "app.kubernetes.io/name" = "nats";
              "app.kubernetes.io/instance" = name;
              "app.kubernetes.io/component" = "nats";
            };
          })
        else
          null;

      # --- PodDisruptionBudget for NATS (chart 4.2.0 emits this) ---
      natsPdb =
        if config.mayastor.enabled then
          (scope.mkResource {
            apiVersion = "policy/v1";
            kind = "PodDisruptionBudget";
            name = "${name}-nats";
            labels = {
              "app.kubernetes.io/name" = "nats";
              "app.kubernetes.io/instance" = name;
            };
            spec = {
              maxUnavailable = 1;
              selector.matchLabels = {
                "app.kubernetes.io/name" = "nats";
                "app.kubernetes.io/instance" = name;
              };
            };
          })
        else
          null;

      natsService =
        if config.mayastor.enabled then
          (scope.mkResource {
            apiVersion = "v1";
            kind = "Service";
            name = "${name}-nats";
            labels = {
              "app.kubernetes.io/name" = "nats";
              "app.kubernetes.io/instance" = name;
              "app.kubernetes.io/component" = "nats";
            };
            spec = {
              clusterIP = "None";
              selector = self.natsStatefulSet.out.selector;
              publishNotReadyAddresses = true;
              ports = [
                {
                  name = "client";
                  port = 4222;
                  appProtocol = "tcp";
                  protocol = "TCP";
                }
                {
                  name = "cluster";
                  port = 6222;
                  appProtocol = "tcp";
                  protocol = "TCP";
                }
                {
                  name = "monitor";
                  port = 8222;
                  appProtocol = "http";
                  protocol = "TCP";
                }
                {
                  name = "metrics";
                  port = 7777;
                  appProtocol = "http";
                  protocol = "TCP";
                }
                {
                  name = "leafnodes";
                  port = 7422;
                  appProtocol = "tcp";
                  protocol = "TCP";
                }
                {
                  name = "gateways";
                  port = 7522;
                  appProtocol = "tcp";
                  protocol = "TCP";
                }
              ];
            };
          })
        else
          null;

      natsStatefulSet =
        if config.mayastor.enabled then
          (scope.mkResource {
            apiVersion = "apps/v1";
            kind = "StatefulSet";
            name = "${name}-nats";
            labels = {
              "app.kubernetes.io/name" = "nats";
              "app.kubernetes.io/instance" = name;
              "app.kubernetes.io/component" = "nats";
            };
            spec = {
              replicas = config.mayastor.nats.replicaCount;
              serviceName = "${name}-nats";
              podManagementPolicy = "Parallel";
              selector.matchLabels = {
                "app.kubernetes.io/name" = "nats";
                "app.kubernetes.io/instance" = name;
              };
              template = {
                metadata = {
                  labels = {
                    "app.kubernetes.io/name" = "nats";
                    "app.kubernetes.io/instance" = name;
                    app = "nats";
                    "openebs.io/logging" = "true";
                  };
                  annotations = {
                    "prometheus.io/path" = "/metrics";
                    "prometheus.io/port" = "7777";
                    "prometheus.io/scrape" = "true";
                    # Helm uses this to roll the StatefulSet on configmap
                    # change. We pin to the chart-4.2.0 rendering's value
                    # so the diff converges; kix tracks ConfigMap dependency
                    # explicitly via `requires` and doesn't need it.
                    "checksum/config" = "04c9da2849ac0239fed07bca8e89be15fd56add19a0a75e2d4413d74531c2c5e";
                  };
                };
                spec = {
                  serviceAccountName = self.natsSa.out.name;
                  dnsPolicy = "ClusterFirst";
                  shareProcessNamespace = true;
                  terminationGracePeriodSeconds = 60;
                  volumes = [
                    {
                      name = "config-volume";
                      configMap.name = self.natsConfigMap.out.name;
                    }
                    {
                      name = "pid";
                      emptyDir = { };
                    }
                  ];
                  containers = [
                    {
                      name = "nats";
                      image = config.mayastor.nats.image;
                      imagePullPolicy = "IfNotPresent";
                      command = [
                        "nats-server"
                        "--config"
                        "/etc/nats-config/nats.conf"
                      ];
                      env = [
                        {
                          name = "POD_NAME";
                          valueFrom.fieldRef.fieldPath = "metadata.name";
                        }
                        {
                          name = "SERVER_NAME";
                          value = "$(POD_NAME)";
                        }
                        {
                          name = "POD_NAMESPACE";
                          valueFrom.fieldRef.fieldPath = "metadata.namespace";
                        }
                        {
                          name = "CLUSTER_ADVERTISE";
                          value = "$(POD_NAME).${name}-nats.$(POD_NAMESPACE)";
                        }
                      ];
                      ports = [
                        {
                          name = "client";
                          containerPort = 4222;
                        }
                        {
                          name = "cluster";
                          containerPort = 6222;
                        }
                        {
                          name = "monitor";
                          containerPort = 8222;
                        }
                      ];
                      volumeMounts = [
                        {
                          name = "config-volume";
                          mountPath = "/etc/nats-config";
                        }
                        {
                          name = "pid";
                          mountPath = "/var/run/nats";
                        }
                      ];
                      livenessProbe = {
                        httpGet = {
                          path = "/";
                          port = 8222;
                        };
                        initialDelaySeconds = 10;
                        periodSeconds = 30;
                        timeoutSeconds = 5;
                        failureThreshold = 3;
                      };
                      readinessProbe = {
                        httpGet = {
                          path = "/";
                          port = 8222;
                        };
                        initialDelaySeconds = 10;
                        periodSeconds = 10;
                        timeoutSeconds = 5;
                        failureThreshold = 3;
                      };
                      startupProbe = {
                        httpGet = {
                          path = "/healthz";
                          port = 8222;
                        };
                        initialDelaySeconds = 10;
                        periodSeconds = 10;
                        timeoutSeconds = 5;
                        failureThreshold = 90;
                      };
                      lifecycle.preStop.exec.command = [
                        "nats-server"
                        "-sl=ldm=/var/run/nats/nats.pid"
                      ];
                    }
                    {
                      name = "reloader";
                      image = config.mayastor.nats.reloaderImage;
                      imagePullPolicy = "IfNotPresent";
                      command = [
                        "nats-server-config-reloader"
                        "-pid"
                        "/var/run/nats/nats.pid"
                        "-config"
                        "/etc/nats-config/nats.conf"
                      ];
                      volumeMounts = [
                        {
                          name = "config-volume";
                          mountPath = "/etc/nats-config";
                        }
                        {
                          name = "pid";
                          mountPath = "/var/run/nats";
                        }
                      ];
                    }
                    {
                      name = "metrics";
                      image = config.mayastor.nats.exporterImage;
                      imagePullPolicy = "IfNotPresent";
                      args = [
                        "-connz"
                        "-routez"
                        "-subz"
                        "-varz"
                        "-prefix=nats"
                        "-use_internal_server_id"
                        "-jsz=all"
                        "http://localhost:8222/"
                      ];
                      ports = [
                        {
                          name = "metrics";
                          containerPort = 7777;
                        }
                      ];
                    }
                  ];
                };
              };
              # NATS is stateless (no VCTs needed)
            };
          })
        else
          null;

      # --- agent-core (Mayastor control plane) ---
      agentCoreService =
        if config.mayastor.enabled then
          (scope.mkResource {
            apiVersion = "v1";
            kind = "Service";
            name = "${name}-agent-core";
            labels = mayastorLabels // {
              app = "agent-core";
            };
            spec = {
              selector = self.agentCoreDeployment.out.selector;
              ports = [
                {
                  name = "grpc";
                  port = 50051;
                  protocol = "TCP";
                }
                {
                  name = "ha-cluster";
                  port = 50052;
                  protocol = "TCP";
                }
              ];
            };
          })
        else
          null;

      agentCoreDeployment =
        if config.mayastor.enabled then
          (scope.mkResource {
            apiVersion = "apps/v1";
            kind = "Deployment";
            name = "${name}-agent-core";
            labels = mayastorLabels // {
              app = "agent-core";
            };
            spec = {
              replicas = 1;
              selector.matchLabels = mayastorSelector "agent-core";
              template = {
                metadata.labels = mayastorSelector "agent-core" // {
                  "openebs.io/version" = config.mayastor.version;
                  "openebs.io/logging" = "true";
                };
                spec = {
                  serviceAccountName = self.mayastorSa.out.name;
                  priorityClassName = self.priorityClass.out.name;
                  nodeSelector = {
                    "kubernetes.io/arch" = "amd64";
                  };
                  tolerations = controlPlaneTolerations;
                  initContainers = [
                    {
                      name = "etcd-probe";
                      image = config.mayastor.image.alpineSh;
                      imagePullPolicy = "IfNotPresent";
                      command = [
                        "sh"
                        "-c"
                        "trap \"exit 1\" TERM; until nc -vzw 5 ${name}-etcd 2379; do date; echo \"Waiting for etcd...\"; sleep 1; done;"
                      ];
                    }
                  ];
                  containers = [
                    {
                      name = "agent-core";
                      image = config.mayastor.image.agentCore;
                      imagePullPolicy = "IfNotPresent";
                      args = [
                        "--store=${name}-etcd:2379"
                        "--request-timeout=5s"
                        "--cache-period=30s"
                        "--grpc-server-addr=[::]:50051"
                        "--pool-commitment=250%"
                        "--snapshot-commitment=40%"
                        "--volume-commitment-initial=40%"
                        "--volume-commitment=40%"
                        "--events-url=nats://${name}-nats:4222"
                        "--fmt-style=pretty"
                        "--ansi-colors=true"
                        "--create-volume-limit=10"
                      ];
                      env = [
                        {
                          name = "RUST_LOG";
                          value = "info";
                        }
                        {
                          name = "MY_POD_NAME";
                          valueFrom.fieldRef.fieldPath = "metadata.name";
                        }
                        {
                          name = "MY_POD_NAMESPACE";
                          valueFrom.fieldRef.fieldPath = "metadata.namespace";
                        }
                      ];
                      ports = [ { containerPort = 50051; } ];
                      resources = {
                        limits = {
                          cpu = "1000m";
                          memory = "128Mi";
                        };
                        requests = {
                          cpu = "500m";
                          memory = "32Mi";
                        };
                      };
                    }
                    {
                      name = "agent-ha-cluster";
                      image = config.mayastor.image.agentHaCluster;
                      imagePullPolicy = "IfNotPresent";
                      args = [
                        "-g=[::]:50052"
                        "--store=http://${name}-etcd:2379"
                        "--core-grpc=https://${name}-agent-core:50051"
                        "--events-url=nats://${name}-nats:4222"
                        "--ansi-colors=true"
                        "--fmt-style=pretty"
                      ];
                      env = [
                        {
                          name = "RUST_LOG";
                          value = "info";
                        }
                        {
                          name = "MY_POD_NAME";
                          valueFrom.fieldRef.fieldPath = "metadata.name";
                        }
                        {
                          name = "MY_POD_NAMESPACE";
                          valueFrom.fieldRef.fieldPath = "metadata.namespace";
                        }
                      ];
                      ports = [ { containerPort = 50052; } ];
                      resources = {
                        limits = {
                          cpu = "100m";
                          memory = "64Mi";
                        };
                        requests = {
                          cpu = "100m";
                          memory = "16Mi";
                        };
                      };
                    }
                  ];
                };
              };
            };
            requires = [
              self.etcdService
              self.natsService
            ];
          })
        else
          null;

      # --- api-rest (REST API gateway) ---
      apiRestService =
        if config.mayastor.enabled then
          (scope.mkResource {
            apiVersion = "v1";
            kind = "Service";
            name = "${name}-api-rest";
            labels = mayastorLabels // {
              app = "api-rest";
            };
            spec = {
              type = "ClusterIP";
              selector = self.apiRestDeployment.out.selector;
              ports = [
                {
                  name = "https";
                  port = 8080;
                  targetPort = 8080;
                  protocol = "TCP";
                }
                {
                  name = "http";
                  port = 8081;
                  targetPort = 8081;
                  protocol = "TCP";
                }
              ];
            };
          })
        else
          null;

      apiRestDeployment =
        if config.mayastor.enabled then
          (scope.mkResource {
            apiVersion = "apps/v1";
            kind = "Deployment";
            name = "${name}-api-rest";
            labels = mayastorLabels // {
              app = "api-rest";
            };
            spec = {
              replicas = 1;
              selector.matchLabels = mayastorSelector "api-rest";
              template = {
                metadata.labels = mayastorSelector "api-rest" // {
                  "openebs.io/version" = config.mayastor.version;
                  "openebs.io/logging" = "true";
                };
                spec = {
                  priorityClassName = self.priorityClass.out.name;
                  nodeSelector = {
                    "kubernetes.io/arch" = "amd64";
                  };
                  tolerations = controlPlaneTolerations;
                  initContainers = [
                    {
                      name = "agent-core-grpc-probe";
                      image = config.mayastor.image.alpineSh;
                      imagePullPolicy = "IfNotPresent";
                      command = [
                        "sh"
                        "-c"
                        "trap \"exit 1\" TERM; until nc -vzw 5 ${name}-agent-core 50051; do date; echo \"Waiting for agent-core-grpc services...\"; sleep 1; done;"
                      ];
                    }
                    {
                      name = "etcd-probe";
                      image = config.mayastor.image.alpineSh;
                      imagePullPolicy = "IfNotPresent";
                      command = [
                        "sh"
                        "-c"
                        "trap \"exit 1\" TERM; until nc -vzw 5 ${name}-etcd 2379; do date; echo \"Waiting for etcd...\"; sleep 1; done;"
                      ];
                    }
                  ];
                  containers = [
                    {
                      name = "api-rest";
                      image = config.mayastor.image.apiRest;
                      imagePullPolicy = "IfNotPresent";
                      args = [
                        "--dummy-certificates"
                        "--no-auth"
                        "--http=[::]:8081"
                        "--request-timeout=5s"
                        "--core-grpc=https://${name}-agent-core:50051"
                        "--ansi-colors=true"
                        "--fmt-style=pretty"
                        "--core-health-freq=20s"
                      ];
                      env = [
                        {
                          name = "RUST_LOG";
                          value = "info";
                        }
                      ];
                      ports = [
                        { containerPort = 8080; }
                        { containerPort = 8081; }
                      ];
                      readinessProbe = {
                        httpGet = {
                          path = "/ready";
                          port = 8081;
                        };
                        failureThreshold = 2;
                        periodSeconds = 20;
                        timeoutSeconds = 5;
                      };
                      livenessProbe = {
                        httpGet = {
                          path = "/live";
                          port = 8081;
                        };
                        failureThreshold = 1;
                        periodSeconds = 30;
                        timeoutSeconds = 5;
                      };
                      resources = {
                        limits = {
                          cpu = "100m";
                          memory = "128Mi";
                        };
                        requests = {
                          cpu = "50m";
                          memory = "32Mi";
                        };
                      };
                    }
                  ];
                };
              };
            };
            requires = [
              self.agentCoreService
              self.etcdService
            ];
          })
        else
          null;

      # --- operator-diskpool ---
      operatorDiskpoolDeployment =
        if config.mayastor.enabled then
          (scope.mkResource {
            apiVersion = "apps/v1";
            kind = "Deployment";
            name = "${name}-operator-diskpool";
            labels = mayastorLabels // {
              app = "operator-diskpool";
            };
            spec = {
              replicas = 1;
              selector.matchLabels = mayastorSelector "operator-diskpool";
              template = {
                metadata.labels = mayastorSelector "operator-diskpool" // {
                  "openebs.io/version" = config.mayastor.version;
                  "openebs.io/logging" = "true";
                };
                spec = {
                  serviceAccountName = self.mayastorSa.out.name;
                  priorityClassName = self.priorityClass.out.name;
                  nodeSelector = {
                    "kubernetes.io/arch" = "amd64";
                  };
                  tolerations = controlPlaneTolerations;
                  initContainers = [
                    {
                      name = "agent-core-grpc-probe";
                      image = config.mayastor.image.alpineSh;
                      imagePullPolicy = "IfNotPresent";
                      command = [
                        "sh"
                        "-c"
                        "trap \"exit 1\" TERM; until nc -vzw 5 ${name}-agent-core 50051; do date; echo \"Waiting for agent-core-grpc services...\"; sleep 1; done;"
                      ];
                    }
                    {
                      name = "etcd-probe";
                      image = config.mayastor.image.alpineSh;
                      imagePullPolicy = "IfNotPresent";
                      command = [
                        "sh"
                        "-c"
                        "trap \"exit 1\" TERM; until nc -vzw 5 ${name}-etcd 2379; do date; echo \"Waiting for etcd...\"; sleep 1; done;"
                      ];
                    }
                  ];
                  containers = [
                    {
                      name = "operator-diskpool";
                      image = config.mayastor.image.operatorDiskpool;
                      imagePullPolicy = "IfNotPresent";
                      args = [
                        "-e http://${name}-api-rest:8081"
                        "-n${ns}"
                        "--request-timeout=5s"
                        "--interval=30s"
                        "--ansi-colors=true"
                        "--fmt-style=pretty"
                      ];
                      env = [
                        {
                          name = "RUST_LOG";
                          value = "info";
                        }
                        {
                          name = "MY_POD_NAME";
                          valueFrom.fieldRef.fieldPath = "metadata.name";
                        }
                      ];
                      resources = {
                        limits = {
                          cpu = "100m";
                          memory = "32Mi";
                        };
                        requests = {
                          cpu = "50m";
                          memory = "16Mi";
                        };
                      };
                    }
                  ];
                };
              };
            };
            requires = [
              self.apiRestService
              self.agentCoreService
              self.etcdService
            ];
          })
        else
          null;

      # --- csi-controller (Mayastor CSI provisioner/attacher/snapshotter) ---
      csiControllerDeployment =
        if config.mayastor.enabled then
          (scope.mkResource {
            apiVersion = "apps/v1";
            kind = "Deployment";
            name = "${name}-csi-controller";
            labels = mayastorLabels // {
              app = "csi-controller";
            };
            spec = {
              replicas = config.mayastor.csiController.replicas;
              selector.matchLabels = mayastorSelector "csi-controller";
              template = {
                metadata.labels = mayastorSelector "csi-controller" // {
                  "openebs.io/version" = config.mayastor.version;
                  "openebs.io/logging" = "true";
                };
                spec = {
                  hostNetwork = true;
                  serviceAccountName = self.mayastorSa.out.name;
                  dnsPolicy = "ClusterFirstWithHostNet";
                  priorityClassName = self.priorityClass.out.name;
                  nodeSelector = {
                    "kubernetes.io/arch" = "amd64";
                  };
                  tolerations = controlPlaneTolerations;
                  initContainers = [
                    {
                      name = "api-rest-probe";
                      image = config.mayastor.image.alpineSh;
                      imagePullPolicy = "IfNotPresent";
                      command = [
                        "sh"
                        "-c"
                        "trap \"exit 1\" TERM; until nc -vzw 5 ${name}-api-rest 8081; do date; echo \"Waiting for REST API endpoint to become available\"; sleep 1; done;"
                      ];
                    }
                  ];
                  containers = [
                    {
                      name = "csi-provisioner";
                      image = config.mayastor.csiController.csiProvisioner;
                      imagePullPolicy = "IfNotPresent";
                      args = [
                        "--v=2"
                        "--csi-address=$(ADDRESS)"
                        "--feature-gates=Topology=true"
                        "--strict-topology=false"
                        "--default-fstype=ext4"
                        "--extra-create-metadata"
                        "--timeout=36s"
                        "--worker-threads=10"
                        "--prevent-volume-mode-conversion"
                      ];
                      env = [
                        {
                          name = "ADDRESS";
                          value = "/var/lib/csi/sockets/pluginproxy/csi.sock";
                        }
                      ];
                      volumeMounts = [
                        {
                          name = "socket-dir";
                          mountPath = "/var/lib/csi/sockets/pluginproxy/";
                        }
                      ];
                    }
                    {
                      name = "csi-attacher";
                      image = config.mayastor.csiController.csiAttacher;
                      imagePullPolicy = "IfNotPresent";
                      args = [
                        "--v=2"
                        "--timeout=36s"
                        "--csi-address=$(ADDRESS)"
                      ];
                      env = [
                        {
                          name = "ADDRESS";
                          value = "/var/lib/csi/sockets/pluginproxy/csi.sock";
                        }
                      ];
                      volumeMounts = [
                        {
                          name = "socket-dir";
                          mountPath = "/var/lib/csi/sockets/pluginproxy/";
                        }
                      ];
                    }
                    {
                      name = "csi-snapshotter";
                      image = config.mayastor.csiController.csiSnapshotter;
                      imagePullPolicy = "IfNotPresent";
                      args = [
                        "--v=2"
                        "--csi-address=$(ADDRESS)"
                      ];
                      env = [
                        {
                          name = "ADDRESS";
                          value = "/var/lib/csi/sockets/pluginproxy/csi.sock";
                        }
                      ];
                      volumeMounts = [
                        {
                          name = "socket-dir";
                          mountPath = "/var/lib/csi/sockets/pluginproxy/";
                        }
                      ];
                    }
                    {
                      name = "csi-snapshot-controller";
                      image = config.mayastor.csiController.snapshotController;
                      imagePullPolicy = "IfNotPresent";
                      args = [
                        "--v=2"
                        "--leader-election=false"
                        "--prevent-volume-mode-conversion"
                      ];
                    }
                    {
                      name = "csi-resizer";
                      image = config.mayastor.csiController.csiResizer;
                      imagePullPolicy = "IfNotPresent";
                      args = [
                        "--v=2"
                        "--csi-address=$(ADDRESS)"
                        "--handle-volume-inuse-error=false"
                      ];
                      env = [
                        {
                          name = "ADDRESS";
                          value = "/var/lib/csi/sockets/pluginproxy/csi.sock";
                        }
                      ];
                      volumeMounts = [
                        {
                          name = "socket-dir";
                          mountPath = "/var/lib/csi/sockets/pluginproxy/";
                        }
                      ];
                    }
                    {
                      name = "csi-controller";
                      image = config.mayastor.image.csiController;
                      imagePullPolicy = "IfNotPresent";
                      args = [
                        "--csi-socket=/var/lib/csi/sockets/pluginproxy/csi.sock"
                        "--rest-endpoint=http://${name}-api-rest:8081"
                        "--node-selector=openebs.io/csi-node=mayastor"
                        "--ansi-colors=true"
                        "--fmt-style=pretty"
                        "--create-volume-limit=10"
                      ];
                      env = [
                        {
                          name = "RUST_LOG";
                          value = "info";
                        }
                      ];
                      volumeMounts = [
                        {
                          name = "socket-dir";
                          mountPath = "/var/lib/csi/sockets/pluginproxy/";
                        }
                      ];
                      resources = {
                        limits = {
                          cpu = "32m";
                          memory = "128Mi";
                        };
                        requests = {
                          cpu = "16m";
                          memory = "64Mi";
                        };
                      };
                    }
                  ];
                  volumes = [
                    {
                      name = "socket-dir";
                      emptyDir = { };
                    }
                  ];
                };
              };
            };
            requires = [
              self.apiRestService
            ];
          })
        else
          null;

      # --- csi-node DaemonSet (Mayastor CSI node plugin) ---
      csiNodeDaemonSet =
        if config.mayastor.enabled then
          (scope.mkResource {
            apiVersion = "apps/v1";
            kind = "DaemonSet";
            name = "${name}-csi-node";
            labels = mayastorLabels // {
              app = "csi-node";
              "openebs.io/csi-node" = "mayastor";
            };
            spec = {
              selector.matchLabels = mayastorSelector "csi-node";
              updateStrategy = {
                type = "RollingUpdate";
                rollingUpdate.maxUnavailable = 1;
              };
              minReadySeconds = 10;
              template = {
                metadata.labels = mayastorSelector "csi-node" // {
                  "openebs.io/version" = config.mayastor.version;
                  "openebs.io/logging" = "true";
                };
                spec = {
                  serviceAccountName = self.mayastorSa.out.name;
                  hostNetwork = true;
                  dnsPolicy = "ClusterFirstWithHostNet";
                  nodeSelector = {
                    "kubernetes.io/arch" = "amd64";
                  };
                  initContainers = [
                    {
                      name = "nvme-tcp-probe";
                      image = config.mayastor.image.alpineSh;
                      command = [
                        "sh"
                        "-c"
                        ''trap "exit 1" TERM; until [ -d /sys/module/nvme_tcp ]; do [ -z "$WARNED" ] && echo "nvme_tcp module not loaded..."; WARNED=1; sleep 60; done;''
                      ];
                    }
                  ];
                  containers = [
                    {
                      name = "csi-node";
                      image = config.mayastor.image.csiNode;
                      imagePullPolicy = "IfNotPresent";
                      securityContext.privileged = true;
                      env = [
                        {
                          name = "RUST_LOG";
                          value = "info";
                        }
                        {
                          name = "MY_NODE_NAME";
                          valueFrom.fieldRef.fieldPath = "spec.nodeName";
                        }
                        {
                          name = "MY_POD_IP";
                          valueFrom.fieldRef.fieldPath = "status.podIP";
                        }
                        {
                          name = "RUST_BACKTRACE";
                          value = "1";
                        }
                      ];
                      args = [
                        "--csi-socket=/csi/csi.sock"
                        "--node-name=$(MY_NODE_NAME)"
                        "--rest-endpoint=http://${name}-api-rest:8081"
                        "--enable-rest"
                        "--enable-registration"
                        "--grpc-ip=$(MY_POD_IP)"
                        "--grpc-port=10199"
                        "--nvme-io-timeout=110s10s"
                        "--nvme-core-io-timeout=110s10s"
                        "--nvme-ctrl-loss-tmo=1980"
                        "--nvme-nr-io-queues=1"
                        "--nvme-connect-fallback=true"
                        "--kubelet-path=/var/lib/kubelet"
                        "--node-selector=openebs.io/csi-node=mayastor"
                        "--fmt-style=pretty"
                        "--ansi-colors=true"
                      ];
                      volumeMounts = [
                        {
                          name = "device";
                          mountPath = "/dev";
                        }
                        {
                          name = "sys";
                          mountPath = "/sys";
                        }
                        {
                          name = "run-udev";
                          mountPath = "/run/udev";
                        }
                        {
                          name = "plugin-dir";
                          mountPath = "/csi";
                        }
                        {
                          name = "kubelet-dir";
                          mountPath = "/var/lib/kubelet";
                          mountPropagation = "Bidirectional";
                        }
                      ];
                      resources = {
                        limits = {
                          cpu = "500m";
                          memory = "128Mi";
                        };
                        requests = {
                          cpu = "100m";
                          memory = "64Mi";
                        };
                      };
                    }
                    {
                      name = "csi-driver-registrar";
                      image = config.mayastor.csiNodeRegistrar;
                      imagePullPolicy = "IfNotPresent";
                      args = [
                        "--csi-address=/csi/csi.sock"
                        "--kubelet-registration-path=/var/lib/kubelet/plugins/io.openebs.mayastor/csi.sock"
                      ];
                      volumeMounts = [
                        {
                          name = "plugin-dir";
                          mountPath = "/csi";
                        }
                        {
                          name = "registration-dir";
                          mountPath = "/registration";
                        }
                      ];
                      resources = {
                        limits = {
                          cpu = "100m";
                          memory = "50Mi";
                        };
                        requests = {
                          cpu = "100m";
                          memory = "50Mi";
                        };
                      };
                      ports = [
                        {
                          containerPort = 10199;
                          protocol = "TCP";
                          name = "mayastor-node";
                        }
                      ];
                    }
                  ];
                  volumes = [
                    {
                      name = "device";
                      hostPath = {
                        path = "/dev";
                        type = "Directory";
                      };
                    }
                    {
                      name = "sys";
                      hostPath = {
                        path = "/sys";
                        type = "Directory";
                      };
                    }
                    {
                      name = "run-udev";
                      hostPath = {
                        path = "/run/udev";
                        type = "Directory";
                      };
                    }
                    {
                      name = "registration-dir";
                      hostPath = {
                        path = "/var/lib/kubelet/plugins_registry/";
                        type = "Directory";
                      };
                    }
                    {
                      name = "plugin-dir";
                      hostPath = {
                        path = "/var/lib/kubelet/plugins/io.openebs.mayastor/";
                        type = "DirectoryOrCreate";
                      };
                    }
                    {
                      name = "kubelet-dir";
                      hostPath = {
                        path = "/var/lib/kubelet";
                        type = "Directory";
                      };
                    }
                  ];
                };
              };
            };
            requires = [
              self.apiRestService
            ];
          })
        else
          null;

      # --- io-engine DaemonSet (Mayastor data plane — hugepages, privileged) ---
      ioEngineDaemonSet =
        if config.mayastor.enabled then
          (scope.mkResource {
            apiVersion = "apps/v1";
            kind = "DaemonSet";
            name = "${name}-io-engine";
            labels = mayastorLabels // {
              app = "io-engine";
            };
            spec = {
              selector.matchLabels = mayastorSelector "io-engine";
              updateStrategy.type = "OnDelete"; # io-engine requires manual rolling restart
              minReadySeconds = 10;
              template = {
                metadata.labels = mayastorSelector "io-engine" // {
                  "openebs.io/version" = config.mayastor.version;
                  "openebs.io/logging" = "true";
                };
                spec = {
                  hostNetwork = true;
                  dnsPolicy = "ClusterFirstWithHostNet";
                  nodeSelector = {
                    "kubernetes.io/arch" = "amd64";
                    "openebs.io/engine" = "mayastor"; # Only on designated storage nodes
                  };
                  initContainers = [
                    {
                      name = "agent-core-grpc-probe";
                      image = config.mayastor.image.alpineSh;
                      imagePullPolicy = "IfNotPresent";
                      command = [
                        "sh"
                        "-c"
                        "trap \"exit 1\" TERM; until nc -vzw 5 ${name}-agent-core 50051; do date; echo \"Waiting for agent-core-grpc services...\"; sleep 1; done;"
                      ];
                    }
                    {
                      name = "etcd-probe";
                      image = config.mayastor.image.alpineSh;
                      imagePullPolicy = "IfNotPresent";
                      command = [
                        "sh"
                        "-c"
                        "trap \"exit 1\" TERM; until nc -vzw 5 ${name}-etcd 2379; do date; echo \"Waiting for etcd...\"; sleep 1; done;"
                      ];
                    }
                  ];
                  containers = [
                    {
                      name = "metrics-exporter-io-engine";
                      image = config.mayastor.image.metricsExporter;
                      imagePullPolicy = "IfNotPresent";
                      env = [
                        {
                          name = "MY_NODE_NAME";
                          valueFrom.fieldRef.fieldPath = "spec.nodeName";
                        }
                        {
                          name = "MY_POD_IP";
                          valueFrom.fieldRef.fieldPath = "status.podIP";
                        }
                      ];
                      ports = [
                        {
                          containerPort = 9502;
                          protocol = "TCP";
                          name = "metrics";
                        }
                      ];
                      args = [
                        "--fmt-style=pretty"
                        "--ansi-colors=true"
                      ];
                    }
                    {
                      name = "io-engine";
                      image = config.mayastor.image.ioEngine;
                      imagePullPolicy = "IfNotPresent";
                      securityContext.privileged = true;
                      command = [ "io-engine" ];
                      args = [
                        "--grpc-ip=$(MY_POD_IP)"
                        "-N$(MY_NODE_NAME)"
                        "-Rhttps://${name}-agent-core:50051"
                        "-y/var/local/openebs/io-engine/config.yaml"
                        "-l${cpuList}"
                        "-p=${name}-etcd:2379"
                        "--ptpl-dir=/var/local/openebs/io-engine/ptpl/"
                        "--api-versions=v1"
                        "--tgt-crdt=30"
                        "--events-url=nats://${name}-nats:4222"
                        "--ps-retries=300"
                      ];
                      env = [
                        {
                          name = "RUST_LOG";
                          value = "info";
                        }
                        {
                          name = "NVMF_TCP_MAX_QPAIRS_PER_CTRL";
                          value = "32";
                        }
                        {
                          name = "NVMF_TCP_MAX_QUEUE_DEPTH";
                          value = "32";
                        }
                        {
                          name = "NVME_TIMEOUT";
                          value = "110s";
                        }
                        {
                          name = "NVME_TIMEOUT_ADMIN";
                          value = "30s";
                        }
                        {
                          name = "NVME_KATO";
                          value = "10s";
                        }
                        {
                          name = "MY_NODE_NAME";
                          valueFrom.fieldRef.fieldPath = "spec.nodeName";
                        }
                        {
                          name = "MY_POD_IP";
                          valueFrom.fieldRef.fieldPath = "status.podIP";
                        }
                        {
                          name = "NEXUS_NVMF_ANA_ENABLE";
                          value = "1";
                        }
                        {
                          name = "NEXUS_NVMF_RESV_ENABLE";
                          value = "1";
                        }
                      ];
                      volumeMounts = [
                        {
                          name = "device";
                          mountPath = "/dev";
                        }
                        {
                          name = "udev";
                          mountPath = "/run/udev";
                        }
                        {
                          name = "dshm";
                          mountPath = "/dev/shm";
                        }
                        {
                          name = "configlocation";
                          mountPath = "/var/local/openebs/io-engine/";
                        }
                        {
                          name = "hugepage";
                          mountPath = "/dev/hugepages";
                        }
                      ];
                      resources = config.mayastor.ioEngine.resources;
                      ports = [
                        {
                          containerPort = 10124;
                          protocol = "TCP";
                          name = "io-engine";
                        }
                      ];
                    }
                  ];
                  volumes = [
                    {
                      name = "device";
                      hostPath = {
                        path = "/dev";
                        type = "Directory";
                      };
                    }
                    {
                      name = "udev";
                      hostPath = {
                        path = "/run/udev";
                        type = "Directory";
                      };
                    }
                    {
                      name = "dshm";
                      emptyDir = {
                        medium = "Memory";
                        sizeLimit = "1Gi";
                      };
                    }
                    {
                      name = "hugepage";
                      emptyDir = {
                        medium = "HugePages";
                      };
                    }
                    {
                      name = "configlocation";
                      hostPath = {
                        path = "/var/local/openebs/io-engine/";
                        type = "DirectoryOrCreate";
                      };
                    }
                  ];
                };
              };
            };
            requires = [
              self.agentCoreService
              self.etcdService
              self.natsService
            ];
          })
        else
          null;

      # --- io-engine metrics Service ---
      ioEngineMetricsService =
        if config.mayastor.enabled then
          (scope.mkResource {
            apiVersion = "v1";
            kind = "Service";
            name = "${name}-metrics-exporter-io-engine";
            labels = mayastorLabels // {
              app = "io-engine";
            };
            spec = {
              selector = self.ioEngineDaemonSet.out.selector;
              ports = [
                {
                  name = "metrics";
                  port = 9502;
                  targetPort = 9502;
                  protocol = "TCP";
                }
              ];
            };
          })
        else
          null;

      # --- agent-ha-node DaemonSet ---
      agentHaNodeDaemonSet =
        if config.mayastor.enabled then
          (scope.mkResource {
            apiVersion = "apps/v1";
            kind = "DaemonSet";
            name = "${name}-agent-ha-node";
            labels = mayastorLabels // {
              app = "agent-ha-node";
            };
            spec = {
              selector.matchLabels = mayastorSelector "agent-ha-node";
              updateStrategy = {
                type = "RollingUpdate";
                rollingUpdate.maxUnavailable = 1;
              };
              minReadySeconds = 10;
              template = {
                metadata.labels = mayastorSelector "agent-ha-node" // {
                  "openebs.io/version" = config.mayastor.version;
                  "openebs.io/logging" = "true";
                };
                spec = {
                  hostNetwork = true;
                  dnsPolicy = "ClusterFirstWithHostNet";
                  nodeSelector = {
                    "kubernetes.io/arch" = "amd64";
                  };
                  initContainers = [
                    {
                      name = "agent-cluster-grpc-probe";
                      image = config.mayastor.image.alpineSh;
                      imagePullPolicy = "IfNotPresent";
                      command = [
                        "sh"
                        "-c"
                        "trap \"exit 1\" TERM; until nc -vzw 5 ${name}-agent-core 50052; do date; echo \"Waiting for agent-cluster-grpc services...\"; sleep 1; done;"
                      ];
                    }
                  ];
                  containers = [
                    {
                      name = "agent-ha-node";
                      image = config.mayastor.image.agentHaNode;
                      imagePullPolicy = "IfNotPresent";
                      securityContext.privileged = true;
                      env = [
                        {
                          name = "RUST_LOG";
                          value = "info";
                        }
                        {
                          name = "MY_NODE_NAME";
                          valueFrom.fieldRef.fieldPath = "spec.nodeName";
                        }
                        {
                          name = "MY_POD_IP";
                          valueFrom.fieldRef.fieldPath = "status.podIP";
                        }
                        {
                          name = "RUST_BACKTRACE";
                          value = "1";
                        }
                      ];
                      args = [
                        "--node-name=$(MY_NODE_NAME)"
                        "--csi-socket=/csi/csi.sock"
                        "--grpc-ip=$(MY_POD_IP)"
                        "--grpc-port=50053"
                        "--cluster-agent=https://${name}-agent-core:50052"
                        "--events-url=nats://${name}-nats:4222"
                        "--ansi-colors=true"
                        "--fmt-style=pretty"
                      ];
                      volumeMounts = [
                        {
                          name = "device";
                          mountPath = "/dev";
                        }
                        {
                          name = "sys";
                          mountPath = "/sys";
                        }
                        {
                          name = "run-udev";
                          mountPath = "/run/udev";
                        }
                        {
                          name = "plugin-dir";
                          mountPath = "/csi";
                        }
                      ];
                      resources = {
                        limits = {
                          cpu = "100m";
                          memory = "64Mi";
                        };
                        requests = {
                          cpu = "100m";
                          memory = "64Mi";
                        };
                      };
                      ports = [
                        {
                          containerPort = 50053;
                          protocol = "TCP";
                          name = "ha-node";
                        }
                      ];
                    }
                  ];
                  volumes = [
                    {
                      name = "device";
                      hostPath = {
                        path = "/dev";
                        type = "Directory";
                      };
                    }
                    {
                      name = "sys";
                      hostPath = {
                        path = "/sys";
                        type = "Directory";
                      };
                    }
                    {
                      name = "run-udev";
                      hostPath = {
                        path = "/run/udev";
                        type = "Directory";
                      };
                    }
                    {
                      name = "plugin-dir";
                      hostPath = {
                        path = "/var/lib/kubelet/plugins/io.openebs.mayastor/";
                        type = "DirectoryOrCreate";
                      };
                    }
                  ];
                };
              };
            };
            requires = [
              self.agentCoreService
              self.natsService
            ];
          })
        else
          null;

      # --- Mayastor default StorageClass ---
      #
      # Matches the mayastor helm chart's storageclass.yaml: no labels, no
      # explicit volumeBindingMode (k8s defaults to Immediate),
      # allowVolumeExpansion enabled, parameter is `repl` (not `repl_count`).
      mayastorStorageClass =
        if config.mayastor.enabled then
          (scope.mkClusterResource {
            apiVersion = "storage.k8s.io/v1";
            kind = "StorageClass";
            name = "openebs-single-replica";
            extra = {
              provisioner = "io.openebs.csi-mayastor";
              allowVolumeExpansion = true;
              parameters = {
                protocol = "nvmf";
                repl = "1";
              };
            };
          })
        else
          null;

      # ==========================================================================
      #  ZFS LocalPV
      # ==========================================================================

      # --- ServiceAccounts ---
      zfsControllerSa =
        if config.zfsLocalPv.enabled then
          (scope.mkResource {
            apiVersion = "v1";
            kind = "ServiceAccount";
            name = "${name}-zfs-controller-sa";
            labels = zfsControllerLabels;
          })
        else
          null;

      zfsNodeSa =
        if config.zfsLocalPv.enabled then
          (scope.mkResource {
            apiVersion = "v1";
            kind = "ServiceAccount";
            name = "${name}-zfs-node-sa";
            labels = zfsNodeLabels;
          })
        else
          null;

      # --- CSIDriver ---
      zfsCsiDriver =
        if config.zfsLocalPv.enabled then
          (scope.mkClusterResource {
            apiVersion = "storage.k8s.io/v1";
            kind = "CSIDriver";
            name = "zfs.csi.openebs.io";
            labels = zfsLabels;
            spec = {
              attachRequired = false;
              podInfoOnMount = false;
              storageCapacity = true;
            };
          })
        else
          null;

      # --- ZFS ConfigMap (zfs binary wrapper) ---
      zfsConfigMap =
        if config.zfsLocalPv.enabled then
          (scope.mkResource {
            apiVersion = "v1";
            kind = "ConfigMap";
            name = "${name}-zfspv-bin";
            labels = zfsNodeLabels;
            data.zfs = ''
              #!/bin/sh
              if [ -x /host/sbin/zfs ]; then
                chroot /host /sbin/zfs "$@"
              elif [ -x /host/usr/sbin/zfs ]; then
                chroot /host /usr/sbin/zfs "$@"
              else
                chroot /host "zfs" "$@"
              fi
            '';
          })
        else
          null;

      # --- ZFS Controller Deployment ---
      zfsController =
        if config.zfsLocalPv.enabled then
          (scope.mkResource {
            apiVersion = "apps/v1";
            kind = "Deployment";
            name = "${name}-zfs-localpv-controller";
            labels = zfsControllerLabels // {
              app = "openebs-zfs-controller";
            };
            spec = {
              replicas = 1;
              selector.matchLabels = {
                app = "openebs-zfs-controller";
                component = "openebs-zfs-controller";
                release = name;
              };
              template = {
                metadata.labels = {
                  app = "openebs-zfs-controller";
                  role = "openebs-zfs";
                  component = "openebs-zfs-controller";
                  name = "openebs-zfs-controller";
                  release = name;
                  "openebs.io/component-name" = "openebs-zfs-controller";
                  "openebs.io/version" = zfsVersion;
                };
                spec = {
                  serviceAccountName = self.zfsControllerSa.out.name;
                  priorityClassName = "openebs-zfs-csi-controller-critical";
                  containers = [
                    {
                      name = "csi-provisioner";
                      image = config.zfsLocalPv.csiProvisioner;
                      imagePullPolicy = "IfNotPresent";
                      args = [
                        "--csi-address=$(ADDRESS)"
                        "--v=5"
                        "--feature-gates=Topology=true"
                        "--strict-topology"
                        "--extra-create-metadata=true"
                        "--enable-capacity=true"
                        "--default-fstype=ext4"
                      ];
                      env = [
                        {
                          name = "ADDRESS";
                          value = "/var/lib/csi/sockets/pluginproxy/csi.sock";
                        }
                        {
                          name = "NAMESPACE";
                          valueFrom.fieldRef.fieldPath = "metadata.namespace";
                        }
                        {
                          name = "POD_NAME";
                          valueFrom.fieldRef.fieldPath = "metadata.name";
                        }
                      ];
                      volumeMounts = [
                        {
                          name = "socket-dir";
                          mountPath = "/var/lib/csi/sockets/pluginproxy/";
                        }
                      ];
                    }
                    {
                      name = "csi-resizer";
                      image = "registry.k8s.io/sig-storage/csi-resizer:v1.8.0";
                      imagePullPolicy = "IfNotPresent";
                      args = [
                        "--v=5"
                        "--csi-address=$(ADDRESS)"
                      ];
                      env = [
                        {
                          name = "ADDRESS";
                          value = "/var/lib/csi/sockets/pluginproxy/csi.sock";
                        }
                      ];
                      volumeMounts = [
                        {
                          name = "socket-dir";
                          mountPath = "/var/lib/csi/sockets/pluginproxy/";
                        }
                      ];
                    }
                    {
                      name = "csi-snapshotter";
                      image = "registry.k8s.io/sig-storage/csi-snapshotter:v6.2.2";
                      imagePullPolicy = "IfNotPresent";
                      args = [
                        "--csi-address=$(ADDRESS)"
                      ];
                      env = [
                        {
                          name = "ADDRESS";
                          value = "/var/lib/csi/sockets/pluginproxy/csi.sock";
                        }
                      ];
                      volumeMounts = [
                        {
                          name = "socket-dir";
                          mountPath = "/var/lib/csi/sockets/pluginproxy/";
                        }
                      ];
                    }
                    {
                      name = "snapshot-controller";
                      image = "registry.k8s.io/sig-storage/snapshot-controller:v6.2.2";
                      imagePullPolicy = "IfNotPresent";
                      args = [
                        "--v=5"
                      ];
                    }
                    {
                      name = "openebs-zfs-plugin";
                      image = "openebs/zfs-driver:${zfsVersion}";
                      imagePullPolicy = "IfNotPresent";
                      args = [
                        "--endpoint=$(OPENEBS_CSI_ENDPOINT)"
                        "--plugin=$(OPENEBS_CONTROLLER_DRIVER)"
                      ];
                      env = [
                        {
                          name = "OPENEBS_CSI_ENDPOINT";
                          value = "unix:///var/lib/csi/sockets/pluginproxy/csi.sock";
                        }
                        {
                          name = "OPENEBS_CONTROLLER_DRIVER";
                          value = "controller";
                        }
                        {
                          name = "OPENEBS_IO_ENABLE_ANALYTICS";
                          value = "true";
                        }
                        {
                          name = "OPENEBS_IO_INSTALLER_TYPE";
                          value = "zfs-localpv-helm";
                        }
                        {
                          name = "OPENEBS_NAMESPACE";
                          valueFrom.fieldRef.fieldPath = "metadata.namespace";
                        }
                      ];
                      volumeMounts = [
                        {
                          name = "socket-dir";
                          mountPath = "/var/lib/csi/sockets/pluginproxy/";
                        }
                      ];
                    }
                  ];
                  volumes = [
                    {
                      name = "socket-dir";
                      emptyDir = { };
                    }
                  ];
                };
              };
            };
            requires = [
              self.zfsCsiDriver
            ];
          })
        else
          null;

      # --- ZFS Node DaemonSet ---
      zfsNode =
        if config.zfsLocalPv.enabled then
          (scope.mkResource {
            apiVersion = "apps/v1";
            kind = "DaemonSet";
            name = "${name}-zfs-localpv-node";
            labels = zfsNodeLabels // {
              app = "openebs-zfs-node";
            };
            spec = {
              selector.matchLabels = {
                name = "openebs-zfs-node";
                release = name;
              };
              updateStrategy = {
                type = "RollingUpdate";
                rollingUpdate = {
                  maxUnavailable = "100%";
                };
              };
              template = {
                metadata.labels = {
                  app = "openebs-zfs-node";
                  role = "openebs-zfs";
                  name = "openebs-zfs-node";
                  release = name;
                  "openebs.io/component-name" = "openebs-zfs-node";
                  "openebs.io/version" = zfsVersion;
                };
                spec = {
                  serviceAccountName = self.zfsNodeSa.out.name;
                  hostNetwork = true;
                  priorityClassName = "openebs-zfs-csi-node-critical";
                  containers = [
                    {
                      name = "csi-node-driver-registrar";
                      image = "registry.k8s.io/sig-storage/csi-node-driver-registrar:v2.8.0";
                      imagePullPolicy = "IfNotPresent";
                      args = [
                        "--v=5"
                        "--csi-address=$(ADDRESS)"
                        "--kubelet-registration-path=$(DRIVER_REG_SOCK_PATH)"
                      ];
                      env = [
                        {
                          name = "ADDRESS";
                          value = "/plugin/csi.sock";
                        }
                        {
                          name = "DRIVER_REG_SOCK_PATH";
                          value = "/var/lib/kubelet/plugins/zfs-localpv/csi.sock";
                        }
                        {
                          name = "KUBE_NODE_NAME";
                          valueFrom.fieldRef.fieldPath = "spec.nodeName";
                        }
                        {
                          name = "NODE_DRIVER";
                          value = "openebs-zfs";
                        }
                      ];
                      lifecycle.preStop.exec.command = [
                        "/bin/sh"
                        "-c"
                        "rm -rf /registration/zfs-localpv /registration/zfs-localpv-reg.sock"
                      ];
                      volumeMounts = [
                        {
                          name = "plugin-dir";
                          mountPath = "/plugin";
                        }
                        {
                          name = "registration-dir";
                          mountPath = "/registration";
                        }
                      ];
                    }
                    {
                      name = "openebs-zfs-plugin";
                      image = "openebs/zfs-driver:${zfsVersion}";
                      imagePullPolicy = "IfNotPresent";
                      securityContext = {
                        privileged = true;
                        allowPrivilegeEscalation = true;
                      };
                      args = [
                        "--endpoint=$(OPENEBS_CSI_ENDPOINT)"
                        "--nodename=$(OPENEBS_NODE_NAME)"
                        "--plugin=$(OPENEBS_NODE_DRIVER)"
                      ];
                      env = [
                        {
                          name = "OPENEBS_CSI_ENDPOINT";
                          value = "unix:///plugin/csi.sock";
                        }
                        {
                          name = "OPENEBS_NODE_NAME";
                          valueFrom.fieldRef.fieldPath = "spec.nodeName";
                        }
                        {
                          name = "OPENEBS_NODE_DRIVER";
                          value = "agent";
                        }
                        {
                          name = "OPENEBS_NAMESPACE";
                          valueFrom.fieldRef.fieldPath = "metadata.namespace";
                        }
                        {
                          name = "ALLOWED_TOPOLOGIES";
                          value = "All";
                        }
                      ];
                      volumeMounts = [
                        {
                          name = "plugin-dir";
                          mountPath = "/plugin";
                        }
                        {
                          name = "device-dir";
                          mountPath = "/dev";
                        }
                        {
                          name = "host-root";
                          mountPath = "/host";
                          mountPropagation = "HostToContainer";
                          readOnly = true;
                        }
                        {
                          name = "pods-mount-dir";
                          mountPath = "/var/lib/kubelet/";
                          mountPropagation = "Bidirectional";
                        }
                        {
                          name = "chroot-zfs";
                          mountPath = "/sbin/zfs";
                          subPath = "zfs";
                        }
                        {
                          name = "encr-keys";
                          mountPath = "/home/keys";
                        }
                      ];
                    }
                  ];
                  volumes = [
                    {
                      name = "device-dir";
                      hostPath = {
                        path = "/dev";
                        type = "Directory";
                      };
                    }
                    {
                      name = "host-root";
                      hostPath = {
                        path = "/";
                        type = "Directory";
                      };
                    }
                    {
                      name = "registration-dir";
                      hostPath = {
                        path = "/var/lib/kubelet/plugins_registry/";
                        type = "DirectoryOrCreate";
                      };
                    }
                    {
                      name = "plugin-dir";
                      hostPath = {
                        path = "/var/lib/kubelet/plugins/zfs-localpv/";
                        type = "DirectoryOrCreate";
                      };
                    }
                    {
                      name = "pods-mount-dir";
                      hostPath = {
                        path = "/var/lib/kubelet/";
                        type = "Directory";
                      };
                    }
                    {
                      name = "chroot-zfs";
                      configMap = {
                        name = self.zfsConfigMap.out.name;
                        defaultMode = 365;
                      };
                    } # 0555
                    {
                      name = "encr-keys";
                      hostPath = {
                        path = config.zfsLocalPv.encrKeysDir;
                        type = "DirectoryOrCreate";
                      };
                    }
                  ];
                };
              };
            };
            requires = [
              self.zfsCsiDriver
            ];
          })
        else
          null;

      # ==========================================================================
      #  LVM LocalPV
      # ==========================================================================

      # --- ServiceAccounts ---
      lvmControllerSa =
        if config.lvmLocalPv.enabled then
          (scope.mkResource {
            apiVersion = "v1";
            kind = "ServiceAccount";
            name = "${name}-lvm-controller-sa";
            labels = lvmControllerLabels;
          })
        else
          null;

      lvmNodeSa =
        if config.lvmLocalPv.enabled then
          (scope.mkResource {
            apiVersion = "v1";
            kind = "ServiceAccount";
            name = "${name}-lvm-node-sa";
            labels = lvmNodeLabels;
          })
        else
          null;

      # --- CSIDriver ---
      lvmCsiDriver =
        if config.lvmLocalPv.enabled then
          (scope.mkClusterResource {
            apiVersion = "storage.k8s.io/v1";
            kind = "CSIDriver";
            name = "local.csi.openebs.io";
            labels = lvmLabels;
            spec = {
              attachRequired = false;
              podInfoOnMount = true;
              storageCapacity = true;
            };
          })
        else
          null;

      # --- LVM Controller Deployment ---
      lvmController =
        if config.lvmLocalPv.enabled then
          (scope.mkResource {
            apiVersion = "apps/v1";
            kind = "Deployment";
            name = "${name}-lvm-localpv-controller";
            labels = lvmControllerLabels // {
              app = "openebs-lvm-controller";
            };
            spec = {
              replicas = 1;
              selector.matchLabels = {
                app = "openebs-lvm-controller";
                component = "openebs-lvm-controller";
                release = name;
              };
              template = {
                metadata.labels = {
                  app = "openebs-lvm-controller";
                  role = "openebs-lvm";
                  component = "openebs-lvm-controller";
                  release = name;
                  "openebs.io/component-name" = "openebs-lvm-controller";
                  "openebs.io/version" = lvmVersion;
                };
                spec = {
                  serviceAccountName = self.lvmControllerSa.out.name;
                  priorityClassName = "openebs-lvm-localpv-csi-controller-critical";
                  containers = [
                    {
                      name = "csi-provisioner";
                      image = config.lvmLocalPv.csiProvisioner;
                      imagePullPolicy = "IfNotPresent";
                      args = [
                        "--csi-address=$(ADDRESS)"
                        "--v=5"
                        "--feature-gates=Topology=true"
                        "--strict-topology"
                        "--extra-create-metadata=true"
                        "--enable-capacity=true"
                        "--default-fstype=ext4"
                      ];
                      env = [
                        {
                          name = "ADDRESS";
                          value = "/var/lib/csi/sockets/pluginproxy/csi.sock";
                        }
                        {
                          name = "NAMESPACE";
                          valueFrom.fieldRef.fieldPath = "metadata.namespace";
                        }
                        {
                          name = "POD_NAME";
                          valueFrom.fieldRef.fieldPath = "metadata.name";
                        }
                      ];
                      volumeMounts = [
                        {
                          name = "socket-dir";
                          mountPath = "/var/lib/csi/sockets/pluginproxy/";
                        }
                      ];
                    }
                    {
                      name = "csi-resizer";
                      image = "registry.k8s.io/sig-storage/csi-resizer:v1.8.0";
                      imagePullPolicy = "IfNotPresent";
                      args = [
                        "--v=5"
                        "--csi-address=$(ADDRESS)"
                      ];
                      env = [
                        {
                          name = "ADDRESS";
                          value = "/var/lib/csi/sockets/pluginproxy/csi.sock";
                        }
                      ];
                      volumeMounts = [
                        {
                          name = "socket-dir";
                          mountPath = "/var/lib/csi/sockets/pluginproxy/";
                        }
                      ];
                    }
                    {
                      name = "csi-snapshotter";
                      image = "registry.k8s.io/sig-storage/csi-snapshotter:v6.2.2";
                      imagePullPolicy = "IfNotPresent";
                      args = [
                        "--csi-address=$(ADDRESS)"
                      ];
                      env = [
                        {
                          name = "ADDRESS";
                          value = "/var/lib/csi/sockets/pluginproxy/csi.sock";
                        }
                      ];
                      volumeMounts = [
                        {
                          name = "socket-dir";
                          mountPath = "/var/lib/csi/sockets/pluginproxy/";
                        }
                      ];
                    }
                    {
                      name = "snapshot-controller";
                      image = "registry.k8s.io/sig-storage/snapshot-controller:v6.2.2";
                      imagePullPolicy = "IfNotPresent";
                      args = [
                        "--v=5"
                      ];
                    }
                    {
                      name = "openebs-lvm-plugin";
                      image = "openebs/lvm-driver:${lvmVersion}";
                      imagePullPolicy = "IfNotPresent";
                      args = [
                        "--endpoint=$(OPENEBS_CSI_ENDPOINT)"
                        "--kube-api-burst=0"
                        "--kube-api-qps=0"
                        "--plugin=$(OPENEBS_CONTROLLER_DRIVER)"
                      ];
                      env = [
                        {
                          name = "OPENEBS_CSI_ENDPOINT";
                          value = "unix:///var/lib/csi/sockets/pluginproxy/csi.sock";
                        }
                        {
                          name = "LVM_NAMESPACE";
                          valueFrom.fieldRef.fieldPath = "metadata.namespace";
                        }
                        {
                          name = "OPENEBS_CONTROLLER_DRIVER";
                          value = "controller";
                        }
                        {
                          name = "OPENEBS_IO_ENABLE_ANALYTICS";
                          value = "true";
                        }
                        {
                          name = "OPENEBS_IO_INSTALLER_TYPE";
                          value = "lvm-localpv-helm";
                        }
                      ];
                      volumeMounts = [
                        {
                          name = "socket-dir";
                          mountPath = "/var/lib/csi/sockets/pluginproxy/";
                        }
                      ];
                    }
                  ];
                  volumes = [
                    {
                      name = "socket-dir";
                      emptyDir = { };
                    }
                  ];
                };
              };
            };
            requires = [
              self.lvmCsiDriver
            ];
          })
        else
          null;

      # --- LVM Node DaemonSet ---
      lvmNode =
        if config.lvmLocalPv.enabled then
          (scope.mkResource {
            apiVersion = "apps/v1";
            kind = "DaemonSet";
            name = "${name}-lvm-localpv-node";
            labels = lvmNodeLabels // {
              app = "openebs-lvm-node";
            };
            spec = {
              selector.matchLabels = {
                name = "openebs-lvm-node";
                release = name;
              };
              updateStrategy = {
                type = "RollingUpdate";
                rollingUpdate = {
                  maxUnavailable = "100%";
                };
              };
              template = {
                metadata.labels = {
                  app = "openebs-lvm-node";
                  role = "openebs-lvm";
                  name = "openebs-lvm-node";
                  release = name;
                  "openebs.io/component-name" = "openebs-lvm-node";
                  "openebs.io/version" = lvmVersion;
                };
                spec = {
                  serviceAccountName = self.lvmNodeSa.out.name;
                  priorityClassName = "openebs-lvm-localpv-csi-node-critical";
                  containers = [
                    {
                      name = "csi-node-driver-registrar";
                      image = "registry.k8s.io/sig-storage/csi-node-driver-registrar:v2.8.0";
                      imagePullPolicy = "IfNotPresent";
                      args = [
                        "--v=5"
                        "--csi-address=$(ADDRESS)"
                        "--kubelet-registration-path=$(DRIVER_REG_SOCK_PATH)"
                      ];
                      env = [
                        {
                          name = "ADDRESS";
                          value = "/plugin/csi.sock";
                        }
                        {
                          name = "DRIVER_REG_SOCK_PATH";
                          value = "/var/lib/kubelet/plugins/lvm-localpv/csi.sock";
                        }
                        {
                          name = "KUBE_NODE_NAME";
                          valueFrom.fieldRef.fieldPath = "spec.nodeName";
                        }
                        {
                          name = "NODE_DRIVER";
                          value = "openebs-lvm";
                        }
                      ];
                      lifecycle.preStop.exec.command = [
                        "/bin/sh"
                        "-c"
                        "rm -rf /registration/lvm-localpv /registration/lvm-localpv-reg.sock"
                      ];
                      volumeMounts = [
                        {
                          name = "plugin-dir";
                          mountPath = "/plugin";
                        }
                        {
                          name = "registration-dir";
                          mountPath = "/registration";
                        }
                      ];
                    }
                    {
                      name = "openebs-lvm-plugin";
                      image = "openebs/lvm-driver:${lvmVersion}";
                      imagePullPolicy = "IfNotPresent";
                      securityContext = {
                        privileged = true;
                        allowPrivilegeEscalation = true;
                      };
                      args = [
                        "--endpoint=$(OPENEBS_CSI_ENDPOINT)"
                        "--nodeid=$(OPENEBS_NODE_ID)"
                        "--kube-api-burst=0"
                        "--kube-api-qps=0"
                        "--listen-address=$(METRICS_LISTEN_ADDRESS)"
                        "--plugin=$(OPENEBS_NODE_DRIVER)"
                      ];
                      env = [
                        {
                          name = "OPENEBS_CSI_ENDPOINT";
                          value = "unix:///plugin/csi.sock";
                        }
                        {
                          name = "OPENEBS_NODE_ID";
                          valueFrom.fieldRef.fieldPath = "spec.nodeName";
                        }
                        {
                          name = "LVM_NAMESPACE";
                          valueFrom.fieldRef.fieldPath = "metadata.namespace";
                        }
                        {
                          name = "ALLOWED_TOPOLOGIES";
                          value = "kubernetes.io/hostname,";
                        }
                        {
                          name = "METRICS_LISTEN_ADDRESS";
                          value = ":9500";
                        }
                        {
                          name = "OPENEBS_NODE_DRIVER";
                          value = "agent";
                        }
                      ];
                      volumeMounts = [
                        {
                          name = "plugin-dir";
                          mountPath = "/plugin";
                        }
                        {
                          name = "device-dir";
                          mountPath = "/dev";
                        }
                        {
                          name = "pods-mount-dir";
                          mountPath = "/var/lib/kubelet/";
                          mountPropagation = "Bidirectional";
                        }
                      ];
                    }
                  ];
                  volumes = [
                    {
                      name = "device-dir";
                      hostPath = {
                        path = "/dev";
                        type = "Directory";
                      };
                    }
                    {
                      name = "registration-dir";
                      hostPath = {
                        path = "/var/lib/kubelet/plugins_registry/";
                        type = "DirectoryOrCreate";
                      };
                    }
                    {
                      name = "plugin-dir";
                      hostPath = {
                        path = "/var/lib/kubelet/plugins/lvm-localpv/";
                        type = "DirectoryOrCreate";
                      };
                    }
                    {
                      name = "pods-mount-dir";
                      hostPath = {
                        path = "/var/lib/kubelet/";
                        type = "Directory";
                      };
                    }
                  ];
                };
              };
            };
            requires = [
              self.lvmCsiDriver
            ];
          })
        else
          null;

      # --- LVM Node Service (for metrics) ---
      lvmNodeService =
        if config.lvmLocalPv.enabled then
          (scope.mkResource {
            apiVersion = "v1";
            kind = "Service";
            name = "${name}-lvm-localpv-node-service";
            labels = lvmNodeLabels;
            spec = {
              clusterIP = "None";
              # Chart 4.2.0 uses an `app:` selector here, not the DaemonSet's
              # full label set. The lvmNode pod template carries `app:
              # openebs-lvm-node`, so this still selects correctly.
              selector.app = "openebs-lvm-node";
              ports = [
                {
                  name = "metrics";
                  port = 9500;
                  targetPort = 9500;
                  protocol = "TCP";
                }
              ];
            };
          })
        else
          null;

      # ==========================================================================
      #  LocalPV Provisioner (hostpath — optional)
      # ==========================================================================

      localPvSa =
        if config.localPvProvisioner.enabled then
          (scope.mkResource {
            apiVersion = "v1";
            kind = "ServiceAccount";
            name = "${name}-localpv-provisioner";
            labels = localPvLabels // {
              "openebs.io/component-name" = "${name}-localpv-provisioner";
            };
          })
        else
          null;

      localPvDeployment =
        if config.localPvProvisioner.enabled then
          (scope.mkResource {
            apiVersion = "apps/v1";
            kind = "Deployment";
            name = "${name}-localpv-provisioner";
            labels = localPvLabels // {
              "openebs.io/component-name" = "${name}-localpv-provisioner";
            };
            spec = {
              replicas = 1;
              strategy.type = "Recreate";
              selector.matchLabels = {
                app = "localpv-provisioner";
                name = "${name}-localpv-provisioner";
              };
              template = {
                metadata.labels = {
                  app = "localpv-provisioner";
                  name = "${name}-localpv-provisioner";
                  "openebs.io/component-name" = "${name}-localpv-provisioner";
                };
                spec = {
                  serviceAccountName = self.localPvSa.out.name;
                  tolerations = controlPlaneTolerations;
                  containers = [
                    {
                      name = "openebs-localpv-provisioner";
                      image = config.localPvProvisioner.image;
                      imagePullPolicy = "IfNotPresent";
                      env = [
                        {
                          name = "LEADER_ELECTION_ENABLED";
                          value = "true";
                        }
                        {
                          name = "NODE_NAME";
                          valueFrom.fieldRef.fieldPath = "spec.nodeName";
                        }
                        {
                          name = "OPENEBS_NAMESPACE";
                          valueFrom.fieldRef.fieldPath = "metadata.namespace";
                        }
                        {
                          name = "OPENEBS_IO_HELPER_IMAGE";
                          value =
                            if config.localPvProvisioner.helperImage != null then
                              config.localPvProvisioner.helperImage
                            else
                              config.localPvProvisioner.image;
                        }
                        {
                          name = "OPENEBS_IO_BASE_PATH";
                          value = config.localPvProvisioner.basePath;
                        }
                        {
                          name = "OPENEBS_IO_ENABLE_ANALYTICS";
                          value = "true";
                        }
                        {
                          name = "OPENEBS_IO_INSTALLER_TYPE";
                          value = "openebs-localpv-provisioner-helm";
                        }
                      ];
                      livenessProbe = {
                        exec.command = [
                          "sh"
                          "-c"
                          "test `pgrep -c \"^provisioner-loc\"` = 1"
                        ];
                        initialDelaySeconds = 30;
                        periodSeconds = 60;
                      };
                    }
                  ];
                };
              };
            };
            requires = [ ];
          })
        else
          null;

      localPvStorageClass =
        if config.localPvProvisioner.enabled then
          (scope.mkClusterResource {
            apiVersion = "storage.k8s.io/v1";
            kind = "StorageClass";
            name = "openebs-hostpath";
            labels = localPvLabels;
            annotations = {
              "openebs.io/cas-type" = "local";
              "cas.openebs.io/config" = ''
                - name: StorageType
                  value: "hostpath"
                - name: BasePath
                  value: "${config.localPvProvisioner.basePath}"
              '';
            };
            extra = {
              provisioner = "openebs.io/local";
              volumeBindingMode = "WaitForFirstConsumer";
              reclaimPolicy = "Delete";
            };
          })
        else
          null;

      # ==========================================================================
      # ==========================================================================
      #  DiskPool custom resources
      # ==========================================================================

      diskPoolResources = lib.listToAttrs (
        map (pool: {
          name = "diskPool-${pool.name}";
          value = scope.mkResource {
            apiVersion = "openebs.io/v1beta2";
            kind = "DiskPool";
            name = pool.name;
            spec = {
              node = pool.node;
              disks = pool.disks;
            };
          };
        }) config.diskPools
      );

      # ==========================================================================
      #  obs-callhome (telemetry: ships periodic usage reports to OpenEBS)
      #  Verbatim from the upstream chart — emitted to converge with the
      #  Ansible dump. Deployment + sidecar Service, paired with the
      #  shared `mayastorSa` service account.
      # ==========================================================================

      obsCallhomeService =
        if config.mayastor.enabled then
          (scope.mkResource {
            apiVersion = "v1";
            kind = "Service";
            name = "${name}-obs-callhome-stats";
            labels = {
              app = "obs-callhome";
              "openebs.io/release" = name;
              "openebs.io/version" = "2.8.0";
            };
            spec = {
              selector = {
                app = "obs-callhome";
                "openebs.io/release" = name;
              };
              ports = [
                {
                  name = "https";
                  port = 9090;
                  targetPort = 9090;
                  protocol = "TCP";
                }
                {
                  name = "http";
                  port = 9091;
                  targetPort = 9091;
                  protocol = "TCP";
                }
              ];
            };
          })
        else
          null;

      obsCallhomeDeployment =
        if config.mayastor.enabled then
          (scope.mkResource {
            apiVersion = "apps/v1";
            kind = "Deployment";
            name = "${name}-obs-callhome";
            labels = {
              app = "obs-callhome";
              "openebs.io/release" = name;
              "openebs.io/version" = "2.8.0";
            };
            spec = {
              replicas = 1;
              selector.matchLabels = {
                app = "obs-callhome";
                "openebs.io/release" = name;
              };
              template = {
                metadata.labels = {
                  app = "obs-callhome";
                  "openebs.io/release" = name;
                  "openebs.io/version" = "2.8.0";
                  "openebs.io/logging" = "true";
                };
                spec = {
                  serviceAccountName = self.mayastorSa.out.name;
                  imagePullSecrets = null;
                  nodeSelector = {
                    "kubernetes.io/arch" = "amd64";
                  };
                  containers = [
                    {
                      name = "obs-callhome";
                      image = "docker.io/openebs/mayastor-obs-callhome:v2.8.0";
                      args = [
                        "-e http://${name}-api-rest:8081"
                        "-n ${ns}"
                        "--aggregator-url=http://${name}-obs-callhome-stats:9090/stats"
                        "--send-report"
                      ];
                      env = [
                        {
                          name = "RUST_LOG";
                          value = "info";
                        }
                      ];
                      imagePullPolicy = "IfNotPresent";
                      resources = {
                        limits = {
                          cpu = "100m";
                          memory = "32Mi";
                        };
                        requests = {
                          cpu = "50m";
                          memory = "16Mi";
                        };
                      };
                    }
                    {
                      name = "obs-callhome-stats";
                      image = "docker.io/openebs/mayastor-obs-callhome-stats:v2.8.0";
                      args = [
                        "--namespace=${ns}"
                        "--release-name=${name}"
                        "--mbus-url=nats://${name}-nats:4222"
                        "--ansi-colors=true"
                        "--fmt-style=pretty"
                      ];
                      ports = [
                        {
                          containerPort = 9090;
                          protocol = "TCP";
                          name = "stats";
                        }
                      ];
                      env = [
                        {
                          name = "RUST_LOG";
                          value = "info";
                        }
                      ];
                      imagePullPolicy = "IfNotPresent";
                      resources = {
                        limits = {
                          cpu = "100m";
                          memory = "32Mi";
                        };
                        requests = {
                          cpu = "50m";
                          memory = "16Mi";
                        };
                      };
                    }
                  ];
                };
              };
            };
            requires = [
              self.mayastorSa
              self.apiRestService
              self.natsService
              self.obsCallhomeService
            ];
          })
        else
          null;

      #  Entry point
      # ==========================================================================

      root = {
        resource = self.apiRestService;
        requires =
          # --- Mayastor components ---
          lib.optionals config.mayastor.enabled [
            self.mayastorSa
            self.priorityClass
            self.etcdStatefulSet
            self.etcdService
            self.etcdHeadlessService
            self.etcdStorageClass
            self.etcdPdb
            self.natsStatefulSet
            self.natsService
            self.natsSa
            self.natsConfigMap
            self.natsPdb
            self.agentCoreDeployment
            self.agentCoreService
            self.apiRestDeployment
            self.operatorDiskpoolDeployment
            self.csiControllerDeployment
            self.csiNodeDaemonSet
            self.ioEngineDaemonSet
            self.ioEngineMetricsService
            self.agentHaNodeDaemonSet
            self.mayastorStorageClass
            self.obsCallhomeService
            self.obsCallhomeDeployment
          ]
          # --- ZFS LocalPV components ---
          ++ lib.optionals config.zfsLocalPv.enabled [
            self.zfsControllerSa
            self.zfsNodeSa
            self.zfsCsiDriver
            self.zfsConfigMap
            self.zfsController
            self.zfsNode
          ]
          # --- LVM LocalPV components ---
          ++ lib.optionals config.lvmLocalPv.enabled [
            self.lvmControllerSa
            self.lvmNodeSa
            self.lvmCsiDriver
            self.lvmController
            self.lvmNode
            self.lvmNodeService
          ]
          # --- LocalPV Provisioner (optional) ---
          ++ lib.optionals config.localPvProvisioner.enabled [
            self.localPvSa
            self.localPvDeployment
            self.localPvStorageClass
          ]
          # --- DiskPool CRs ---
          ++ lib.attrValues self.diskPoolResources;
      };
    }
    // mayastorClusterRoles
    // zfsControllerRoles
    // zfsNodeRoles
    // lvmControllerRoles
    // lvmNodeRoles
    // localPvClusterRoles;
}
