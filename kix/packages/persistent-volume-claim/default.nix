# PersistentVolumeClaim package — operator-managed storage.
#
# Creates a PVC backed by a StorageClass. Intended as a first-class
# instance in the cluster definition, not embedded inside consuming
# packages. This ensures PVCs are visible in the dependency graph
# and get lifecycle protection from kix-diff.
#
# The StorageClass is resolved one of two ways:
#   - set `storageClassName` explicitly (lets one cluster use several classes
#     at once, e.g. block RWO for a DB and File Storage RWX for blobs), OR
#   - leave it null and let the optional `storageClasses` dep supply it (the
#     flavor's platform-storage default class).
#
# Dependencies:
#   storageClasses — optional, provides the default StorageClass name when
#                    config.storageClassName is null.
#
# root = the PVC (via the `claim` part — the renderable resource must live
# under a non-`root` key, since collectResources drops the `root` key; see the
# `secret` package for the same pattern, and kixpkgs#25).

{
  scope,
  lib,
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
    storageClassName = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "scw-bssd-retain";
      description = ''
        StorageClass name. When set, overrides the class from the
        `storageClasses` dep — lets one cluster use several classes at once.
        When null, the class is taken from the optional `storageClasses` dep.
      '';
    };
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
      # Optional: only consulted when config.storageClassName is null. Default
      # null so the package works with an explicit class and no dep wired.
      storageClasses ? null,
    }:
    let
      storageClassName =
        if config.storageClassName != null then
          config.storageClassName
        else if storageClasses != null then
          storageClasses.out.storageClassName
        else
          throw "persistent-volume-claim: set the `storageClassName` option or wire a `storageClasses` dependency.";
      claim = scope.mkResource {
        apiVersion = "v1";
        kind = "PersistentVolumeClaim";
        name = scope.instanceName;
        spec = {
          inherit storageClassName;
          accessModes = config.accessModes;
          resources.requests.storage = config.size;
        };
        outputs = {
          size = config.size;
        };
      };
    in
    {
      # NB: resource lives under `claim` (rendered); `root` only points at it
      # (same store path → dedup'd by the manifest writer). collectResources
      # drops the `root` key, so a PVC-as-root would never render. See kixpkgs#25.
      inherit claim;
      root = claim;
    };
}
