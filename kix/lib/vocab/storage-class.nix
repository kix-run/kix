# StorageClass vocabulary: the option type `kix.types.storageClass` and the
# renderer `kix.storage.mkClasses`. A generic class author (storage-classes)
# and CSI driver packages (zfs-localpv) use both, so every StorageClass a
# package renders has the same fields, checks and `out` shape.
#
# A class is the cluster default only through the real annotation
# `storageclass.kubernetes.io/is-default-class`. Kix has no separate field for
# the class its consumers get: `storageClassName` is the class annotated
# default when exactly one is, else the only class, and otherwise consumers
# name their class.
{ lib }:

let
  defaultAnnotation = "storageclass.kubernetes.io/is-default-class";

  isAnnotatedDefault = cls: (cls.annotations.${defaultAnnotation} or null) == "true";

  immutable = "The apiserver refuses changes to this field, so changing it means deleting and recreating the class.";

  topologySelector = lib.types.submodule {
    options.matchLabelExpressions = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            key = lib.mkOption {
              type = lib.types.str;
              description = "Node label key, such as `topology.kubernetes.io/zone`.";
            };
            values = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              description = "Label values the node must carry one of.";
            };
          };
        }
      );
      default = [ ];
      description = "Label requirements a node must meet for a volume of this class to be provisioned there.";
    };
  };
