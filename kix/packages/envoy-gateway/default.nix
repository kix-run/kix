# envoy-gateway kix package — Gateway API resources.
#
# Creates GatewayClass and Gateway resources for the Gateway API.
# The actual Envoy Gateway controller is installed separately (e.g.
# via Helm at the cluster level). This package provides the Gateway
# API resources and the DI contract that kix.expose consumes.
#
# Supports multiple instances (public gateway, private gateway, etc.)
# — all resource names derive from scope.instanceName.
#
# Resources: GatewayClass, Gateway.
# root = Gateway, with out.gatewayRef for kix.expose consumption.

{
  scope,
  lib,
}:

{
  meta = {
    version = "1.0.0";
    description = "Gateway API resources (GatewayClass + Gateway)";
    defaultAliases = [ "gateway" ];
    k8s.minVersion = "1.26";
  };

  options = {
    # GatewayClass controller name. Must match the controller installed in the cluster.
    # Common values: "gateway.envoyproxy.io/gatewayclass-controller" (Envoy Gateway),
    #                "gateway.nginx.org/nginx-gateway-controller" (nginx-gateway-fabric).
    controllerName = lib.mkOption {
      type = lib.types.str;
      default = "gateway.envoyproxy.io/gatewayclass-controller";
      description = "Controller name for the GatewayClass. Must match the installed gateway controller.";
    };

    # Override GatewayClass name. Defaults to instance name.
    gatewayClassName = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "GatewayClass name. Defaults to the instance name.";
    };

    # Override Gateway name. Defaults to instance name.
    gatewayName = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Gateway name. Defaults to the instance name.";
    };

    # Gateway listeners. Each listener defines a port, protocol, and optional TLS config.
    listeners = lib.mkOption {
      type = lib.types.listOf lib.types.anything;
      default = [
        {
          name = "http";
          port = 80;
          protocol = "HTTP";
          allowedRoutes.namespaces.from = "All";
        }
        {
          name = "https";
          port = 443;
          protocol = "HTTPS";
          tls = {
            mode = "Terminate";
            certificateRefs = [ ];
          };
          allowedRoutes.namespaces.from = "All";
        }
      ];
      description = ''
        Gateway listener configuration. Each listener specifies a port,
        protocol, optional TLS config, and route namespace policy.
      '';
    };

    # Gateway addresses (e.g. for static IP assignment).
    addresses = lib.mkOption {
      type = lib.types.listOf lib.types.anything;
      default = [ ];
      description = "Optional static addresses for the Gateway.";
    };
  };

  build =
    {
      self,
      config,
      scope,
      ...
    }:
    let
      name = scope.instanceName;
      gatewayClassName = if config.gatewayClassName != null then config.gatewayClassName else name;
      gatewayName = if config.gatewayName != null then config.gatewayName else name;

      selectorLabels = {
        "app.kubernetes.io/name" = "envoy-gateway";
        "app.kubernetes.io/instance" = name;
        "app.kubernetes.io/component" = "gateway";
      };

      # Filter out HTTPS listeners with empty certificateRefs — these are
      # placeholders that the cluster operator hasn't configured yet.
      activeListeners = builtins.filter (
        l: if l.protocol == "HTTPS" && l ? tls.certificateRefs then l.tls.certificateRefs != [ ] else true
      ) config.listeners;
    in
    {
      # --- GatewayClass (cluster-scoped) ---
      gatewayClass = scope.mkClusterResource {
        apiVersion = "gateway.networking.k8s.io/v1";
        kind = "GatewayClass";
        name = gatewayClassName;
        labels = selectorLabels;
        spec = {
          controllerName = config.controllerName;
        };
      };

      # --- Gateway ---
      gateway = scope.mkResource {
        apiVersion = "gateway.networking.k8s.io/v1";
        kind = "Gateway";
        name = gatewayName;
        labels = selectorLabels;
        spec = {
          gatewayClassName = self.gatewayClass.out.name;
          listeners = activeListeners;
        }
        // lib.optionalAttrs (config.addresses != [ ]) {
          addresses = config.addresses;
        };
      };

      # --- Entry point ---
      root = {
        resource = self.gateway;
        out = {
          # The DI contract consumed by kix.expose: a reference to this Gateway.
          gatewayRef = {
            name = self.gateway.out.name;
            namespace = scope.namespaceName;
          };
          # Selector for network policies — matches the envoy proxy pods
          # spawned by the controller for this Gateway.
          selector = selectorLabels;
        };
      };
    };
}
