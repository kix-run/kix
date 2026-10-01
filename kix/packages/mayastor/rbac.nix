# One ServiceAccount per component and the API access each binary uses in
# Mayastor 2.12.1:
# - agent-core and agent-ha-cluster (one pod) read the kube-system
#   Namespace's uid, which keys Mayastor's records in etcd.
# - operator-diskpool creates, migrates, and reconciles the DiskPool CRD and
#   DiskPools in this namespace, and reads the pool key to validate it.
# - csi-controller runs the provisioner, attacher, resizer, and (with the
#   snapshot API) snapshotter sidecars.
# - csi-node labels its own Node with its NVMe multipath support. RBAC
#   cannot limit that to one Node.
# - io-engine reads the pool key when it creates or imports an encrypted
#   pool. Its token is always mounted, so wiring the key later does not
#   change its OnDelete pod template.
# - api-rest, agent-ha-node, and etcd call no API and mount no token.
{
  self,
  scope,
  lib,
  kix,
  snapshotController ? null,
  poolEncryptionKey ? null,
  ...
}:

let
  c = import ./common.nix { inherit lib kix scope; };
  inherit (c) name ns;

  inherit (scope.rbac)
    group
    core
    grant
    watch
    allow
    restrictTo
    sub
    mkClusterRoleSet
    mkRoleSet
    ;

  apiext = group "apiextensions.k8s.io" [ "customresourcedefinitions" ];
  openebs = group "openebs.io" [
    "diskpools"
    "mayastorpools"
  ];
  storage = group "storage.k8s.io" [
    "storageclasses"
    "csinodes"
    "volumeattachments"
  ];
  snapshot = group "snapshot.storage.k8s.io" [
    "volumesnapshotclasses"
    "volumesnapshotcontents"
    "volumesnapshots"
  ];

  # The CRDs the operator writes: DiskPool, and MayastorPool, which it
  # migrates from Mayastor 1.x.
  operatorCrds = [
    "diskpools.openebs.io"
    "mayastorpools.openebs.io"
  ];

  key = kix.checkSecretKeys {
    inherit (c) who;
    arg = "poolEncryptionKey";
    dep = poolEncryptionKey;
    keys = [ "encryption_parameters" ];
  };

  serviceAccount =
    component: automount:
    scope.mkResource {
      apiVersion = "v1";
      kind = "ServiceAccount";
      name = "${name}-${component}";
      labels = c.componentLabels component;
      extra.automountServiceAccountToken = automount;
    };

  # A role set for one component's ServiceAccount, as { role; binding; }.
  roleSet =
    mkSet: saPart: component: rules:
    let
      roleName = "${name}-${component}";
      set = mkSet scope {
        subjects = [
          {
            kind = "ServiceAccount";
            name = self.${saPart}.out.name;
            namespace = ns;
          }
        ];
        labels = c.componentLabels component;
        roles.${roleName} = grant rules;
      };
    in
    {
      role = set.${roleName};
      binding = set."${roleName}-binding";
    };

  agentCore = roleSet mkClusterRoleSet "agentCoreServiceAccount" "agent-core" [
    (core.namespaces |> restrictTo [ "kube-system" ] |> allow [ "get" ])
  ];

  operatorCluster = roleSet mkClusterRoleSet "operatorDiskpoolServiceAccount" "operator-diskpool" [
    # A create request carries no object name, so it cannot be limited to
    # these CRDs.
    (apiext.customresourcedefinitions |> allow [ "create" ])
    (
      apiext.customresourcedefinitions
      |> restrictTo operatorCrds
      |> allow [
        "get"
        "update"
        "patch"
      ]
    )
    (
      sub "status" apiext.customresourcedefinitions
      |> restrictTo operatorCrds
      |> allow [
        "get"
        "update"
        "patch"
      ]
    )
  ];

  operatorNamespace = roleSet mkRoleSet "operatorDiskpoolServiceAccount" "operator-diskpool" [
    (
      openebs.diskpools
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
      sub "status" openebs.diskpools
      |> allow [
        "update"
        "patch"
      ]
    )
    (
      openebs.mayastorpools
      |> allow [
        "get"
        "list"
        "patch"
        "delete"
        "deletecollection"
      ]
    )
    (
      core.events
      |> allow [
        "create"
        "patch"
      ]
    )
  ];

  csiController = roleSet mkClusterRoleSet "csiControllerServiceAccount" "csi-controller" (
    [
      (
        core.persistentvolumes
        |> allow [
          "get"
          "list"
          "watch"
          "create"
          "update"
          "patch"
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
          "patch"
        ]
      )
      (sub "status" core.persistentvolumeclaims |> allow [ "patch" ])
      (storage.storageclasses |> watch)
      (storage.csinodes |> watch)
      (core.nodes |> watch)
      (core.pods |> watch)
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
      (sub "status" storage.volumeattachments |> allow [ "patch" ])
    ]
    # csi-snapshotter's own rules, and the reads csi-provisioner makes to
    # restore a claim from a snapshot.
    ++ lib.optionals (snapshotController != null) [
      (snapshot.volumesnapshotclasses |> watch)
      (
        snapshot.volumesnapshotcontents
        |> allow [
          "get"
          "list"
          "watch"
          "update"
          "patch"
        ]
      )
      (
        sub "status" snapshot.volumesnapshotcontents
        |> allow [
          "update"
          "patch"
        ]
      )
      (
        snapshot.volumesnapshots
        |> allow [
          "get"
          "list"
        ]
      )
    ]
  );

  csiNode = roleSet mkClusterRoleSet "csiNodeServiceAccount" "csi-node" [
    (core.nodes |> allow [ "patch" ])
  ];

  # Read access to the pool key Secret alone, for a component that reads it.
  keyReader =
    saPart: component:
    if key == null then
      {
        role = null;
        binding = null;
      }
    else
      roleSet mkRoleSet saPart "${component}-pool-key" [
        (core.secrets |> restrictTo [ key.out.name ] |> allow [ "get" ])
      ];

  operatorKey = keyReader "operatorDiskpoolServiceAccount" "operator-diskpool";
  ioEngineKey = keyReader "ioEngineServiceAccount" "io-engine";
in
{
  agentCoreServiceAccount = serviceAccount "agent-core" true;
  apiRestServiceAccount = serviceAccount "api-rest" false;
  operatorDiskpoolServiceAccount = serviceAccount "operator-diskpool" true;
  csiControllerServiceAccount = serviceAccount "csi-controller" true;
  csiNodeServiceAccount = serviceAccount "csi-node" true;
  ioEngineServiceAccount = serviceAccount "io-engine" true;
  agentHaNodeServiceAccount = serviceAccount "agent-ha-node" false;
  etcdServiceAccount = serviceAccount "etcd" false;

  agentCoreClusterRole = agentCore.role;
  agentCoreClusterRoleBinding = agentCore.binding;
  operatorDiskpoolClusterRole = operatorCluster.role;
  operatorDiskpoolClusterRoleBinding = operatorCluster.binding;
  operatorDiskpoolRole = operatorNamespace.role;
  operatorDiskpoolRoleBinding = operatorNamespace.binding;
  operatorDiskpoolKeyRole = operatorKey.role;
  operatorDiskpoolKeyRoleBinding = operatorKey.binding;
  csiControllerClusterRole = csiController.role;
  csiControllerClusterRoleBinding = csiController.binding;
  csiNodeClusterRole = csiNode.role;
  csiNodeClusterRoleBinding = csiNode.binding;
  ioEngineKeyRole = ioEngineKey.role;
  ioEngineKeyRoleBinding = ioEngineKey.binding;
}
