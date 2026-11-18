# clusters/test-envoy-gateway.nix: Envoy Gateway as the cluster's Gateway
# API implementation on kind, under Cilium default-deny, with a public and a
# private Gateway.
#
# gateway-api installs the Gateway API CRDs, envoy-gateway-controller
# installs the controller and its GatewayClass, and two envoy-gateway
# instances add a Gateway each, in a namespace of its own:
#   edge/envoy-gateway   public. HTTP redirects to HTTPS, the HTTPS
#                        listeners take certificates from a self-signed
#                        ClusterIssuer, one listener admits only the
#                        namespace tenant-a, and a ClientTrafficPolicy
#                        trusts X-Forwarded-For from one range and adds
#                        Strict-Transport-Security.
#   internal/private     private. A ClusterIP Service at 10.96.200.10, no
#                        clients from outside the cluster, and a
#                        SecurityPolicy allow-list.
# filebrowser is exposed through kix.expose on each Gateway, so it gets an
# HTTPRoute and a policy that admits that Gateway's proxies to its pod
# port. The kind flavour binds the loadBalancer role absent, so the public
# proxy Service is a NodePort. prometheus-operator answers the `prometheus`
# alias, so the packages render their metrics Service, ServiceMonitor,
# PodMonitor, and alert rules, which test-envoy-gateway.rules-test.yaml
# tests. No Prometheus server runs.
#
# Bring-up and the behaviour checks: scripts/kind-gateway.sh, which creates
# the kind cluster, deploys this cluster, and sends the requests.
#
# Build:  kix build envoy-gateway

{ kix, packages }:

kix.buildCluster {
  name = "envoy-gateway";
  modules = [
    kix.flavors.kind

    (
      { ref, ... }:
      {
        instances.edge.envoy-gateway.deps.clusterIssuer = ref.cert-manager.selfsigned;
        instances.internal-files.filebrowser.deps.gateway = ref.internal.private;
      }
    )

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
          envoy-gateway-controller = {
            package = packages.experimental.envoy-gateway-controller;
            config = {
              metrics.enabled = true;
              settings.extensionApis.enableBackend = true;
            };
          };
        };

        cert-manager = {
          cert-manager.package = packages.experimental.cert-manager;
          selfsigned = {
            package = packages.experimental.cluster-issuer;
            config.spec.selfSigned = { };
          };
        };

        # The public Gateway has a namespace of its own, where the
        # controller starts its proxies. Its HTTPS listeners take their
        # certificates from the issuer. The `tenant` listener admits routes
        # from the namespace tenant-a only.
        edge.envoy-gateway = {
          package = packages.experimental.envoy-gateway;
          config = {
            metrics.enabled = true;
            proxySpec.logging.level.default = "warn";
            listeners = [
              {
                name = "http";
                port = 80;
                protocol = "HTTP";
              }
              {
                name = "https";
                port = 443;
                protocol = "HTTPS";
                hostname = "*.envoy.test";
                allowedRoutes.namespaces.from = "All";
              }
              {
                name = "tenant";
                port = 443;
                protocol = "HTTPS";
                hostname = "*.tenant.test";
                allowedRoutes.namespaces = {
                  from = "Selector";
                  selector.matchLabels."kubernetes.io/metadata.name" = "tenant-a";
                };
              }
            ];
            httpsRedirect = true;
            clientTrafficPolicy = {
              # Only this range may say who the client is.
              clientIPDetection.xForwardedFor.trustedCIDRs = [ "192.0.2.0/24" ];
              headers.lateResponseHeaders.set = [
                {
                  name = "Strict-Transport-Security";
                  value = "max-age=31536000; includeSubDomains";
                }
              ];
            };
          };
        };

        # The private Gateway: a ClusterIP Service at a fixed address, no
        # clients from outside the cluster, and an allow-list. The proxies
        # believe X-Forwarded-For from the cluster's own addresses, so the
        # test can stand in for a client on the allowed range.
        internal.private = {
          package = packages.experimental.envoy-gateway;
          aliases = [ ];
          config = {
            listeners = [
              {
                name = "http";
                port = 80;
                protocol = "HTTP";
                allowedRoutes.namespaces.from = "All";
              }
            ];
            addresses = [ { value = "10.96.200.10"; } ];
            proxySpec.provider.kubernetes.envoyService.type = "ClusterIP";
            clientSources = [ "all-pods" ];
            clientTrafficPolicy.clientIPDetection.xForwardedFor.trustedCIDRs = [
              "10.0.0.0/8"
              "172.16.0.0/12"
              "192.168.0.0/16"
            ];
            securityPolicy.authorization = {
              defaultAction = "Deny";
              rules = [
                {
                  action = "Allow";
                  principal.clientCIDRs = [ "203.0.113.0/24" ];
                }
              ];
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

        internal-files = {
          filebrowser = {
            package = packages.experimental.filebrowser;
            config.ingress.host = "files.internal.test";
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
