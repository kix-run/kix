# clusters/test-envoy-gateway.nix: Envoy Gateway as the cluster's Gateway
# API implementation on kind, under Cilium default-deny.
#
# gateway-api installs the Gateway API CRDs, and envoy-gateway installs the
# controller, its GatewayClass, EnvoyProxy, and Gateway. filebrowser, in a
# namespace of its own, is exposed through kix.expose, so it gets an
# HTTPRoute on the Gateway and a policy that admits the Envoy proxies to
# its pod port. The kind flavour binds the loadBalancer role absent, so the
# proxy Service is a NodePort. prometheus-operator answers the `prometheus`
# alias, so the package renders its metrics Service, ServiceMonitor,
# PodMonitor, and alert rules, which test-envoy-gateway.rules-test.yaml
# tests. No Prometheus server runs.
#
# Bring-up, on a kind cluster created with `disableDefaultCNI: true` and
# `podSubnet: "10.244.0.0/16"`:
#   kix deploy envoy-gateway --context kind-<name> -y --timeout 15m
# Then, from the host, through a node's address and the proxy's NodePort:
#   curl -H 'Host: files.envoy.test' http://<node IP>:<NodePort of port 80>/
#
# Build:  kix build envoy-gateway

{ kix, packages }:

kix.buildCluster {
  name = "envoy-gateway";
  modules = [
    kix.flavors.kind

    {
      # kind runs with the default CNI disabled; the managed cilium instance
      # fills the vacant role.
      cluster.roles.cni = {
        binding = "absent";
        provider = null;
      };
      cluster.domain = "envoy.test";
      networkPolicy.enable = true;

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

        envoy-gateway-system = {
          gateway-api.package = packages.experimental.gateway-api;
          envoy-gateway = {
            package = packages.experimental.envoy-gateway;
            config = {
              metrics.enabled = true;
              settings.extensionApis.enableBackend = true;
              proxySpec.logging.level.default = "warn";
            };
          };
        };

        files = {
          filebrowser = {
            package = packages.experimental.filebrowser;
            config.ingress.host = "files.envoy.test";
          };
          filebrowser-data = {
            package = packages.persistent-volume-claim;
            aliases = [ "storage" ];
            config.size = "1Gi";
          };
        };
      };
    }
  ];
}
