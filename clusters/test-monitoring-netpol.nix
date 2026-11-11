# clusters/test-monitoring-netpol.nix: Prometheus scrapes under default deny.
#
# The smallest kind cluster that exercises the scrape policies of the netpol
# plugin (kix/lib/plugins/netpol/scrape.nix): the monitoring module's
# Prometheus, Alertmanager, kube-state-metrics, and node-exporter (on the host
# network) in `monitoring-system`, reloader in `reloader`, and a one-instance
# StackGres cluster in `data`, whose PodMonitor scrapes the exporter sidecar
# of operator-created pods on port 9187 (`portNumber`). Cilium is
# installed by Kix with `networkPolicy.enable`. Every target in Prometheus's
# `/api/v1/targets` should be up, and Alertmanager should be discovered.
#
# Bring up: kind create cluster --name kix-monitoring-netpol --config <config>
#           where the config sets networking.disableDefaultCNI = true
# Deploy:   kix --flake ./clusters --context kind-kix-monitoring-netpol deploy monitoring-netpol -y

{ kix, packages }:

kix.buildCluster {
  name = "monitoring-netpol";
  specialArgs = { inherit packages kix; };
  modules = [
    kix.flavors.kind
    kix.modules.experimental.monitoring

    {
      cluster.availability.default = "none";
      # kind runs with disableDefaultCNI, so the managed cilium instance
      # fills the vacant CNI role.
      cluster.roles.cni = {
        binding = "absent";
        provider = null;
      };
      networkPolicy.enable = true;
      instances.kube-system.cilium.package = packages.experimental.cilium;

      monitoring.enabled = true;
      monitoring.grafana.enabled = false;

      instances.reloader.reloader.package = packages.experimental.reloader;

      instances.stackgres-system.stackgres-operator.package = packages.experimental.stackgres-operator;
      instances.data.pg = {
        package = packages.experimental.stackgres-cluster;
        # kind has one node and the pods anti-affine, so a second instance
        # never schedules.
        config.instances = 1;
      };
    }
  ];
}
