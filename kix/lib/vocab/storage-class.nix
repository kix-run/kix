# Define the StorageClass submodule option type (`kix.types.storageClass`) and
# renderer (`kix.storage.mkClasses`) shared by storage packages and CSI drivers.
#
# A StorageClass becomes the cluster default through the Kubernetes annotation
# `storageclass.kubernetes.io/is-default-class = "true"`. The same annotation
# selects `storageClassName` for Kix consumers that do not name a class: the
# annotated class when exactly one is annotated, or the sole class when only
# one exists.
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
  # Build a StorageClass submodule type. Set `provisioner = false` in CSI driver
  # packages that pass a fixed provisioner to `mkClasses`. `parameters` sets the
  # option type for the `parameters` map, and `defaults` sets `lib.mkDefault`
  # values on matching option fields.
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

  # Render `classes` as cluster-scoped StorageClass resources and return
  # `{ resources; storageClassName; }`.
  #
  # `storageClassName` resolves to the `out.name` of the single default-annotated
  # class or the sole class, and throws when read if the choice is ambiguous.
  # Reading `out.name` from `parts` (such as `self.classes`) preserves
  # `partsOverlays` edits and orders consumers after the StorageClass.
  mkClasses =
    {
      scope,
      clusterConfig,
      who,
      optionPath,
      classes,
      parts,
      provisioner ? null,
      requires ? [ ],
    }:
    let
      names = builtins.attrNames classes;
      namesText = builtins.concatStringsSep ", " names;
      annotated = builtins.filter (n: isAnnotatedDefault classes.${n}) names;
      binding = (clusterConfig.cluster.roles.storageClasses or { }).binding or null;
      shadowable = binding == "shadowable";

      # `instancePartResources` (`eval/helpers.nix`) skips keys named `root` or
      # `meta` at every depth, so a class under either key would not render.
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
          parts.${builtins.head annotated}.out.name
        else if annotated != [ ] then
          throw "${who}: out.storageClassName was read, but ${optionPath} annotates ${builtins.concatStringsSep ", " annotated} as the cluster default. Keep the annotation on one class."
        else if builtins.length names == 1 then
          parts.${builtins.head names}.out.name
        else
          throw "${who}: out.storageClassName was read, but ${optionPath} has ${toString (builtins.length names)} classes (${namesText}) and none is chosen for consumers that name no class. ${
            lib.toUpper (builtins.substring 0 1 remedies)
          }${builtins.substring 1 (-1) remedies}.";
    };
}
