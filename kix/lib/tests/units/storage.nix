# Tests for the StorageClass vocabulary (vocab/storage-class.nix):
# kix.types.storageClass, and kix.storage.mkClasses with its rendering,
# checks and the class it gives consumers that name none.

{
  lib,
  kixlib,
  mkCluster,
  baseInstances,
  manifests,
  ofKind,
  byName,
  hasName,
  evalFails,
  requiredScConsumer,
  ...
}:

let
  # A storageClasses provider that authors the classes it is given, as the
  # storage-classes package does.
  classAuthor = {
    meta = {
      version = "test";
      roles = [ "storageClasses" ];
    };
    options.classes = lib.mkOption {
      type = lib.types.attrsOf (kixlib.types.storageClass { });
    };
    build =
      {
        self,
        scope,
        config,
        clusterConfig,
        ...
      }:
      let
        sc = kixlib.storage.mkClasses {
          inherit scope clusterConfig;
          who = "class-author ${scope.namespaceName}/${scope.instanceName}";
          optionPath = "config.classes";
          classes = config.classes;
        };
      in
      {
        classes = sc.resources;
        root = {
          resource = self.classes.${builtins.head (builtins.attrNames config.classes)};
          out = { inherit (sc) storageClassName; };
        };
      };
  };

  # A driver-style provider: one provisioner for every class and a typed
  # parameters submodule with a required key.
  driver = {
    meta = {
      version = "test";
      roles = [ "storageClasses" ];
    };
    options.classes = lib.mkOption {
      type = lib.types.attrsOf (
        kixlib.types.storageClass {
          provisioner = false;
          parameters = lib.types.submodule {
            options = {
              poolname = lib.mkOption { type = lib.types.str; };
              compression = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
              };
            };
          };
          defaults.volumeBindingMode = "WaitForFirstConsumer";
        }
      );
    };
    build =
      {
        self,
        scope,
        config,
        clusterConfig,
        ...
      }:
      let
        sc = kixlib.storage.mkClasses {
          inherit scope clusterConfig;
          who = "driver ${scope.namespaceName}/${scope.instanceName}";
          optionPath = "config.classes";
          classes = config.classes;
          provisioner = "driver.example.com";
        };
      in
      {
        classes = sc.resources;
        root = {
          resource = self.classes.${builtins.head (builtins.attrNames config.classes)};
          out = { inherit (sc) storageClassName; };
        };
      };
  };

  local = {
    provisioner = "rancher.io/local-path";
  };
  annotated = local // {
    annotations."storageclass.kubernetes.io/is-default-class" = "true";
  };

  # A cluster with the class author holding `classes`, plus the consumer
  # when `consume` is true. `extra` is one more module.
  clusterWith =
    {
      classes,
      consume ? true,
      package ? classAuthor,
      extra ? { },
    }:
    mkCluster [
      baseInstances
      {
        instances.storage.sc = {
          inherit package;
          config = { inherit classes; };
        };
      }
      (lib.optionalAttrs consume { instances.appns.consumer.package = requiredScConsumer; })
      extra
    ];

  consumed = cluster: (byName "sc-consumer" (ofKind "ConfigMap" (manifests cluster))).data.sc;
  classNamed = name: cluster: byName name (ofKind "StorageClass" (manifests cluster));
  shadowable.cluster.roles.storageClasses.binding = "shadowable";
