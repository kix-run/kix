# Tests for the priority-class package: the rendered PriorityClass, the
# refusal of a `system-` instance name, and its use as a dependency (a
# consumer that takes `priorityClass ? null` gets the class's name and an
# ordering dependency on it when wired, and nothing when not).
# Loaded by ../default.nix with the other files in this directory.

{
  lib,
  k8s,
  kixKeys,
  mkCluster,
  manifests,
  ofKind,
  evalFails,
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

  # One priority-class instance `x/<name>` with the given config.
  classCluster =
    name: config:
    mkCluster [
      {
        namespaces.x = { };
        instances.x.${name} = {
          package = priorityClassPackage;
          inherit config;
        };
      }
    ];
  classOf = cluster: builtins.head (ofKind "PriorityClass" (manifests cluster));

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

  # globalDefault and description are omitempty in the API, so they are left
  # out when unset; the apiserver defaults preemptionPolicy, so it is always
  # rendered.
  priority-classes-renders-api-shape =
    let
      plain = classOf (classCluster "plain" { value = 10; });
      full = classOf (
        classCluster "full" {
          value = -5;
          description = "batch";
          globalDefault = true;
          preemptionPolicy = "Never";
        }
      );
    in
    (
      plain.metadata.name == "plain"
      && plain.value == 10
      && plain.preemptionPolicy == "PreemptLowerPriority"
      && !(plain ? globalDefault)
      && !(plain ? description)
      && full.value == -5
      && full.description == "batch"
      && full.globalDefault
      && full.preemptionPolicy == "Never"
    )
    || throw "rendered: ${builtins.toJSON { inherit plain full; }}";

  # An empty description would render `description: ""`, which the live
  # object lacks; the option type refuses it.
  priority-classes-empty-description-refused =
    evalFails (
      classCluster "plain" {
        value = 10;
        description = "";
      }
    )
    || throw "description = \"\" evaluated";

  # The instance name becomes the PriorityClass name, and Kubernetes reserves
  # the `system-` prefix. A name that only contains `system` still builds.
  priority-classes-system-prefix-refused =
    (
      evalFails (classCluster "system-x" { value = 10; })
      && !(evalFails (classCluster "x-system" { value = 10; }))
    )
    || throw "system-x built, or x-system failed";
}
