# envoy-gateway: the GatewayClass and Gateway for an Envoy Gateway
# controller that is installed outside Kix.
#
# This package does not install Envoy Gateway. It creates no controller, no
# data plane, and no CRDs. Install the controller and the Gateway API CRDs
# first, for example with upstream's Helm chart, as the how-to guide
# "Install Envoy Gateway" shows. The package creates GatewayClass and
# Gateway resources, an optional EnvoyProxy that tells Envoy Gateway how to
# provision the data plane for that class, and the gateway contract that
# kix.expose reads.
#
# Supports multiple instances (public gateway, private gateway, etc.);
# all resource names derive from scope.instanceName.
#
# Resources: EnvoyProxy (optional), GatewayClass, Gateway, plus CRD refs
# for the two Gateway API kinds and, with an EnvoyProxy, for EnvoyProxy.
# root = Gateway, with out.gatewayRef, out.listeners, out.podSelector, and
# out.podNamespace for kix.expose (kix.contracts.gateway).
#
# Network policy: Envoy Gateway's controller creates the proxy pods. It
# labels them with the owning Gateway's name and namespace, or with the
# owning GatewayClass when the EnvoyProxy sets `mergeGateways`
# (internal/gatewayapi/helpers.go and
# internal/infrastructure/kubernetes/proxy/resource.go at v1.9.1). By
# default they run in the controller's namespace, which `proxyNamespace`
# names. kix.expose reads the selector and namespace to admit the proxies to
# each exposed backend. With another controllerName, or `proxyNamespace =
# null`, both are null and kix.expose warns that no policy admits the
# gateway's pods.
#
# Alerts: none. The package runs no program, so it has no metrics to
# scrape. The Envoy Gateway controller and the Envoy proxies it creates
# come from the controller's own installation, so their scrape and alerts
# belong with that installation.

{
  scope,
  lib,
  kix,
}:

let
  # The controller name Envoy Gateway's own GatewayClass controller
  # watches for. Spelled once: it is both the `controllerName` default
  # and the precondition for emitting an EnvoyProxy, which is an Envoy
  # Gateway extension and means nothing to another implementation.
  envoyGatewayController = "gateway.envoyproxy.io/gatewayclass-controller";

  gatewayListeners = import ./listeners.nix { inherit lib; };
in

{
  meta = {
    description = "GatewayClass, Gateway, and optional EnvoyProxy for Envoy Gateway. Does not install the Envoy Gateway controller or Gateway API CRDs";
    owner = "platform";
    defaultAliases = [ "gateway" ];
    # One Gateway accepts HTTPRoutes from every namespace, so consumers in
    # any namespace find it by name.
    scope = "cluster";
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

    listeners = lib.mkOption {
      type = lib.types.listOf gatewayListeners.type;
      default = gatewayListeners.defaults;
      description = ''
        Gateway API v1 `Listener` entries for the Gateway's `spec.listeners`,
        with the upstream field names. An HTTPS listener with no
        `tls.certificateRefs` is a placeholder and is not rendered.

        kix.expose reads the rendered listeners: `protocol`, `hostname`,
        `port`, and `allowedRoutes.namespaces.from` decide whether an
        HTTPRoute can attach and which URL scheme and port it gets.
      '';
    };

    proxyNamespace = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "envoy-gateway-system";
      description = ''
        Namespace of the Envoy proxy pods. Envoy Gateway runs them in the
        controller's namespace, `envoy-gateway-system` in its install guide.
        Set it to the controller's namespace when it is installed elsewhere,
        or to this instance's namespace when the controller runs in
        GatewayNamespace mode. kix.expose admits the proxy pods in this
        namespace to each exposed backend. Null leaves `out.podSelector`
        null, so no policy admits them.
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

      activeListeners = gatewayListeners.active config.listeners;

      haveProxy = config.proxySpec != null;

      # Labels Envoy Gateway puts on the proxy pods it creates. A merged
      # GatewayClass shares one proxy fleet across its Gateways.
      proxySelector =
        let
          owner =
            if haveProxy && (config.proxySpec.mergeGateways or false) then
              { "gateway.envoyproxy.io/owning-gatewayclass" = gatewayClassName; }
            else
              {
                "gateway.envoyproxy.io/owning-gateway-name" = gatewayName;
                "gateway.envoyproxy.io/owning-gateway-namespace" = scope.namespaceName;
              };
        in
        if config.controllerName != envoyGatewayController || config.proxyNamespace == null then
          null
        else
          {
            "app.kubernetes.io/name" = "envoy";
            "app.kubernetes.io/component" = "proxy";
            "app.kubernetes.io/managed-by" = "envoy-gateway";
          }
          // owner;

      gatewayApiGroup = "gateway.networking.k8s.io";
    in
    # Envoy Gateway reads this through the GatewayClass's parametersRef and
    # provisions the proxy Deployment/Service from it. The reference is by
    # name and namespace, so it must exist before the class is accepted;
    # the `self.envoyProxy.out.name` below is what buys that ordering edge.
    # The EnvoyProxy CRD is installed with the Envoy Gateway controller.
    lib.optionalAttrs haveProxy {
      envoyProxyCrd = scope.mkCRDRef {
        group = "gateway.envoyproxy.io";
        kind = "EnvoyProxy";
        plural = "envoyproxies";
        version = "v1alpha1";
        # A proxy configuration; the Gateway that uses it runs the pods.
        usesAtLeast = _: { };
      };

      envoyProxy = scope.mkCR self.envoyProxyCrd {
        name = "${name}-proxy";
        labels = selectorLabels;
        spec = config.proxySpec;
      };
    }
    // {
      # The CRDs arrive with the controller, outside Kix. The refs give each
      # CR its CRD-before-CR edge and carry the Gateway API's readiness
      # conditions: a GatewayClass is usable once Accepted=True, a Gateway
      # once Programmed=True. Neither kind sets Ready or Available.
      gatewayClassCrd = scope.mkCRDRef {
        group = gatewayApiGroup;
        kind = "GatewayClass";
        plural = "gatewayclasses";
        version = "v1";
        crdScope = "Cluster";
        usesAtLeast = _: { };
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

      root = {
        resource = self.gateway;
        # The gateway contract (kix/contracts/stable/gateway.nix), read by
        # kix.expose.
        out = kix.contracts.gateway.check "envoy-gateway ${scope.namespaceName}/${name}" {
          gatewayRef = {
            name = self.gateway.out.name;
            namespace = scope.namespaceName;
          };
          # kix.expose matches a route's host and namespace against these
          # to pick the URL scheme and port.
          listeners = activeListeners;
          podSelector = proxySelector;
          podNamespace = if proxySelector == null then null else config.proxyNamespace;
        };
      };
    };
}