in
{
  # One class and no annotation: consumers get it, and the manifest holds
  # only the fields that differ from the apiserver's unset values.
  storage-only-class-is-provided =
    let
      c = clusterWith { classes.local = local; };
      sc = classNamed "local" c;
    in
    (
      consumed c == "local"
      && sc.provisioner == "rancher.io/local-path"
      && sc.reclaimPolicy == "Delete"
      && sc.volumeBindingMode == "Immediate"
      && !(sc ? allowVolumeExpansion)
      && !(sc ? parameters)
      && !(sc ? mountOptions)
      && !(sc ? allowedTopologies)
    )
    || throw "only class: consumer got ${consumed c}, manifest ${builtins.toJSON sc}";

  # Two classes, one annotated default: consumers get the annotated one.
  storage-annotated-class-is-provided =
    let
      c = clusterWith {
        classes = {
          a = local;
          b = annotated;
        };
      };
    in
    (
      consumed c == "b"
      && (classNamed "b" c).metadata.annotations."storageclass.kubernetes.io/is-default-class" == "true"
    )
    || throw "annotated class: consumer got ${consumed c}";

  # Two unannotated classes build while no consumer reads
  # out.storageClassName, and fail once one does.
  storage-unchosen-class-throws-on-read =
    let
      classes = {
        a = local;
        b = local;
      };
      unread = clusterWith {
        inherit classes;
        consume = false;
      };
    in
    (
      hasName "a" (ofKind "StorageClass" (manifests unread))
      && hasName "b" (ofKind "StorageClass" (manifests unread))
      && evalFails (clusterWith { inherit classes; })
    )
    || throw "two unannotated classes: the unread build failed, or the read did not throw";

  storage-two-annotated-classes-throw-on-read = evalFails (clusterWith {
    classes = {
      a = annotated;
      b = annotated;
    };
  });

  # A class keyed `root` would be dropped from the parts, so it is refused.
  storage-reserved-class-key-throws = evalFails (clusterWith {
    classes.root = local;
    consume = false;
  });

  # Under a shadowable binding the environment already has a default
  # class, so an annotated managed class is refused; an unannotated one
  # still serves kix consumers.
  storage-annotated-class-under-shadowable-throws =
    let
      plain = clusterWith {
        classes.local = local;
        extra = shadowable;
      };
    in
    (
      consumed plain == "local"
      && evalFails (clusterWith {
        classes.local = annotated;
        consume = false;
        extra = shadowable;
      })
    )
    || throw "shadowable binding: unannotated class gave ${consumed plain}, or the annotated class was accepted";

  storage-optional-fields-rendered =
    let
      c = clusterWith {
        classes.full = local // {
          parameters = {
            fsType = "xfs";
          };
          reclaimPolicy = "Retain";
          volumeBindingMode = "WaitForFirstConsumer";
          allowVolumeExpansion = true;
          mountOptions = [ "noatime" ];
          allowedTopologies = [
            {
              matchLabelExpressions = [
                {
                  key = "topology.kubernetes.io/zone";
                  values = [ "a" ];
                }
              ];
            }
          ];
          labels.tier = "fast";
        };
        consume = false;
      };
      sc = classNamed "full" c;
    in
    (
      sc.parameters == { fsType = "xfs"; }
      && sc.reclaimPolicy == "Retain"
      && sc.volumeBindingMode == "WaitForFirstConsumer"
      && sc.allowVolumeExpansion
      && sc.mountOptions == [ "noatime" ]
      && sc.allowedTopologies == [
        {
          matchLabelExpressions = [
            {
              key = "topology.kubernetes.io/zone";
              values = [ "a" ];
            }
          ];
        }
      ]
      && sc.metadata.labels.tier == "fast"
    )
    || throw "optional fields: ${builtins.toJSON sc}";

  # A driver sets the provisioner on every class, applies its field
  # defaults, drops null parameters, and requires its typed parameters.
  storage-driver-classes =
    let
      c = clusterWith {
        package = driver;
        classes.zfs.parameters.poolname = "pool";
      };
      sc = classNamed "zfs" c;
    in
    (
      consumed c == "zfs"
      && sc.provisioner == "driver.example.com"
      && sc.volumeBindingMode == "WaitForFirstConsumer"
      && sc.parameters == { poolname = "pool"; }
      && evalFails (clusterWith {
        package = driver;
        classes.zfs = { };
        consume = false;
      })
    )
    || throw "driver classes: ${builtins.toJSON sc}";
}
