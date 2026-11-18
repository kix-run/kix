# envoy-gateway: one Gateway served by Envoy Gateway, with its own
# Envoy proxies and Service.
#
# Installs an EnvoyProxy and a Gateway, both named after the instance, and
# the network policy for the Gateway's proxies. The Gateway uses the
# GatewayClass of the envoy-gateway-controller instance and names the EnvoyProxy in
# `spec.infrastructure.parametersRef`, so each Gateway has its own proxy
# Deployment and Service, configured apart from every other Gateway's. With
# the optional `prometheus` dependency and `metrics.enabled`, it also adds
# a PodMonitor for the proxies and alerts.
#
# Dependencies:
#   envoyGateway (required)  the envoy-gateway-controller instance, which runs the
#                            controller and owns the GatewayClass.
#   gatewayApi (required)    the Gateway API CRDs, the role the gateway-api
#                            package claims. The Gateway is built from its
#                            `out.crds`.
#   prometheus (optional)    scrapes the proxies while `metrics.enabled`.
#
# Minimal instance, beside gateway-api and envoy-gateway-controller:
#
#   instances.envoy-gateway-system.gateway.package = packages.experimental.envoy-gateway;
#
# An instance lives in the envoy-gateway-controller instance's namespace, because the
# controller starts every Gateway's proxies there and the policies select
# them there. A cluster can run several instances, such as a public Gateway
# and a private one. Every instance answers the `gateway` alias by default,
# so with more than one, set `aliases = [ ]` on all but one and wire the
# packages that use those with `deps.gateway = ref.<namespace>.<instance>`.
#
# The controller creates the data plane. It starts an Envoy Deployment and
# a Service for the Gateway in its own namespace
# (internal/infrastructure/kubernetes/proxy/resource.go), from the
# EnvoyProxy the Gateway names. Kix renders that EnvoyProxy: the Envoy
# image the envoy-gateway-controller instance pins, the replica count from the
# availability level, a topology spread and a PodDisruptionBudget when
# there is more than one replica, and a NodePort Service when
# `cluster.roles.loadBalancer.binding` is "absent" (the kind flavour sets
# that). `proxySpec` adds to it. The proxies run as uid 65532 with every
# capability dropped, which the restricted Pod Security level admits. The
# Gateway is ready once the controller reports it Programmed, which needs
# an available proxy and, for a LoadBalancer Service, an address
# (internal/gatewayapi/status/gateway.go).
#
# Network policy: clients from outside the cluster and from every pod
# reach the proxies on their listener ports. The proxies reach every pod in
# the cluster, because HTTPRoutes name their backends at runtime, which
# includes the controller's xDS and Wasm ports. kix.expose admits the
# proxies to each exposed backend through `out.podSelector`.
#
# `out` (the gateway contract, kix.contracts.gateway):
#   out.gatewayRef    the Gateway, the parentRef of every HTTPRoute
#                     kix.expose renders.
#   out.listeners     the rendered listeners, from which kix.expose picks a
#                     route's URL scheme and port.
#   out.podSelector, out.podNamespace
#                     the proxy pods of the Gateway, for the policy
#                     kix.expose writes so they can reach each backend.
#   out.version       the Envoy Gateway version the controller runs.
#   out.crds.<Kind>   the envoy-gateway-controller instance's CRD handles for Envoy
#                     Gateway's policy kinds.
#
# Alerts: with a prometheus dependency and `metrics.enabled`, a
# PrometheusRule selects the PodMonitor's series.
#   EnvoyProxyDown (critical)         no proxy of the Gateway answers a
#                                     scrape, so the Gateway serves nothing.
#   EnvoyProxyControlPlaneLost        a proxy has lost its xDS connection to
#   (warning)                         the controller for 10 minutes.
# Fewer ready replicas than desired is left to prometheus-default-rules,
# and request errors and latency to the site's own objectives. The
# controller's alerts are the envoy-gateway-controller package's.
#
# Escape hatches: `proxySpec` (the EnvoyProxy spec), `listeners` and
# `addresses` (the Gateway's), the CRD handles on `out.crds`, and the
# instance's `partsOverlays`.
#
# Limits: under network policy, the proxies reach only pods in the
# cluster. A Backend with an FQDN or IP outside the cluster, and an
# external authorization or OIDC server, need a policy written outside Kix.
# A pod in the cluster reaches the proxies only if its own egress allows
# it, because the graph does not show which pods call the Gateway.
# `proxySpec.mergeGateways` is refused: it is a setting of a whole
# GatewayClass, and each instance runs its own proxies.

