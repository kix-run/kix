# clusters/test-tailscale/cluster.nix: the tailscale operator and a backend
# on the tailnet, under Cilium default-deny.
#
# The `tailscale` namespace holds the operator and its OAuth Secret, which
# is created outside Kix. `tailnet-demo` holds `consumer.nix`, an nginx
# backend reached through an Ingress from `out.mkIngress` and through a
# LoadBalancer Service with `out.loadBalancerClass`. Each gets a
# `*-from-tailscale` policy and no ingress from outside the cluster.
#
# Commands run from the repository root. Build:
#
#   nix build ./clusters#cluster-tailscale --extra-experimental-features pipe-operators
#
# Deploy on a kind cluster that runs Cilium, after creating the Secret:
#
#   kubectl create namespace tailscale
#   kubectl -n tailscale create secret generic oauth-credentials \
#     --from-literal=client_id=<id> --from-literal=client_secret=<secret>
#   nix run .#kix -- deploy tailscale --flake ./clusters
#
# With dummy credentials the operator exits on its first call to the
# Tailscale API, which shows that its egress policy lets TCP 443 out, and
# never becomes Ready.
#
# No flavour: a flavour declares platform instances in `kube-system`, and
# default deny there would cut off the target cluster's own DNS.

{ kix, packages }:

kix.buildCluster {
  name = "test-tailscale";
  specialArgs = { inherit packages kix; };
  modules = [
    (
      {
        config,
        kix,
        packages,
        ...
      }:
      {
        availablePackages = packages;
        networkPolicy.enable = true;
        cluster.availability.default = "none";

        # The target installs Cilium; the `cilium` instance uses it and
        # claims the enforcer role.
        cluster.network.environmentCilium.helmChartConfig = null;
        cluster.roles = {
          cni = {
            binding = "shadowable";
            provider = "cilium (environment)";
          };
          loadBalancer.binding = "absent";
        };

        instances.tailscale = {
          cilium.package = packages.cilium;
          # No `kind`: the deploy would look for a Service named coredns in
          # this namespace. The role and the address are all it carries.
          platform-dns.package = kix.mkImport {
            roles = [ "dns" ];
            out = {
              name = "coredns";
              fqdn = "kube-dns.kube-system.svc.${config.clusterDomain}";
            };
          };
          tailscale.package = packages.tailscale;
          oauth-credentials = {
            package = packages.secret-ref;
            aliases = [ "oauthCredentials" ];
            config.keys = [
              "client_id"
              "client_secret"
            ];
          };
        };

        instances.tailnet-demo.web.package = import ./consumer.nix;
      }
    )
  ];
}
