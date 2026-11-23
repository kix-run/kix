# clusters/test-coredns.nix: coredns as the only DNS server of a kind
# cluster, under Cilium default-deny, with its ServiceMonitor and alerts.
#
# The kind cluster skips kubeadm's CoreDNS addon, so the instance below is
# the server every pod's resolv.conf names. It takes the kubelet's
# clusterDNS address, 10.96.0.10, and the Service name kube-dns. The kind
# flavour's platform-dns import is optional here, so no deploy waits for
# kind's own CoreDNS. The instance runs two replicas at availability `pod`,
# and a second server block answers `kix.test` from the `hosts` plugin, so
# a query for it shows that the Corefile the package renders is the one
# CoreDNS serves.
#
# Create the kind cluster without the default CNI and without CoreDNS:
#
#   kind: Cluster
#   apiVersion: kind.x-k8s.io/v1alpha4
#   networking:
#     disableDefaultCNI: true
#   nodes:
#     - role: control-plane
#     - role: worker
#   kubeadmConfigPatches:
#     - |
#       kind: InitConfiguration
#       skipPhases: [ addon/coredns ]
#
# Build:  kix build coredns
# Deploy: kix deploy coredns --context kind-<name> -y
# Check:  kubectl run dig --rm -i --restart=Never --image=busybox -- \
#           nslookup kubernetes.default

{ kix, packages }:

kix.buildCluster {
  name = "coredns";
  modules = [
    kix.flavors.kind

    {
      cluster.capabilities.multiNode = true;

      # kind runs with the default CNI disabled; the managed cilium instance
      # fills the vacant role.
      cluster.roles.cni = {
        binding = "absent";
        provider = null;
      };
      networkPolicy.enable = true;

      namespaces.monitoring = { };

      instances = {
        kube-system = {
          cilium = {
            package = packages.experimental.cilium;
            config.values = {
              kubeProxyReplacement = false;
              prometheus.enabled = false;
              ipam.operator.clusterPoolIPv4PodCIDRList = [ "10.244.0.0/16" ];
            };
          };

          kube-dns = {
            package = packages.experimental.coredns;
            availability = "pod";
            config = {
              clusterIP = "10.96.0.10";
              metrics.enabled = true;
              servers.kix-test = {
                zones = [ "kix.test" ];
                plugins = {
                  errors = { };
                  hosts.block = [
                    "192.0.2.10 probe.kix.test"
                    "fallthrough"
                  ];
                };
              };
            };
          };

          # The kind flavour imports the `kube-system/kube-dns` Service here,
          # and the deploy waits for it to have a ready endpoint.
          platform-dns.optional = true;
        };

        monitoring.prometheus-operator.package = packages.experimental.prometheus-operator;
      };
    }
  ];
}
