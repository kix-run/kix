# clusters/test-arc-runner-set.nix: the arc controller and one runner set on
# kind under Cilium default-deny.
#
# The runner set reads its GitHub credentials from the Secret
# `github-config` in `arc-runners`, which no package renders. Without real
# credentials the controller cannot register the scale set with GitHub, so
# no listener or runner pod starts. The cluster still shows that the runner
# set renders, applies, and is reconciled, and that the runner image runs.
#
# Kind: networking.disableDefaultCNI true, podSubnet 10.244.0.0/16.
# Before the first deploy:
#   kubectl create namespace arc-runners
#   kubectl -n arc-runners create secret generic github-config \
#     --from-literal=github_token=<token>
# Deploy: kix deploy arc-runner-set --context <context> -y

{ kix, packages }:

kix.buildCluster {
  name = "arc-runner-set";
  modules = [
    kix.flavors.kind

    {
      cluster.roles.cni = {
        binding = "absent";
        provider = null;
      };
      networkPolicy.enable = true;

      namespaces = {
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

        arc-systems.arc.package = packages.experimental.arc;

        arc-runners.github-config = {
          package = packages.secret-ref;
          aliases = [ "githubConfigSecret" ];
          config.keys = [ "github_token" ];
        };

        arc-runners.linux = {
          package = packages.experimental.arc-runner-set;
          config = {
            githubConfigUrl = "https://github.com/example-org/example-repo";
            maxRunners = 2;
          };
        };
      };
    }
  ];
}
