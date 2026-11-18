# clusters/test-caddy.nix: Caddy on kind under Cilium default-deny.
#
# One Caddy with a claim for /data and a Caddyfile that issues a site
# certificate from Caddy's own local CA. The CA and the certificate live in
# /data, so a deploy over an older version shows whether the new version
# keeps what the old one wrote, or issues new ones. metrics-server serves the
# HorizontalPodAutoscaler. kind has no LoadBalancer controller, so the main
# Service is a ClusterIP.
#
# Bring-up, on a kind cluster created with `disableDefaultCNI: true` and
# `podSubnet: "10.244.0.0/16"`:
#   kix deploy caddy --context kind-<name> -y
#
# Check, from inside the pod:
#   wget -qO- --no-check-certificate --header 'Host: caddy.test' https://127.0.0.1/
#
# Build:  kix build caddy

{ kix, packages }:

kix.buildCluster {
  name = "test-caddy";
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

      namespaces = {
        edge = { };
        metrics-server = { };
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

        metrics-server.metrics-server = {
          package = packages.experimental.metrics-server;
          config.extraArgs = [ "--kubelet-insecure-tls" ];
        };

        edge = {
          caddy = {
            package = packages.experimental.caddy;
            config.service.type = "ClusterIP";
          };
          caddy-config = {
            package = packages.secret;
            aliases = [ "caddyfile" ];
            config.stringData.Caddyfile = ''
              {
                admin :2019
                local_certs
                skip_install_trust
              }

              :8080 {
                respond /healthz 200
              }

              caddy.test {
                tls internal
                respond "hello from {system.hostname}"
              }
            '';
          };
          caddy-data = {
            package = packages."persistent-volume-claim";
            aliases = [ "storage" ];
            config.size = "1Gi";
          };
        };
      };
    }
  ];
}