{
  scope,
  lib,
  kix,
  availability,
}:

let
  name = scope.instanceName;
  ns = scope.namespaceName;
  who = "envoy-gateway ${ns}/${name}";

  # The proxy's stats port (internal/xds/bootstrap/bootstrap.go).
  proxyStatsPort = 19001;

  gatewayListeners = import ./listeners.nix { inherit lib; };

  # Options of earlier releases of this package, when it also named the
  # controller, which Helm installed outside Kix.
  removedOptions = {
    controllerName = "Remove `controllerName` and add an `envoy-gateway-controller` instance in the same namespace, or set `package` to another Gateway API package such as `packages.experimental.traefik`.";
    proxyNamespace = "Remove `proxyNamespace`. Envoy proxy pods always run in the same namespace as `envoy-gateway-controller` and this instance.";
    gatewayClassName = "Remove `gatewayClassName`. The Gateway uses the `GatewayClass` created by `envoy-gateway-controller`.";
    gatewayName = "Remove `gatewayName`. The Gateway always uses the instance name.";
  };
in
{
  meta = {
    description = "A Gateway served by Envoy Gateway, with its own Envoy proxies and Service";
    owner = "platform";
    defaultAliases = [ "gateway" ];
    # One Gateway accepts HTTPRoutes from every namespace, so consumers in
    # any namespace find it by name.
    scope = "cluster";
  };

  assertions =
    { config, ... }:
    lib.mapAttrsToList (option: fix: {
      assertion = config.${option} == null;
      id = "K5531";
      inherit option fix;
      message = "option '${option}' was removed. envoy-gateway now creates a Gateway managed by the envoy-gateway-controller package.";
    }) removedOptions;

  options = {
    listeners = lib.mkOption {
      type = lib.types.listOf gatewayListeners.type;
      default = gatewayListeners.defaults;
      description = ''
        Gateway API v1 `Listener` entries for the Gateway's `spec.listeners`,
        with the upstream field names. An HTTPS listener with no
        `tls.certificateRefs` is a placeholder and is not rendered.

        For listener ports below 1024, Envoy binds to container port
        `port + 10000` (for example, port 80 maps to 10080) unless
        `proxySpec.provider.kubernetes.useListenerPortAsContainerPort` is
        `true`. When network policy is enabled, the package allows incoming
        client traffic to those container ports.
        kix.expose reads the rendered listeners: `protocol`, `hostname`,
        `port`, and `allowedRoutes.namespaces.from` decide whether an
        HTTPRoute can attach and which URL scheme and port it gets.
      '';
    };

    addresses = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            type = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "`IPAddress` (the Gateway API default), `Hostname`, or an implementation-specific type.";
            };
            value = lib.mkOption {
              type = lib.types.str;
              description = "Address value, such as an IP address for `IPAddress` or a DNS name for `Hostname`.";
            };
          };
        }
      );
      default = [ ];
      example = [
        {
          type = "IPAddress";
          value = "192.0.2.10";
        }
      ];
      description = "Addresses to request on the Gateway (`spec.addresses`), such as a static IP for the proxy `LoadBalancer` Service.";
    };

    proxySpec = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      example = lib.literalExpression ''
        {
          provider.kubernetes.envoyService.annotations."service.beta.kubernetes.io/aws-load-balancer-type" = "nlb";
          logging.level.default = "info";
        }
      '';
      description = ''
        EnvoyProxy `spec` fields (`gateway.envoyproxy.io/v1alpha1`) merged
        into this Gateway's `EnvoyProxy` resource.

        By default, the package sets `provider.type = "Kubernetes"`, the
        Envoy image from `envoy-gateway-controller` (`operandImages.envoy`), the
        replica count from the cluster's availability level
        (`provider.kubernetes.envoyDeployment.replicas`), pod topology spread
        constraints and a `PodDisruptionBudget` when running multiple
        replicas, and the proxy Service type (`NodePort` when
        `cluster.roles.loadBalancer.binding = "absent"`, or `LoadBalancer`
        otherwise).

        You can override the replica count, Service type, and other
        `EnvoyProxy` fields here. Kix rejects overrides to `provider.type`
        (must be `"Kubernetes"`),
        `provider.kubernetes.envoyDeployment.container.image` (set
        `operandImages.envoy` on `envoy-gateway-controller` instead),
        `provider.kubernetes.envoyDeployment.pod.topologySpreadConstraints`,
        and `mergeGateways`.
      '';
    };

    metrics = kix.options.monitor;
  }
  // lib.mapAttrs (
    _: fix:
    lib.mkOption {
      type = lib.types.unspecified;
      default = null;
      visible = false;
      description = "Removed. ${fix}";
    }
  ) removedOptions;

  build = [
    (
      {
        self,
        config,
        clusterConfig,
        envoyGateway ? null,
        gatewayApi ? null,
        prometheus ? null,
        ...
      }:
      let
        netpol = scope.networkPolicyEnforcer.netpol;

        # Without an instance, the refusal carries the change record's id,
        # because every cluster that used this package before the
        # controller moved out of it arrives here. A `kix.mkImport`
        # answering envoyGateway has none of the fields.
        controller =
          let
            out = envoyGateway.out or { };
          in
          if envoyGateway == null then
            scope.fail {
              id = "K5531";
              dependency = "envoyGateway";
              message = "this envoy-gateway instance requires the Envoy Gateway controller, but no envoy-gateway-controller instance in the cluster provides it. envoy-gateway creates a Gateway, while envoy-gateway-controller deploys the controller and GatewayClass.";
              fix = "Add `instances.${ns}.envoy-gateway-controller.package = packages.experimental.envoy-gateway-controller;`.";
            }
          else if
            out ? gatewayClassName
            && out ? namespace
            && out ? proxyImage
            && out ? proxyLabels
            && out ? version
            && (out.crds or { }) ? EnvoyProxy
          then
            out
          else
            scope.fail {
              dependency = "envoyGateway";
              message = "the 'envoyGateway' dependency is not an envoy-gateway-controller instance. envoy-gateway requires the envoy-gateway-controller package and cannot use kix.mkImport or another package in its place.";
              fix = "Add `instances.${ns}.envoy-gateway-controller.package = packages.experimental.envoy-gateway-controller;` and remove the `envoyGateway` alias from any other instance. If Envoy Gateway is installed outside Kix, replace this `envoy-gateway` instance with a `kix.mkImport { out.gatewayRef = { name = \"<gateway>\"; namespace = \"<namespace>\"; }; }` instance with `aliases = [ \"gateway\" ];`.";
            };

        inControllerNamespace =
          if controller.namespace == ns then
            true
          else
            scope.fail {
              message = "this envoy-gateway instance is in namespace \"${ns}\", but envoy-gateway-controller is in \"${controller.namespace}\". Both must be in the same namespace because Envoy Gateway runs all proxy pods in the controller's namespace.";
              fix = "Move this instance to namespace \"${controller.namespace}\", or move envoy-gateway-controller to the same namespace.";
            };

        activeListeners = gatewayListeners.active config.listeners;
        # Envoy runs unprivileged, so the controller moves a listener port
        # below 1024 up by 10000, unless proxySpec sets
        # useListenerPortAsContainerPort (servicePortToContainerPort in
        # internal/gatewayapi/listener.go).
        listenerPortIsContainerPort =
          proxyMerged.provider.kubernetes.useListenerPortAsContainerPort or false;
        containerPort = port: if port < 1024 && !listenerPortIsContainerPort then port + 10000 else port;
        frontDoorPorts = lib.unique (
          map (l: {
            port = containerPort l.port;
            protocol = if l.protocol == "UDP" then "UDP" else "TCP";
          }) activeListeners
        );

        loadBalancerBinding = ((clusterConfig.cluster.roles or { }).loadBalancer or { }).binding or null;
        loadBalancerAbsent = loadBalancerBinding == "absent";
        proxyBase = {
          provider = {
            type = "Kubernetes";
            kubernetes = {
              envoyDeployment = {
                replicas = kix.availability.pick availability {
                  none = 1;
                  pod = 2;
                  node = 2;
                  zone = 2;
                };
                container.image = controller.proxyImage;
              };
              envoyService.type = if loadBalancerAbsent then "NodePort" else "LoadBalancer";
            };
          };
        };
        # The Kubernetes provider is the only one that runs proxies in a
        # cluster, and the controller's roles and the policies assume it.
        proxyProviderType = config.proxySpec.provider.type or "Kubernetes";
        proxyMerged =
          if proxyProviderType != "Kubernetes" then
            scope.fail {
              option = "proxySpec.provider.type";
              message = "proxySpec.provider.type is \"${toString proxyProviderType}\", which this package does not support. Envoy Gateway only deploys in-cluster proxy pods when provider.type is \"Kubernetes\".";
              fix = "Remove proxySpec.provider.type (it defaults to \"Kubernetes\").";
            }
          else if config.proxySpec ? mergeGateways then
            scope.fail {
              id = "K5531";
              option = "proxySpec.mergeGateways";
              message = "proxySpec.mergeGateways is not supported on envoy-gateway. Each envoy-gateway instance creates its own Envoy proxies, Service, and network policies for a single Gateway instead of sharing one proxy Deployment across the GatewayClass.";
              fix = "Remove proxySpec.mergeGateways.";
            }
          else
            kix.mergeGuarded {
              inherit who;
              what = "proxySpec";
              locked = [
                [
                  "provider"
                  "kubernetes"
                  "envoyDeployment"
                  "container"
                  "image"
                ]
                [
                  "provider"
                  "kubernetes"
                  "envoyDeployment"
                  "pod"
                  "topologySpreadConstraints"
                ]
              ];
            } proxyBase config.proxySpec;
        proxyReplicas = proxyMerged.provider.kubernetes.envoyDeployment.replicas or 1;
        proxyServiceType = proxyMerged.provider.kubernetes.envoyService.type or "LoadBalancer";

        # The pods of this Gateway (internal/gatewayapi/helpers.go).
        proxySelector = controller.proxyLabels // {
          "gateway.envoyproxy.io/owning-gateway-name" = name;
          "gateway.envoyproxy.io/owning-gateway-namespace" = ns;
        };

        proxySpread = lib.optionalAttrs (proxyReplicas > 1) {
          provider.kubernetes = {
            envoyDeployment.pod.topologySpreadConstraints = kix.availability.spreadConstraints {
              level = availability;
              selector = proxySelector;
              topology = clusterConfig.cluster.topology;
            };
          }
          # A PodDisruptionBudget the user sets in proxySpec replaces this one,
          # since one cannot hold both minAvailable and maxUnavailable.
          // lib.optionalAttrs (!(proxyMerged.provider.kubernetes ? envoyPDB)) {
            envoyPDB.minAvailable = 1;
          };
        };
        proxySpec = lib.recursiveUpdate proxyMerged proxySpread;

        gatewayCrds = kix.contracts.experimental.gatewayApi.helpers.crdsFor {
          who = "${ns}/${name}";
          inherit gatewayApi;
          kinds = [ "Gateway" ];
          # The Gateway API release Envoy Gateway 1.10 is built against
          # (go.mod and site/content/en/news/releases/matrix.md upstream).
          minVersion = "1.6";
        };
      in
      {
        proxyPodMonitor =
          if config.metrics.enabled && prometheus != null then
            prometheus.out.mkPodMonitor scope {
              name = "${name}-proxy";
              labels = scope.selectorLabels;
              spec = {
                selector.matchLabels = proxySelector;
                podMetricsEndpoints = [
                  (
                    {
                      portNumber = proxyStatsPort;
                      path = "/stats/prometheus";
                    }
                    // lib.optionalAttrs (config.metrics.interval != null) { inherit (config.metrics) interval; }
                  )
                ];
              };
              requires = [ self.gateway ];
            }
          else
            null;

        proxyIngress =
          if frontDoorPorts == [ ] then
            null
          else
            kix.operandPolicy {
              inherit scope;
              name = "${name}-proxy-ingress";
              spec = {
                endpointSelector.matchLabels = proxySelector;
                ingress =
                  (netpol.translateIntentRules {
                    intents.front-door.ingress = [
                      {
                        from = "world";
                        ports = frontDoorPorts;
                      }
                      {
                        from = "all-pods";
                        ports = frontDoorPorts;
                      }
                    ];
                  }).ingressRules;
              };
            };

        # HTTPRoutes name their backends at runtime, on any port, so the
        # graph cannot see the proxies' upstream connections. The `pods`
        # target reaches every pod, including the controller's xDS and Wasm
        # ports, and leaves out the nodes and the API server.
        proxyEgress = kix.operandPolicy {
          inherit scope;
          name = "${name}-proxy-egress";
          spec = {
            endpointSelector.matchLabels = proxySelector;
            egress = [
              netpol.dnsEgressRule
            ]
            ++ (netpol.translateIntentRules {
              intents.backends.egress = [ { to = "pods"; } ];
            }).egressRules;
          };
        };

        envoyProxy =
          builtins.seq inControllerNamespace (
            scope.mkCR controller.crds.EnvoyProxy {
              inherit name;
              labels = scope.selectorLabels;
              spec = proxySpec;
            }
          )
          // {
            _warnings = lib.optional (loadBalancerBinding == null && proxyServiceType == "LoadBalancer") {
              clusterOption = "cluster.roles.loadBalancer.binding";
              message = "cluster.roles.loadBalancer.binding is not set, so Kix configured EnvoyProxy '${ns}/${name}' with a LoadBalancer Service for Gateway '${ns}/${name}'. If the cluster has no load balancer controller, that Service will never get an address, Gateway '${ns}/${name}' will never become Programmed, and `kix deploy` will time out.";
              fix = "Set `cluster.roles.loadBalancer.binding = \"shadowable\";` if the cluster provides a load balancer, or `\"absent\";` so Kix configures a NodePort Service instead.";
            };
          };

        gateway =
          if activeListeners == [ ] then
            scope.fail {
              option = "listeners";
              message = "Gateway '${ns}/${name}' has no active listeners; Kubernetes requires at least one listener on a Gateway. Kix omits HTTPS listeners that have an empty `tls.certificateRefs` list.";
              fix = "Add an active listener in `config.listeners`, or set `tls.certificateRefs` on an HTTPS listener.";
            }
          else
            scope.mkCR gatewayCrds.Gateway {
              inherit name;
              labels = scope.selectorLabels;
              # The proxies need their network policy to become ready.
              requires = builtins.filter (p: p != null) [
                self.proxyIngress
                self.proxyEgress
              ];
              spec = {
                # The class name carries the envoy-gateway-controller instance's
                # context, so the Gateway waits for the controller.
                gatewayClassName = controller.gatewayClassName;
                infrastructure.parametersRef = {
                  group = "gateway.envoyproxy.io";
                  kind = "EnvoyProxy";
                  name = self.envoyProxy.out.name;
                };
                listeners = activeListeners;
              }
              // lib.optionalAttrs (config.addresses != [ ]) {
                addresses = map (lib.filterAttrs (_: v: v != null)) config.addresses;
              };
            };

        root = {
          resource = self.gateway;
          out = kix.contracts.gateway.check who {
            gatewayRef = {
              name = self.gateway.out.name;
              namespace = ns;
            };
            listeners = activeListeners;
            # Raw labels: the reader writes a policy selector from them and
            # already depends on this instance through gatewayRef.
            podSelector = proxySelector;
            podNamespace = ns;
            inherit (controller) version crds;
          };
        };
      }
    )

    ./alerts.nix
  ];
}
