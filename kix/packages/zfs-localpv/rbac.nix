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
      (
        core.persistentvolumes
        |> allow [
          "get"
          "list"
          "watch"
          "create"
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
        ]
      )
      (core "persistentvolumeclaims/status" |> allow [ "patch" ])
      (core.pods |> watch)
      (core.nodes |> watch)
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
        [
          storage.storageclasses
          storage.csinodes
          storage.volumeattachments
          storage.volumeattributesclasses
        ]
        |> watch
      )
      (
        zfsAll
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
    ]
    ++ lib.optionals hasSnapshotApi [
      (
        [
          snapshots.volumesnapshots
          snapshots.volumesnapshotcontents
        ]
        |> allow [
          "get"
          "list"
        ]
      )
      (snapshots.volumesnapshotclasses |> watch)
      (
        snapshots.volumesnapshotcontents
        |> allow [
          "get"
          "list"
          "watch"
          "update"
          "patch"
        ]
      )
      (
        snapshots "volumesnapshotcontents/status"
        |> allow [
          "update"
          "patch"
        ]
      )
    ]
  );
}
// mkClusterRoleSet scope {
  subjects = serviceAccountSubject self.nodeServiceAccount;
  labels = scope.selectorLabels;
  roles."${name}-${ns}-node" = grant [
    (core.nodes |> watch)
    (
      core.events
      |> allow [
        "create"
        "update"
        "patch"
      ]
    )
    (
      zfsAll
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
}
// mkRoleSet scope {
  subjects = serviceAccountSubject self.controllerServiceAccount;
  labels = scope.selectorLabels;
  roles."${name}-controller" = grant [
    (
      coordination.leases
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
      storage.csistoragecapacities
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
    (core.pods |> allow [ "get" ])
    (apps.replicasets |> allow [ "get" ])
  ];
}
