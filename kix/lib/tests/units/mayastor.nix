# Tests for kix/packages/experimental/mayastor: where etcd's StorageClass comes from, the
# pool, class, toleration, and resource checks, and the flags and env
# variables the package owns. Refusals raised by `throw` in the build are
# checked with evalFails beside a control that changes only the refused
# field; refusals raised as package assertions are checked by their text.

{
  lib,
  eval,
  kixlib,
  mkCluster,
  manifests,
  ofKind,
  byName,
  evalFails,
  storageClassImport,
  ...
}:

let
  mayastorPackage = import ../../../packages/experimental/mayastor;

  # A cluster with the instance mayastor/mayastor. `deps` and `aliases` are
  # functions of `ref`; the default wires etcd's class to an import of
  # local-path in the same namespace.
  clusterWith =
    {
      config ? { },
      deps ? ref: { storageClasses = ref.mayastor.local-path; },
      aliases ? null,
      importClass ? "local-path",
      extra ? { },
    }:
    mkCluster [
      (
        { ref, ... }:
        {
          instances.mayastor = {
            local-path = storageClassImport importClass;
            # The class the named-class cases give etcd.
            local-class = storageClassImport "local";
            mayastor = {
              package = mayastorPackage;
              inherit config;
              deps = deps ref;
            }
            // lib.optionalAttrs (aliases != null) { inherit aliases; };
          };
        }
      )
      extra
    ];

  builds = cluster: !(evalFails cluster);
  ms = manifests;
  daemonSet = name: cluster: byName "mayastor-${name}" (ofKind "DaemonSet" (ms cluster));
  deployment = name: cluster: byName "mayastor-${name}" (ofKind "Deployment" (ms cluster));
  etcdOf = cluster: byName "mayastor-etcd" (ofKind "StatefulSet" (ms cluster));
  etcdClass =
    cluster: (builtins.head (etcdOf cluster).spec.volumeClaimTemplates).spec.storageClassName;
  containerArgs =
    workload: container:
    (lib.findFirst (c: c.name == container) { args = [ ]; } workload.spec.template.spec.containers)
    .args;

  pool = node: disk: {
    inherit node;
    disks = [ disk ];
  };

  # The package's `assertions` called directly with a config evaluated
  # against its options. tryEval drops a throw's message, so this is how the
  # tests read the message text. `deps` stands in for resolved dependencies.
  mayastor = mayastorPackage {
    scope = {
      instanceName = "mayastor";
      namespaceName = "mayastor";
    };
    inherit lib;
    kix = kixlib;
  };
  configOf =
    config:
    eval.evaluateInstanceConfig {
      packageOptions = mayastor.options;
      instCfg.config.imports = [ config ];
      namespaceName = "mayastor";
      instanceName = "mayastor";
    };
  failedMessages =
    {
      config,
      deps ? { },
    }:
    map (a: a.message) (
      builtins.filter (a: !a.assertion) (
        mayastor.assertions {
          config = configOf config;
          inherit deps;
        }
      )
    );
  # True when one of `messages` contains every fragment.
  someMessageHas =
    fragments: messages: builtins.any (m: builtins.all (f: lib.hasInfix f m) fragments) messages;

  # An environment that runs its own snapshot controller, as an import that
  # answers the snapshotController role with the VolumeSnapshotClass CRD.
  snapshotEnvironment = {
    cluster.roles.snapshotController = {
      binding = "exclusive";
      provider = "test-snapshot-controller";
    };
    instances.kube-system.platform-snapshot-controller.package = eval.mkImport {
      roles = [ "snapshotController" ];
      crds = [
        {
          group = "snapshot.storage.k8s.io";
          kind = "VolumeSnapshotClass";
          plural = "volumesnapshotclasses";
          version = "v1";
          crdScope = "Cluster";
        }
      ];
    };
  };
