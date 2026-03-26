# PersistentVolumeClaim package — operator-managed storage.
#
# Creates a PVC backed by a StorageClass. Intended as a first-class
# instance in the cluster definition, not embedded inside consuming
# packages. This ensures PVCs are visible in the dependency graph
# and get lifecycle protection from kix-diff.
#
# Dependencies:
#   storageClasses — required, provides the StorageClass name
#
# root = PersistentVolumeClaim.

{
  scope,
  lib,
  storageClasses,
}:

{
  meta = {
    version = "1.0.0";
    description = "Persistent Volume Claim — operator-managed storage";
    lifecycle = "stateful";
    scope = "namespace";
    provides = [ "storage" ];
    defaultAliases = [ "storage" ];
  };

  options = {
    size = lib.mkOption {
      type = lib.types.str;
      default = "10Gi";
      description = "Storage size (K8s quantity, e.g. 50Gi, 1Ti)";
    };
    accessModes = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "ReadWriteOnce" ];
      description = "PVC access modes";
    };
  };

  build =
    {
      self,
      config,
      clusterConfig,
    }:
    {
      root = scope.mkResource {
        apiVersion = "v1";
        kind = "PersistentVolumeClaim";
        name = scope.instanceName;
        spec = {
          storageClassName = storageClasses.out.storageClassName;
          accessModes = config.accessModes;
          resources.requests.storage = config.size;
        };
        outputs = {
          size = config.size;
        };
      };
    };
}
