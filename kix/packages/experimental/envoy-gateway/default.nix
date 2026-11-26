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
#   clusterIssuer (optional) one cluster-issuer instance, or a list of them
#                            (`deps.clusterIssuer = [ ref... ]`). Each
#                            HTTPS listener that sets no
#                            `tls.certificateRefs` gets a Certificate from
#                            one of them, chosen by `listenerIssuers`.
#   prometheus (optional)    scrapes the proxies while `metrics.enabled`.
#
# Minimal instance, beside gateway-api and envoy-gateway-controller:
#
#   instances.envoy-gateway-system.gateway.package = packages.experimental.envoy-gateway;
#
# An instance lives in any namespace, and the controller starts the
# Gateway's proxies there. A cluster can run several instances, such as a
# public Gateway and a private one, each in a namespace of its own. Every
# instance answers the `gateway` alias by default, so with more than one,
# set `aliases = [ ]` on all but one and wire the packages that use those
# with `deps.gateway = ref.<namespace>.<instance>`.
#
# The controller creates the data plane. It starts an Envoy Deployment, a
# Service, a ServiceAccount, and a ConfigMap, all named after the Gateway,
# in this namespace (internal/infrastructure/kubernetes/proxy/resource.go),
# from the EnvoyProxy the Gateway names. The package grants the controller
# a Role here for that (`<instance>-envoy-gateway-infra`). Kix renders the
# EnvoyProxy: the Envoy image the envoy-gateway-controller instance pins,
# the replica count from the availability level, a topology spread and a
# PodDisruptionBudget when there is more than one replica, and a NodePort
# Service when `cluster.roles.loadBalancer.binding` is "absent" (the kind
# flavour sets that). `proxySpec` adds to it. The proxies run as uid 65532
# with every capability dropped, which the restricted Pod Security level
# admits. The Gateway is ready once the controller reports it Programmed,
# which needs an available proxy and, for a LoadBalancer Service, an
# address (internal/gatewayapi/status/gateway.go).
#
# Listener certificates: with a clusterIssuer dependency, the package
# writes a cert-manager Certificate `<instance>-<listener>` in this
# namespace for the `hostname` of every HTTPS listener that names no
# Secret, and the listener serves its Secret. The Gateway waits for the
# Certificate. An ACME issuer needs a dns01 solver, because the package
# does not route HTTP-01 challenges through the Gateway.
#
# Tenants: give each domain its own HTTPS listener and admit only that
# tenant's namespaces, with the Gateway API's own fields:
#   allowedRoutes.namespaces = {
#     from = "Selector";
#     selector.matchLabels."kubernetes.io/metadata.name" = "tenant-a";
#   };
# A route from another namespace then cannot attach to the listener.
#
# Policies: `clientTrafficPolicy` and `securityPolicy` are the specs of an
# Envoy Gateway ClientTrafficPolicy and SecurityPolicy that the package
# targets at the Gateway. The first holds the TLS minimum version, whose
# X-Forwarded-For the Gateway believes, HTTP/2, and headers added to every
# response, such as Strict-Transport-Security. The second holds a
# source-address allow-list. `httpsRedirect` answers every request on the
# HTTP listeners with a redirect to HTTPS. Access logs go to the proxies'
# stdout as JSON unless `proxySpec.telemetry.accessLog` says otherwise.
#
# The proxy Service: `proxySpec.provider.kubernetes.envoyService` sets its
# `type`, `labels`, and `annotations`, which is where a load balancer's
# address pool and pinned address go. Envoy Gateway sets
# `externalTrafficPolicy: Local` unless it is set there, so a node with no
# proxy drops the traffic a load balancer sends it; set `Cluster` where one
# node answers for the address, or run a proxy on every such node. With
# `type = "ClusterIP"`, the first of the Gateway's `addresses` becomes the
# Service's cluster IP (internal/infrastructure/kubernetes/proxy/resource_provider.go).
#
# Network policy: the clients in `clientSources`, by default every address
# outside the cluster and every pod, reach the proxies on their listener
# ports. The proxies reach every pod in
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
#   out.public        false when the proxy Service is a ClusterIP, so the
#                     Gateway cannot be reached from outside the cluster,
#                     and true otherwise.
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
# Escape hatches: `proxySpec` (the EnvoyProxy spec), `clientTrafficPolicy`
# and `securityPolicy` (the policies' specs), `listeners` and `addresses`
# (the Gateway's), the CRD handles on `out.crds`, and the instance's
# `partsOverlays`.
#
# Limits: under network policy, the proxies reach only pods in the
# cluster. A Backend with an FQDN or IP outside the cluster, and an
# external authorization or OIDC server, need a policy written outside Kix.
# A pod in the cluster reaches the proxies only if its own egress allows
# it, because the graph does not show which pods call the Gateway.
# `proxySpec.mergeGateways` is refused: it is a setting of a whole
# GatewayClass, and each instance runs its own proxies. The proxy
# Deployment, Service, ServiceAccount, and ConfigMap take the instance's
# name, so no other object of those kinds in the namespace may have it.

