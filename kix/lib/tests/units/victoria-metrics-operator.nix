# Tests for kix/packages/victoria-metrics-operator: the readiness rules its
# custom resources carry, and the options it removed.

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
  readinessOf = m: builtins.fromJSON ((m.metadata.annotations or { }).${kixKeys.readiness} or "null");
  ms = manifests (mkCluster [
    {
      instances.monitoring.vm-operator.package = import ../../../packages/victoria-metrics-operator;
      instances.monitoring.vm-cluster.package = import ../../../packages/victoria-metrics-cluster;
    }
  ]);
in
{
  # The operator writes updateStatus on a VMServiceScrape only from a VMAgent
  # or VMSingle that selects it, so the operator's own scrape is ready unless
  # a consumer rejects it. The VMCluster, which the operator reconciles
  # itself, must report operational.
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
      package = import ../../../packages/victoria-metrics-operator;
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
      placement = "Set the operator pod's placement with the instance's partsOverlays.";
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
        nodeSelector = [ "nodeSelector was removed. ${placement}" ];
        tolerations = [ "tolerations was removed. ${placement}" ];
        affinity = [ "affinity was removed. ${placement}" ];
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
}
