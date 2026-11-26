# Tests for `cluster.capabilities.criticalPriorityNamespaces`: a workload
# that uses a built-in critical PriorityClass fails evaluation outside the
# namespaces the platform admits it in.

{
  lib,
  mkCluster,
  manifests,
  ofKind,
  hasName,
  evalFails,
  ...
}:

let
  flavor = name: import (../../flavors + "/${name}.nix");
  helpers = import ../caught.nix { inherit lib; };

  # Return a package with one Deployment whose pods use `class`.
  criticalPackage = class: {
    meta.version = "test";
    build =
      { self, scope, ... }:
      {
        deploy = scope.mkDeployment {
          name = "critical";
          spec = {
            selector.matchLabels = scope.selectorLabels;
            template = {
              metadata.labels = scope.selectorLabels;
              spec = {
                containers = [
                  {
                    name = "main";
                    image = "example/critical:1";
                    resources = {
                      requests = {
                        cpu = "10m";
                        memory = "16Mi";
                      };
                      limits.memory = "64Mi";
                    };
                  }
                ];
              }
              // lib.optionalAttrs (class != null) { priorityClassName = class; };
            };
          };
        };
        root = self.deploy;
      };
  };

  # Return a cluster on flavour `flavorName` with the package in `ns`.
  clusterWith =
    {
      flavorName ? "gke",
      ns,
      class ? "system-node-critical",
      extra ? { },
    }:
    mkCluster [
      (flavor flavorName)
      { instances.${ns}.critical.package = criticalPackage class; }
      extra
    ];

  deploys = cluster: hasName "critical" (ofKind "Deployment" (manifests cluster));

  # Run the check alone with `allowed` as the capability, for its text.
  checkIn =
    allowed: ns:
    ((helpers.loadCaught ../../scope/validators.nix { inherit lib; }).mkValidators {
      instanceName = "critical";
      namespaceName = ns;
      capabilities.criticalPriorityNamespaces = allowed;
    }).checkCriticalPriority
      { priorityClassName = "system-cluster-critical"; };
in
{
  # On GKE, a critical class outside kube-system fails evaluation.
  critical-priority-gke-refuses-other-namespace = evalFails (clusterWith {
    ns = "apps";
  });

  # On GKE, the same workload in kube-system evaluates.
  critical-priority-gke-admits-kube-system = deploys (clusterWith {
    ns = "kube-system";
  });

  # A class that is not built in is not limited.
  critical-priority-gke-ignores-other-classes = deploys (clusterWith {
    ns = "apps";
    class = null;
  });

  # A cluster definition can add a namespace that holds its own quota.
  critical-priority-cluster-adds-namespace = deploys (clusterWith {
    ns = "apps";
    extra.cluster.capabilities.criticalPriorityNamespaces = [
      "kube-system"
      "apps"
    ];
  });

  # A flavour that leaves the capability unset does not restrict the class.
  critical-priority-unset-admits-anywhere = deploys (clusterWith {
    flavorName = "kind";
    ns = "apps";
  });

  # The refusal names the class, the namespace, and where the class runs.
  critical-priority-message-names-namespaces =
    let
      result = checkIn [ "kube-system" ] "apps";
    in
    (
      result ? thrown
      && lib.hasInfix ''Pods in namespace "apps" set priorityClassName "system-cluster-critical"'' result.thrown
      && lib.hasInfix ''allows only in "kube-system"'' result.thrown
    )
    || throw "unexpected check result: ${builtins.toJSON result}";

  # The fix asks for a quota that names both classes, because GKE admits
  # each class only through a quota whose scope names it.
  critical-priority-fix-asks-for-both-classes =
    let
      result = checkIn [ "kube-system" ] "apps";
    in
    (
      result ? thrown
      && lib.hasInfix ''includes both "system-node-critical" and "system-cluster-critical"'' result.thrown
    )
    || throw "unexpected check result: ${builtins.toJSON result}";

  # The check passes in a namespace on the list.
  critical-priority-check-passes-listed-namespace = checkIn [ "kube-system" ] "kube-system" == [ ];

  # An empty list admits the class nowhere, and says so.
  critical-priority-message-empty-list =
    let
      result = checkIn [ ] "kube-system";
    in
    (result ? thrown && lib.hasInfix "does not allow in any namespace" result.thrown)
    || throw "unexpected check result: ${builtins.toJSON result}";
}