{
  scope,
  lib,
  kix,
  availability,
}:

let
  name = scope.instanceName;
  ns = scope.namespaceName;

  # The proxy's stats port (internal/xds/bootstrap/bootstrap.go).
  proxyStatsPort = 19001;

  gatewayListeners = import ./listeners.nix { inherit lib; };

  # Options of earlier releases of this package, when it also named the
  # controller, which Helm installed outside Kix.
  removedOptions = {
    controllerName = "Remove `controllerName` and add an `envoy-gateway-controller` instance, or set `package` to another Gateway API package such as `packages.experimental.traefik`.";
    proxyNamespace = "Remove `proxyNamespace`. Envoy proxy pods always run in this instance's namespace.";
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

    listenerIssuers = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = {
        example-com = "letsencrypt-example-com";
      };
      description = ''
        Map of HTTPS listener name to `ClusterIssuer` name for automatic TLS
        certificates. Each value must match a `cluster-issuer` instance wired
        to `clusterIssuer`. When only one issuer is wired, HTTPS listeners
        omitted here use it automatically.

        When a `clusterIssuer` dependency is present, the package creates a
        cert-manager `Certificate` for each HTTPS listener without
        `tls.certificateRefs` (using the listener's `hostname`) and attaches
        the generated `Secret` to the listener.
      '';
    };

    clientTrafficPolicy = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      example = lib.literalExpression ''
        {
          clientIPDetection.xForwardedFor.trustedCIDRs = [ "192.0.2.0/24" ];
          tls.minVersion = "1.3";
          headers.lateResponseHeaders.set = [
            {
              name = "Strict-Transport-Security";
              value = "max-age=31536000; includeSubDomains";
            }
          ];
        }
      '';
      description = ''
        Envoy Gateway `ClientTrafficPolicy` `spec` fields
        (`gateway.envoyproxy.io/v1alpha1`) configuring how the proxies handle
        client connections across all listeners. When non-empty, the package
        creates a `ClientTrafficPolicy` attached to this `Gateway`. Kix rejects
        `targetRef`, `targetRefs`, and `targetSelectors`.

        Common settings: `clientIPDetection.xForwardedFor.trustedCIDRs` lists
        upstream proxy or CDN IP ranges whose `X-Forwarded-For` header the
        Gateway trusts; `tls.minVersion` sets the minimum TLS version (defaults
        to `"1.2"`); `tls.alpnProtocols = [ "http/1.1" ]` disables HTTP/2; and
        `headers.lateResponseHeaders` adds response headers across all routes on
        the Gateway.
      '';
    };

    securityPolicy = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      example = lib.literalExpression ''
        {
          authorization = {
            defaultAction = "Deny";
            rules = [
              {
                action = "Allow";
                principal.clientCIDRs = [ "10.0.0.0/8" ];
              }
            ];
          };
        }
      '';
      description = ''
        Envoy Gateway `SecurityPolicy` `spec` fields
        (`gateway.envoyproxy.io/v1alpha1`) applied to every route on this
        `Gateway` unless overridden by a route-level policy. When non-empty,
        the package creates a `SecurityPolicy` attached to this `Gateway`. Kix
        rejects `targetRef`, `targetRefs`, and `targetSelectors`.

        Use `authorization` with `principal.clientCIDRs` to restrict access by
        client IP range. Envoy Gateway evaluates the connection's source IP, or
        the client IP extracted via `clientTrafficPolicy.clientIPDetection`
        from a trusted proxy.
      '';
    };

    httpsRedirect = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Redirect all requests on the Gateway's HTTP listeners to HTTPS with a
        301 status code. The package attaches a redirect `HTTPRoute` to each
        HTTP listener and sets `allowedRoutes.namespaces.from = "Same"` on
        HTTP listeners so routes from other namespaces attach only to HTTPS
        listeners. Requires at least one HTTP listener and one active HTTPS
        listener.
      '';
    };

    clientSources = lib.mkOption {
      type = lib.types.listOf (
        lib.types.enum [
          "world"
          "all-pods"
        ]
      );
      default = [
        "world"
        "all-pods"
      ];
      example = [ "all-pods" ];
      description = ''
        Traffic sources that the network policy allows to reach the proxies'
        listener ports: `"world"` allows external IP addresses outside the
        cluster, and `"all-pods"` allows all pods and cluster nodes. Omit
        `"world"` (for example, `[ "all-pods" ]`) on an internal Gateway. Any
        `securityPolicy` IP allowlist runs after the network policy.

        Clients need `"world"` when they reach the Gateway through a router
        that rewrites their source to an address other than a pod or node
        IP, as some VPN subnet routers do.
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
        clusterIssuer ? null,
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
              fix = "Add `instances.envoy-gateway-system.envoy-gateway-controller.package = packages.experimental.envoy-gateway-controller;`.";
            }
          else if
            out ? gatewayClassName
            && out ? namespace
            && out ? proxyImage
            && out ? proxyLabels
            && out ? serviceAccount
            && out ? infraManagerRules
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

        # The wired issuers, by ClusterIssuer name. deps.clusterIssuer takes
        # one instance or a list.
        issuers =
          let
            wired =
              if clusterIssuer == null then
                [ ]
              else if builtins.isList clusterIssuer then
                clusterIssuer
              else
                [ clusterIssuer ];
            nameOf =
              issuer:
              if (issuer.out or { }) ? mkCertificate && (issuer.out or { }) ? name then
                builtins.unsafeDiscardStringContext issuer.out.name
              else
                scope.fail {
                  dependency = "clusterIssuer";
                  message = "the 'clusterIssuer' dependency does not provide `out.mkCertificate` (for example, because it uses `kix.mkImport`), so `envoy-gateway` cannot create listener `Certificate` resources from it.";
                  fix = "Use `packages.experimental.cluster-issuer` for `clusterIssuer`, or set `tls.certificateRefs` on every HTTPS listener and remove `deps.clusterIssuer`.";
                };
          in
          lib.listToAttrs (map (issuer: lib.nameValuePair (nameOf issuer) issuer) wired);
        issuerNames = builtins.attrNames issuers;

        needsCertificate =
          l:
          l.protocol == "HTTPS"
          && (l.tls == null || l.tls.certificateRefs == null || l.tls.certificateRefs == [ ]);
        certificateName = l: "${name}-${l.name}";

        # The issuer of a listener's certificate, or the reason it has none.
        issuerFor =
          l:
          let
            chosen = config.listenerIssuers.${l.name} or null;
            wildcard = lib.hasPrefix "*." l.hostname;
            issuer = if chosen != null then issuers.${chosen} or null else issuers.${builtins.head issuerNames};
          in
          if l.hostname == null then
            {
              error = "HTTPS listener \"${l.name}\" has no `hostname`, so Kix cannot request a TLS certificate for it. Set `hostname` on the listener, or set `tls.certificateRefs` to an existing TLS Secret.";
            }
          else if chosen == null && builtins.length issuerNames != 1 then
            {
              error = "HTTPS listener \"${l.name}\" needs a certificate, but ${toString (builtins.length issuerNames)} ClusterIssuers are wired (${lib.concatStringsSep ", " issuerNames}) and none is selected for this listener. Set `listenerIssuers.${l.name}` to one of them.";
            }
          else if issuer == null then
            {
              error = "`listenerIssuers.${l.name}` is set to \"${chosen}\", which is not in `deps.clusterIssuer` (wired issuers: ${
                if issuerNames == [ ] then "none" else lib.concatStringsSep ", " issuerNames
              }). Add that `cluster-issuer` instance to `deps.clusterIssuer`, or change `listenerIssuers` to a wired issuer.";
            }
          else if issuer.out.needsHttp01 or false then
            {
              error = "HTTPS listener \"${l.name}\" uses ClusterIssuer \"${issuer.out.name}\", which is an ACME issuer without a `dns01` solver. `envoy-gateway` does not route ACME HTTP-01 challenges through the Gateway${lib.optionalString wildcard ", and a wildcard name such as \"${l.hostname}\" cannot be issued that way"}. Switch to a ClusterIssuer with a `dns01` solver, or set `tls.certificateRefs` to an existing TLS Secret.";
            }
          else
            { inherit issuer; };

        certificateListeners =
          if issuers == { } then [ ] else builtins.filter needsCertificate config.listeners;
        unknownListenerIssuers = builtins.filter (
          n: !(builtins.any (l: l.name == n) certificateListeners)
        ) (builtins.attrNames config.listenerIssuers);
        certificateErrors =
          lib.concatMap (
            l:
            let
              found = issuerFor l;
            in
            lib.optional (found ? error) found.error
          ) certificateListeners
          ++ map (
            n:
            "`listenerIssuers.${n}` does not match an HTTPS listener that needs a managed certificate (matching listeners: ${
              if certificateListeners == [ ] then
                "none"
              else
                lib.concatMapStringsSep ", " (l: l.name) certificateListeners
            }). Remove that entry from `listenerIssuers`, or ensure the listener uses `protocol = \"HTTPS\"` without `tls.certificateRefs` and that `clusterIssuer` is wired."
          ) unknownListenerIssuers;

        # Listeners with the certificate filled in, and, with httpsRedirect,
        # the HTTP ones closed to routes of other namespaces.
        withCertificate =
          l:
          if issuers != { } && needsCertificate l then
            l
            // {
              tls = (if l.tls == null then { } else l.tls) // {
                mode = "Terminate";
                certificateRefs = [
                  {
                    group = "";
                    kind = "Secret";
                    name = self.certificates.${l.name}.out.name;
                  }
                ];
              };
            }
          else
            l;
        withRedirect =
          l:
          if config.httpsRedirect && l.protocol == "HTTP" then
            l // { allowedRoutes.namespaces.from = "Same"; }
          else
            l;
        # Raised by whichever of the listeners and the Certificates is read
        # first.
        certificatesChecked =
          if certificateErrors == [ ] then
            true
          else
            scope.fail (
              map (message: {
                option = "listeners";
                inherit message;
              }) certificateErrors
            );
        activeListeners = builtins.seq certificatesChecked gatewayListeners.active (
          map (l: withRedirect (withCertificate l)) config.listeners
        );
        httpListeners = builtins.filter (l: l.protocol == "HTTP") activeListeners;
        hasHttps = builtins.any (l: l.protocol == "HTTPS") activeListeners;

        # A policy's spec, with the target the package owns.
        policySpec =
          what: spec:
          kix.mergeGuarded
            {
              inherit scope;
              option = what;
              locked = [
                [ "targetRef" ]
                [ "targetRefs" ]
                [ "targetSelectors" ]
              ];
            }
            {
              targetRefs = [
                {
                  group = "gateway.networking.k8s.io";
                  kind = "Gateway";
                  inherit name;
                }
              ];
            }
            spec;
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
              inherit scope;
              option = "proxySpec";
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
          inherit scope;
          inherit gatewayApi;
          kinds = [
            "Gateway"
            "HTTPRoute"
          ];
          # The Gateway API release Envoy Gateway 1.10 is built against
          # (go.mod and site/content/en/news/releases/matrix.md upstream).
          minVersion = "1.6";
        };
      in
      {
        # The controller creates this Gateway's proxy Deployment, Service,
        # ServiceAccount, and ConfigMap in this namespace, and this Role is
        # what lets it. Its own ClusterRole only reads them.
        infraRole = scope.rbac.mkRoleSet scope {
          subjects = [
            {
              kind = "ServiceAccount";
              inherit (controller.serviceAccount) name namespace;
            }
          ];
          labels = scope.selectorLabels;
          roles."${name}-envoy-gateway-infra" = controller.infraManagerRules;
        };

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
          if frontDoorPorts == [ ] || config.clientSources == [ ] then
            null
          else
            kix.operandPolicy {
              inherit scope;
              name = "${name}-proxy-ingress";
              selector = proxySelector;
              ingress =
                (netpol.translateIntentRules {
                  # `"all-pods"` in clientSources admits the nodes too (NodePort
                  # and load balancer traffic SNATed from a node), so it maps
                  # to the `cluster` entity.
                  intents.front-door.ingress = map (
                    source:
                    {
                      ports = frontDoorPorts;
                    }
                    // (
                      if source == "all-pods" then
                        {
                          from = "world";
                          entities = [ "cluster" ];
                        }
                      else
                        { from = source; }
                    )
                  ) config.clientSources;
                }).ingressRules;
            };

        # HTTPRoutes name their backends at runtime, on any port, so the
        # graph cannot see the proxies' upstream connections. The `pods`
        # target reaches every pod, including the controller's xDS and Wasm
        # ports, and leaves out the nodes and the API server.
        proxyEgress = kix.operandPolicy {
          inherit scope;
          name = "${name}-proxy-egress";
          selector = proxySelector;
          egress = [
            netpol.dnsEgressRule
          ]
          ++ (netpol.translateIntentRules {
            intents.backends.egress = [ { to = "pods"; } ];
          }).egressRules;
        };

        # One Certificate per HTTPS listener that names no Secret of its own.
        certificates = builtins.seq certificatesChecked lib.listToAttrs (
          map (
            l:
            lib.nameValuePair l.name (
              (issuerFor l).issuer.out.mkCertificate scope {
                name = certificateName l;
                dnsNames = [ l.hostname ];
              }
            )
          ) certificateListeners
        );

        clientTrafficPolicy =
          if config.clientTrafficPolicy == { } then
            null
          else
            scope.mkCR controller.crds.ClientTrafficPolicy {
              inherit name;
              labels = scope.selectorLabels;
              spec = policySpec "clientTrafficPolicy" config.clientTrafficPolicy;
            };

        securityPolicy =
          if config.securityPolicy == { } then
            null
          else
            scope.mkCR controller.crds.SecurityPolicy {
              inherit name;
              labels = scope.selectorLabels;
              spec = policySpec "securityPolicy" config.securityPolicy;
            };

        # Attached to the HTTP listeners by name, which admit routes of this
        # namespace only, so no application route competes with it.
        httpsRedirect =
          if !config.httpsRedirect then
            null
          else if httpListeners == [ ] || !hasHttps then
            scope.fail {
              option = "httpsRedirect";
              message = "`httpsRedirect` is `true`, but this Gateway has ${
                if hasHttps then "no HTTP listener to redirect from" else "no HTTPS listener to redirect to"
              }. Kix omits HTTPS listeners that have neither `tls.certificateRefs` nor a `clusterIssuer` dependency.";
              fix = "Configure an HTTP listener and an HTTPS listener with a certificate (`tls.certificateRefs` or `deps.clusterIssuer`), or set `httpsRedirect = false`.";
            }
          else
            scope.mkCR gatewayCrds.HTTPRoute {
              name = "${name}-https-redirect";
              labels = scope.selectorLabels;
              spec = {
                parentRefs = map (l: {
                  name = self.gateway.out.name;
                  sectionName = l.name;
                }) httpListeners;
                rules = [
                  {
                    filters = [
                      {
                        type = "RequestRedirect";
                        requestRedirect = {
                          scheme = "https";
                          statusCode = 301;
                        };
                      }
                    ];
                  }
                ];
              };
            };

        envoyProxy =
          scope.mkCR controller.crds.EnvoyProxy {
            inherit name;
            labels = scope.selectorLabels;
            spec = proxySpec;
          }
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
              # The controller needs the Role to create the proxies, and the
              # proxies need their network policy to become ready.
              # The policies come first, so the Gateway never serves without
              # an allow-list or a TLS floor it was given. Each listener
              # names its Certificate's Secret, which already makes the
              # Gateway wait for the Certificate.
              requires =
                builtins.attrValues self.infraRole
                ++ builtins.filter (p: p != null) [
                  self.proxyIngress
                  self.proxyEgress
                  self.clientTrafficPolicy
                  self.securityPolicy
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
          requires = builtins.filter (p: p != null) [ self.httpsRedirect ];
          out = kix.contracts.gateway.check scope {
            gatewayRef = {
              name = self.gateway.out.name;
              namespace = ns;
            };
            listeners = activeListeners;
            # Raw labels: the reader writes a policy selector from them and
            # already depends on this instance through gatewayRef.
            podSelector = proxySelector;
            podNamespace = ns;
            # A ClusterIP Service is reachable from inside the cluster
            # only. Any other type may be reachable from the internet,
            # whatever allow-list the Gateway carries.
            public = proxyServiceType != "ClusterIP";
            inherit (controller) version crds;
          };
        };
      }
    )

    ./alerts.nix
  ];
}
