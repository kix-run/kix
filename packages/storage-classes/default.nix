# StorageClass package — NW1 cluster storage classes.
#
# Defines storage classes for Mayastor (replicated NVMe-oF) and OpenEBS
# LocalPV-ZFS provisioners. Each StorageClass is cluster-scoped.
#
# The `lbs1-pool1-2x` class is the default (annotation-based).

{
  scope,
  config,
  lib,
}:

let
  cfg = scope.defaults config {
    classes = {
      lbs1-pool1-2x = {
        provisioner = "io.openebs.csi-mayastor";
        parameters = {
          ioTimeout = "60";
          protocol = "nvmf";
          repl = "2";
          thin = "true";
          stsAffinityGroup = "true";
        };
        reclaimPolicy = "Delete";
        volumeBindingMode = "Immediate";
        allowVolumeExpansion = true;
        isDefault = true;
      };

      localzfs-retain = {
        provisioner = "zfs.csi.openebs.io";
        parameters = {
          fstype = "zfs";
          poolname = "zfspv-pool";
          shared = "yes";
        };
        reclaimPolicy = "Retain";
        volumeBindingMode = "WaitForFirstConsumer";
        allowVolumeExpansion = false;
      };

      localzfs = {
        provisioner = "zfs.csi.openebs.io";
        parameters = {
          fstype = "zfs";
          poolname = "zfspv-pool";
          shared = "yes";
        };
        reclaimPolicy = "Delete";
        volumeBindingMode = "WaitForFirstConsumer";
        allowVolumeExpansion = false;
      };

      localzfs-block = {
        provisioner = "zfs.csi.openebs.io";
        parameters = {
          fstype = "zfs";
          poolname = "zfspv-pool";
          shared = "yes";
        };
        reclaimPolicy = "Delete";
        volumeBindingMode = "WaitForFirstConsumer";
        allowVolumeExpansion = false;
      };
    };
  };

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

  classResources = lib.mapAttrs mkStorageClass cfg.classes;
  classList = builtins.attrValues classResources;

in
self:
classResources
// {
  main = {
    resource = self.lbs1-pool1-2x;
    requires = classList;
  };
}
