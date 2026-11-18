# clusters/test-smartctl-exporter.nix: the smartctl exporter under Cilium
# default-deny, scraped by a Prometheus server that loads its alert rules.
#
# prometheus-operator and a Prometheus server in `monitoring` answer the
# exporter's `prometheus` dependency, so the ServiceMonitor, the scrape
# ingress, and the PrometheusRule are built and used. Prometheus's
# `/api/v1/targets` should list the exporter as up, and its
# `/api/v1/rules` should list the smartctl-exporter alerts. kind nodes are
# privileged containers that see the host's /dev, so on a host with a
# SATA or NVMe disk the exporter reports `smartctl_device` series for it.
# Used to test a version change of the exporter.
#
# Bring up: kind create cluster --name <name> --config <config>
#           where the config sets networking.disableDefaultCNI = true and
#           lists one control-plane node.
# Deploy:   kix deploy smartctl-exporter --context kind-<name> -y

{ kix, packages }:

kix.buildCluster {
  name = "smartctl-exporter";
  modules = [
    kix.flavors.kind
    (
      { ref, ... }:
      {
        # kind runs with the default CNI disabled, so the managed cilium
        # instance fills the cni role.
        cluster.roles.cni = {
          binding = "absent";
          provider = null;
        };
        networkPolicy.enable = true;
        instances.kube-system.cilium.package = packages.experimental.cilium;

        instances.monitoring = {
          prometheus-operator.package = packages.experimental.prometheus-operator;
          prometheus = {
            package = packages.experimental.prometheus;
            config.storage.size = "1Gi";
          };
          # The prometheus server publishes the same contract, so the
          # exporter names the operator that defines the monitor kinds.
          smartctl-exporter = {
            package = packages.experimental.smartctl-exporter;
            deps.prometheus = ref.monitoring.prometheus-operator;
          };
        };
      }
    )
  ];
}
