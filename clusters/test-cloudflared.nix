# clusters/test-cloudflared.nix: cloudflared on kind under Cilium default-deny.
#
# A test run has no Cloudflare account, so it has no tunnel token, and
# cloudflared with an invalid token never turns ready. The `quick` instance
# keeps the package's Deployment, image, security context, and probes, and
# overlays only the container arguments: `--url` runs an account-less quick
# tunnel on trycloudflare.com instead of `run` with the token. Its log prints
# the public URL, and a request to that URL from outside the cluster reaches
# the `hello` echo server through the connector. The token is a placeholder
# that the quick tunnel does not read.
#
# The package declares no egress to Cloudflare and derives no path to the
# Services the tunnel serves, so the `tunnel` namespace opens both with a
# plain NetworkPolicy.
#
# Bring-up, on a kind cluster created with `disableDefaultCNI: true` and
# `podSubnet: "10.244.0.0/16"`:
#   kix deploy cloudflared --context kind-<name> -y
#   kubectl -n tunnel logs deploy/quick | grep trycloudflare.com
#   curl https://<name>.trycloudflare.com/
#
# Build:  kix build cloudflared

{ kix, packages }:

kix.buildCluster {
  name = "test-cloudflared";
  modules = [
    kix.flavors.kind

    {
      # kind runs with the default CNI disabled; the managed cilium instance
      # fills the vacant role.
      cluster.roles.cni = {
        binding = "absent";
        provider = null;
      };
      networkPolicy.enable = true;

      namespaces.tunnel.networkPolicies.tunnel-paths = {
        podSelector = { };
        policyTypes = [
          "Ingress"
          "Egress"
        ];
        ingress = [ { from = [ { podSelector = { }; } ]; } ];
        egress = [ { } ];
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

        tunnel = {
          hello = {
            package = packages.echo-server;
            config.message = "hello through the tunnel";
          };

          quick = {
            package = packages.experimental.cloudflared;
            partsOverlays = [
              (
                scope: _self: base:
                let
                  manifest = base.deployment.rawManifest;
                  podSpec = manifest.spec.template.spec;
                  quickTunnel =
                    c:
                    c
                    // {
                      args = [
                        "tunnel"
                        "--no-autoupdate"
                        "--metrics"
                        "0.0.0.0:2000"
                        "--url"
                        "http://hello.tunnel.svc.cluster.local:80"
                      ];
                    };
                in
                {
                  deployment = scope.mkDeployment {
                    name = manifest.metadata.name;
                    spec = manifest.spec // {
                      template = manifest.spec.template // {
                        spec = podSpec // {
                          containers = map quickTunnel podSpec.containers;
                        };
                      };
                    };
                  };
                }
              )
            ];
          };
          tunnel-token = {
            package = packages.secret;
            aliases = [ "tunnelToken" ];
            config.stringData.token = "placeholder-the-quick-tunnel-reads-no-token";
          };
        };
      };
    }
  ];
}
