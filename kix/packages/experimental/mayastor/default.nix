# mayastor: OpenEBS Mayastor, replicated block storage served over NVMe-oF
# from DiskPools on labelled nodes.
#
# Renders the control plane (`agent-core` with `agent-ha-cluster`, `api-rest`,
# `operator-diskpool`, and `csi-controller`), its `etcd` StatefulSet, the node
# agents (`io-engine`, `csi-node`, and `agent-ha-node`), CSIDriver
# `io.openebs.csi-mayastor`, component ServiceAccounts and RBAC, and the
# declared StorageClasses, VolumeSnapshotClasses, and DiskPools.
#
#   instances.mayastor = {
#     local-path.package = kix.mkImport { out.storageClassName = "local-path"; };
#     mayastor = {
#       package = packages.experimental.mayastor;
#       deps.storageClasses = ref.mayastor.local-path;   # etcd's volumes
#       config = {
#         diskPools.pool-node1 = { node = "node1"; disks = [ "/dev/disk/by-id/nvme-..." ]; };
#         storageClasses.mayastor-3.parameters.repl = "3";
#       };
#     };
#   };
#
# Host prerequisites Kix cannot verify:
# - `csi-node` nodes require the `nvme_tcp` kernel module and writable `/sys`
#   and `/run/udev`.
# - `io-engine` nodes require an x86-64 CPU with SSE4.2, kernel 5.13+,
#   `ioEngine.cpuCount` cores, 1 GiB memory, `ioEngine.hugepages2Mi` of 2 MiB
#   hugepages pre-allocated, free host ports 10124, 8420, and 4421,
#   `nvme_core.multipath=Y`, and dedicated unpartitioned pool disks.
#
# Dependencies:
#   storageClasses (optional)     etcd's StorageClass (must not be Mayastor's).
#   snapshotController (optional) Snapshot API (`csi-snapshotter` and
#                                 `volumeSnapshotClasses`).
#   poolEncryptionKey (optional)  Secret with key `encryption_parameters` for
#                                 encrypted pools.
#   prometheus (optional)         io-engine metrics Service, ServiceMonitor,
#                                 and DiskPool alerts.
#
# Exposes (`root.out`, `root` = `csi-controller`):
#   out.provisioner, out.storageClasses, out.storageClassName,
#   out.volumeSnapshotClasses, out.diskPools, and out.crds.DiskPool.
#   out.version is the Mayastor version `image.tag` names.
#
# Upgrades: 2.12.2 is a patch release. Its control-plane and io-engine source
# is identical to 2.12.1, and its chart changes only the Loki and MinIO
# images, which this package does not render. Its CRD chart changes only its
# version, so the DiskPool CRD and the RBAC here need no change. A plain
# deploy upgrades a 2.12.1 install. The control-plane pods restart on the new
# images. io-engine is an OnDelete DaemonSet, so its pods keep the 2.12.1
# image until an operator deletes each one, and the CLI reports them as
# pending a restart. Upstream does not document going back to 2.12.1, and
# this package has not tested it.

{
  scope,
  lib,
  kix,
}:

let
  c = import ./common.nix { inherit lib kix scope; };
  inherit (c) release;

  followers = [
    "agentCore"
    "agentHaCluster"
    "agentHaNode"
    "apiRest"
    "csiController"
    "csiNode"
    "operatorDiskpool"
    "metricsExporter"
  ];

  # Return the cluster.nodes that a pool's node is checked against, or null
  # when Kix does not check it: cluster.nodes is empty, or an autoscaler
  # adds nodes the cluster definition does not list. The build refuses a
  # node missing from them, and `warnings` checks its labels.
  checkedNodes =
    clusterConfig:
    let
      nodes = clusterConfig.cluster.nodes;
    in
    if nodes != { } && clusterConfig.cluster.capabilities.nodeAutoscaling != true then nodes else null;
