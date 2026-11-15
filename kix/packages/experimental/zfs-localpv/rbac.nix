# RBAC resources for the zfs-localpv controller and node ServiceAccounts.
{
  scope,
  lib,
  self,
  name,
  ns,
  hasSnapshotApi,
}:
let
  inherit (scope.rbac)
    core
    group
    grant
    watch
    allow
    mkClusterRoleSet
    mkRoleSet
    ;
  storage = group "storage.k8s.io" [
    "storageclasses"
    "csinodes"
    "volumeattachments"
    "volumeattributesclasses"
    "csistoragecapacities"
  ];
  snapshots = group "snapshot.storage.k8s.io" [
    "volumesnapshotclasses"
    "volumesnapshotcontents"
    "volumesnapshots"
  ];
  zfs = group "zfs.openebs.io" [
    "zfsvolumes"
    "zfssnapshots"
    "zfsbackups"
    "zfsrestores"
    "zfsnodes"
  ];
  zfsAll = [
    zfs.zfsvolumes
    zfs.zfssnapshots
    zfs.zfsbackups
    zfs.zfsrestores
    zfs.zfsnodes
  ];
  coordination = group "coordination.k8s.io" [ "leases" ];
  apps = group "apps" [ "replicasets" ];

  serviceAccountSubject = sa: [
    {
      kind = "ServiceAccount";
      name = sa.out.name;
      namespace = ns;
    }
  ];
in
mkClusterRoleSet scope {
  subjects = serviceAccountSubject self.controllerServiceAccount;
  labels = scope.selectorLabels;
  roles."${name}-${ns}-controller" = grant (
    [
      (allow [
        "get"
        "list"
        "watch"
        "create"
        "patch"
        "delete"
      ] core.persistentvolumes)
      (allow [
        "get"
        "list"
        "watch"
        "update"
      ] core.persistentvolumeclaims)
      (allow [ "patch" ] (core "persistentvolumeclaims/status"))
      (watch core.pods)
      (watch core.nodes)
      (allow [
        "list"
        "watch"
        "create"
        "update"
        "patch"
      ] core.events)
      (watch [
        storage.storageclasses
        storage.csinodes
        storage.volumeattachments
        storage.volumeattributesclasses
      ])
      (allow [
        "get"
        "list"
        "watch"
        "create"
        "update"
        "patch"
        "delete"
      ] zfsAll)
    ]
    ++ lib.optionals hasSnapshotApi [
      (allow
        [
          "get"
          "list"
        ]
        [
          snapshots.volumesnapshots
          snapshots.volumesnapshotcontents
        ]
      )
      (watch snapshots.volumesnapshotclasses)
      (allow [
        "get"
        "list"
        "watch"
        "update"
        "patch"
      ] snapshots.volumesnapshotcontents)
      (allow [
        "update"
        "patch"
      ] (snapshots "volumesnapshotcontents/status"))
    ]
  );
}
// mkClusterRoleSet scope {
  subjects = serviceAccountSubject self.nodeServiceAccount;
  labels = scope.selectorLabels;
  roles."${name}-${ns}-node" = grant [
    (watch core.nodes)
    (allow [
      "create"
      "update"
      "patch"
    ] core.events)
    (allow [
      "get"
      "list"
      "watch"
      "create"
      "update"
      "patch"
    ] zfsAll)
  ];
}
// mkRoleSet scope {
  subjects = serviceAccountSubject self.controllerServiceAccount;
  labels = scope.selectorLabels;
  roles."${name}-controller" = grant [
    (allow [
      "get"
      "watch"
      "list"
      "delete"
      "update"
      "create"
    ] coordination.leases)
    (allow [
      "get"
      "list"
      "watch"
      "create"
      "update"
      "patch"
      "delete"
    ] storage.csistoragecapacities)
    (allow [ "get" ] core.pods)
    (allow [ "get" ] apps.replicasets)
  ];
}
