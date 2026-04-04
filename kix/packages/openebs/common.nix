# Shared labels, helpers, and RBAC group definitions for OpenEBS subsystems.
#
# This is a plain function (not a build part), imported by each component file.
{ scope, lib }:
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
  inherit
    name
    ns
    mayastorLabels
    zfsLabels
    lvmLabels
    localPvLabels
    mayastorSelector
    controlPlaneTolerations
    ;

  # RBAC DSL re-exports
  inherit
    core
    grant
    full
    watch
    emit
    allow
    mkClusterRoleSet
    openebsGrp
    storage
    snap
    coord
    apiext
    appsGrp
    zfsAll
    lvmAll
    ;
}
