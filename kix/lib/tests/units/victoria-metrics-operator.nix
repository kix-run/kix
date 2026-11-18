# Tests for kix/packages/stable/victoria-metrics-operator: the readiness rules its
# custom resources carry, the options it removed, and the Kubernetes range
# it declares.

{
  lib,
  eval,
  kixlib,
  kixKeys,
  mkCluster,
  manifests,
  ofKind,
  byName,
  evalFails,
  ...
}:

let
  readinessOf = m: builtins.fromJSON (m.metadata.annotations.${kixKeys.readiness} or "null");
  ms = manifests (mkCluster [
    {
      instances.monitoring.vm-operator.package = import ../../../packages/stable/victoria-metrics-operator;
      instances.monitoring.vm-cluster.package = import ../../../packages/stable/victoria-metrics-cluster;
    }
  ]);
in
{
  # A VMServiceScrape is ready unless its updateStatus reads `failed`, so
  # the operator's own scrape is ready with no VMAgent selecting it. The
  # VMCluster, which the operator reconciles itself, must report
  # operational.
  victoria-metrics-operator-config-kinds-ready-without-consumer =
    let
      scrapes = ofKind "VMServiceScrape" ms;
      clusters = ofKind "VMCluster" ms;
    in
    (
      scrapes != [ ]
      && clusters != [ ]
      && builtins.all (
        m:
        readinessOf m == {
          path = "/status/updateStatus";
          notEquals = "failed";
        }
      ) scrapes
      && builtins.all (
        m:
        readinessOf m == {
          path = "/status/updateStatus";
          equals = "operational";
        }
      ) clusters
    )
    || throw "VM readiness: scrapes ${builtins.toJSON (map readinessOf scrapes)}, clusters ${builtins.toJSON (map readinessOf clusters)}";

  # Each removed option fails with its replacement, and extraArgs carries
  # the log level.
  victoria-metrics-operator-removed-options =
    let
      package = import ../../../packages/stable/victoria-metrics-operator;
      attrs = package {
        scope = {
          instanceName = "vm-operator";
          namespaceName = "monitoring";
        };
        inherit lib;
        kix = kixlib;
        availability = "none";
      };
      failedMessages =
        config:
        map (a: a.message) (
          builtins.filter (a: !a.assertion) (
            attrs.assertions {
              config = eval.evaluateInstanceConfig {
                packageOptions = attrs.options;
                instCfg.config.imports = [ config ];
                namespaceName = "monitoring";
                instanceName = "vm-operator";
              };
              deps = { };
            }
          )
        );
      withConfig =
        config:
        mkCluster [
          {
            instances.monitoring.vm-operator = {
              package = package;
              inherit config;
            };
          }
        ];
      got = {
        nodeSelector = failedMessages { nodeSelector.disk = "ssd"; };
        tolerations = failedMessages { tolerations = [ { operator = "Exists"; } ]; };
        affinity = failedMessages { affinity.nodeAffinity = { }; };
        logLevel = failedMessages { logLevel = "debug"; };
        none = failedMessages { };
      };
      placement = option: "Set extraSpec.template.spec.${option} instead.";
      deployment = byName "vm-operator" (
        ofKind "Deployment" (
          manifests (withConfig {
            extraArgs = [ "--zap-log-level=debug" ];
          })
        )
      );
      args = (builtins.head deployment.spec.template.spec.containers).args;
    in
    (
      got == {
        nodeSelector = [ "nodeSelector was removed. ${placement "nodeSelector"}" ];
        tolerations = [ "tolerations was removed. ${placement "tolerations"}" ];
        affinity = [ "affinity was removed. ${placement "affinity"}" ];
        logLevel = [ "logLevel was removed. Pass --zap-log-level=<level> in extraArgs." ];
        none = [ ];
      }
      && evalFails (withConfig {
        logLevel = "debug";
      })
      && builtins.elem "--zap-log-level=debug" args
      && !(builtins.elem "--zap-log-level=info" args)
    )
    || throw "VM operator removed options: ${builtins.toJSON { inherit got args; }}";

  # A cluster that declares a Kubernetes version outside 1.25 to 1.37 is
  # refused with the change record's id. The meta check is called directly,
  # because a failed meta assertion fails the cluster before its messages
  # can be read.
  victoria-metrics-operator-k8s-range =
    let
      metaLib = import ../../meta.nix { inherit lib; };
      meta =
        (import ../../../packages/stable/victoria-metrics-operator {
          inherit lib;
          kix = kixlib;
          scope = {
            instanceName = "vm-operator";
            namespaceName = "monitoring";
          };
          availability = "none";
        }).meta;
      refusals =
        k8sVersion:
        map (a: a.message) (
          builtins.filter (a: !a.assertion) (
            (metaLib.checkMetaStatic {
              packageMeta = meta;
              instanceName = "vm-operator";
              namespaceName = "monitoring";
              clusterConfig = { inherit k8sVersion; };
              resolvedDepMeta = { };
              resolutionIndex.byKey = { };
            }).assertions
          )
        );
      refused = v: builtins.any (lib.hasInfix "[K1442]") (refusals v);
      got = lib.genAttrs [ "1.24" "1.25" "1.37" "1.38" ] refusals;
    in
    (
      refused "1.24"
      && refused "1.38"
      && refusals "1.25" == [ ]
      && refusals "1.37" == [ ]
      && refusals null == [ ]
    )
    || throw "victoria-metrics-operator-k8s-range: ${builtins.toJSON got}";
}
