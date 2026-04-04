# Test cluster: monitoring via native kix packages.
#
# Minimal cluster for structural comparison against the Helm chart.
# Build: nix build .#cluster-monitoring-native -o result-monitoring-native

{ kix, packages }:

kix.buildCluster {
  name = "monitoring-native";
  specialArgs = { inherit packages kix; };
  modules = [
    kix.flavors.kind
    kix.modules.monitoring

    {
      monitoring.enabled = true;
      # monitoring.defaultRules.enabled = true;  # opt-in: standard K8s alerts + recording rules
    }
  ];
}
