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
# main = api-rest Service (primary Mayastor interface)
# Everything else pulled in via requires chain.

{
  scope,
  config,
  lib,
}:

let
  name = scope.instanceName;

  cfg = scope.defaults config {
    mayastor = {
      enabled = true;
      version = "v2.8.0";
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
        # dedicated to SPDK reactor. Default 2 matches upstream.
        cpuCount = 2;
        resources = {
          requests = {
            cpu = "2";
            memory = "1Gi";
            "hugepages-2Mi" = "2Gi";
          };
          limits = {
            cpu = "2";
            memory = "1Gi";
            "hugepages-2Mi" = "2Gi";
          };
        };
      };
      csiNodeRegistrar = "registry.k8s.io/sig-storage/csi-node-driver-registrar:v2.10.0";
    };
    zfsLocalPv = {
      enabled = true;
      image = "openebs/zfs-driver:2.7.0";
      csiProvisioner = "registry.k8s.io/sig-storage/csi-provisioner:v3.5.0";
      csiResizer = "registry.k8s.io/sig-storage/csi-resizer:v1.9.3";
      csiSnapshotter = "registry.k8s.io/sig-storage/csi-snapshotter:v6.3.3";
      snapshotController = "registry.k8s.io/sig-storage/snapshot-controller:v6.3.3";
      csiNodeRegistrar = "registry.k8s.io/sig-storage/csi-node-driver-registrar:v2.10.0";
    };
    lvmLocalPv = {
      enabled = true;
      image = "openebs/lvm-driver:1.7.0";
      csiProvisioner = "registry.k8s.io/sig-storage/csi-provisioner:v3.5.0";
      csiResizer = "registry.k8s.io/sig-storage/csi-resizer:v1.9.3";
      csiSnapshotter = "registry.k8s.io/sig-storage/csi-snapshotter:v6.3.3";
      snapshotController = "registry.k8s.io/sig-storage/snapshot-controller:v6.3.3";
      csiNodeRegistrar = "registry.k8s.io/sig-storage/csi-node-driver-registrar:v2.10.0";
    };
    localPvProvisioner = {
      enabled = false;
      image = "openebs/provisioner-localpv:4.2.0";
      basePath = "/var/openebs/local";
    };
  };

  ns = scope.namespaceName;

  # --- Shared labels ---
  mayastorLabels = {
    "app.kubernetes.io/name" = "openebs";
    "app.kubernetes.io/instance" = name;
    "app.kubernetes.io/component" = "mayastor";
  };

  zfsLabels = {
    "app.kubernetes.io/name" = "openebs";
    "app.kubernetes.io/instance" = name;
    "app.kubernetes.io/component" = "zfs-localpv";
  };

  lvmLabels = {
    "app.kubernetes.io/name" = "openebs";
    "app.kubernetes.io/instance" = name;
    "app.kubernetes.io/component" = "lvm-localpv";
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

  # --- CPU list for io-engine (e.g. "1,2" for cpuCount=2) ---
  cpuList =
    let
      indices = lib.genList (i: toString (i + 1)) cfg.mayastor.ioEngine.cpuCount;
    in
    builtins.concatStringsSep "," indices;

  # --- RBAC DSL ---
  inherit (scope.rbac) group core grant full watch emit allow mkClusterRoleSet;
  openebsGrp = group "openebs.io" [ "mayastorpools" "diskpools" ];
  storage    = group "storage.k8s.io" [ "storageclasses" "volumeattachments" "csinodes" ];
  snap       = group "snapshot.storage.k8s.io" [ "volumesnapshotclasses" "volumesnapshotcontents" "volumesnapshots" ];
  coord      = group "coordination.k8s.io" [ "leases" ];
  apiext     = group "apiextensions.k8s.io" [ "customresourcedefinitions" ];
  appsGrp    = group "apps" [ "deployments" ];
  zfsAll     = group "zfs.openebs.io" [];
  lvmAll     = group "local.openebs.io" [];

in
self:
let
  # ── Mayastor RBAC ────────────────────────────────────────
  mayastorClusterRoles =
    if cfg.mayastor.enabled then
      mkClusterRoleSet scope {
        subjects = [{ kind = "ServiceAccount"; name = "${self.mayastorSa}"; namespace = ns; }];
        labels = mayastorLabels;
        roles = {
          "${name}-cluster-role" = grant [
            (apiext.customresourcedefinitions           |> allow [ "create" "get" "update" "list" "patch" "replace" ])
            (apiext "customresourcedefinitions/status"  |> allow [ "get" "update" "patch" ])
            (openebsGrp.mayastorpools                  |> allow [ "get" "list" "patch" "delete" "deletecollection" ])
            (openebsGrp.diskpools                      |> allow [ "get" "list" "watch" "update" "replace" "patch" "create" ])
            (openebsGrp "diskpools/status"             |> allow [ "update" "patch" ])
            (core.configmaps                           |> allow [ "create" "get" "update" "patch" ])
            (appsGrp.deployments                       |> allow [ "get" "list" ])
            (core.persistentvolumes                    |> full)
            (core.nodes                                |> allow [ "get" "list" "watch" "patch" ])
            (core.persistentvolumeclaims               |> allow [ "get" "list" "watch" "update" ])
            (storage.storageclasses                    |> watch)
            (core.events                               |> allow [ "list" "watch" "create" "update" "patch" ])
            (core.pods                                 |> watch)
            (core "persistentvolumeclaims/status"      |> allow [ "patch" ])
            (snap.volumesnapshotclasses                |> watch)
            (snap.volumesnapshotcontents               |> full)
            (snap "volumesnapshotcontents/status"      |> allow [ "update" "patch" ])
            (snap.volumesnapshots                      |> allow [ "get" "list" "watch" "update" "patch" "delete" ])
            (snap "volumesnapshots/status"             |> allow [ "update" "patch" ])
            (storage.volumeattachments                 |> allow [ "get" "list" "watch" "update" "patch" ])
            (storage "volumeattachments/status"        |> allow [ "patch" ])
            (storage.csinodes                          |> watch)
            (core.secrets                              |> watch)
          ];
        };
      }
    else {};

  # ── ZFS LocalPV RBAC ────────────────────────────────────
  zfsControllerRoles =
    if cfg.zfsLocalPv.enabled then
      mkClusterRoleSet scope {
        subjects = [{ kind = "ServiceAccount"; name = "${self.zfsControllerSa}"; namespace = ns; }];
        labels = zfsLabels;
        roles = {
          "${name}-zfs-provisioner-role" = grant [
            (core.persistentvolumes                    |> full)
            (core.persistentvolumeclaims               |> allow [ "get" "list" "watch" "update" ])
            (core "persistentvolumeclaims/status"      |> allow [ "update" "patch" ])
            (storage.storageclasses                    |> watch)
            (storage.csinodes                          |> watch)
            (core.events                               |> allow [ "list" "watch" "create" "update" "patch" ])
            (core.nodes                                |> watch)
            (coord.leases                              |> allow [ "get" "watch" "list" "delete" "update" "create" ])
            (zfsAll "*"                                |> allow [ "*" ])
          ];
          "${name}-zfs-snapshotter-role" = grant [
            (snap.volumesnapshotclasses                |> watch)
            (snap.volumesnapshotcontents               |> full)
            (snap "volumesnapshotcontents/status"      |> allow [ "update" "patch" ])
            (snap.volumesnapshots                      |> allow [ "get" "list" "watch" "update" "patch" ])
            (snap "volumesnapshots/status"             |> allow [ "update" "patch" ])
          ];
        };
      }
    else {};

  zfsNodeRoles =
    if cfg.zfsLocalPv.enabled then
      mkClusterRoleSet scope {
        subjects = [{ kind = "ServiceAccount"; name = "${self.zfsNodeSa}"; namespace = ns; }];
        labels = zfsLabels;
        roles = {
          "${name}-zfs-driver-registrar-role" = grant [
            (core.events                               |> allow [ "get" "list" "watch" "create" "update" "patch" ])
            (zfsAll "*"                                |> allow [ "*" ])
          ];
        };
      }
    else {};

  # ── LVM LocalPV RBAC ───────────────────────────────────
  lvmControllerRoles =
    if cfg.lvmLocalPv.enabled then
      mkClusterRoleSet scope {
        subjects = [{ kind = "ServiceAccount"; name = "${self.lvmControllerSa}"; namespace = ns; }];
        labels = lvmLabels;
        roles = {
          "${name}-lvm-provisioner-role" = grant [
            (core.persistentvolumes                    |> full)
            (core.persistentvolumeclaims               |> allow [ "get" "list" "watch" "update" ])
            (core "persistentvolumeclaims/status"      |> allow [ "update" "patch" ])
            (storage.storageclasses                    |> watch)
            (storage.csinodes                          |> watch)
            (core.events                               |> allow [ "list" "watch" "create" "update" "patch" ])
            (core.nodes                                |> watch)
            (coord.leases                              |> allow [ "get" "watch" "list" "delete" "update" "create" ])
            (lvmAll "*"                                |> allow [ "*" ])
          ];
          "${name}-lvm-snapshotter-role" = grant [
            (snap.volumesnapshotclasses                |> watch)
            (snap.volumesnapshotcontents               |> full)
            (snap "volumesnapshotcontents/status"      |> allow [ "update" "patch" ])
            (snap.volumesnapshots                      |> allow [ "get" "list" "watch" "update" "patch" ])
            (snap "volumesnapshots/status"             |> allow [ "update" "patch" ])
          ];
        };
      }
    else {};

  lvmNodeRoles =
    if cfg.lvmLocalPv.enabled then
      mkClusterRoleSet scope {
        subjects = [{ kind = "ServiceAccount"; name = "${self.lvmNodeSa}"; namespace = ns; }];
        labels = lvmLabels;
        roles = {
          "${name}-lvm-driver-registrar-role" = grant [
            (core.events                               |> allow [ "get" "list" "watch" "create" "update" "patch" ])
            (lvmAll "*"                                |> allow [ "*" ])
          ];
        };
      }
    else {};

  # ── LocalPV Provisioner RBAC ────────────────────────────
  localPvClusterRoles =
    if cfg.localPvProvisioner.enabled then
      mkClusterRoleSet scope {
        subjects = [{ kind = "ServiceAccount"; name = "${self.localPvSa}"; namespace = ns; }];
        labels = localPvLabels;
        roles = {
          "${name}-localpv-provisioner" = grant [
            (core.nodes                                |> watch)
            (core.persistentvolumes                    |> allow [ "get" "list" "watch" "create" "delete" ])
            (core.persistentvolumeclaims               |> allow [ "get" "list" "watch" "update" ])
            (storage.storageclasses                    |> watch)
            (core.events                               |> emit)
          ];
        };
      }
    else {};
in {

  # ==========================================================================
  #  MAYASTOR — Replicated Block Storage
  # ==========================================================================

  # --- ServiceAccount (shared by all Mayastor components) ---
  mayastorSa =
    if cfg.mayastor.enabled then
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
    if cfg.mayastor.enabled then
      (scope.mkClusterResource {
        apiVersion = "scheduling.k8s.io/v1";
        kind = "PriorityClass";
        name = "${name}-cluster-critical";
        labels = mayastorLabels;
        extra = {
          value = 1000000000;
          preemptionPolicy = "PreemptLowerPriority";
          description = "Critical pods for OpenEBS Mayastor control plane.";
        };
      })
    else
      null;

  # --- etcd (coordination store for Mayastor) ---

  etcdHeadlessService =
    if cfg.mayastor.enabled then
      (scope.mkResource {
        apiVersion = "v1";
        kind = "Service";
        name = "${name}-etcd-headless";
        labels = mayastorLabels // {
          "app.kubernetes.io/component" = "etcd";
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
              targetPort = 2379;
              protocol = "TCP";
            }
            {
              name = "peer";
              port = 2380;
              targetPort = 2380;
              protocol = "TCP";
            }
          ];
        };
      })
    else
      null;

  etcdService =
    if cfg.mayastor.enabled then
      (scope.mkResource {
        apiVersion = "v1";
        kind = "Service";
        name = "${name}-etcd";
        labels = mayastorLabels // {
          "app.kubernetes.io/component" = "etcd";
        };
        spec = {
          type = "ClusterIP";
          selector = scope.selectWorkload self.etcdStatefulSet;
          ports = [
            {
              name = "client";
              port = 2379;
              targetPort = 2379;
              protocol = "TCP";
            }
            {
              name = "peer";
              port = 2380;
              targetPort = 2380;
              protocol = "TCP";
            }
          ];
        };
      })
    else
      null;

  etcdStatefulSet =
    if cfg.mayastor.enabled then
      (scope.mkResource {
        apiVersion = "apps/v1";
        kind = "StatefulSet";
        name = "${name}-etcd";
        labels = mayastorLabels // {
          "app.kubernetes.io/component" = "etcd";
        };
        spec = {
          replicas = cfg.mayastor.etcd.replicaCount;
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
              securityContext = {
                fsGroup = 1001;
              };
              initContainers = [
                {
                  name = "volume-permissions";
                  image = cfg.mayastor.image.alpineBash;
                  imagePullPolicy = "IfNotPresent";
                  command = [
                    "/bin/bash"
                    "-ec"
                    "chown -R 1001:1001 /bitnami/etcd"
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
                  image = cfg.mayastor.etcd.image;
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
                        ) cfg.mayastor.etcd.replicaCount
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
                  ];
                }
              ];
            };
          };
          volumeClaimTemplates = [
            {
              metadata.name = "data";
              spec = {
                accessModes = [ "ReadWriteOnce" ];
                resources.requests.storage = cfg.mayastor.etcd.persistence.size;
                storageClassName = cfg.mayastor.etcd.persistence.storageClass;
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
  etcdStorageClass =
    if cfg.mayastor.enabled then
      (scope.mkClusterResource {
        apiVersion = "storage.k8s.io/v1";
        kind = "StorageClass";
        name = "mayastor-etcd-localpv";
        labels = mayastorLabels;
        extra = {
          provisioner = "openebs.io/local";
          volumeBindingMode = "WaitForFirstConsumer";
          reclaimPolicy = "Delete";
          parameters."cas.openebs.io/config" = ''
            - name: StorageType
              value: "hostpath"
            - name: BasePath
              value: "/var/local/openebs/mayastor-etcd"
          '';
        };
      })
    else
      null;

  # --- NATS (messaging for Mayastor events) ---

  natsConfigMap =
    if cfg.mayastor.enabled then
      (scope.mkResource {
        apiVersion = "v1";
        kind = "ConfigMap";
        name = "${name}-nats-config";
        labels = mayastorLabels // {
          "app.kubernetes.io/component" = "nats";
        };
        data."nats.conf" = ''
          # NATS config for OpenEBS Mayastor
          pid_file: "/var/run/nats/nats.pid"
          http: 8222
          server_name: $SERVER_NAME
          cluster {
            port: 6222
            routes [
              ${builtins.concatStringsSep "\n          " (
                lib.genList (
                  i: "nats://${name}-nats-${toString i}.${name}-nats.${ns}:6222"
                ) cfg.mayastor.nats.replicaCount
              )}
            ]
            cluster_advertise: $CLUSTER_ADVERTISE
            connect_retries: 120
          }
          max_payload: 8MB
          max_pending: 128MB
          lame_duck_duration: 30s
          lame_duck_grace_period: 10s
        '';
      })
    else
      null;

  natsSa =
    if cfg.mayastor.enabled then
      (scope.mkResource {
        apiVersion = "v1";
        kind = "ServiceAccount";
        name = "${name}-nats";
        labels = mayastorLabels // {
          "app.kubernetes.io/component" = "nats";
        };
      })
    else
      null;

  natsService =
    if cfg.mayastor.enabled then
      (scope.mkResource {
        apiVersion = "v1";
        kind = "Service";
        name = "${name}-nats";
        labels = mayastorLabels // {
          "app.kubernetes.io/component" = "nats";
        };
        spec = {
          selector = scope.selectWorkload self.natsStatefulSet;
          ports = [
            {
              name = "client";
              port = 4222;
              protocol = "TCP";
            }
            {
              name = "cluster";
              port = 6222;
              protocol = "TCP";
            }
            {
              name = "monitor";
              port = 8222;
              protocol = "TCP";
            }
            {
              name = "metrics";
              port = 7777;
              protocol = "TCP";
            }
          ];
        };
      })
    else
      null;

  natsStatefulSet =
    if cfg.mayastor.enabled then
      (scope.mkResource {
        apiVersion = "apps/v1";
        kind = "StatefulSet";
        name = "${name}-nats";
        labels = mayastorLabels // {
          "app.kubernetes.io/component" = "nats";
        };
        spec = {
          replicas = cfg.mayastor.nats.replicaCount;
          serviceName = "${name}-nats";
          podManagementPolicy = "Parallel";
          selector.matchLabels = {
            "app.kubernetes.io/name" = "nats";
            "app.kubernetes.io/instance" = name;
          };
          template = {
            metadata.labels = {
              "app.kubernetes.io/name" = "nats";
              "app.kubernetes.io/instance" = name;
              app = "nats";
            };
            spec = {
              serviceAccountName = "${self.natsSa}";
              dnsPolicy = "ClusterFirst";
              shareProcessNamespace = true;
              terminationGracePeriodSeconds = 60;
              volumes = [
                {
                  name = "config-volume";
                  configMap.name = "${self.natsConfigMap}";
                }
                {
                  name = "pid";
                  emptyDir = { };
                }
              ];
              containers = [
                {
                  name = "nats";
                  image = cfg.mayastor.nats.image;
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
                  image = cfg.mayastor.nats.reloaderImage;
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
                  image = cfg.mayastor.nats.exporterImage;
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
    if cfg.mayastor.enabled then
      (scope.mkResource {
        apiVersion = "v1";
        kind = "Service";
        name = "${name}-agent-core";
        labels = mayastorLabels // {
          app = "agent-core";
        };
        spec = {
          selector = scope.selectWorkload self.agentCoreDeployment;
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
    if cfg.mayastor.enabled then
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
              "openebs.io/version" = cfg.mayastor.version;
            };
            spec = {
              serviceAccountName = "${self.mayastorSa}";
              priorityClassName = "${self.priorityClass}";
              nodeSelector = {
                "kubernetes.io/arch" = "amd64";
              };
              tolerations = controlPlaneTolerations;
              initContainers = [
                {
                  name = "etcd-probe";
                  image = cfg.mayastor.image.alpineSh;
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
                  image = cfg.mayastor.image.agentCore;
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
                  image = cfg.mayastor.image.agentHaCluster;
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
          self.mayastorSa
          self.priorityClass
        ];
      })
    else
      null;

  # --- api-rest (REST API gateway) ---
  apiRestService =
    if cfg.mayastor.enabled then
      (scope.mkResource {
        apiVersion = "v1";
        kind = "Service";
        name = "${name}-api-rest";
        labels = mayastorLabels // {
          app = "api-rest";
        };
        spec = {
          type = "ClusterIP";
          selector = scope.selectWorkload self.apiRestDeployment;
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
    if cfg.mayastor.enabled then
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
              "openebs.io/version" = cfg.mayastor.version;
            };
            spec = {
              priorityClassName = "${self.priorityClass}";
              nodeSelector = {
                "kubernetes.io/arch" = "amd64";
              };
              tolerations = controlPlaneTolerations;
              initContainers = [
                {
                  name = "agent-core-grpc-probe";
                  image = cfg.mayastor.image.alpineSh;
                  imagePullPolicy = "IfNotPresent";
                  command = [
                    "sh"
                    "-c"
                    "trap \"exit 1\" TERM; until nc -vzw 5 ${name}-agent-core 50051; do date; echo \"Waiting for agent-core...\"; sleep 1; done;"
                  ];
                }
                {
                  name = "etcd-probe";
                  image = cfg.mayastor.image.alpineSh;
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
                  image = cfg.mayastor.image.apiRest;
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
                      memory = "64Mi";
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
          self.priorityClass
        ];
      })
    else
      null;

  # --- operator-diskpool ---
  operatorDiskpoolDeployment =
    if cfg.mayastor.enabled then
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
              "openebs.io/version" = cfg.mayastor.version;
            };
            spec = {
              serviceAccountName = "${self.mayastorSa}";
              priorityClassName = "${self.priorityClass}";
              nodeSelector = {
                "kubernetes.io/arch" = "amd64";
              };
              tolerations = controlPlaneTolerations;
              initContainers = [
                {
                  name = "agent-core-grpc-probe";
                  image = cfg.mayastor.image.alpineSh;
                  imagePullPolicy = "IfNotPresent";
                  command = [
                    "sh"
                    "-c"
                    "trap \"exit 1\" TERM; until nc -vzw 5 ${name}-agent-core 50051; do date; echo \"Waiting for agent-core...\"; sleep 1; done;"
                  ];
                }
                {
                  name = "etcd-probe";
                  image = cfg.mayastor.image.alpineSh;
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
                  image = cfg.mayastor.image.operatorDiskpool;
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
          self.mayastorSa
          self.priorityClass
        ];
      })
    else
      null;

  # --- csi-controller (Mayastor CSI provisioner/attacher/snapshotter) ---
  csiControllerDeployment =
    if cfg.mayastor.enabled then
      (scope.mkResource {
        apiVersion = "apps/v1";
        kind = "Deployment";
        name = "${name}-csi-controller";
        labels = mayastorLabels // {
          app = "csi-controller";
        };
        spec = {
          replicas = cfg.mayastor.csiController.replicas;
          selector.matchLabels = mayastorSelector "csi-controller";
          template = {
            metadata.labels = mayastorSelector "csi-controller" // {
              "openebs.io/version" = cfg.mayastor.version;
            };
            spec = {
              hostNetwork = true;
              serviceAccountName = "${self.mayastorSa}";
              dnsPolicy = "ClusterFirstWithHostNet";
              priorityClassName = "${self.priorityClass}";
              nodeSelector = {
                "kubernetes.io/arch" = "amd64";
              };
              tolerations = controlPlaneTolerations;
              initContainers = [
                {
                  name = "api-rest-probe";
                  image = cfg.mayastor.image.alpineSh;
                  imagePullPolicy = "IfNotPresent";
                  command = [
                    "sh"
                    "-c"
                    "trap \"exit 1\" TERM; until nc -vzw 5 ${name}-api-rest 8081; do date; echo \"Waiting for REST API...\"; sleep 1; done;"
                  ];
                }
              ];
              containers = [
                {
                  name = "csi-provisioner";
                  image = cfg.mayastor.csiController.csiProvisioner;
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
                  image = cfg.mayastor.csiController.csiAttacher;
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
                  image = cfg.mayastor.csiController.csiSnapshotter;
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
                  image = cfg.mayastor.csiController.snapshotController;
                  imagePullPolicy = "IfNotPresent";
                  args = [
                    "--v=2"
                    "--leader-election=false"
                    "--prevent-volume-mode-conversion"
                  ];
                }
                {
                  name = "csi-resizer";
                  image = cfg.mayastor.csiController.csiResizer;
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
                  image = cfg.mayastor.image.csiController;
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
          self.mayastorSa
          self.priorityClass
        ];
      })
    else
      null;

  # --- csi-node DaemonSet (Mayastor CSI node plugin) ---
  csiNodeDaemonSet =
    if cfg.mayastor.enabled then
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
              "openebs.io/version" = cfg.mayastor.version;
            };
            spec = {
              serviceAccountName = "${self.mayastorSa}";
              hostNetwork = true;
              dnsPolicy = "ClusterFirstWithHostNet";
              nodeSelector = {
                "kubernetes.io/arch" = "amd64";
              };
              containers = [
                {
                  name = "csi-node";
                  image = cfg.mayastor.image.csiNode;
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
                    "--nvme-nr-io-queues=2"
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
                      cpu = "100m";
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
                  image = cfg.mayastor.csiNodeRegistrar;
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
          self.mayastorSa
        ];
      })
    else
      null;

  # --- io-engine DaemonSet (Mayastor data plane — hugepages, privileged) ---
  ioEngineDaemonSet =
    if cfg.mayastor.enabled then
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
              "openebs.io/version" = cfg.mayastor.version;
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
                  image = cfg.mayastor.image.alpineSh;
                  imagePullPolicy = "IfNotPresent";
                  command = [
                    "sh"
                    "-c"
                    "trap \"exit 1\" TERM; until nc -vzw 5 ${name}-agent-core 50051; do date; echo \"Waiting for agent-core...\"; sleep 1; done;"
                  ];
                }
                {
                  name = "etcd-probe";
                  image = cfg.mayastor.image.alpineSh;
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
                  image = cfg.mayastor.image.metricsExporter;
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
                  image = cfg.mayastor.image.ioEngine;
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
                  resources = cfg.mayastor.ioEngine.resources;
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
    if cfg.mayastor.enabled then
      (scope.mkResource {
        apiVersion = "v1";
        kind = "Service";
        name = "${name}-metrics-exporter-io-engine";
        labels = mayastorLabels // {
          app = "io-engine";
        };
        spec = {
          selector = scope.selectWorkload self.ioEngineDaemonSet;
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
    if cfg.mayastor.enabled then
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
              "openebs.io/version" = cfg.mayastor.version;
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
                  image = cfg.mayastor.image.alpineSh;
                  imagePullPolicy = "IfNotPresent";
                  command = [
                    "sh"
                    "-c"
                    "trap \"exit 1\" TERM; until nc -vzw 5 ${name}-agent-core 50052; do date; echo \"Waiting for agent-cluster-grpc...\"; sleep 1; done;"
                  ];
                }
              ];
              containers = [
                {
                  name = "agent-ha-node";
                  image = cfg.mayastor.image.agentHaNode;
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
  mayastorStorageClass =
    if cfg.mayastor.enabled then
      (scope.mkClusterResource {
        apiVersion = "storage.k8s.io/v1";
        kind = "StorageClass";
        name = "openebs-single-replica";
        labels = mayastorLabels;
        extra = {
          provisioner = "io.openebs.csi-mayastor";
          volumeBindingMode = "Immediate";
          parameters = {
            ioTimeout = "30";
            protocol = "nvmf";
            repl_count = "1";
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
    if cfg.zfsLocalPv.enabled then
      (scope.mkResource {
        apiVersion = "v1";
        kind = "ServiceAccount";
        name = "${name}-zfs-controller-sa";
        labels = zfsLabels;
      })
    else
      null;

  zfsNodeSa =
    if cfg.zfsLocalPv.enabled then
      (scope.mkResource {
        apiVersion = "v1";
        kind = "ServiceAccount";
        name = "${name}-zfs-node-sa";
        labels = zfsLabels;
      })
    else
      null;

  # --- CSIDriver ---
  zfsCsiDriver =
    if cfg.zfsLocalPv.enabled then
      (scope.mkClusterResource {
        apiVersion = "storage.k8s.io/v1";
        kind = "CSIDriver";
        name = "zfs.csi.openebs.io";
        labels = zfsLabels;
        spec = {
          attachRequired = false;
          podInfoOnMount = true;
          storageCapacity = true;
        };
      })
    else
      null;

  # --- ZFS ConfigMap (zfs binary wrapper) ---
  zfsConfigMap =
    if cfg.zfsLocalPv.enabled then
      (scope.mkResource {
        apiVersion = "v1";
        kind = "ConfigMap";
        name = "${name}-zfspv-bin";
        labels = zfsLabels;
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
    if cfg.zfsLocalPv.enabled then
      (scope.mkResource {
        apiVersion = "apps/v1";
        kind = "Deployment";
        name = "${name}-zfs-localpv-controller";
        labels = zfsLabels // {
          app = "openebs-zfs-controller";
        };
        spec = {
          replicas = 1;
          selector.matchLabels = {
            app = "openebs-zfs-controller";
            role = "openebs-zfs";
          };
          template = {
            metadata.labels = {
              app = "openebs-zfs-controller";
              role = "openebs-zfs";
            };
            spec = {
              serviceAccountName = "${self.zfsControllerSa}";
              containers = [
                {
                  name = "csi-provisioner";
                  image = cfg.zfsLocalPv.csiProvisioner;
                  imagePullPolicy = "IfNotPresent";
                  args = [
                    "--csi-address=$(ADDRESS)"
                    "--v=5"
                    "--feature-gates=Topology=true"
                    "--strict-topology"
                    "--leader-election"
                    "--extra-create-metadata=true"
                    "--enable-capacity=true"
                    "--default-fstype=ext4"
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
                  name = "csi-resizer";
                  image = cfg.zfsLocalPv.csiResizer;
                  imagePullPolicy = "IfNotPresent";
                  args = [
                    "--v=5"
                    "--csi-address=$(ADDRESS)"
                    "--leader-election"
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
                  image = cfg.zfsLocalPv.csiSnapshotter;
                  imagePullPolicy = "IfNotPresent";
                  args = [
                    "--csi-address=$(ADDRESS)"
                    "--v=5"
                    "--leader-election"
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
                  image = cfg.zfsLocalPv.snapshotController;
                  imagePullPolicy = "IfNotPresent";
                  args = [
                    "--v=5"
                    "--leader-election=true"
                  ];
                }
                {
                  name = "openebs-zfs-plugin";
                  image = cfg.zfsLocalPv.image;
                  imagePullPolicy = "IfNotPresent";
                  args = [
                    "--endpoint=$(OPENEBS_CSI_ENDPOINT)"
                    "--nodeid=$(OPENEBS_NODE_ID)"
                    "--plugin-type=controller"
                  ];
                  env = [
                    {
                      name = "OPENEBS_CSI_ENDPOINT";
                      value = "unix:///var/lib/csi/sockets/pluginproxy/csi.sock";
                    }
                    {
                      name = "OPENEBS_NAMESPACE";
                      valueFrom.fieldRef.fieldPath = "metadata.namespace";
                    }
                    {
                      name = "OPENEBS_NODE_ID";
                      valueFrom.fieldRef.fieldPath = "spec.nodeName";
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
          self.zfsControllerSa
          self.zfsCsiDriver
        ];
      })
    else
      null;

  # --- ZFS Node DaemonSet ---
  zfsNode =
    if cfg.zfsLocalPv.enabled then
      (scope.mkResource {
        apiVersion = "apps/v1";
        kind = "DaemonSet";
        name = "${name}-zfs-localpv-node";
        labels = zfsLabels // {
          app = "openebs-zfs-node";
        };
        spec = {
          selector.matchLabels = {
            app = "openebs-zfs-node";
          };
          updateStrategy = {
            type = "RollingUpdate";
          };
          template = {
            metadata.labels = {
              app = "openebs-zfs-node";
              role = "openebs-zfs";
            };
            spec = {
              serviceAccountName = "${self.zfsNodeSa}";
              containers = [
                {
                  name = "csi-node-driver-registrar";
                  image = cfg.zfsLocalPv.csiNodeRegistrar;
                  imagePullPolicy = "IfNotPresent";
                  args = [
                    "--v=5"
                    "--csi-address=$(ADDRESS)"
                    "--kubelet-registration-path=$(DRIVER_REG_SOCK_PATH)"
                  ];
                  env = [
                    {
                      name = "ADDRESS";
                      value = "/csi/csi.sock";
                    }
                    {
                      name = "DRIVER_REG_SOCK_PATH";
                      value = "/var/lib/kubelet/plugins/zfs.csi.openebs.io/csi.sock";
                    }
                    {
                      name = "KUBE_NODE_NAME";
                      valueFrom.fieldRef.fieldPath = "spec.nodeName";
                    }
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
                }
                {
                  name = "openebs-zfs-plugin";
                  image = cfg.zfsLocalPv.image;
                  imagePullPolicy = "IfNotPresent";
                  securityContext.privileged = true;
                  args = [
                    "--endpoint=$(OPENEBS_CSI_ENDPOINT)"
                    "--nodeid=$(OPENEBS_NODE_ID)"
                    "--plugin-type=node"
                  ];
                  env = [
                    {
                      name = "OPENEBS_CSI_ENDPOINT";
                      value = "unix:///csi/csi.sock";
                    }
                    {
                      name = "OPENEBS_NODE_ID";
                      valueFrom.fieldRef.fieldPath = "spec.nodeName";
                    }
                    {
                      name = "OPENEBS_NAMESPACE";
                      valueFrom.fieldRef.fieldPath = "metadata.namespace";
                    }
                  ];
                  volumeMounts = [
                    {
                      name = "plugin-dir";
                      mountPath = "/csi";
                    }
                    {
                      name = "device-dir";
                      mountPath = "/dev";
                    }
                    {
                      name = "host-root";
                      mountPath = "/host";
                      mountPropagation = "HostToContainer";
                    }
                    {
                      name = "pods-mount-dir";
                      mountPath = "/var/lib/kubelet/";
                      mountPropagation = "Bidirectional";
                    }
                    {
                      name = "chroot-zfs";
                      mountPath = "/usr/local/bin/zfs";
                      subPath = "zfs";
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
                    path = "/var/lib/kubelet/plugins/zfs.csi.openebs.io/";
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
                    name = "${self.zfsConfigMap}";
                    defaultMode = 365;
                  };
                } # 0555
              ];
            };
          };
        };
        requires = [
          self.zfsNodeSa
          self.zfsConfigMap
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
    if cfg.lvmLocalPv.enabled then
      (scope.mkResource {
        apiVersion = "v1";
        kind = "ServiceAccount";
        name = "${name}-lvm-controller-sa";
        labels = lvmLabels;
      })
    else
      null;

  lvmNodeSa =
    if cfg.lvmLocalPv.enabled then
      (scope.mkResource {
        apiVersion = "v1";
        kind = "ServiceAccount";
        name = "${name}-lvm-node-sa";
        labels = lvmLabels;
      })
    else
      null;

  # --- CSIDriver ---
  lvmCsiDriver =
    if cfg.lvmLocalPv.enabled then
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
    if cfg.lvmLocalPv.enabled then
      (scope.mkResource {
        apiVersion = "apps/v1";
        kind = "Deployment";
        name = "${name}-lvm-localpv-controller";
        labels = lvmLabels // {
          app = "openebs-lvm-controller";
        };
        spec = {
          replicas = 1;
          selector.matchLabels = {
            app = "openebs-lvm-controller";
            role = "openebs-lvm";
          };
          template = {
            metadata.labels = {
              app = "openebs-lvm-controller";
              role = "openebs-lvm";
            };
            spec = {
              serviceAccountName = "${self.lvmControllerSa}";
              containers = [
                {
                  name = "csi-provisioner";
                  image = cfg.lvmLocalPv.csiProvisioner;
                  imagePullPolicy = "IfNotPresent";
                  args = [
                    "--csi-address=$(ADDRESS)"
                    "--v=5"
                    "--feature-gates=Topology=true"
                    "--strict-topology"
                    "--leader-election"
                    "--extra-create-metadata=true"
                    "--enable-capacity=true"
                    "--default-fstype=ext4"
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
                  name = "csi-resizer";
                  image = cfg.lvmLocalPv.csiResizer;
                  imagePullPolicy = "IfNotPresent";
                  args = [
                    "--v=5"
                    "--csi-address=$(ADDRESS)"
                    "--leader-election"
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
                  image = cfg.lvmLocalPv.csiSnapshotter;
                  imagePullPolicy = "IfNotPresent";
                  args = [
                    "--csi-address=$(ADDRESS)"
                    "--v=5"
                    "--leader-election"
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
                  image = cfg.lvmLocalPv.snapshotController;
                  imagePullPolicy = "IfNotPresent";
                  args = [
                    "--v=5"
                    "--leader-election=true"
                  ];
                }
                {
                  name = "openebs-lvm-plugin";
                  image = cfg.lvmLocalPv.image;
                  imagePullPolicy = "IfNotPresent";
                  args = [
                    "--endpoint=$(OPENEBS_CSI_ENDPOINT)"
                    "--nodeid=$(OPENEBS_NODE_ID)"
                    "--plugin-type=controller"
                  ];
                  env = [
                    {
                      name = "OPENEBS_CSI_ENDPOINT";
                      value = "unix:///var/lib/csi/sockets/pluginproxy/csi.sock";
                    }
                    {
                      name = "OPENEBS_NAMESPACE";
                      valueFrom.fieldRef.fieldPath = "metadata.namespace";
                    }
                    {
                      name = "OPENEBS_NODE_ID";
                      valueFrom.fieldRef.fieldPath = "spec.nodeName";
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
          self.lvmControllerSa
          self.lvmCsiDriver
        ];
      })
    else
      null;

  # --- LVM Node DaemonSet ---
  lvmNode =
    if cfg.lvmLocalPv.enabled then
      (scope.mkResource {
        apiVersion = "apps/v1";
        kind = "DaemonSet";
        name = "${name}-lvm-localpv-node";
        labels = lvmLabels // {
          app = "openebs-lvm-node";
        };
        spec = {
          selector.matchLabels = {
            app = "openebs-lvm-node";
          };
          updateStrategy.type = "RollingUpdate";
          template = {
            metadata.labels = {
              app = "openebs-lvm-node";
              role = "openebs-lvm";
            };
            spec = {
              serviceAccountName = "${self.lvmNodeSa}";
              containers = [
                {
                  name = "csi-node-driver-registrar";
                  image = cfg.lvmLocalPv.csiNodeRegistrar;
                  imagePullPolicy = "IfNotPresent";
                  args = [
                    "--v=5"
                    "--csi-address=$(ADDRESS)"
                    "--kubelet-registration-path=$(DRIVER_REG_SOCK_PATH)"
                  ];
                  env = [
                    {
                      name = "ADDRESS";
                      value = "/csi/csi.sock";
                    }
                    {
                      name = "DRIVER_REG_SOCK_PATH";
                      value = "/var/lib/kubelet/plugins/local.csi.openebs.io/csi.sock";
                    }
                    {
                      name = "KUBE_NODE_NAME";
                      valueFrom.fieldRef.fieldPath = "spec.nodeName";
                    }
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
                }
                {
                  name = "openebs-lvm-plugin";
                  image = cfg.lvmLocalPv.image;
                  imagePullPolicy = "IfNotPresent";
                  securityContext.privileged = true;
                  args = [
                    "--endpoint=$(OPENEBS_CSI_ENDPOINT)"
                    "--nodeid=$(OPENEBS_NODE_ID)"
                    "--plugin-type=node"
                  ];
                  env = [
                    {
                      name = "OPENEBS_CSI_ENDPOINT";
                      value = "unix:///csi/csi.sock";
                    }
                    {
                      name = "OPENEBS_NODE_ID";
                      valueFrom.fieldRef.fieldPath = "spec.nodeName";
                    }
                    {
                      name = "OPENEBS_NAMESPACE";
                      valueFrom.fieldRef.fieldPath = "metadata.namespace";
                    }
                  ];
                  volumeMounts = [
                    {
                      name = "plugin-dir";
                      mountPath = "/csi";
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
                    path = "/var/lib/kubelet/plugins/local.csi.openebs.io/";
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
          self.lvmNodeSa
          self.lvmCsiDriver
        ];
      })
    else
      null;

  # --- LVM Node Service (for metrics) ---
  lvmNodeService =
    if cfg.lvmLocalPv.enabled then
      (scope.mkResource {
        apiVersion = "v1";
        kind = "Service";
        name = "${name}-lvm-localpv-node-service";
        labels = lvmLabels;
        spec = {
          selector = scope.selectWorkload self.lvmNode;
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
    if cfg.localPvProvisioner.enabled then
      (scope.mkResource {
        apiVersion = "v1";
        kind = "ServiceAccount";
        name = "${name}-localpv-provisioner";
        labels = localPvLabels;
      })
    else
      null;

  localPvDeployment =
    if cfg.localPvProvisioner.enabled then
      (scope.mkResource {
        apiVersion = "apps/v1";
        kind = "Deployment";
        name = "${name}-localpv-provisioner";
        labels = localPvLabels;
        spec = {
          replicas = 1;
          selector.matchLabels = {
            app = "localpv-provisioner";
          };
          template = {
            metadata.labels = {
              app = "localpv-provisioner";
            };
            spec = {
              serviceAccountName = "${self.localPvSa}";
              containers = [
                {
                  name = "openebs-provisioner-hostpath";
                  image = cfg.localPvProvisioner.image;
                  imagePullPolicy = "IfNotPresent";
                  env = [
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
                      value = cfg.localPvProvisioner.image;
                    }
                    {
                      name = "OPENEBS_IO_BASE_PATH";
                      value = cfg.localPvProvisioner.basePath;
                    }
                    {
                      name = "OPENEBS_IO_INSTALLER_TYPE";
                      value = "kix";
                    }
                    {
                      name = "OPENEBS_IO_ENABLE_ANALYTICS";
                      value = "false";
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
        requires = [ self.localPvSa ];
      })
    else
      null;

  localPvStorageClass =
    if cfg.localPvProvisioner.enabled then
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
              value: "${cfg.localPvProvisioner.basePath}"
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
  #  Entry point
  # ==========================================================================

  main = {
    resource = self.apiRestService;
    requires =
      # --- Mayastor components ---
      lib.optionals cfg.mayastor.enabled [
        self.mayastorSa
        self.priorityClass
        self.etcdStatefulSet
        self.etcdService
        self.etcdHeadlessService
        self.etcdStorageClass
        self.natsStatefulSet
        self.natsService
        self.natsSa
        self.natsConfigMap
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
      ]
      # --- ZFS LocalPV components ---
      ++ lib.optionals cfg.zfsLocalPv.enabled [
        self.zfsControllerSa
        self.zfsNodeSa
        self.zfsCsiDriver
        self.zfsConfigMap
        self.zfsController
        self.zfsNode
      ]
      # --- LVM LocalPV components ---
      ++ lib.optionals cfg.lvmLocalPv.enabled [
        self.lvmControllerSa
        self.lvmNodeSa
        self.lvmCsiDriver
        self.lvmController
        self.lvmNode
        self.lvmNodeService
      ]
      # --- LocalPV Provisioner (optional) ---
      ++ lib.optionals cfg.localPvProvisioner.enabled [
        self.localPvSa
        self.localPvDeployment
        self.localPvStorageClass
      ];
  };
}
// mayastorClusterRoles
// zfsControllerRoles
// zfsNodeRoles
// lvmControllerRoles
// lvmNodeRoles
// localPvClusterRoles
