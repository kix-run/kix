# StorageClass package — cluster storage classes.
#
# Defines storage classes for Mayastor (replicated NVMe-oF) and OpenEBS
# LocalPV-ZFS provisioners. Each StorageClass is cluster-scoped.
#
# The `lbs1-pool1-2x` class is the default (annotation-based).

{
  scope,
  lib,
}:

{
  options = {
    classes = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = {
        lbs1-pool1-2x = {
          provisioner = "io.openebs.csi-mayastor";
          parameters = {
            fsType = "xfs";
            ioTimeout = "300";
            local = "true";
            protocol = "nvmf";
            repl = "2";
            thin = "true";
          };
          reclaimPolicy = "Delete";
          volumeBindingMode = "Immediate";
          allowVolumeExpansion = true;
          isDefault = true;
        };

        localzfs-retain = {
          provisioner = "zfs.csi.openebs.io";
          parameters = {
            compression = "on";
            dedup = "off";
            fstype = "zfs";
            poolname = "zfspool0";
            recordsize = "128k";
          };
          reclaimPolicy = "Retain";
          volumeBindingMode = "WaitForFirstConsumer";
          allowVolumeExpansion = true;
        };

        localzfs = {
          provisioner = "zfs.csi.openebs.io";
          parameters = {
            compression = "on";
            dedup = "off";
            fstype = "zfs";
            poolname = "zfspool0";
            recordsize = "128k";
          };
          reclaimPolicy = "Delete";
          volumeBindingMode = "WaitForFirstConsumer";
          allowVolumeExpansion = true;
        };
      };
    };
  };

  build = { self, config, clusterConfig }:
  let
    mkStorageClass =
      name: spec:
      scope.mkClusterResource {
        apiVersion = "storage.k8s.io/v1";
        kind = "StorageClass";
        inherit name;
        annotations = lib.optionalAttrs (spec.isDefault or false) {
          "storageclass.kubernetes.io/is-default-class" = "true";
        };
        extra = {
          provisioner = spec.provisioner;
          parameters = spec.parameters;
          reclaimPolicy = spec.reclaimPolicy;
          volumeBindingMode = spec.volumeBindingMode;
        }
        // lib.optionalAttrs (spec.allowVolumeExpansion or false) {
          allowVolumeExpansion = true;
        };
      };

    classResources = lib.mapAttrs mkStorageClass config.classes;
    classList = builtins.attrValues classResources;

  in
  classResources
  // {
    main = {
      resource = self.lbs1-pool1-2x;
      requires = classList;
      out = {
        storageClassName = self.lbs1-pool1-2x.out.name;
      };
    };
  };
}
