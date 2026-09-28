# envoy-gateway kix package: Gateway API resources.
#
# Creates GatewayClass and Gateway resources for the Gateway API, plus an
# optional EnvoyProxy that tells Envoy Gateway how to provision the data
# plane for that class.
#
# The actual Envoy Gateway controller is installed separately (e.g.
# via Helm at the cluster level). This package provides the Gateway
# API resources and the DI contract that kix.expose consumes.
#
# Supports multiple instances (public gateway, private gateway, etc.);
# all resource names derive from scope.instanceName.
#
# Resources: EnvoyProxy (optional), GatewayClass, Gateway, plus CRD refs
# for the two Gateway API kinds.
# root = Gateway, with out.gatewayRef for kix.expose consumption.

{
  scope,
  lib,
}:

let
  # The controller name Envoy Gateway's own GatewayClass controller
  # watches for. Spelled once: it is both the `controllerName` default
  # and the precondition for emitting an EnvoyProxy, which is an Envoy
  # Gateway extension and means nothing to another implementation.
  envoyGatewayController = "gateway.envoyproxy.io/gatewayclass-controller";
in

{
  meta = {
    version = "1.1.0";
    description = "Gateway API resources (GatewayClass + Gateway)";
    owner = "platform";
    defaultAliases = [ "gateway" ];
    k8s.minVersion = "1.26";
  };

  options = {
    # GatewayClass controller name. Must match the controller installed in the cluster.
    # Common values: "gateway.envoyproxy.io/gatewayclass-controller" (Envoy Gateway),
    #                "gateway.nginx.org/nginx-gateway-controller" (nginx-gateway-fabric).
    controllerName = lib.mkOption {
      type = lib.types.str;
      default = envoyGatewayController;
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

    # Data-plane provisioning parameters, as an EnvoyProxy spec.
    proxySpec = lib.mkOption {
      type = lib.types.nullOr (lib.types.attrsOf lib.types.anything);
      default = null;
      example = lib.literalExpression ''
        {
          provider = {
            type = "Kubernetes";
            kubernetes.envoyService.type = "NodePort";
          };
        }
      '';
      description = ''
        `spec` of an EnvoyProxy (gateway.envoyproxy.io/v1alpha1), verbatim.

        When set, the package emits an EnvoyProxy and points the
        GatewayClass's `parametersRef` at it, so Envoy Gateway provisions
        every Gateway in the class from this spec. Leave it null (the
        default) to accept Envoy Gateway's own defaults, which include a
        `LoadBalancer` Service for the proxy.

        That default never gets an address on a cluster with no
        LoadBalancer implementation (stock kind, for one), so the Gateway
        stays `Programmed=False` and `kix deploy` waits for a readiness
        that cannot arrive. Setting
        `provider.kubernetes.envoyService.type = "NodePort"` makes Envoy
        Gateway publish the node addresses instead, and the Gateway
        programs.
      '';
    };
  };

  assertions =
    { config, ... }:
    [
      {
        assertion = config.proxySpec == null || config.controllerName == envoyGatewayController;
        message =
          "envoy-gateway: proxySpec configures an EnvoyProxy, an Envoy Gateway extension, "
          + "but controllerName is \"${config.controllerName}\". Either drop proxySpec or point "
          + "controllerName at \"${envoyGatewayController}\".";
      }
    ];

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

      # Filter out HTTPS listeners with empty certificateRefs; these are
      # placeholders that the cluster operator hasn't configured yet.
      activeListeners = builtins.filter (
        l: if l.protocol == "HTTPS" && l ? tls.certificateRefs then l.tls.certificateRefs != [ ] else true
      ) config.listeners;

      haveProxy = config.proxySpec != null;

      gatewayApiGroup = "gateway.networking.k8s.io";
    in
    # --- EnvoyProxy (optional, namespaced) ---
    # Envoy Gateway reads this through the GatewayClass's parametersRef and
    # provisions the proxy Deployment/Service from it. The reference is by
    # name and namespace, so it must exist before the class is accepted;
    # the `self.envoyProxy.out.name` below is what buys that ordering edge.
    lib.optionalAttrs haveProxy {
      envoyProxy = scope.mkResource {
        apiVersion = "gateway.envoyproxy.io/v1alpha1";
        kind = "EnvoyProxy";
        name = "${name}-proxy";
        labels = selectorLabels;
        spec = config.proxySpec;
      };
    }
    // {
      # --- Gateway API CRD refs ---
      # The CRDs arrive with the controller, outside kix. The refs give each
      # CR its CRD-before-CR edge and carry the Gateway API's readiness
      # conditions: a GatewayClass is usable once Accepted=True, a Gateway
      # once Programmed=True. Neither kind sets Ready or Available.
      gatewayClassCrd = scope.mkCRDRef {
        group = gatewayApiGroup;
        kind = "GatewayClass";
        plural = "gatewayclasses";
        version = "v1";
        crdScope = "Cluster";
        readiness.condition = {
          type = "Accepted";
          status = "True";
        };
      };

      gatewayCrd = scope.mkCRDRef {
        group = gatewayApiGroup;
        kind = "Gateway";
        plural = "gateways";
        version = "v1";
        crdScope = "Namespaced";
        readiness.condition = {
          type = "Programmed";
          status = "True";
        };
      };

      # --- GatewayClass (cluster-scoped) ---
      gatewayClass = self.gatewayClassCrd.out.mkCR scope {
        name = gatewayClassName;
        labels = selectorLabels;
        spec = {
          controllerName = config.controllerName;
        }
        // lib.optionalAttrs haveProxy {
          parametersRef = {
            group = "gateway.envoyproxy.io";
            kind = "EnvoyProxy";
            name = self.envoyProxy.out.name;
            namespace = scope.namespaceName;
          };
        };
      };

      # --- Gateway ---
      gateway = self.gatewayCrd.out.mkCR scope {
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
          # Selector for network policies: matches the envoy proxy pods
          # spawned by the controller for this Gateway.
          selector = selectorLabels;
        };
      };
    };
}
