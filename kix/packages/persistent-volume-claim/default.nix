# persistent-volume-claim: one PersistentVolumeClaim as its own cluster
# instance, so a claim appears in the dependency graph and gets the
# stateful lifecycle protection of kix diff. Packages that need a volume take
# it through their `storage` dependency.
#
# The claim's class is `config.storageClassName` when set, else the class the
# optional `storageClasses` provider gives consumers that name none
# (`out.storageClassName`). With neither, the build fails.
#
# root = the PVC.

{
  scope,
  lib,
  kix,
}:

let
  accessModeNames = [
    "ReadWriteOnce"
    "ReadOnlyMany"
    "ReadWriteMany"
    "ReadWriteOncePod"
  ];
in
{
  meta = {
    description = "A PersistentVolumeClaim as its own cluster instance, with its StorageClass set explicitly or taken from the storageClasses dependency";
    owner = "platform";
    lifecycle = "stateful";
    scope = "namespace";
    defaultAliases = [ "storage" ];
    # The canonical PVC author: raw claims are an eval-time error everywhere
    # else (v2_discussions/128). The grant is listed by the scorecard's
    # unsafeGrants audit.
    unsafe = [ "raw-pvc" ];
  };

  options = {
    size = lib.mkOption {
      # A string so that consumers can parse `out.size` as a quantity with a
      # unit; immich reads it with kix.parseGi.
      type = lib.types.addCheck kix.types.quantity builtins.isString;
      example = "20Gi";
      description = ''
        Requested capacity, as a Kubernetes quantity string such as "20Gi".
        Required: a generic claim cannot know how much its consumer stores.
        Rendered as `spec.resources.requests.storage` and published as
        `out.size`. The apiserver accepts an increase only when the class
        allows volume expansion, and refuses a decrease.
      '';
    };
    storageClassName = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "local-path-retain";
      description = ''
        StorageClass of the claim. Null takes `out.storageClassName` from the
        `storageClasses` dependency. `""` requests no class, for binding to a
        pre-provisioned PersistentVolume named in `extraSpec.volumeName`. The
        apiserver refuses a change on a bound claim.
      '';
    };
    accessModes = lib.mkOption {
      type = lib.types.nonEmptyListOf (lib.types.enum accessModeNames);
      default = [ "ReadWriteOnce" ];
      description = ''
        Access modes of the claim. `ReadWriteMany` and `ReadOnlyMany` need a
        provisioner that supports shared mounts; the claim stays Pending
        otherwise. `ReadWriteOncePod` cannot be combined with another mode.
      '';
    };
    extraSpec = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      example = lib.literalExpression ''{ volumeMode = "Block"; }'';
      description = ''
        Merged into the claim's `spec`, for fields without an option of their
        own: `volumeMode`, `dataSource`, `dataSourceRef`, `selector`,
        `volumeName` and `volumeAttributesClassName`. `storageClassName`,
        `accessModes` and `resources.requests.storage` are set by their
        options and refused here.
      '';
    };
  };

  build =
    {
      config,
      storageClasses ? null,
      ...
    }:
    let
      who = "persistent-volume-claim ${scope.namespaceName}/${scope.instanceName}";
      modes = config.accessModes;
      modesText = "[ ${lib.concatMapStringsSep " " (m: "\"${m}\"") modes} ]";
      repeated = lib.filter (m: lib.count (x: x == m) modes > 1) (lib.unique modes);

      storageClassName =
        if config.storageClassName != null then
          config.storageClassName
        else if storageClasses != null then
          storageClasses.out.storageClassName
        else
          throw "${who}: no StorageClass for this claim. Set config.storageClassName, or give the cluster a storageClasses provider: a flavor whose environment has a default class, a storage-classes instance, a CSI driver instance with aliases = [ \"storageClasses\" ], or an import of the environment's class: instances.kube-system.platform-storage.package = kix.mkImport { kind = \"StorageClass\"; apiVersion = \"storage.k8s.io/v1\"; roles = [ \"storageClasses\" ]; out = { name = \"<class>\"; storageClassName = \"<class>\"; }; }.";

      checks =
        if builtins.elem "ReadWriteOncePod" modes && builtins.length modes > 1 then
          throw "${who}: accessModes ${modesText} combines ReadWriteOncePod with other modes; the apiserver refuses that. Use [ \"ReadWriteOncePod\" ] alone."
        else if repeated != [ ] then
          throw "${who}: accessModes lists ${builtins.head repeated} more than once. List each mode once."
        else if builtins.match "0*(\\.0*)?(m|k|M|G|T|P|E|Ki|Mi|Gi|Ti|Pi|Ei)?" config.size != null then
          throw "${who}: size = \"${config.size}\" must be greater than zero."
        else
          null;

      claim = builtins.seq checks (
        scope.mkResource {
          apiVersion = "v1";
          kind = "PersistentVolumeClaim";
          name = scope.instanceName;
          spec =
            kix.mergeGuarded
              {
                inherit who;
                locked = [
                  [ "storageClassName" ]
                  [ "accessModes" ]
                  [
                    "resources"
                    "requests"
                    "storage"
                  ]
                ];
              }
              {
                inherit storageClassName;
                accessModes = modes;
                resources.requests.storage = config.size;
              }
              config.extraSpec;
          outputs.size = config.size;
        }
      );
    in
    {
      # instancePartResources skips the `root` key, so the PVC is rendered
      # from this named part.
      inherit claim;
      root = claim;
    };
}