in
{
  # The plain instance: etcd on the imported class, the headless Service
  # named by the StatefulSet, io-engine
  # on the engine label, and the control plane on a read-only root.
  mayastor-builds-with-imported-etcd-class =
    let
      c = clusterWith { };
      ioEngine = daemonSet "io-engine" c;
      readOnly =
        name:
        builtins.all (ct: ct.securityContext.readOnlyRootFilesystem or false)
          (deployment name c).spec.template.spec.containers;
    in
    (
      etcdClass c == "local-path"
      && (etcdOf c).spec.serviceName == "mayastor-etcd-headless"
      &&
        ioEngine.spec.template.spec.nodeSelector == {
          "openebs.io/engine" = "mayastor";
          "kubernetes.io/arch" = "amd64";
        }
      && ioEngine.spec.updateStrategy.type == "OnDelete"
      && builtins.all readOnly [
        "agent-core"
        "api-rest"
        "operator-diskpool"
        "csi-controller"
      ]
    )
    || throw "plain mayastor instance: etcd class ${etcdClass c}, io-engine selector ${builtins.toJSON ioEngine.spec.template.spec.nodeSelector}";

  # A set ioEngine.nodeSelector replaces the engine label as a whole.
  mayastor-io-engine-node-selector-replaces-default =
    let
      selector =
        (daemonSet "io-engine" (clusterWith {
          config.ioEngine.nodeSelector."example.com/storage" = "nvme";
        })).spec.template.spec.nodeSelector;
    in
    selector == {
      "example.com/storage" = "nvme";
      "kubernetes.io/arch" = "amd64";
    }
    || throw "io-engine selector with ioEngine.nodeSelector set: ${builtins.toJSON selector}";

  # etcd's class (etcd.nix, "The class of the members' volumes"). Each
  # refusal has a control that differs from it in one field and builds.
  mayastor-etcd-class-checks =
    let
      cases = {
        # The instance answers storageClasses through its own alias and no
        # explicit dependency is wired.
        aliasOnly = evalFails (clusterWith {
          aliases = [
            "storageClasses"
            "mayastor"
          ];
          deps = _: { };
        });
        # The alias with the dependency wired explicitly builds.
        aliasWithDep =
          let
            c = clusterWith {
              aliases = [
                "storageClasses"
                "mayastor"
              ];
            };
          in
          builds c && etcdClass c == "local-path";
        # With the alias, a named class is still refused: the dependency
        # resolves to this instance before the named class is read.
        aliasWithNamedClass = evalFails (clusterWith {
          aliases = [
            "storageClasses"
            "mayastor"
          ];
          deps = _: { };
          config.etcd.storage.storageClassName = "local";
        });
        selfRef = evalFails (clusterWith {
          deps = ref: { storageClasses = ref.mayastor.mayastor; };
        });
        # A named class wins over the dependency, unless it is one of this
        # instance's classes.
        namedClass =
          let
            c = clusterWith { config.etcd.storage.storageClassName = "local"; };
          in
          builds c && etcdClass c == "local";
        namedOwnClass = evalFails (clusterWith {
          config = {
            storageClasses.ms-2.parameters.repl = "2";
            etcd.storage.storageClassName = "ms-2";
          };
        });
        namedOtherClass = builds (clusterWith {
          config = {
            storageClasses.ms-2.parameters.repl = "2";
            etcd.storage.storageClassName = "local";
          };
        });
        # The dependency gives one of this instance's class names.
        depOwnClass = evalFails (clusterWith {
          importClass = "ms-2";
          config.storageClasses.ms-2.parameters.repl = "2";
        });
        # Nothing provides storageClasses and no class is named.
        noProvider = evalFails (clusterWith {
          deps = _: { };
        });
      };
    in
    builtins.all (v: v) (builtins.attrValues cases)
    || throw "etcd class checks (true is the expected result for each): ${builtins.toJSON cases}";

  # Pools are checked against cluster.nodes while the cluster lists its
  # nodes and does not autoscale them.
  mayastor-pool-node-checks =
    let
      withNodes = autoscale: poolNode: {
        extra = {
          cluster.nodes.node1.labels."openebs.io/engine" = "mayastor";
          cluster.capabilities.nodeAutoscaling = autoscale;
        };
        config.diskPools.pool-1 = pool poolNode "/dev/sdb";
      };
      cases = {
        knownNode = builds (clusterWith (withNodes false "node1"));
        unknownNode = evalFails (clusterWith (withNodes false "node9"));
        unknownNodeAutoscaled = builds (clusterWith (withNodes true "node9"));
      };
    in
    builtins.all (v: v) (builtins.attrValues cases)
    || throw "pool node checks (true is the expected result for each): ${builtins.toJSON cases}";

  # Flags and env variables the package derives are refused; the same
  # option with a flag or variable the package does not own builds.
  mayastor-owned-flags-and-env =
    let
      cases = {
        ioEngineGrpcEndpoint = evalFails (clusterWith {
          config.ioEngine.extraArgs = [ "--grpc-endpoint=0.0.0.0" ];
        });
        ioEngineShortGrpcEndpoint = evalFails (clusterWith {
          config.ioEngine.extraArgs = [ "-g=0.0.0.0" ];
        });
        ioEngineReactorMask = evalFails (clusterWith {
          config.ioEngine.extraArgs = [ "-m=0x3" ];
        });
        ioEngineOtherFlag = builds (clusterWith {
          config.ioEngine.extraArgs = [ "--log-format=json" ];
        });
        agentCoreStore = evalFails (clusterWith {
          config.agentCore.extraArgs = [ "--store=x:2379" ];
        });
        operatorEndpoint = evalFails (clusterWith {
          config.operatorDiskpool.extraArgs = [ "--endpoint=x" ];
        });
        etcdName = evalFails (clusterWith {
          config.etcd.env.ETCD_NAME = "x";
        });
        etcdQuota = evalFails (clusterWith {
          config.etcd.env.ETCD_QUOTA_BACKEND_BYTES = "1";
        });
        etcdLogLevel = builds (clusterWith {
          config.etcd.env.ETCD_LOG_LEVEL = "debug";
        });
        haNodeName = evalFails (clusterWith {
          config.agentHaNode.env.MY_NODE_NAME = "x";
        });
        haNodeRustLog = builds (clusterWith {
          config.agentHaNode.env.RUST_LOG = "debug";
        });
        poolSpecNode = evalFails (clusterWith {
          config.diskPools.pool-1 = pool "node1" "/dev/sdb" // {
            extraSpec.node = "node2";
          };
        });
        # A tunable flag in extraArgs replaces the package's default.
        tunableOnce =
          let
            args = containerArgs (deployment "api-rest" (clusterWith {
              config.apiRest.extraArgs = [ "--core-health-freq=10s" ];
            })) "api-rest";
          in
          builtins.filter (lib.hasPrefix "--core-health-freq") args == [ "--core-health-freq=10s" ];
      };
    in
    builtins.all (v: v) (builtins.attrValues cases)
    || throw "owned flags and env (true is the expected result for each): ${builtins.toJSON cases}";

  # Assertion messages for pools, snapshot classes, tolerations, and
  # io-engine's resources.
  mayastor-assertion-messages =
    let
      snapshotDep = {
        snapshotController = { };
      };
      cases = {
        valid =
          failedMessages {
            config = {
              diskPools.pool-1 = pool "node1" "/dev/sdb";
              volumeSnapshotClasses.snap = { };
              ioEngine.tolerations = [
                {
                  key = "storage";
                  operator = "Exists";
                  effect = "NoSchedule";
                }
              ];
            };
            deps = snapshotDep;
          } == [ ];
        sharedDisk =
          someMessageHas
            [ "diskPools name the same disk more than once" "/dev/sdb on node node1" "pool-a, pool-b" ]
            (failedMessages {
              config.diskPools = {
                pool-a = pool "node1" "/dev/sdb";
                pool-b = pool "node1" "/dev/sdb";
              };
            });
        sameDiskOtherNode =
          failedMessages {
            config.diskPools = {
              pool-a = pool "node1" "/dev/sdb";
              pool-b = pool "node2" "/dev/sdb";
            };
          } == [ ];
        reservedNames =
          let
            messages = failedMessages {
              config = {
                diskPools.root = pool "node1" "/dev/sdb";
                volumeSnapshotClasses.meta = { };
              };
              deps = snapshotDep;
            };
          in
          someMessageHas [ "diskPools.root: Kix reserves the names \"root\" and \"meta\"" ] messages
          && someMessageHas [
            "config.volumeSnapshotClasses.meta: Kix reserves the names \"root\" and \"meta\""
          ] messages;
        ownedResources =
          someMessageHas [ "ioEngine.resources sets cpu" "ioEngine.cpuCount" ]
            (failedMessages {
              config.ioEngine.resources.limits.cpu = "4";
            });
        twoDefaultSnapshotClasses =
          let
            default.annotations."snapshot.storage.kubernetes.io/is-default-class" = "true";
          in
          someMessageHas
            [
              "config.volumeSnapshotClasses.a and config.volumeSnapshotClasses.b each set"
              "Keep this annotation on at most one class"
            ]
            (failedMessages {
              config.volumeSnapshotClasses = {
                a = default;
                b = default;
              };
              deps = snapshotDep;
            });
        snapshotClassesWithoutApi =
          someMessageHas
            [ "volumeSnapshotClasses defines snap" "nothing provides the snapshotController role" ]
            (failedMessages {
              config.volumeSnapshotClasses.snap = { };
            });
        tolerationWithoutKey =
          someMessageHas [ "ioEngine.tolerations[0] has no key" "operator = \"Exists\"" ]
            (failedMessages {
              config.ioEngine.tolerations = [ { effect = "NoSchedule"; } ];
            });
        tolerationExistsWithValue =
          someMessageHas [ "csiNode.tolerations[1] sets value with operator \"Exists\"" ]
            (failedMessages {
              config.csiNode.tolerations = [
                { operator = "Exists"; }
                {
                  key = "k";
                  operator = "Exists";
                  value = "v";
                }
              ];
            });
        tolerationSecondsWithoutNoExecute =
          someMessageHas [ "ioEngine.tolerations[0] sets tolerationSeconds" "effect = \"NoExecute\"" ]
            (failedMessages {
              config.ioEngine.tolerations = [
                {
                  key = "k";
                  value = "v";
                  effect = "NoSchedule";
                  tolerationSeconds = 30;
                }
              ];
            });
      };
    in
    builtins.all (v: v) (builtins.attrValues cases)
    || throw "assertion messages (true is the expected result for each): ${builtins.toJSON cases}";

  # With the snapshot API, a VolumeSnapshotClass for the Mayastor driver and
  # the csi-snapshotter sidecar are rendered; without it, neither is.
  mayastor-snapshot-classes-with-snapshot-api =
    let
      withApi = clusterWith {
        extra = snapshotEnvironment;
        config.volumeSnapshotClasses.snap = { };
      };
      withoutApi = clusterWith { };
      vsc = byName "snap" (ofKind "VolumeSnapshotClass" (ms withApi));
      sidecars =
        cluster: map (c: c.name) (deployment "csi-controller" cluster).spec.template.spec.containers;
    in
    (
      vsc != null
      && vsc.driver == "io.openebs.csi-mayastor"
      && vsc.deletionPolicy == "Delete"
      && builtins.elem "csi-snapshotter" (sidecars withApi)
      && !(builtins.elem "csi-snapshotter" (sidecars withoutApi))
    )
    || throw "snapshot classes: VolumeSnapshotClass ${builtins.toJSON vsc}, sidecars ${builtins.toJSON (sidecars withApi)}";
}
