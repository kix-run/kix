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
#       package = packages.mayastor;
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

{
  scope,
  lib,
  kix,
}:

let
  c = import ./common.nix { inherit lib kix scope; };
  inherit (c) release who;

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
          builtins.attrNames (lib.filterAttrs (_: v: v != null) res.${side})
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

      reserved = builtins.filter (n: n == "root" || n == "meta");
      reservedNames =
        map (n: "diskPools.${n}") (reserved (builtins.attrNames config.diskPools))
        ++ map (n: "volumeSnapshotClasses.${n}") (
          reserved (builtins.attrNames config.volumeSnapshotClasses)
        );

      tolerationErrors =
        option:
        lib.concatLists (
          lib.imap0 (
            i: t:
            let
              at = "${option}[${toString i}]";
            in
            lib.optional (t.key == null && t.operator != "Exists")
              "${at} has no key, which the apiserver accepts only with operator Exists (tolerate every taint). Set key, or set operator = \"Exists\"."
            ++
              lib.optional (t.operator == "Exists" && t.value != null)
                "${at} sets value with operator Exists, which matches any value; the apiserver refuses it. Remove value, or set operator = \"Equal\"."
            ++
              lib.optional (t.tolerationSeconds != null && t.effect != "NoExecute")
                "${at} sets tolerationSeconds, which the apiserver accepts only with effect NoExecute. Set effect = \"NoExecute\", or remove tolerationSeconds."
          ) (lib.attrByPath (lib.splitString "." option) [ ] config)
        );
      badTolerations = tolerationErrors "ioEngine.tolerations" ++ tolerationErrors "csiNode.tolerations";

      defaultSnapshotClasses = builtins.attrNames (
        lib.filterAttrs (
          _: v: (v.annotations."snapshot.storage.kubernetes.io/is-default-class" or null) == "true"
        ) config.volumeSnapshotClasses
      );
    in
    [
      {
        assertion = badTolerations == [ ];
        message = lib.concatStringsSep " " badTolerations;
      }
      {
        assertion = owned == [ ];
        message = "ioEngine.resources sets ${lib.concatStringsSep ", " owned}, which the package sets: CPU from ioEngine.cpuCount and 2 MiB hugepages from ioEngine.hugepages2Mi. Set those options instead.";
      }
      {
        assertion = shared == { };
        message = "diskPools name the same disk more than once: ${sharedText}. A disk belongs to one pool; Mayastor refuses the second as claimed. The comparison is by text, so two paths to one disk (a by-id link and its /dev name) are not detected.";
      }
      {
        assertion = reservedNames == [ ];
        message = "${lib.concatStringsSep " and " reservedNames}: Kix drops parts named root or meta, so ${
          if builtins.length reservedNames == 1 then "it" else "they"
        } would not be rendered. Rename ${if builtins.length reservedNames == 1 then "it" else "them"}.";
      }
      {
        assertion = config.volumeSnapshotClasses == { } || (deps.snapshotController or null) != null;
        message = "volumeSnapshotClasses defines ${lib.concatStringsSep ", " (builtins.attrNames config.volumeSnapshotClasses)}, but nothing provides the snapshotController role, so the VolumeSnapshotClass kind has no owner. Add a snapshot-controller instance, or on a cluster whose environment runs the controller use a flavour or an import that provides the role, or remove volumeSnapshotClasses.";
      }
      {
        assertion = builtins.length defaultSnapshotClasses <= 1;
        message = "volumeSnapshotClasses ${lib.concatStringsSep " and " defaultSnapshotClasses} are each annotated snapshot.storage.kubernetes.io/is-default-class=\"true\". A VolumeSnapshot that names no class then fails, because the snapshot controller refuses to choose between two defaults for one driver. Keep the annotation on one class.";
      }
    ];

  warnings =
    { config, ... }:
    let
      pools = builtins.attrValues config.diskPools;
      poolNodes = lib.unique (map (p: p.node) pools);
      encryptedPools = builtins.filter (p: p.encrypted) pools;
    in
    lib.optionals (pools != [ ]) (
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
          inherit scope clusterConfig who;
          optionPath = "config.storageClasses";
          classes = config.storageClasses;
          parts = self.classes;
          provisioner = self.csiDriver.out.name;
          requires = [
            self.csiController
            self.csiNode
          ];
        };

        key = c.poolKey poolEncryptionKey;

        nodes = clusterConfig.cluster.nodes;
        checkNodes = nodes != { } && clusterConfig.cluster.capabilities.nodeAutoscaling != true;
        ioEngineLabels = c.ioEngineLabels config;
        checkPool =
          poolName: pool:
          if !checkNodes then
            pool
          else if !(nodes ? ${pool.node}) then
            throw "${who}: diskPools.${poolName}.node is \"${pool.node}\", which is not in cluster.nodes (${lib.concatStringsSep ", " (builtins.attrNames nodes)}). Name the node that holds the pool's disk."
          else
            let
              missing = lib.filterAttrs (k: v: (nodes.${pool.node}.labels.${k} or null) != v) ioEngineLabels;
            in
            lib.warnIf (missing != { })
              "${who}: diskPools.${poolName} is on node ${pool.node}, whose labels in cluster.nodes lack ${
                lib.concatStringsSep ", " (lib.mapAttrsToList (k: v: "${k}=${v}") missing)
              } from ioEngine.nodeSelector, so io-engine may not run there and the pool would not come up. Label the node, or ignore this if it is labelled outside the cluster definition."
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

        snapshotClasses =
          if snapshotController == null then
            { }
          else
            lib.mapAttrs (
              className: cls:
              scope.mkCR snapshotController.out.crds.VolumeSnapshotClass {
                name = className;
                inherit (cls) labels annotations;
                extra = {
                  driver = self.csiDriver.out.name;
                  inherit (cls) deletionPolicy;
                }
                // lib.optionalAttrs (cls.parameters != { }) { inherit (cls) parameters; };
                requires = [ self.csiController ];
              }
            ) config.volumeSnapshotClasses;

        diskPoolCrd = scope.mkCRDRef {
          group = "openebs.io";
          kind = "DiskPool";
          plural = "diskpools";
          version = "v1beta3";
          installedBy = self.operatorDiskpool;
          # A pool is the disk the replicas of every volume on it live on.
          holdsData = true;
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
                  inherit who;
                  what = "diskPools.${poolName}.extraSpec";
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
                        throw "${who}: diskPools.${poolName}.encrypted is true, but the poolEncryptionKey dependency is not wired. Wire a secret with key encryption_parameters through deps.poolEncryptionKey = ref.<ns>.<instance>, or set encrypted = false."
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
