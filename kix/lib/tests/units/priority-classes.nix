# Tests for the priority-class package as a dependency: a consumer that takes
# `priorityClass ? null` gets the class's name and an ordering dependency on
# it when wired, and nothing when not.
# Loaded by ../default.nix with the other files in this directory.

{
  lib,
  k8s,
  kixKeys,
  mkCluster,
  manifests,
  ofKind,
  ...
}:

let
  priorityClassPackage = import ../../../packages/priority-class;

  consumer =
    { scope, lib }:
    {
      meta = {
        description = "Deployment that takes an optional PriorityClass";
        owner = "test";
      };
      build =
        {
          self,
          priorityClass ? null,
          ...
        }:
        {
          deployment = scope.mkDeployment {
            name = scope.instanceName;
            spec = {
              selector.matchLabels = scope.selectorLabels;
              template.spec = {
                containers = [
                  {
                    name = "c";
                    image = "nginx:1.27@sha256:0000000000000000000000000000000000000000000000000000000000000000";
                  }
                ];
              }
              // lib.optionalAttrs (priorityClass != null) {
                priorityClassName = priorityClass.out.name;
              };
            };
          };
          root = self.deployment;
        };
    };

  clusterWith =
    wire:
    mkCluster [
      (
        { ref, ... }:
        {
          namespaces.apps = { };
          namespaces.platform = { };
          instances.platform.high = {
            package = priorityClassPackage;
            config.value = 10;
          };
          instances.apps.web = {
            package = consumer;
          }
          // lib.optionalAttrs wire { deps.priorityClass = ref.platform.high; };
        }
      )
    ];

  deploymentOf = cluster: builtins.head (ofKind "Deployment" (manifests cluster));
  dependsOn = m: (m.metadata.annotations or { }).${kixKeys.dependsOn} or "";
  classHash = cluster: k8s.extractStoreHash cluster.instances.platform.high.raw.priorityClass.outPath;
in
{
  priority-classes-dep-edge =
    let
      cluster = clusterWith true;
      d = deploymentOf cluster;
    in
    (d.spec.template.spec.priorityClassName or null) == "high"
    && lib.hasInfix (classHash cluster) (dependsOn d)
    || throw "wired: ${
      builtins.toJSON {
        inherit (d.spec.template) spec;
        ann = dependsOn d;
      }
    }";

  # The consumer's argument `priorityClass` is not an instance name or alias
  # here, so it stays null. An instance or alias named `priorityClass` would
  # bind it.
  priority-classes-unwired-dep-unbound =
    let
      cluster = clusterWith false;
      d = deploymentOf cluster;
    in
    !(d.spec.template.spec ? priorityClassName) && !(lib.hasInfix (classHash cluster) (dependsOn d))
    || throw "unwired: ${
      builtins.toJSON {
        inherit (d.spec.template) spec;
        ann = dependsOn d;
      }
    }";
}
