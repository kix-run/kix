# clusters/test-prometheus-operator.nix: the Prometheus Operator with the
# packages that depend on it.
#
# prometheus-operator, a Prometheus server, and an Alertmanager in
# `monitoring`, under network policy with Cilium, plus a second Alertmanager,
# `alertmanager-ha`, at availability `pod`, whose two replicas gossip
# silences. Prometheus sends alerts to the first one. Prometheus and
# Alertmanager keep their data on claims, so the data outlives the restart
# the operator makes when its config-reloader image changes. Prometheus
# scrapes the operator's metrics Service, Alertmanager, and itself, so every
# target in its `/api/v1/targets` should be up and Alertmanager should be
# discovered. Used to test a version change of the operator over a running
# Prometheus and Alertmanager.
#
# Bring up: kind create cluster --name <name> --config <config>
#           where the config sets networking.disableDefaultCNI = true and
#           lists a control-plane and a worker node, so the two
#           alertmanager-ha replicas spread over two nodes.
# Deploy:   kix deploy prometheus-operator --context kind-<name> -y

{ kix, packages }:

kix.buildCluster {
  name = "prometheus-operator";
  modules = [
    kix.flavors.kind

    (
      { ref, ... }:
      {
        cluster.availability.default = "none";
        cluster.capabilities.multiNode = true;
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
            deps.alertmanager = ref.monitoring.alertmanager;
            config.storage.size = "1Gi";
          };
          alertmanager = {
            package = packages.experimental.alertmanager;
            config.storage.size = "1Gi";
          };
          alertmanager-ha = {
            package = packages.experimental.alertmanager;
            availability = "pod";
            config.storage.size = "1Gi";
          };
        };
      }
    )
  ];
}
