# Tests for the StorageClass vocabulary (vocab/storage-class.nix):
# kix.types.storageClass, and kix.storage.mkClasses with its rendering,
# checks and the class it gives consumers that name none. Then the
# storage-classes and persistent-volume-claim packages that build on it.

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
  kixKeys,
  storageClassImport,
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
          optionPath = "config.classes";
          classes = config.classes;
          parts = self.classes;
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
          optionPath = "config.classes";
          classes = config.classes;
          parts = self.classes;
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

  dependsOn = m: m.metadata.annotations.${kixKeys.dependsOn} or "";
  # The identity hash a consumer's depends-on lists for a part of an
  # instance.
  hashOf =
    cluster: ns: inst: path:
    builtins.unsafeDiscardStringContext
      (lib.attrByPath path (throw "no part ${toString path}") cluster.instances.${ns}.${inst}.raw)
      .out.identityHash;

  storageClassesPackage = import ../../../packages/stable/storage-classes;
  pvcPackage = import ../../../packages/stable/persistent-volume-claim;

  # A cluster with one claim in `apps` and, when `classes` is set, a
  # storage-classes instance in kube-system. No flavor, so nothing else
  # provides the storageClasses role.
  pvcCluster =
    {
      claim,
      classes ? null,
    }:
    mkCluster [
      {
        instances.apps.data = {
          package = pvcPackage;
          config = claim;
        };
      }
      (
        if classes != null then
          {
            instances.kube-system.storage-classes = {
              package = storageClassesPackage;
              config = { inherit classes; };
            };
          }
        else
          # The class validClaim names, so a claim the package accepts builds.
          { instances.apps.local-class = storageClassImport "local"; }
      )
    ];
  claimOf = cluster: byName "data" (ofKind "PersistentVolumeClaim" (manifests cluster));
  # A claim that passes every check, so each refusal test changes one field.
  validClaim = {
    size = "1Gi";
    storageClassName = "local";
  };
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
      && evalFails (clusterWith {
        inherit classes;
      })
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
      sc.parameters == {
        fsType = "xfs";
      }
      && sc.reclaimPolicy == "Retain"
      && sc.volumeBindingMode == "WaitForFirstConsumer"
      && sc.allowVolumeExpansion
      && sc.mountOptions == [ "noatime" ]
      &&
        sc.allowedTopologies == [
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

  # out.storageClassName carries the class's identity, so the consumer is
  # applied after the class.
  storage-consumer-depends-on-class =
    let
      c = clusterWith { classes.local = local; };
      consumer = byName "sc-consumer" (ofKind "ConfigMap" (manifests c));
    in
    lib.hasInfix (hashOf c "storage" "sc" [
      "classes"
      "local"
    ]) (dependsOn consumer)
    || throw "consumer depends-on lacks the class: ${dependsOn consumer}";

  # A partsOverlays replacement of the class is the dependency, so the
  # consumer never names a class hash that is not in the build.
  storage-overlaid-class-is-the-dependency =
    let
      c = clusterWith {
        classes.local = local;
        extra.instances.storage.sc.partsOverlays = [
          (scope: _self: super: {
            classes = super.classes // {
              local = scope.mkClusterResource {
                apiVersion = "storage.k8s.io/v1";
                kind = "StorageClass";
                name = "local";
                labels.overlaid = "true";
                extra.provisioner = "rancher.io/local-path";
              };
            };
          })
        ];
      };
      consumer = byName "sc-consumer" (ofKind "ConfigMap" (manifests c));
    in
    (
      (classNamed "local" c).metadata.labels.overlaid == "true"
      && lib.hasInfix (hashOf c "storage" "sc" [
        "classes"
        "local"
      ]) (dependsOn consumer)
    )
    || throw "overlaid class: consumer depends-on ${dependsOn consumer}";

  # A claim that names no class takes the storage-classes class and
  # depends on it.
  storage-classes-claim-depends-on-class =
    let
      c = pvcCluster {
        claim.size = "1Gi";
        classes.local = local;
      };
      claim = claimOf c;
    in
    (
      claim.spec.storageClassName == "local"
      && lib.hasInfix (hashOf c "kube-system" "storage-classes" [
        "classes"
        "local"
      ]) (dependsOn claim)
    )
    || throw "storage-classes claim: ${builtins.toJSON claim}";

  storage-classes-empty-throws =
    !evalFails (pvcCluster {
      claim = validClaim;
      classes.local = local;
    })
    && evalFails (pvcCluster {
      claim = validClaim;
      classes = { };
    });

  # The rendered spec is exactly the three fields with options, and an
  # integer size is rendered as a string.
  storage-pvc-renders-spec =
    let
      claim = claimOf (pvcCluster {
        claim = validClaim // {
          size = 1073741824;
        };
      });
    in
    claim.spec == {
      storageClassName = "local";
      accessModes = [ "ReadWriteOnce" ];
      resources.requests.storage = "1073741824";
    }
    || throw "claim spec: ${builtins.toJSON claim.spec}";

  storage-pvc-no-class-throws = evalFails (pvcCluster {
    claim.size = "1Gi";
  });

  # `""` requests no class, for a claim bound to a named PersistentVolume.
  storage-pvc-empty-class-binds-volume =
    let
      claim = claimOf (pvcCluster {
        claim = {
          size = "1Gi";
          storageClassName = "";
          extraSpec.volumeName = "pv-data";
        };
      });
    in
    (claim.spec.storageClassName == "" && claim.spec.volumeName == "pv-data")
    || throw "empty class: ${builtins.toJSON claim.spec}";

  storage-pvc-mode-refusals =
    let
      withModes =
        accessModes:
        pvcCluster {
          claim = validClaim // {
            inherit accessModes;
          };
        };
    in
    !evalFails (withModes [
      "ReadWriteOnce"
      "ReadOnlyMany"
    ])
    && evalFails (withModes [
      "ReadWriteOncePod"
      "ReadWriteOnce"
    ])
    && evalFails (withModes [
      "ReadWriteOnce"
      "ReadWriteOnce"
    ])
    && evalFails (withModes [
      "ReadWriteOncePod"
      "ReadWriteOncePod"
    ]);

  # Zero and sub-byte sizes are refused.
  storage-pvc-size-refusals =
    let
      withSize =
        size:
        pvcCluster {
          claim = validClaim // {
            inherit size;
          };
        };
    in
    !evalFails (withSize "1")
    && evalFails (withSize "0Gi")
    && evalFails (withSize "0.0Mi")
    && evalFails (withSize "500m")
    && evalFails (withSize 0);

  # extraSpec cannot set the fields that have options.
  storage-pvc-extraspec-locks =
    let
      withExtra =
        extraSpec:
        pvcCluster {
          claim = validClaim // {
            inherit extraSpec;
          };
        };
    in
    !evalFails (withExtra {
      volumeMode = "Block";
    })
    && evalFails (withExtra {
      storageClassName = "other";
    })
    && evalFails (withExtra {
      accessModes = [ "ReadWriteMany" ];
    })
    && evalFails (withExtra {
      resources.requests.storage = "2Gi";
    });
}
