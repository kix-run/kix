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
}
