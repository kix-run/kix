# Tests for the `gke-autopilot` flavour's capabilities, as a live Autopilot
# cluster showed them: DaemonSets run, host access does not.

{
  lib,
  mkCluster,
  manifests,
  ofKind,
  hasName,
  evalFails,
  containerBase,
  ...
}:

let
  autopilot = import ../../flavors/gke-autopilot.nix;
  helpers = import ../caught.nix { inherit lib; };

  # Run the privileged check alone on `podSpec`, for its text.
  refusalOf =
    podSpec:
    ((helpers.loadCaught ../../scope/validators.nix { inherit lib; }).mkValidators {
      instanceName = "agent";
      namespaceName = "agents";
      capabilities.privilegedContainers = false;
    }).checkPrivileged
      podSpec;

  # Return true when the refusal of `podSpec` contains `text`.
  refusalSays =
    podSpec: text:
    let
      result = refusalOf podSpec;
    in
    (result ? thrown && lib.hasInfix text result.thrown)
    || throw "unexpected refusal: ${builtins.toJSON result}";

  # Return a package with one DaemonSet, with `podSpec` merged into its pods.
  agentPackage = podSpec: {
    meta.version = "test";
    build =
      { self, scope, ... }:
      {
        ds = scope.mkDaemonSet {
          name = "agent";
          spec = {
            selector.matchLabels = scope.selectorLabels;
            template = {
              metadata.labels = scope.selectorLabels;
              spec = {
                containers = [
                  (
                    {
                      name = "agent";
                      image = "example/agent:1";
                    }
                    // containerBase
                  )
                ];
              }
              // podSpec;
            };
          };
        };
        root = self.ds;
      };
  };

  clusterWith =
    podSpec:
    mkCluster [
      autopilot
      { instances.agents.agent.package = agentPackage podSpec; }
    ];
in
{
  # A plain DaemonSet builds on Autopilot.
  flavor-gke-autopilot-admits-daemonset = hasName "agent" (
    ofKind "DaemonSet" (manifests (clusterWith { }))
  );

  # A DaemonSet on the host network still fails, as Autopilot refuses it.
  flavor-gke-autopilot-refuses-host-network = evalFails (clusterWith {
    hostNetwork = true;
  });

  # Each refusal names the rule the pod breaks.
  flavor-gke-autopilot-refusal-names-host-namespace = refusalSays {
    hostNetwork = true;
  } "set hostNetwork = true. This cluster does not allow pods to share a host namespace";
  flavor-gke-autopilot-refusal-names-host-path = refusalSays {
    volumes = [
      {
        name = "logs";
        hostPath.path = "/var/log";
      }
    ];
  } "hostPath volume 'logs' (/var/log)";
  flavor-gke-autopilot-refusal-names-privileged-container = refusalSays {
    containers = [
      {
        name = "main";
        securityContext.privileged = true;
      }
    ];
  } "container 'main' with securityContext.privileged = true";

  # A pod without host access passes the check.
  flavor-gke-autopilot-plain-pod-passes = refusalOf { containers = [ { name = "main"; } ]; } == [ ];
}
