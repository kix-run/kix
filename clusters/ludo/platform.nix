# Platform — infra that needs explicit config on this cluster.
# Everything with acceptable defaults auto-instantiates via availablePackages.
#
# This cluster uses Gateway API (envoy-gateway) instead of ingress-nginx.
# LAN-only: no TLS, plain HTTP.

{
  config,
  lib,
  packages,
  ...
}:
{
  options = {
    cluster.domain = lib.mkOption {
      type = lib.types.str;
      description = "Base domain for the cluster";
    };
  };

  config.instances = {

    # k3s provides local-path-provisioner; this satisfies the storageClasses DI dep.
    # Default class uses Delete policy (fine for ephemeral data).
    kube-system.storage-classes = {
      package = {
        meta.version = "1.0.0";
        meta.defaultAliases = [ "storageClasses" ];
        build =
          { scope, ... }:
          {
            root = scope.mkResource {
              apiVersion = "storage.k8s.io/v1";
              kind = "StorageClass";
              name = "local-path";
              extra = {
                provisioner = "rancher.io/local-path";
                reclaimPolicy = "Delete";
                volumeBindingMode = "WaitForFirstConsumer";
              };
              annotations."storageclass.kubernetes.io/is-default-class" = "true";
              outputs.storageClassName = "local-path";
            };

            # Retain class for data you don't want to lose on PVC deletion.
            retain = scope.mkResource {
              apiVersion = "storage.k8s.io/v1";
              kind = "StorageClass";
              name = "local-path-retain";
              extra = {
                provisioner = "rancher.io/local-path";
                reclaimPolicy = "Retain";
                volumeBindingMode = "WaitForFirstConsumer";
              };
              outputs.storageClassName = "local-path-retain";
            };
          };
      };
    };

    # Gateway API — replaces ingress-nginx on this cluster.
    # Envoy Gateway controller is installed separately (e.g. via Helm).
    # This provides the GatewayClass + Gateway resources and the DI contract
    # that kix.expose consumes to emit HTTPRoutes instead of Ingresses.
    gateway-system.gateway = {
      package = packages."envoy-gateway";
      config = {
        controllerName = "gateway.envoyproxy.io/gatewayclass-controller";
        listeners = [
          {
            name = "http";
            port = 80;
            protocol = "HTTP";
            allowedRoutes.namespaces.from = "All";
          }
        ];
      };
    };

  };
}
