# clusters/test-falco.nix: the Falco agent under Cilium default-deny, with a
# rules file and a Prometheus provider, so the rules ConfigMap, the metrics
# Service, the ServiceMonitor, and the alert are built.
#
# Falco calls no API and opens no connection, so its only network policy is
# the scrape ingress derived from the ServiceMonitor. On kind the nodes share
# the host's kernel, which must be Linux 5.8 or later with BTF for the
# modern eBPF driver.
#
# Build:  nix build ./clusters#cluster-falco --extra-experimental-features pipe-operators

{ kix, packages }:

kix.buildCluster {
  name = "test-falco";
  modules = [
    kix.flavors.kind
    {
      availablePackages = packages;
      networkPolicy.enable = true;

      # kind runs with the default CNI disabled, so the managed cilium
      # instance fills the cni role.
      cluster.roles.cni = {
        binding = "absent";
        provider = null;
      };
      instances.kube-system.cilium.package = packages.experimental.cilium;

      instances.monitoring.prometheus-operator.package = packages.experimental.prometheus-operator;

      instances.security.falco = {
        package = packages.experimental.falco;
        config.rules."50-shell-in-pod" = [
          {
            rule = "Shell in a pod of the security namespace";
            desc = "A shell started in a container of the security namespace.";
            condition = "spawned_process and container and k8s.ns.name = security and proc.name in (sh, bash)";
            output = "Shell in security pod (user=%user.name command=%proc.cmdline pod=%k8s.pod.name)";
            priority = "WARNING";
          }
        ];
      };
    }
  ];
}