in
{
  meta = {
    version = release;
    description = "OpenEBS Mayastor: replicated NVMe-oF block storage from DiskPools on labelled nodes";
    owner = "platform";
    lifecycle = "stateful";
    defaultAliases = [ "mayastor" ];
    conflictsWith = [ "cluster:mayastor" ];
    unsafe = [
      "privileged"
      "host-network"
      "run-as-root"
    ];
    podSecurity = "privileged";
    k8s.minVersion = "1.23";
    # Host-network peers (`io-engine`, `csi-node`, `agent-ha-node`, and
    # `csi-controller`) appear as node traffic to pod network policy, so
    # cluster-wide pod rules open control-plane and node-agent ports.
    network.intents.hostNetworkPeers =
      let
        tcp = map (port: {
          inherit port;
          protocol = "TCP";
        });
      in
      {
        ingress = [
          {
            from = "all-pods";
            ports = tcp [
              2379
              8081
              50051
              50052
            ];
          }
        ];
        egress = [
          {
            to = "all-pods";
            ports = tcp [
              10124
              10199
              50053
            ];
          }
        ];
      };
  };

  options = import ./options.nix {
    inherit lib kix release;
  };

  config =
    { config, ... }:
    lib.genAttrs followers (_: {
      image.tag = lib.mkDefault config.image.tag;
    });

  assertions =
    { config, deps, ... }:
    let
      res = config.ioEngine.resources;
      setByPackage =
        side:
        builtins.filter (k: k == "cpu" || lib.hasPrefix "hugepages-" k) (
          builtins.attrNames (lib.filterAttrs (_: v: v != null) (res.${side} or { }))
        );
      owned = lib.unique (setByPackage "requests" ++ setByPackage "limits");

      claims = lib.concatLists (
        lib.mapAttrsToList (
          pool: p:
          map (disk: {
            inherit pool disk;
            inherit (p) node;
          }) p.disks
        ) config.diskPools
      );
      byDevice = lib.groupBy (cl: "${cl.node} ${cl.disk}") claims;
      shared = lib.filterAttrs (
        _: cls: builtins.length (lib.unique (map (cl: cl.pool) cls)) > 1
      ) byDevice;
      sharedText = lib.concatStringsSep "; " (
        lib.mapAttrsToList (
          _: cls:
          "${(builtins.head cls).disk} on node ${(builtins.head cls).node} (pools ${
            lib.concatStringsSep ", " (lib.unique (map (cl: cl.pool) cls))
          })"
        ) shared
      );

      reservedPools = builtins.filter (n: n == "root" || n == "meta") (
        builtins.attrNames config.diskPools
      );
    in
    map
      (message: {
        assertion = false;
        inherit message;
      })
      (
        kix.storage.snapshotClassProblems {
          optionPath = "config.volumeSnapshotClasses";
          classes = config.volumeSnapshotClasses;
          snapshotController = deps.snapshotController or null;
        }
        ++ kix.tolerations.problems {
          optionPath = "config.ioEngine.tolerations";
          inherit (config.ioEngine) tolerations;
        }
        ++ kix.tolerations.problems {
          optionPath = "config.csiNode.tolerations";
          inherit (config.csiNode) tolerations;
        }
      )
    ++ [
      {
        assertion = owned == [ ];
        message = "ioEngine.resources sets ${lib.concatStringsSep ", " owned}, which the package sets: CPU from ioEngine.cpuCount and 2 MiB hugepages from ioEngine.hugepages2Mi. Set those options instead.";
      }
      {
        assertion = shared == { };
        message = "diskPools name the same disk more than once: ${sharedText}. A disk belongs to one pool; Mayastor refuses the second as claimed. The comparison is by text, so two paths to one disk (a by-id link and its /dev name) are not detected.";
      }
      {
        assertion = reservedPools == [ ];
        message = "${
          lib.concatMapStringsSep " and " (n: "diskPools.${n}") reservedPools
        }: Kix reserves the keys \"root\" and \"meta\", so ${
          if builtins.length reservedPools == 1 then "it" else "they"
        } cannot be built. Rename ${if builtins.length reservedPools == 1 then "it" else "them"}.";
      }
    ]
    # A follower that keeps image.tag is covered by the check on image.tag.
    ++
      map
        (
          option:
          kix.image.checkRelease {
            image = lib.getAttrFromPath (lib.splitString "." option) config;
            inherit option release;
            reason = "the DiskPool CRD version and RBAC rules in kix/packages/experimental/mayastor are written for ${release}";
            fix = "To update this package to another version, change release in kix/packages/experimental/mayastor/common.nix.";
          }
        )
        (
          [ "image" ]
          ++ map (f: "${f}.image") (builtins.filter (f: config.${f}.image.tag != config.image.tag) followers)
        );

  warnings =
    { config, clusterConfig, ... }:
    let
      pools = builtins.attrValues config.diskPools;
      poolNodes = lib.unique (map (p: p.node) pools);
      encryptedPools = builtins.filter (p: p.encrypted) pools;

      nodes = checkedNodes clusterConfig;
      ioEngineLabels = c.ioEngineLabels config;
      unlabelledPool =
        poolName: pool:
        let
          missing = lib.filterAttrs (k: v: (nodes.${pool.node}.labels.${k} or null) != v) ioEngineLabels;
        in
        lib.optional (nodes != null && nodes ? ${pool.node} && missing != { }) {
          option = "diskPools.${poolName}.node";
          message = "diskPools.${poolName} uses node \"${pool.node}\", whose labels in cluster.nodes do not include ${
            lib.concatStringsSep ", " (lib.mapAttrsToList (k: v: "${k}=${v}") missing)
          } (required by ioEngine.nodeSelector). Kix still built the DiskPool, which will stay offline unless the io-engine DaemonSet runs on that node.";
          fix = "Label the Kubernetes node to match ioEngine.nodeSelector and record the labels under cluster.nodes in the cluster definition, or update ioEngine.nodeSelector.";
        };
    in
    lib.concatLists (lib.mapAttrsToList unlabelledPool config.diskPools)
    ++ lib.optionals (pools != [ ]) (
      lib.concatLists (
        lib.mapAttrsToList (
          cls: def:
          lib.optional (lib.toInt def.parameters.repl > builtins.length poolNodes)
            "storageClasses.${cls} asks for ${def.parameters.repl} replicas, but diskPools has pools on ${toString (builtins.length poolNodes)} node(s); each replica needs a pool on a different node, so its volumes cannot be created. This counts only pools this instance declares."
          ++
            lib.optional ((def.parameters.encrypted or "false") == "true" && encryptedPools == [ ])
              "storageClasses.${cls} sets encrypted = \"true\", but no pool in diskPools is encrypted, so its volumes cannot be placed. This counts only pools this instance declares."
        ) config.storageClasses
      )
    );

  build = [
    ./rbac.nix
    ./etcd.nix
    ./control-plane.nix
    ./node.nix

    (
      {
        self,
        config,
        clusterConfig,
        scope,
        lib,
        kix,
        snapshotController ? null,
        poolEncryptionKey ? null,
        ...
      }:
      let
        sc = kix.storage.mkClasses {
          inherit scope clusterConfig;
          optionPath = "storageClasses";
          classes = config.storageClasses;
          parts = self.classes;
          provisioner = self.csiDriver.out.name;
          requires = [
            self.csiController
            self.csiNode
          ];
        };

        key = c.poolKey poolEncryptionKey;

        nodes = checkedNodes clusterConfig;
        checkPool =
          poolName: pool:
          if nodes == null then
            pool
          else if !(nodes ? ${pool.node}) then
            scope.fail {
              option = "diskPools.${poolName}.node";
              message = "diskPools.${poolName}.node is \"${pool.node}\", which is not in cluster.nodes (${lib.concatStringsSep ", " (builtins.attrNames nodes)}).";
              fix = "Name the node that holds the pool's disk.";
            }
          else
            pool;
      in
      {
        csiDriver = scope.mkClusterResource {
          apiVersion = "storage.k8s.io/v1";
          kind = "CSIDriver";
          name = "io.openebs.csi-mayastor";
          spec = {
            attachRequired = true;
            podInfoOnMount = true;
            volumeLifecycleModes = [ "Persistent" ];
            storageCapacity = false;
          };
        };

        classes = sc.resources;

        snapshotClasses = kix.storage.mkSnapshotClasses {
          inherit scope snapshotController;
          driver = self.csiDriver.out.name;
          classes = config.volumeSnapshotClasses;
          requires = [ self.csiController ];
        };

        diskPoolCrd = scope.mkCRDRef {
          group = "openebs.io";
          kind = "DiskPool";
          plural = "diskpools";
          version = "v1beta3";
          installedBy = self.operatorDiskpool;
          # A pool is the disk the replicas of every volume on it live on.
          holdsData = true;
          # The io-engine on the node serves the pool; no pod is created for it.
          usesAtLeast = _: { };
          readiness.condition = {
            type = "PoolReady";
            status = "True";
          };
        };

        pools = lib.mapAttrs (
          poolName: pool':
          let
            pool = checkPool poolName pool';
          in
          scope.mkCR self.diskPoolCrd {
            name = poolName;
            spec =
              kix.mergeGuarded
                {
                  inherit scope;
                  option = "diskPools.${poolName}.extraSpec";
                  locked = [
                    [ "node" ]
                    [ "disks" ]
                    [ "encryptionConfig" ]
                  ];
                }
                (
                  {
                    inherit (pool) node disks;
                  }
                  // lib.optionalAttrs pool.encrypted {
                    encryptionConfig.source.secret.name =
                      if key == null then
                        scope.fail {
                          option = "diskPools.${poolName}.encrypted";
                          message = "diskPools.${poolName}.encrypted is true, but the poolEncryptionKey dependency is not wired.";
                          fix = "Wire a secret with key encryption_parameters through deps.poolEncryptionKey = ref.<ns>.<instance>, or set encrypted = false.";
                        }
                      else
                        key.out.name;
                  }
                )
                pool.extraSpec;
            requires = [ self.ioEngine ];
          }
        ) config.diskPools;

        root = {
          resource = self.csiController;
          requires = [
            self.csiNode
            self.ioEngine
            self.agentHaNode
            self.agentCore
            self.apiRest
            self.operatorDiskpool
            self.etcd
          ]
          ++ builtins.attrValues self.classes
          ++ builtins.attrValues self.snapshotClasses
          ++ builtins.attrValues self.pools;
          out = {
            provisioner = self.csiDriver.out.name;
            inherit (sc) storageClassName;
            storageClasses = self.classes;
            volumeSnapshotClasses = self.snapshotClasses;
            diskPools = self.pools;
            crds.DiskPool = self.diskPoolCrd;
            version = kix.image.version config.image;
          };
        };
      }
    )

    (
      {
        self,
        config,
        scope,
        lib,
        prometheus ? null,
        ...
      }@args:
      let
        enabled = config.metrics.enabled && prometheus != null;
        sel = ''namespace="${c.ns}",service="${self.ioEngineMetrics.out.name}"'';
      in
      {
        ioEngineMetrics =
          if enabled then
            self.ioEngine
            |> kix.service.fromWorkload {
              name = "${c.name}-io-engine-metrics";
              labels = c.componentLabels "io-engine-metrics";
              ports = [
                {
                  name = "metrics";
                  port = 9502;
                  targetPort = "metrics";
                  protocol = "TCP";
                }
              ];
            }
            |> scope.mkResource
          else
            null;
      }
      // kix.monitor {
        service = "ioEngineMetrics";
        port = "metrics";
        alerts = {
          MayastorIoEngineMetricsDown = {
            expr = "up{${sel}} == 0";
            "for" = "5m";
            severity = "critical";
            summary = "A Mayastor io-engine metrics target is down";
            description = "Prometheus has not scraped the io-engine metrics exporter in pod {{ $labels.pod }} of Mayastor in ${c.ns} for 5 minutes, so the DiskPool alerts cannot fire for that node. Check the io-engine pod and its node.";
          };
          MayastorDiskPoolNotOnline = {
            expr = "diskpool_status{${sel}} == 0 or diskpool_status{${sel}} == 3";
            "for" = "5m";
            severity = "critical";
            summary = "A Mayastor DiskPool is faulted or its state is unknown";
            description = "DiskPool {{ $labels.name }} on node {{ $labels.node }} of Mayastor in ${c.ns} has been faulted or unknown for 5 minutes. Check kubectl -n ${c.ns} get diskpool {{ $labels.name }} and the io-engine pod on that node.";
          };
          MayastorDiskPoolUsageHigh = {
            expr = "diskpool_used_size_bytes{${sel}} / diskpool_total_size_bytes{${sel}} > 0.75";
            "for" = "15m";
            severity = "warning";
            summary = "A Mayastor DiskPool is more than 75% full";
            description = "DiskPool {{ $labels.name }} on node {{ $labels.node }} of Mayastor in ${c.ns} is {{ $value | humanizePercentage }} full.";
          };
          MayastorDiskPoolUsageCritical = {
            expr = "diskpool_used_size_bytes{${sel}} / diskpool_total_size_bytes{${sel}} > 0.90";
            "for" = "5m";
            severity = "critical";
            summary = "A Mayastor DiskPool is more than 90% full";
            description = "DiskPool {{ $labels.name }} on node {{ $labels.node }} of Mayastor in ${c.ns} is {{ $value | humanizePercentage }} full. Add a pool or free space before writes fail.";
          };
        };
      } args
    )
  ];
}
