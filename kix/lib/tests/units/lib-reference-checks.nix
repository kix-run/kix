# Tests for CRD reference declarations (scope.mkCRDRef: required version,
# per-instance markers, the crd-* annotations), served-version checks on
# custom resources, optional import activation (a demand in eval/auto.nix
# activates an optional import; a resolution alone does not), the
# cross-resource checks 18-23 in eval/validate.nix,
# the instance-of edge for chart custom resources, kix.expose's HTTPRoute
# CRD ref, mkSecret's refusal of keys without a value, and cloudflared's
# token check, which must run before mkSecret.

{
  lib,
  eval,
  kixlib,
  kixKeys,
  mkCluster,
  baseInstances,
  manifests,
  ofKind,
  byName,
  hasName,
  evalFails,
  ...
}:

let
  kixAnnotations = import ../../core/annotations.nix;

  # A package that references the example.com Widget CRD. `refArgs` is
  # merged into the mkCRDRef call; `crArgs`, when set, builds one Widget.
  widgetRefPackage =
    {
      refArgs ? {
        version = "v1";
      },
      crArgs ? null,
    }:
    {
      meta.version = "test";
      build =
        { self, scope, ... }:
        {
          widgetCrd = scope.mkCRDRef (
            {
              group = "example.com";
              kind = "Widget";
              plural = "widgets";
            }
            // refArgs
          );
          root = self.widgetCrd;
        }
        // lib.optionalAttrs (crArgs != null) {
          widget = scope.mkCR self.widgetCrd ({ name = "w"; } // crArgs);
        };
    };

  # A package that declares a Gadget CRD serving v1 and listing v1beta1 as
  # not served, and builds one Gadget with `crArgs`.
  gadgetPackage = crArgs: {
    meta.version = "test";
    build =
      { self, scope, ... }:
      {
        gadgetCrd = scope.mkCRD {
          spec = {
            group = "example.com";
            scope = "Namespaced";
            names = {
              kind = "Gadget";
              listKind = "GadgetList";
              plural = "gadgets";
              singular = "gadget";
            };
            versions = [
              {
                name = "v1";
                served = true;
                storage = true;
                schema.openAPIV3Schema = {
                  type = "object";
                  x-kubernetes-preserve-unknown-fields = true;
                };
              }
              {
                name = "v1beta1";
                served = false;
                storage = false;
                schema.openAPIV3Schema = {
                  type = "object";
                  x-kubernetes-preserve-unknown-fields = true;
                };
              }
            ];
          };
        };
        gadget = scope.mkCR self.gadgetCrd ({ name = "g"; } // crArgs);
        root = self.gadgetCrd;
      };
  };

  withApp =
    instances:
    mkCluster [
      baseInstances
      { inherit instances; }
    ];

  annotationsOf = m: m.metadata.annotations or { };

  # --- activation fixtures ---

  # An optional import answering `x`, as a flavour's platform import does.
  optionalImport = {
    instances.platform.x = {
      package = eval.mkImport {
        kind = "StorageClass";
        apiVersion = "storage.k8s.io/v1";
        out = {
          name = "import-sc";
          who = "import";
        };
      };
      optional = true;
    };
  };

  # A consumer whose `x` dependency is optional or required.
  xConsumer =
    { optional }:
    {
      meta.version = "test";
      build =
        if optional then
          {
            self,
            scope,
            x ? null,
            ...
          }:
          {
            cm = scope.mkResource {
              apiVersion = "v1";
              kind = "ConfigMap";
              name = "x-consumer";
              extra.data.who = if x == null then "none" else x.out.who;
            };
            root = self.cm;
          }
        else
          {
            self,
            scope,
            x,
            ...
          }:
          {
            cm = scope.mkResource {
              apiVersion = "v1";
              kind = "ConfigMap";
              name = "x-consumer";
              extra.data.who = x.out.who;
            };
            root = self.cm;
          };
    };

  # A managed package answering `x` (and any `aliases` given).
  xProvider =
    {
      who,
      aliases ? [ "x" ],
      scope ? null,
    }:
    {
      meta = {
        version = "test";
        defaultAliases = aliases;
      }
      // lib.optionalAttrs (scope != null) { inherit scope; };
      build =
        { self, scope, ... }:
        {
          cm = scope.mkResource {
            apiVersion = "v1";
            kind = "ConfigMap";
            name = "provider-${who}";
          };
          root = {
            resource = self.cm;
            out = { inherit who; };
          };
        };
    };

  activationCluster =
    modules:
    manifests (
      mkCluster (
        [
          baseInstances
          optionalImport
        ]
        ++ modules
      )
    );

  # The import's marker: a PackageInstance named after the import instance
  # in its namespace, in import mode.
  importMarker =
    ms:
    lib.findFirst (
      m:
      m.kind == "PackageInstance"
      && m.metadata.name == "x"
      && (m.metadata.namespace or "") == "platform"
      && (annotationsOf m).${kixKeys.mode} or "" == "import"
    ) null ms;

  whoOf = ms: (byName "x-consumer" (ofKind "ConfigMap" ms)).data.who or "missing";

  # --- cross-resource checks 18-23 on hand-built manifest lists ---

  validate = import ../../eval/validate.nix { inherit lib; };
  helmDag = import ../../helm-dag.nix { inherit lib; };

  mf =
    kind: ns: name: extra:
    lib.recursiveUpdate {
      apiVersion = "v1";
      inherit kind;
      metadata = {
        inherit name;
        labels."app.kubernetes.io/managed-by" = "kix";
      }
      // lib.optionalAttrs (ns != null) { namespace = ns; };
    } extra;

  # The identity hash of a hand-built manifest is a readable id;
  # `dependsOn` writes the same ids into kix.run/depends-on.
  idOf = m: "${m.kind}-${m.metadata.namespace or "_"}-${m.metadata.name}";
  dependsOn = targets: {
    metadata.annotations.${kixKeys.dependsOn} = builtins.concatStringsSep "," (map idOf targets);
  };

  # Failures of `ms` (the Namespace objects are added). `owners` maps an
  # idOf to "<ns>/<instance>".
  failuresOf =
    {
      ms,
      owners ? { },
      externalNames ? { },
    }:
    let
      all = [
        (mf "Namespace" null "a" { })
        (mf "Namespace" null "kube-system" { })
      ]
      ++ ms;
    in
    validate.crossResourceFailures {
      manifests = all;
      identityHashes = map idOf all;
      owners = map (m: owners.${idOf m} or null) all;
      inherit externalNames;
    };

  # Exactly one failure per needle, each containing its needle.
  expectFailures =
    needles: args:
    let
      fs = failuresOf args;
    in
    (
      builtins.length fs == builtins.length needles
      && builtins.all (n: builtins.any (lib.hasInfix n) fs) needles
    )
    || throw "expected failures containing ${builtins.toJSON needles}, got: ${builtins.toJSON fs}";
  expectClean = args: expectFailures [ ] args;

  # A Deployment in namespace a whose one container and pod spec take the
  # given extra fields.
  podDeployment =
    name:
    {
      container ? { },
      pod ? { },
    }:
    mf "Deployment" "a" name {
      apiVersion = "apps/v1";
      spec = {
        selector.matchLabels.app = name;
        template = {
          metadata.labels.app = name;
          spec = {
            containers = [
              (
                {
                  name = "c";
                  image = "example/c:1";
                }
                // container
              )
            ];
          }
          // pod;
        };
      };
    };

  claim =
    name: spec:
    mf "PersistentVolumeClaim" "a" name {
      inherit spec;
    };

  storageClass =
    name: annotations:
    mf "StorageClass" null name {
      apiVersion = "storage.k8s.io/v1";
      provisioner = "example.com/csi";
      metadata = { inherit annotations; };
    };

  importMarkerOf =
    ns: name: kind: iname: extra:
    mf "PackageInstance" ns name {
      apiVersion = kixAnnotations.apiVersion;
      metadata.annotations = {
        ${kixKeys.mode} = "import";
        ${kixKeys.importKind} = kind;
        ${kixKeys.importName} = iname;
      }
      // extra;
    };

  # A Secret built by scope.mkSecret declares its keys in an annotation.
  builtSecret =
    name: keys:
    mf "Secret" "a" name {
      metadata.annotations.${kixKeys.secretKeys} = builtins.concatStringsSep "," keys;
    };

  widgetCrd =
    scope: versions:
    mf "CustomResourceDefinition" null "widgets.example.com" {
      apiVersion = "apiextensions.k8s.io/v1";
      spec = {
        group = "example.com";
        names.kind = "Widget";
        inherit scope;
        versions = map (v: {
          name = v.name;
          served = v.served or true;
          storage = v.storage or false;
        }) versions;
      };
    };

  widgetRefMarker =
    extra:
    importMarkerOf "a" "crd-ref-op-widgets-example-com" "CustomResourceDefinition" "widgets.example.com"
      (
        {
          ${kixKeys.crdKind} = "Widget";
          ${kixKeys.crdVersion} = "v1";
          ${kixKeys.crdScope} = "Namespaced";
        }
        // extra
      );

  widget =
    version: deps:
    mf "Widget" "a" "w" (
      lib.recursiveUpdate { apiVersion = "example.com/${version}"; } (
        lib.optionalAttrs (deps != [ ]) (dependsOn deps)
      )
    );

  claimVolume = {
    name = "data";
    persistentVolumeClaim.claimName = "data";
  };

  secretEnv = envName: secret: key: {
    name = envName;
    valueFrom.secretKeyRef = {
      name = secret;
      inherit key;
    };
  };

  secretVolume = name: extra: {
    inherit name;
    secret = {
      secretName = name;
    }
    // extra;
  };

  # A web Service exposed twice: the default route part and a second one
  # under its own part names. Only the first route is rendered as a part
  # the cluster reads; both CRD ref parts are compared.
  webPackage = {
    meta.version = "test";
    options.ingress.host = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
    build = [
      (
        {
          self,
          scope,
          kix,
          ...
        }:
        {
          deployment = scope.mkDeployment {
            name = scope.instanceName;
            spec = {
              replicas = 1;
              selector.matchLabels = scope.selectorLabels;
              template = {
                metadata.labels = scope.selectorLabels;
                spec.containers = [
                  {
                    name = "web";
                    image = "web:1";
                    ports = [
                      {
                        name = "http";
                        containerPort = 8080;
                      }
                    ];
                    resources = {
                      requests = {
                        cpu = "10m";
                        memory = "16Mi";
                      };
                      limits.memory = "32Mi";
                    };
                  }
                ];
              };
            };
          };
          service =
            self.deployment |> kix.service.fromWorkload { name = scope.instanceName; } |> scope.mkResource;
          root = self.service;
        }
      )
      (kixlib.expose { service = "service"; })
      (
        {
          self,
          config,
          clusterConfig,
          scope,
          lib,
          gateway ? null,
          ...
        }@args:
        let
          second = kixlib.expose {
            service = "service";
            partName = "adminRoute";
            exposurePart = "adminExposure";
          } args;
        in
        # The second route has the first one's name, so only its CRD ref
        # part is kept.
        {
          inherit (second) adminRouteCrd;
        }
      )
    ];
  };
in
{
  # --- mkCRDRef ---

  lib-reference-checks-crdref-without-version-throws = evalFails (withApp {
    appns.widgets.package = widgetRefPackage { refArgs = { }; };
  });

  lib-reference-checks-crdref-invalid-version-throws = evalFails (withApp {
    appns.widgets.package = widgetRefPackage { refArgs.version = "V1"; };
  });

  lib-reference-checks-crdref-invalid-scope-throws = evalFails (withApp {
    appns.widgets.package = widgetRefPackage {
      refArgs = {
        version = "v1";
        crdScope = "namespaced";
      };
    };
  });

  # Two instances in one namespace that reference one CRD render one marker
  # each, named for the instance and carrying the declared kind, version
  # and scope.
  lib-reference-checks-crdref-markers-per-instance =
    let
      ms = manifests (withApp {
        appns.widgets-a.package = widgetRefPackage { };
        appns.widgets-b.package = widgetRefPackage { refArgs.version = "v1beta1"; };
      });
      markers = ofKind "PackageInstance" ms;
      a = byName "crd-ref-widgets-a-widgets-example-com" markers;
      b = byName "crd-ref-widgets-b-widgets-example-com" markers;
    in
    (
      a != null
      && b != null
      && (annotationsOf a).${kixKeys.crdKind} == "Widget"
      && (annotationsOf a).${kixKeys.crdVersion} == "v1"
      && (annotationsOf b).${kixKeys.crdVersion} == "v1beta1"
      && (annotationsOf a).${kixKeys.crdScope} == "Namespaced"
      && (annotationsOf a).${kixKeys.importName} == "widgets.example.com"
    )
    || throw "per-instance CRD ref markers: ${builtins.toJSON (map (m: m.metadata.name) markers)}";

  # --- served versions ---

  lib-reference-checks-cr-at-ref-version-passes =
    let
      ms = manifests (withApp {
        appns.widgets.package = widgetRefPackage { crArgs = { }; };
      });
    in
    (byName "w" (ofKind "Widget" ms)).apiVersion == "example.com/v1"
    || throw "a Widget at the ref's version was not built";

  lib-reference-checks-cr-at-unserved-ref-version-throws = evalFails (withApp {
    appns.widgets.package = widgetRefPackage { crArgs.version = "v2"; };
  });

  # servedVersions lists every version a custom resource may set; `version`
  # stays the default.
  lib-reference-checks-cr-at-listed-served-version-passes =
    let
      refArgs = {
        version = "v1";
        servedVersions = [
          "v1"
          "v1beta1"
        ];
      };
      apiVersionOf =
        crArgs:
        (byName "w" (
          ofKind "Widget" (
            manifests (withApp {
              appns.widgets.package = widgetRefPackage { inherit refArgs crArgs; };
            })
          )
        )).apiVersion;
    in
    (
      apiVersionOf { version = "v1beta1"; } == "example.com/v1beta1"
      && apiVersionOf { } == "example.com/v1"
    )
    || throw "a Widget at a listed served version was not built";

  lib-reference-checks-cr-at-unlisted-version-throws = evalFails (withApp {
    appns.widgets.package = widgetRefPackage {
      refArgs = {
        version = "v1";
        servedVersions = [
          "v1"
          "v1beta1"
        ];
      };
      crArgs.version = "v2";
    };
  });

  lib-reference-checks-crdref-served-versions-without-version-throws = evalFails (withApp {
    appns.widgets.package = widgetRefPackage {
      refArgs = {
        version = "v1";
        servedVersions = [ "v1beta1" ];
      };
    };
  });

  lib-reference-checks-crdref-served-versions-invalid-throws = evalFails (withApp {
    appns.widgets.package = widgetRefPackage {
      refArgs = {
        version = "v1";
        servedVersions = [
          "v1"
          "V2"
        ];
      };
    };
  });

  # A mkImport crds entry takes servedVersions as mkCRDRef does.
  lib-reference-checks-import-crds-served-versions =
    let
      cluster =
        crArgs:
        withApp {
          platform.widget-api = {
            package = eval.mkImport {
              crds = [
                {
                  group = "example.com";
                  kind = "Widget";
                  plural = "widgets";
                  version = "v1";
                  servedVersions = [
                    "v1"
                    "v1beta1"
                  ];
                }
              ];
            };
            aliases = [ "widgetApi" ];
          };
          appns.consumer.package = {
            meta.version = "test";
            build =
              {
                self,
                scope,
                widgetApi,
                ...
              }:
              {
                widget = scope.mkCR widgetApi.out.crds.Widget ({ name = "w"; } // crArgs);
                root = self.widget;
              };
          };
        };
    in
    (
      (byName "w" (
        ofKind "Widget" (
          manifests (cluster {
            version = "v1beta1";
          })
        )
      )).apiVersion == "example.com/v1beta1"
      && evalFails (cluster {
        version = "v2";
      })
    )
    || throw "mkImport crds servedVersions: v1beta1 not built or v2 accepted";

  lib-reference-checks-cr-at-served-crd-version-passes =
    let
      ms = manifests (withApp {
        appns.gadgets.package = gadgetPackage { };
      });
    in
    (byName "g" (ofKind "Gadget" ms)).apiVersion == "example.com/v1"
    || throw "a Gadget at the CRD's served version was not built";

  # v1beta1 is listed in spec.versions with served = false.
  lib-reference-checks-cr-at-unserved-crd-version-throws = evalFails (withApp {
    appns.gadgets.package = gadgetPackage { version = "v1beta1"; };
  });

  # The reference-mode VM operator names every monitoring.coreos.com kind it
  # converts, at the version upstream serves. The AlertmanagerConfig marker
  # is the longest CRD ref marker name in kixpkgs.
  lib-reference-checks-victoria-metrics-operator-refs =
    let
      ms = manifests (mkCluster [
        {
          instances.monitoring-system.victoria-metrics-operator = {
            package = import ../../../packages/victoria-metrics-operator;
            config = {
              prometheusOperatorCRDs = "reference";
              convert = {
                scrapeConfigs = true;
                alertmanagerConfigs = true;
              };
            };
          };
        }
      ]);
      markers = ofKind "PackageInstance" ms;
      versionOf =
        plural:
        (annotationsOf (byName "crd-ref-victoria-metrics-operator-${plural}-monitoring-coreos-com" markers))
        .${kixKeys.crdVersion};
    in
    (
      versionOf "alertmanagerconfigs" == "v1alpha1"
      && versionOf "scrapeconfigs" == "v1alpha1"
      && versionOf "servicemonitors" == "v1"
      && !(hasName "servicemonitors.monitoring.coreos.com" (ofKind "CustomResourceDefinition" ms))
    )
    || throw "VM operator refs: ${builtins.toJSON (map (m: m.metadata.name) markers)}";

  # --- optional import activation ---

  # A required dependency that resolves to an optional import activates it:
  # the marker names the StorageClass the deploy waits for.
  lib-reference-checks-required-dep-activates-import =
    let
      ms = activationCluster [ { instances.appns.consumer.package = xConsumer { optional = false; }; } ];
      marker = importMarker ms;
    in
    (
      whoOf ms == "import"
      && marker != null
      && (annotationsOf marker).${kixKeys.importKind} == "StorageClass"
      && (annotationsOf marker).${kixKeys.importName} == "import-sc"
    )
    || throw "required dependency did not activate the import: ${whoOf ms}, marker ${builtins.toJSON marker}";

  # An optional dependency places no demand. It resolves to the optional
  # import, which stays inactive and emits no marker.
  lib-reference-checks-optional-dep-leaves-import-inactive =
    let
      ms = activationCluster [ { instances.appns.consumer.package = xConsumer { optional = true; }; } ];
    in
    (whoOf ms == "import" && importMarker ms == null)
    || throw "optional dependency: ${whoOf ms}, import marker ${builtins.toJSON (importMarker ms)}";

  # Nothing resolves to the import, so it stays inactive.
  lib-reference-checks-unused-import-stays-inactive =
    importMarker (activationCluster [ ]) == null
    || throw "an unused optional import emitted its marker";

  # A mandatory managed instance answers `x`; the import is not the
  # resolution and stays inactive.
  lib-reference-checks-mandatory-provider-leaves-import-inactive =
    let
      ms = activationCluster [
        {
          instances.infra.provider.package = xProvider { who = "managed"; };
          instances.appns.consumer.package = xConsumer { optional = true; };
        }
      ];
    in
    (whoOf ms == "managed" && importMarker ms == null)
    || throw "mandatory provider: ${whoOf ms}, import marker ${builtins.toJSON (importMarker ms)}";

  # An optional managed instance that a required dependency activates wins
  # over the import.
  lib-reference-checks-activated-optional-leaves-import-inactive =
    let
      ms = activationCluster [
        {
          instances.infra.x = {
            package = xProvider { who = "managed"; };
            optional = true;
          };
          instances.appns.consumer.package = xConsumer { optional = false; };
        }
      ];
    in
    (whoOf ms == "managed" && importMarker ms == null)
    || throw "activated optional: ${whoOf ms}, import marker ${builtins.toJSON (importMarker ms)}";

  # A shelf package pulled for another dependency also answers `x`. The
  # managed, auto-instantiated instance wins over the import.
  lib-reference-checks-auto-instantiated-leaves-import-inactive =
    let
      ms = activationCluster [
        {
          availablePackages.y.package = xProvider {
            who = "auto";
            aliases = [
              "y"
              "x"
            ];
          };
          instances.appns.y-requirer.package = {
            meta.version = "test";
            build =
              {
                self,
                scope,
                y,
                ...
              }:
              {
                cm = scope.mkResource {
                  apiVersion = "v1";
                  kind = "ConfigMap";
                  name = "y-requirer";
                  extra.data.who = y.out.who;
                };
                root = self.cm;
              };
          };
          instances.appns.consumer.package = xConsumer { optional = true; };
        }
      ];
    in
    (whoOf ms == "auto" && importMarker ms == null)
    || throw "auto-instantiated: ${whoOf ms}, import marker ${builtins.toJSON (importMarker ms)}";

  # An optional consumer nothing activates places no demand.
  lib-reference-checks-inactive-consumer-activates-nothing =
    importMarker (activationCluster [
      {
        instances.appns.consumer = {
          package = xConsumer { optional = true; };
          optional = true;
        };
      }
    ]) == null
    || throw "an inactive consumer activated the import";

  # deps.x bound to a value other than a ref: the build uses the value,
  # so the import is not activated.
  lib-reference-checks-direct-wiring-activates-nothing =
    let
      ms = activationCluster [
        {
          instances.appns.consumer = {
            package = xConsumer { optional = true; };
            deps.x = {
              out.who = "direct";
            };
          };
        }
      ];
    in
    (whoOf ms == "direct" && importMarker ms == null)
    || throw "direct wiring: ${whoOf ms}, import marker ${builtins.toJSON (importMarker ms)}";

  # deps.x = ref.platform.x names the import, which is then active.
  lib-reference-checks-ref-wiring-activates-import =
    let
      ms = activationCluster [
        (
          { ref, ... }:
          {
            instances.infra.provider.package = xProvider { who = "managed"; };
            instances.appns.consumer = {
              package = xConsumer { optional = true; };
              deps.x = ref.platform.x;
            };
          }
        )
      ];
    in
    (whoOf ms == "import" && importMarker ms != null)
    || throw "ref wiring: ${whoOf ms}, import marker ${builtins.toJSON (importMarker ms)}";

  # The only managed candidate has meta.scope = "namespace" and sits in
  # another namespace, so resolution skips it and the import answers. The
  # dependency is optional, so the import stays inactive.
  lib-reference-checks-foreign-namespaced-candidate-resolves-to-import =
    let
      ms = activationCluster [
        {
          instances.other.provider.package = xProvider {
            who = "namespaced";
            scope = "namespace";
          };
          instances.appns.consumer.package = xConsumer { optional = true; };
        }
      ];
    in
    (whoOf ms == "import" && importMarker ms == null)
    || throw "foreign namespace-scoped candidate: ${whoOf ms}, import marker ${builtins.toJSON (importMarker ms)}";

  # --- 19. PersistentVolumeClaim references ---

  lib-reference-checks-claim-missing = expectFailures [ "mounts PersistentVolumeClaim 'data'" ] {
    ms = [ (podDeployment "app" { pod.volumes = [ claimVolume ]; }) ];
  };

  lib-reference-checks-claim-in-build = expectClean {
    ms = [
      (podDeployment "app" { pod.volumes = [ claimVolume ]; })
      (claim "data" { })
    ];
  };

  lib-reference-checks-claim-untracked = expectClean {
    ms = [ (podDeployment "app" { pod.volumes = [ claimVolume ]; }) ];
    externalNames."a/data" = true;
  };

  # --- 20. StorageClass references ---

  lib-reference-checks-class-missing =
    expectFailures
      [
        "PersistentVolumeClaim a/data requests StorageClass 'fast'"
        "StatefulSet a/db volumeClaimTemplate 'data' requests StorageClass 'fast'"
      ]
      {
        ms = [
          (claim "data" { storageClassName = "fast"; })
          (mf "StatefulSet" "a" "db" {
            apiVersion = "apps/v1";
            spec = {
              selector.matchLabels.app = "db";
              template.metadata.labels.app = "db";
              volumeClaimTemplates = [
                {
                  metadata.name = "data";
                  spec.storageClassName = "fast";
                }
              ];
            };
          })
        ];
      };

  lib-reference-checks-class-in-build = expectClean {
    ms = [
      (claim "data" { storageClassName = "fast"; })
      (storageClass "fast" { })
    ];
  };

  # A cluster-scoped import marker answers claims in every namespace.
  lib-reference-checks-class-marker-in-another-namespace = expectClean {
    ms = [
      (claim "data" { storageClassName = "fast"; })
      (importMarkerOf "kube-system" "platform-storage" "StorageClass" "fast" { })
    ];
  };

  # A namespaced kind's marker does not: a Service marker in kube-system
  # is no witness for namespace a (control for the case above).
  lib-reference-checks-namespaced-marker-stays-in-its-namespace =
    expectFailures [ "references Service 'db'" ]
      {
        ms = [
          (importMarkerOf "kube-system" "service-ref-x-db" "Service" "db" { })
          (mf "Ingress" "a" "ing" {
            apiVersion = "networking.k8s.io/v1";
            spec.defaultBackend.service.name = "db";
          })
        ];
      };

  lib-reference-checks-class-static-volume = expectClean {
    ms = [
      (claim "data" { storageClassName = "manual"; })
      (mf "PersistentVolume" null "pv-data" { spec.storageClassName = "manual"; })
    ];
  };

  lib-reference-checks-class-empty-is-unchecked = expectClean {
    ms = [ (claim "data" { storageClassName = ""; }) ];
  };

  # A generic ephemeral volume's claim template is a claim too.
  lib-reference-checks-class-ephemeral-volume =
    let
      app = podDeployment "app" {
        pod.volumes = [
          {
            name = "scratch";
            ephemeral.volumeClaimTemplate.spec.storageClassName = "fast";
          }
        ];
      };
    in
    expectFailures [ "Deployment a/app ephemeral volume 'scratch' requests StorageClass 'fast'" ] {
      ms = [ app ];
    }
    && expectClean {
      ms = [
        app
        (storageClass "fast" { })
      ];
    };

  # --- 21. Custom resources depend on a declaration of their kind ---

  lib-reference-checks-cr-without-declaration =
    expectFailures [ "Widget a/w (example.com/v1, instance a/app) has no CustomResourceDefinition" ]
      {
        ms = [ (widget "v1" [ ]) ];
        owners.${idOf (widget "v1" [ ])} = "a/app";
      };

  # Both instances are named when the CR does not depend on the CRD.
  lib-reference-checks-cr-outside-closure =
    let
      crd = widgetCrd "Namespaced" [ { name = "v1"; } ];
    in
    expectFailures
      [
        "Widget a/w (instance a/app) does not depend on CustomResourceDefinition widgets.example.com (instance op/operator)"
      ]
      {
        ms = [
          crd
          (widget "v1" [ ])
        ];
        owners = {
          ${idOf (widget "v1" [ ])} = "a/app";
          ${idOf crd} = "op/operator";
        };
      };

  # A CR built beside its own CRD declaration, without the edge, is told to
  # use that declaration rather than to depend on its own instance.
  lib-reference-checks-cr-same-instance-declaration =
    let
      crd = widgetCrd "Namespaced" [ { name = "v1"; } ];
    in
    expectFailures
      [
        "Widget a/w (instance a/app) does not depend on CustomResourceDefinition widgets.example.com, which the same instance declares, so the deploy can apply it before the CRD is served. Build it with scope.mkCR from that declaration, or list the declaration in its requires."
      ]
      {
        ms = [
          crd
          (widget "v1" [ ])
        ];
        owners = {
          ${idOf (widget "v1" [ ])} = "a/app";
          ${idOf crd} = "a/app";
        };
      };

  # A CRD ref is named once, with its provider in one parenthetical.
  lib-reference-checks-cr-outside-closure-on-ref =
    expectFailures
      [
        "Widget a/w (instance a/app) does not depend on the CRD ref crd-ref-op-widgets-example-com for widgets.example.com (instance a/op), which declares its kind"
      ]
      {
        ms = [
          (widgetRefMarker { })
          (widget "v1" [ ])
        ];
        owners = {
          ${idOf (widget "v1" [ ])} = "a/app";
          ${idOf (widgetRefMarker { })} = "a/op";
        };
      };

  lib-reference-checks-cr-depends-on-crd = expectClean {
    ms = [
      (widgetCrd "Namespaced" [ { name = "v1"; } ])
      (widget "v1" [ (widgetCrd "Namespaced" [ { name = "v1"; } ]) ])
    ];
  };

  # The declaration may be several dependencies away.
  lib-reference-checks-cr-transitive =
    let
      crd = widgetCrd "Namespaced" [ { name = "v1"; } ];
      middle = mf "ConfigMap" "a" "middle" (dependsOn [ crd ]);
    in
    expectClean {
      ms = [
        crd
        middle
        (widget "v1" [ middle ])
      ];
    };

  lib-reference-checks-cr-on-ref = expectClean {
    ms = [
      (widgetRefMarker { })
      (widget "v1" [ (widgetRefMarker { }) ])
    ];
  };

  lib-reference-checks-cr-on-apiservice =
    let
      apiService = mf "APIService" null "v1.example.com" {
        apiVersion = "apiregistration.k8s.io/v1";
        spec = {
          group = "example.com";
          version = "v1";
        };
      };
      marker = importMarkerOf "a" "metrics-api" "APIService" "v1.example.com" { };
    in
    expectClean {
      ms = [
        apiService
        (widget "v1" [ apiService ])
      ];
    }
    && expectClean {
      ms = [
        marker
        (widget "v1" [ marker ])
      ];
    };

  lib-reference-checks-cr-unserved-on-crd =
    let
      crd = widgetCrd "Namespaced" [
        { name = "v1"; }
        {
          name = "v1beta1";
          served = false;
        }
      ];
    in
    expectFailures
      [
        "Widget a/w uses example.com/v1beta1, but CustomResourceDefinition widgets.example.com serves v1 for example.com/Widget"
      ]
      {
        ms = [
          crd
          (widget "v1beta1" [ crd ])
        ];
      };

  lib-reference-checks-cr-unserved-on-ref =
    let
      listed = widgetRefMarker { ${kixKeys.crdServedVersions} = "v1,v1beta1"; };
    in
    expectFailures
      [
        "uses example.com/v1beta1, but the CRD ref crd-ref-op-widgets-example-com for widgets.example.com"
      ]
      {
        ms = [
          (widgetRefMarker { })
          (widget "v1beta1" [ (widgetRefMarker { }) ])
        ];
      }
    && expectClean {
      ms = [
        listed
        (widget "v1beta1" [ listed ])
      ];
    };

  # Built-in groups need no declaration.
  lib-reference-checks-cr-builtin-group = expectClean {
    ms = [
      (mf "PodDisruptionBudget" "a" "pdb" { apiVersion = "policy/v1"; })
      (mf "Lease" "a" "lease" { apiVersion = "coordination.k8s.io/v1"; })
    ];
  };

  # --- 18. a ref declares the scope of its kind ---

  lib-reference-checks-scope-from-ref =
    let
      clusterRef = widgetRefMarker { ${kixKeys.crdScope} = "Cluster"; };
      unnamespaced =
        ref:
        mf "Widget" null "w" (lib.recursiveUpdate { apiVersion = "example.com/v1"; } (dependsOn [ ref ]));
    in
    expectFailures [ "Widget w (example.com/v1) is a namespaced kind" ] {
      ms = [
        (widgetRefMarker { })
        (unnamespaced (widgetRefMarker { }))
      ];
    }
    && expectClean {
      ms = [
        clusterRef
        (unnamespaced clusterRef)
      ];
    };

  # --- 22. Named Secret and ConfigMap keys ---

  lib-reference-checks-key-env =
    expectFailures
      [ "Deployment a/app reads key 'c' of Secret 's' (env C of container c), which declares keys a, b" ]
      {
        ms = [
          (builtSecret "s" [
            "a"
            "b"
          ])
          (podDeployment "app" {
            container.env = [
              (secretEnv "C" "s" "c")
              (secretEnv "A" "s" "a")
            ];
          })
        ];
      };

  lib-reference-checks-key-subpath =
    expectFailures [ "mounts subPath 'c/file' of Secret 's' at /etc/c" ]
      {
        ms = [
          (builtSecret "s" [ "a" ])
          (podDeployment "app" {
            container.volumeMounts = [
              {
                name = "s";
                mountPath = "/etc/c";
                subPath = "c/file";
              }
              {
                name = "s";
                mountPath = "/etc/a";
                subPath = "a";
              }
            ];
            pod.volumes = [ (secretVolume "s" { }) ];
          })
        ];
      };

  lib-reference-checks-key-configmap-item =
    expectFailures [ "reads key 'y' of ConfigMap 'cm' (volume cm items), which declares keys x" ]
      {
        ms = [
          (mf "ConfigMap" "a" "cm" { data.x = "1"; })
          (podDeployment "app" {
            pod.volumes = [
              {
                name = "cm";
                configMap = {
                  name = "cm";
                  items = [
                    {
                      key = "y";
                      path = "y";
                    }
                    {
                      key = "x";
                      path = "x";
                    }
                  ];
                };
              }
            ];
          })
        ];
      };

  # A chart may render `data: null`; the ConfigMap then declares no keys.
  lib-reference-checks-key-configmap-null-data =
    expectFailures [ "reads key 'x' of ConfigMap 'cm' (env X of container c), which declares no keys" ]
      {
        ms = [
          (mf "ConfigMap" "a" "cm" { data = null; })
          (podDeployment "app" {
            container.env = [
              {
                name = "X";
                valueFrom.configMapKeyRef = {
                  name = "cm";
                  key = "x";
                };
              }
            ];
          })
        ];
      };

  lib-reference-checks-key-opaque-ref =
    expectFailures
      [
        "reads key 'token' of Secret 'ext' (env T of container c), whose scope.mkSecretRef declares no keys"
      ]
      {
        ms = [
          (importMarkerOf "a" "secret-ref-app-ext" "Secret" "ext" { })
          (podDeployment "app" { container.env = [ (secretEnv "T" "ext" "token") ]; })
        ];
      };

  # A ref that lists its keys is checked like a built Secret.
  lib-reference-checks-key-listed-ref = expectFailures [ "reads key 'other' of Secret 'ext'" ] {
    ms = [
      (importMarkerOf "a" "secret-ref-app-ext" "Secret" "ext" { ${kixKeys.importSecretKeys} = "token"; })
      (podDeployment "app" {
        container.env = [
          (secretEnv "T" "ext" "token")
          (secretEnv "O" "ext" "other")
        ];
      })
    ];
  };

  # Whole use reads no named key: envFrom, and a volume without items.
  lib-reference-checks-key-whole-use = expectClean {
    ms = [
      (importMarkerOf "a" "secret-ref-app-ext" "Secret" "ext" { })
      (podDeployment "app" {
        container.envFrom = [ { secretRef.name = "ext"; } ];
        container.volumeMounts = [
          {
            name = "ext";
            mountPath = "/ext";
          }
        ];
        pod.volumes = [ (secretVolume "ext" { }) ];
      })
    ];
  };

  lib-reference-checks-key-optional = expectClean {
    ms = [
      (builtSecret "s" [ "a" ])
      (podDeployment "app" {
        container.env = [
          {
            name = "C";
            valueFrom.secretKeyRef = {
              name = "s";
              key = "c";
              optional = true;
            };
          }
        ];
        pod.volumes = [
          (secretVolume "s" {
            optional = true;
            items = [
              {
                key = "c";
                path = "c";
              }
            ];
          })
        ];
      })
    ];
  };

  # A ConfigMap that cedes its data to another manager may gain keys at
  # runtime.
  lib-reference-checks-key-ceded-data = expectClean {
    ms = [
      (mf "ConfigMap" "a" "cm" {
        metadata.annotations.${kixKeys.cedeFields} = "data";
        data.x = "1";
      })
      (podDeployment "app" {
        container.env = [
          {
            name = "Y";
            valueFrom.configMapKeyRef = {
              name = "cm";
              key = "y";
            };
          }
        ];
      })
    ];
  };

  # The ingress-nginx admission shape: a Deployment mounts a Secret a Job
  # creates, named through kix.untrackedRef { by = self.job; }, whole and by
  # item. No Secret is in the build, and the build passes.
  lib-reference-checks-key-controller-created-secret =
    let
      package = {
        meta.version = "test";
        build =
          {
            self,
            scope,
            kix,
            ...
          }:
          let
            certs = kix.untrackedRef {
              kind = "Secret";
              name = "x-admission";
              by = self.job;
            };
          in
          {
            job = scope.mkJob {
              name = "x-admission-create";
              spec.template = {
                metadata.labels.app = "x-admission-create";
                spec = {
                  restartPolicy = "OnFailure";
                  containers = [
                    {
                      name = "create";
                      image = "example/certgen:1";
                      resources = {
                        requests = {
                          cpu = "10m";
                          memory = "16Mi";
                        };
                        limits.memory = "32Mi";
                      };
                    }
                  ];
                };
              };
            };
            deployment = scope.mkDeployment {
              name = "x";
              spec = {
                replicas = 1;
                selector.matchLabels = scope.selectorLabels;
                template = {
                  metadata.labels = scope.selectorLabels;
                  spec = {
                    containers = [
                      {
                        name = "x";
                        image = "example/x:1";
                        resources = {
                          requests = {
                            cpu = "10m";
                            memory = "16Mi";
                          };
                          limits.memory = "32Mi";
                        };
                        volumeMounts = [
                          {
                            name = "whole";
                            mountPath = "/whole";
                          }
                          {
                            name = "items";
                            mountPath = "/items";
                          }
                        ];
                      }
                    ];
                    volumes = [
                      {
                        name = "whole";
                        secret.secretName = certs;
                      }
                      {
                        name = "items";
                        secret = {
                          secretName = certs;
                          items = [
                            {
                              key = "cert";
                              path = "tls.crt";
                            }
                            {
                              key = "key";
                              path = "tls.key";
                            }
                          ];
                        };
                      }
                    ];
                  };
                };
              };
            };
            root = self.deployment;
          };
      };
      ms = manifests (withApp {
        appns.x.package = package;
      });
    in
    (!(hasName "x-admission" (ofKind "Secret" ms)) && hasName "x" (ofKind "Deployment" ms))
    || throw "controller-created Secret: ${builtins.toJSON (map (m: m.metadata.name) ms)}";

  # --- 23. One default per cluster ---

  lib-reference-checks-two-defaults =
    let
      pc =
        name:
        mf "PriorityClass" null name {
          apiVersion = "scheduling.k8s.io/v1";
          value = 1000;
          globalDefault = true;
        };
      ic =
        name:
        mf "IngressClass" null name {
          apiVersion = "networking.k8s.io/v1";
          metadata.annotations."ingressclass.kubernetes.io/is-default-class" = "true";
        };
      sc = name: storageClass name { "storageclass.kubernetes.io/is-default-class" = "true"; };
      ms = [
        (pc "p1")
        (pc "p2")
        (sc "s1")
        (sc "s2")
        (ic "i1")
        (ic "i2")
      ];
    in
    expectFailures
      [
        "PriorityClasses p1 (instance x/one), p2 (instance y/two) all set globalDefault: true"
        "StorageClasses s1 (instance x/one), s2 (instance y/two) are all annotated as the default"
        "IngressClasses i1 (instance x/one), i2 (instance y/two) are all annotated as the default"
      ]
      {
        inherit ms;
        owners = lib.listToAttrs (
          lib.imap0 (i: m: lib.nameValuePair (idOf m) (if lib.mod i 2 == 0 then "x/one" else "y/two")) ms
        );
      };

  # Kubernetes treats the beta StorageClass annotation as a default too.
  lib-reference-checks-two-defaults-beta =
    expectFailures [ "StorageClasses s1, s2 are all annotated as the default" ]
      {
        ms = [
          (storageClass "s1" { "storageclass.beta.kubernetes.io/is-default-class" = "true"; })
          (storageClass "s2" { "storageclass.kubernetes.io/is-default-class" = "true"; })
        ];
      };

  # One default beside a plain class is fine.
  lib-reference-checks-one-default = expectClean {
    ms = [
      (storageClass "s1" { "storageclass.kubernetes.io/is-default-class" = "true"; })
      (storageClass "s2" { })
      (mf "PriorityClass" null "p1" {
        apiVersion = "scheduling.k8s.io/v1";
        value = 1000;
        globalDefault = true;
      })
      (mf "PriorityClass" null "p2" {
        apiVersion = "scheduling.k8s.io/v1";
        value = 10;
      })
    ];
  };

  # Two priority-class instances with globalDefault fail the cluster build.
  # A failing build cannot be read, so the message is checked on the
  # PriorityClass manifests of two builds that each hold one instance.
  lib-reference-checks-priority-class-instances =
    let
      instance = name: value: globalDefault: {
        instances.infra.${name} = {
          package = import ../../../packages/priority-class;
          config = { inherit value globalDefault; };
        };
      };
      withDefaults =
        second:
        mkCluster [
          baseInstances
          (instance "high" 1000 true)
          (instance "low" 10 second)
        ];
      priorityClassOf =
        name: value:
        byName name (
          ofKind "PriorityClass" (
            manifests (mkCluster [
              baseInstances
              (instance name value true)
            ])
          )
        );
      high = priorityClassOf "high" 1000;
      low = priorityClassOf "low" 10;
    in
    evalFails (withDefaults true)
    && !(evalFails (withDefaults false))
    &&
      expectFailures
        [
          "PriorityClasses high (instance infra/high), low (instance infra/low) all set globalDefault: true. The apiserver accepts one; set it on one class."
        ]
        {
          ms = [
            high
            low
          ];
          owners = {
            ${idOf high} = "infra/high";
            ${idOf low} = "infra/low";
          };
        };

  # --- chart custom resources depend on the chart's CRD ---

  lib-reference-checks-chart-cr-depends-on-chart-crd =
    let
      crd = {
        apiVersion = "apiextensions.k8s.io/v1";
        kind = "CustomResourceDefinition";
        metadata.name = "widgets.example.com";
        spec = {
          group = "example.com";
          names.kind = "Widget";
        };
      };
      own = {
        apiVersion = "example.com/v1";
        kind = "Widget";
        metadata.name = "w";
      };
      foreign = {
        apiVersion = "monitoring.coreos.com/v1";
        kind = "ServiceMonitor";
        metadata.name = "sm";
      };
      edges = builtins.filter (e: e.type == "instance-of") (
        helmDag.inferEdges [
          crd
          own
          foreign
        ]
      );
    in
    (
      builtins.length edges == 1
      && (builtins.head edges).from.metadata.name == "w"
      && (builtins.head edges).to.metadata.name == "widgets.example.com"
    )
    || throw "instance-of edges: ${
      builtins.toJSON (map (e: "${e.from.metadata.name}->${e.to.metadata.name}") edges)
    }";

  # --- kix.expose's HTTPRoute references its CRD ---

  # Two exposures in one instance build the same CRD ref; two instances
  # get a marker each, and each route depends on its own.
  lib-reference-checks-expose-route-crd =
    let
      cluster = mkCluster [
        (
          { ref, ... }:
          {
            cluster.domain = "example.test";
            instances.gwns.gateway = {
              package = import ../../../packages/envoy-gateway;
              config.listeners = [
                {
                  name = "http";
                  port = 80;
                  protocol = "HTTP";
                  allowedRoutes.namespaces.from = "All";
                }
              ];
            };
            instances.appns.web = {
              package = webPackage;
              deps.gateway = ref.gwns.gateway;
            };
            instances.appns.web2 = {
              package = webPackage;
              deps.gateway = ref.gwns.gateway;
            };
          }
        )
      ];
      raw = cluster.instances.appns.web.raw;
      # depends-on names a resource by the store hash of its outPath.
      markerHash =
        instance:
        builtins.substring 11 32 (
          builtins.unsafeDiscardStringContext (
            toString cluster.instances.appns.${instance}.raw.routeCrd.outPath
          )
        );
      ms = manifests cluster;
      markers = builtins.filter (
        m:
        m.kind == "PackageInstance" && lib.hasSuffix "-httproutes-gateway-networking-k8s-io" m.metadata.name
      ) ms;
      # mkCR lists the CRD ref under `requires:`.
      routeDeps =
        name:
        map (lib.removePrefix "requires:") (
          lib.splitString "," (
            (annotationsOf (byName name (ofKind "HTTPRoute" ms))).${kixKeys.dependsOn} or ""
          )
        );
    in
    (
      raw.routeCrd.outPath == raw.adminRouteCrd.outPath
      &&
        map (m: m.metadata.name) markers == [
          "crd-ref-web-httproutes-gateway-networking-k8s-io"
          "crd-ref-web2-httproutes-gateway-networking-k8s-io"
        ]
      && builtins.elem (markerHash "web2") (routeDeps "web2")
      && !(builtins.elem (markerHash "web") (routeDeps "web2"))
      && builtins.elem (markerHash "web") (routeDeps "web")
    )
    || throw "HTTPRoute CRD refs: ${
      builtins.toJSON (map (m: m.metadata.name) markers)
    }, web2 route depends on ${builtins.toJSON (routeDeps "web2")}";

  # --- mkSecret ---

  # A declared key needs a value unless a SOPS source fills it or
  # Kubernetes does (a service-account-token Secret). tryEval cannot read a
  # throw's message, so each refused case has a passing twin that differs
  # only in the missing value.
  lib-reference-checks-mksecret-values =
    let
      build =
        args:
        mkCluster [
          baseInstances
          {
            instances.appns.s.package = {
              meta.version = "test";
              build =
                { self, scope, ... }:
                {
                  secret = scope.mkSecret ({ name = "s"; } // args);
                  root = self.secret;
                };
            };
          }
        ];
      builds = args: !(evalFails (build args));
    in
    evalFails (build {
      keys = [ "a" ];
    })
    && builds {
      keys = [ "a" ];
      stringData.a = "1";
    }
    && evalFails (build {
      keys = [
        "a"
        "b"
      ];
      stringData.a = "1";
    })
    && builds {
      keys = [
        "a"
        "b"
      ];
      stringData = {
        a = "1";
        b = "2";
      };
    }
    && builds { stringData.a = "1"; }
    && builds {
      keys = [ "a" ];
      extra.data.a = "MQ==";
    }
    && builds {
      keys = [ "token" ];
      type = "kubernetes.io/service-account-token";
    }
    && builds {
      keys = [ "a" ];
      source = ./lib-reference-checks.nix;
    };

  # cloudflared refuses a missing token itself, before scope.mkSecret sees
  # the valueless key. The stub mkSecret never throws, so the failure is
  # the package's own check.
  lib-reference-checks-cloudflared-token-refused-before-secret =
    let
      stubScope = {
        instanceName = "tunnel";
        namespaceName = "edge";
        mkSecret = args: {
          inherit args;
          out.mkEnv = _: [ ];
        };
        mkDeployment = d: d;
        selectorLabels = { };
      };
      pkg = import ../../../packages/cloudflared {
        scope = stubScope;
        inherit lib;
        kix = kixlib;
        availability = "none";
      };
      tokenOf =
        config:
        (pkg.build {
          self = { };
          scope = stubScope;
          kix = kixlib;
          inherit config;
        }).tunnelToken;
      builds = config: (builtins.tryEval (builtins.deepSeq (tokenOf config) true)).success;
    in
    (
      !(builds {
        token = null;
        tokenSource = null;
      })
      && builds {
        token = "t";
        tokenSource = null;
      }
    )
    || throw "cloudflared: the token check did not run before scope.mkSecret";
}
