# One ServiceAccount per component and the API access each binary of this
# release uses:
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

  key = c.poolKey poolEncryptionKey;

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
    (lib.pipe core.namespaces [
      (restrictTo [ "kube-system" ])
      (allow [ "get" ])
    ])
  ];

  operatorCluster = roleSet mkClusterRoleSet "operatorDiskpoolServiceAccount" "operator-diskpool" [
    # A create request carries no object name, so it cannot be limited to
    # these CRDs.
    (allow [ "create" ] apiext.customresourcedefinitions)
    (lib.pipe apiext.customresourcedefinitions [
      (restrictTo operatorCrds)
      (allow [
        "get"
        "update"
        "patch"
      ])
    ])
    (lib.pipe (sub "status" apiext.customresourcedefinitions) [
      (restrictTo operatorCrds)
      (allow [
        "get"
        "update"
        "patch"
      ])
    ])
  ];

  operatorNamespace = roleSet mkRoleSet "operatorDiskpoolServiceAccount" "operator-diskpool" [
    (allow [
      "get"
      "list"
      "watch"
      "create"
      "update"
      "patch"
    ] openebs.diskpools)
    (allow [
      "update"
      "patch"
    ] (sub "status" openebs.diskpools))
    (allow [
      "get"
      "list"
      "patch"
      "delete"
      "deletecollection"
    ] openebs.mayastorpools)
    (allow [
      "create"
      "patch"
    ] core.events)
  ];

  csiController = roleSet mkClusterRoleSet "csiControllerServiceAccount" "csi-controller" (
    [
      (allow [
        "get"
        "list"
        "watch"
        "create"
        "update"
        "patch"
        "delete"
      ] core.persistentvolumes)
      (allow [
        "get"
        "list"
        "watch"
        "update"
        "patch"
      ] core.persistentvolumeclaims)
      (allow [ "patch" ] (sub "status" core.persistentvolumeclaims))
      (watch storage.storageclasses)
      (watch storage.csinodes)
      (watch core.nodes)
      (watch core.pods)
      (allow [
        "list"
        "watch"
        "create"
        "update"
        "patch"
      ] core.events)
      (allow [
        "get"
        "list"
        "watch"
        "update"
        "patch"
      ] storage.volumeattachments)
      (allow [ "patch" ] (sub "status" storage.volumeattachments))
    ]
    # csi-snapshotter's own rules, and the reads csi-provisioner makes to
    # restore a claim from a snapshot.
    ++ lib.optionals (snapshotController != null) [
      (watch snapshot.volumesnapshotclasses)
      (allow [
        "get"
        "list"
        "watch"
        "update"
        "patch"
      ] snapshot.volumesnapshotcontents)
      (allow [
        "update"
        "patch"
      ] (sub "status" snapshot.volumesnapshotcontents))
      (allow [
        "get"
        "list"
      ] snapshot.volumesnapshots)
    ]
  );

  csiNode = roleSet mkClusterRoleSet "csiNodeServiceAccount" "csi-node" [
    (allow [ "patch" ] core.nodes)
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
        (lib.pipe core.secrets [
          (restrictTo [ key.out.name ])
          (allow [ "get" ])
        ])
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
