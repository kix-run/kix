# clusters/test-arc.nix: the arc controller and one arc-runner-set runner
# set on kind, under Cilium default-deny, with the controller's metrics and
# alerts.
#
# kind has no GitHub credentials, so the runner set never registers with
# GitHub. The controller still reconciles it: it adds its finalizer, reads
# the GitHub secret, and logs the refused credential, and the runner set
# stays `Pending`. The deploy therefore ends with the runner set not ready.
# Run it with `--on-error continue` so every other object is applied and
# checked. Create the secret the runner set names before the first deploy:
#
#   kubectl create namespace arc-runners
#   kubectl -n arc-runners create secret generic github-config \
#     --from-literal=github_token=not-a-real-token
#
# Create the kind cluster without the default CNI:
#
#   kind: Cluster
#   apiVersion: kind.x-k8s.io/v1alpha4
#   networking: { disableDefaultCNI: true, podSubnet: "10.244.0.0/16" }
#   nodes:
#     - role: control-plane
#     - role: worker
#
# Build:  kix build arc
# Deploy: kix deploy arc --context kind-<name> -y --on-error continue --timeout 5m

{ kix, packages }:

kix.buildCluster {
  name = "arc";
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

      namespaces = {
        monitoring = { };
        arc-systems = { };
        arc-runners = { };
      };

      instances = {
        kube-system.cilium = {
          package = packages.experimental.cilium;
          config.values = {
            kubeProxyReplacement = false;
            prometheus.enabled = false;
            ipam.operator.clusterPoolIPv4PodCIDRList = [ "10.244.0.0/16" ];
          };
        };

        monitoring.prometheus-operator.package = packages.experimental.prometheus-operator;

        arc-systems.arc = {
          package = packages.experimental.arc;
          config.metrics.enabled = true;
        };

        arc-runners = {
          github-config = {
            package = packages.secret-ref;
            aliases = [ "githubConfigSecret" ];
            config.keys = [ "github_token" ];
          };
          linux = {
            package = packages.experimental.arc-runner-set;
            config = {
              githubConfigUrl = "https://github.com/example-org";
              maxRunners = 2;
            };
          };
        };
      };
    }
  ];
}