in
{
  # `provisioner = false` drops the `provisioner` field, for a driver package
  # that sets one provisioner on every class through `mkClasses`.
  # `parameters` is the type of the class's `parameters` map; a driver
  # passes a submodule with its typed keys. Each `defaults` entry becomes a
  # `lib.mkDefault` on the field of that name.
  type =
    {
      provisioner ? true,
      parameters ? lib.types.attrsOf lib.types.str,
      defaults ? { },
    }:
    lib.types.submodule {
      options =
        lib.optionalAttrs provisioner {
          provisioner = lib.mkOption {
            type = lib.types.str;
            description = "Name of the CSI driver that provisions volumes of this class, such as `rancher.io/local-path`. The driver must already run in the cluster. ${immutable}";
          };
        }
        // {
          parameters = lib.mkOption {
            type = parameters;
            default = { };
            description = "Driver-specific parameters passed to the provisioner. Null values are left out. Omitted from the manifest when empty. ${immutable}";
          };
          reclaimPolicy = lib.mkOption {
            type = lib.types.enum [
              "Delete"
              "Retain"
            ];
            default = "Delete";
            description = "What happens to a volume when its claim is deleted. ${immutable}";
          };
          volumeBindingMode = lib.mkOption {
            type = lib.types.enum [
              "Immediate"
              "WaitForFirstConsumer"
            ];
            default = "Immediate";
            description = "When a volume is provisioned: as soon as the claim exists, or once a pod using it is scheduled. Node-local drivers need `WaitForFirstConsumer`. ${immutable}";
          };
          allowVolumeExpansion = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Whether a claim of this class may grow. Omitted from the manifest when false, because the apiserver leaves the field unset and rendering `false` would differ from an adopted class.";
          };
          mountOptions = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = "Mount options for volumes of this class. Omitted from the manifest when empty.";
          };
          allowedTopologies = lib.mkOption {
            type = lib.types.listOf topologySelector;
            default = [ ];
            description = "Nodes volumes of this class may be provisioned for. Omitted from the manifest when empty.";
          };
          labels = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = { };
            description = "Labels on the StorageClass.";
          };
          annotations = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = { };
            description = ''
              Annotations on the StorageClass. `"${defaultAnnotation}" = "true"`
              makes it the cluster default, which the apiserver gives every
              claim that names no class.
            '';
          };
        };
      config = lib.mapAttrs (_: lib.mkDefault) defaults;
    };

  # Renders `classes` (an attrset of `type` values keyed by class name) as
  # cluster-scoped StorageClasses and picks the class consumers that name
  # none get. Returns `{ resources; storageClassName; }`:
  #   - `resources`: one resource per class, keyed like `classes`. Forcing the
  #     attrset runs the checks below.
  #   - `storageClassName`: the class annotated default when exactly one is,
  #     else the only class. Otherwise reading it throws, so a package can
  #     put it in `out` and the build fails only when a consumer relies on it.
  # `who` prefixes every message and `optionPath` names the option `classes`
  # came from. `provisioner`, when a string, is set on every class; null
  # reads each class's own `provisioner` field. `requires` is added to every
  # class, such as the driver's CSIDriver and pods.
  mkClasses =
    {
      scope,
      clusterConfig,
      who,
      optionPath,
      classes,
      provisioner ? null,
      requires ? [ ],
    }:
    let
      names = builtins.attrNames classes;
      namesText = builtins.concatStringsSep ", " names;
      annotated = builtins.filter (n: isAnnotatedDefault classes.${n}) names;
      binding = (clusterConfig.cluster.roles.storageClasses or { }).binding or null;
      shadowable = binding == "shadowable";

      # instancePartResources (eval/helpers.nix) skips keys named `root` or
      # `meta` at every depth, so a class under either key is never rendered.
      reserved = builtins.filter (n: n == "root" || n == "meta") names;

      checks =
        if reserved != [ ] then
          throw "${who}: ${optionPath}.${builtins.head reserved}: kix drops parts named root or meta, so this StorageClass would not be rendered. Rename it."
        else if shadowable && annotated != [ ] then
          let
            k = builtins.head annotated;
          in
          throw "${who}: ${optionPath}.${k} is annotated ${defaultAnnotation}=\"true\", but cluster.roles.storageClasses.binding is \"shadowable\": the environment already has a default StorageClass, so the cluster would have two. Remove the annotation; a kix consumer that needs this class names it, for example persistent-volume-claim config.storageClassName = \"${k}\". If the environment's class is no longer annotated default, set cluster.roles.storageClasses.binding = \"absent\"."
        else
          null;

      render =
        name: cls:
        let
          parameters = lib.filterAttrs (_: v: v != null) cls.parameters;
        in
        scope.mkClusterResource {
          apiVersion = "storage.k8s.io/v1";
          kind = "StorageClass";
          inherit name requires;
          inherit (cls) labels annotations;
          extra = {
            provisioner = if provisioner != null then provisioner else cls.provisioner;
            inherit (cls) reclaimPolicy volumeBindingMode;
          }
          // lib.optionalAttrs (parameters != { }) { inherit parameters; }
          // lib.optionalAttrs cls.allowVolumeExpansion { allowVolumeExpansion = true; }
          // lib.optionalAttrs (cls.mountOptions != [ ]) { inherit (cls) mountOptions; }
          // lib.optionalAttrs (cls.allowedTopologies != [ ]) { inherit (cls) allowedTopologies; };
        };

      remedies = lib.concatStringsSep ", or " (
        [
          "name the class in the consumer, for example persistent-volume-claim config.storageClassName = \"${builtins.head names}\""
        ]
        ++ lib.optional (
          !shadowable
        ) "annotate one ${defaultAnnotation}=\"true\", which also makes it the cluster default"
      );
    in
    {
      resources = builtins.seq checks (lib.mapAttrs render classes);
      storageClassName =
        if names == [ ] then
          throw "${who}: out.storageClassName was read, but ${optionPath} defines no classes."
        else if builtins.length annotated == 1 then
          builtins.head annotated
        else if annotated != [ ] then
          throw "${who}: out.storageClassName was read, but ${optionPath} annotates ${builtins.concatStringsSep ", " annotated} as the cluster default. Keep the annotation on one class."
        else if builtins.length names == 1 then
          builtins.head names
        else
          throw "${who}: out.storageClassName was read, but ${optionPath} has ${toString (builtins.length names)} classes (${namesText}) and none is chosen for consumers that name no class. ${lib.toUpper (builtins.substring 0 1 remedies)}${builtins.substring 1 (-1) remedies}.";
    };
}
