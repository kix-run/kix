# envoy-gateway: Envoy Gateway, a Gateway API implementation whose
# controller runs Envoy proxies for each Gateway, and one GatewayClass and
# Gateway that routes reach it through.
#
# Installs Envoy Gateway's own CRDs (gateway.envoyproxy.io, crds/, vendored
# from the release's envoy-gateway-crds.yaml); the controller Deployment, its
# ServiceAccount, ConfigMap, and Service; its roles (rbac/, vendored from the
# release's install.yaml); the certgen Job that writes the control plane's
# certificates; the topology injector's MutatingWebhookConfiguration; and a
# GatewayClass, an EnvoyProxy, and a Gateway named after the instance. With
# the optional `prometheus` dependency and `metrics.enabled`, it also adds a
# metrics Service, a ServiceMonitor for the controller, a PodMonitor for the
# proxies, and alerts.
#
# Dependencies:
#   gatewayApi (required)   the Gateway API CRDs (1.6 or later), the role
#                           the gateway-api package claims. The
#                           GatewayClass and Gateway are built from its
#                           `out.crds`.
#   prometheus (optional)   scrapes the controller and the proxies while
#                           `metrics.enabled`.
#
# Minimal instance:
#
#   instances.envoy-gateway-system.gateway-api.package = packages.experimental.gateway-api;
#   instances.envoy-gateway-system.envoy-gateway.package = packages.experimental.envoy-gateway;
#
# A cluster runs one instance (`conflictsWith`). The controller watches
# Gateway API objects in every namespace, the CRDs are cluster-wide, and
# Envoy Gateway fixes the names of its Service and certificate Secrets. The
# controller's Deployment, ServiceAccount, Service, and ConfigMap are named
# envoy-gateway (the ConfigMap envoy-gateway-config), because the controller
# looks them up by those names; the GatewayClass, EnvoyProxy, and Gateway
# take the instance name.
#
# The controller creates the data plane. For each Gateway it starts an
# Envoy Deployment and a Service in the controller's namespace
# (internal/infrastructure/kubernetes/proxy/resource.go), from the
# EnvoyProxy the GatewayClass names. Kix renders that EnvoyProxy: the Envoy
# image, the replica count from the availability level, a topology spread
# and a PodDisruptionBudget when there is more than one replica, and a
# NodePort Service when `cluster.roles.loadBalancer.binding` is "absent"
# (the kind flavour sets that). `proxySpec` adds to it. The proxies run as
# uid 65532 with every capability dropped, which the restricted Pod
# Security level admits. The Gateway is ready once the controller reports
# it Programmed, which needs an available proxy and, for a LoadBalancer
# Service, an address (internal/gatewayapi/status/gateway.go).
#
# The controller and the proxies talk over mutual TLS. The certgen Job
# (`envoy-gateway certgen`) writes the CA and the certificates into the
# Secrets envoy-gateway, envoy, envoy-rate-limit, and envoy-oidc-hmac in the
# instance's namespace, and the CA into the topology injector's webhook.
# It leaves existing Secrets alone, so it can run again
# (internal/cmd/certgen.go). The certificates are valid for five years
# (internal/crypto/certgen.go) and nothing renews them. Delete the four
# Secrets and run the Job again to renew them.
#
# Leader election is on, as upstream ships it. Every replica serves xDS to
# the proxies, and the leader writes status and the proxy Deployments. The
# controller runs one replica at availability none and pod, and two from
# node up. The proxies keep their last configuration while the controller
# is down.
#
# The topology injector, a mutating webhook on pods/binding in the
# controller's namespace, copies the node's zone onto each proxy pod for
# zone-aware routing. Its failurePolicy is Ignore, so a pod binds while the
# webhook is down.
#
# Network policy: the API server reaches the topology injector on TCP 9443
# (`meta.network.intents.webhook`, which also opens that port on the
# certgen Job's pod, where nothing listens). The rest is built from the
# configuration: clients from outside the cluster and from every pod reach
# the proxies on their listener ports; the proxies reach the controller's
# xDS (18000) and Wasm (18002) ports and every pod in the cluster, because
# HTTPRoutes name their backends at runtime. kix.expose admits the proxies
# to each exposed backend through `out.podSelector`.
#
# `out` (the gateway contract, kix.contracts.gateway):
#   out.gatewayRef    the Gateway, the parentRef of every HTTPRoute
#                     kix.expose renders.
#   out.listeners     the rendered listeners, from which kix.expose picks a
#                     route's URL scheme and port.
#   out.podSelector, out.podNamespace
#                     the proxy pods of the Gateway, for the policy
#                     kix.expose writes so they can reach each backend.
#   out.version       the Envoy Gateway version `image.tag` names.
#   out.crds.<Kind>   CRD handles for Envoy Gateway's policy kinds:
#                     Backend, BackendTrafficPolicy, ClientTrafficPolicy,
#                     EnvoyExtensionPolicy, EnvoyPatchPolicy, EnvoyProxy,
#                     HTTPRouteFilter, and SecurityPolicy.
#   out.extraImages   the Envoy and rate limit images the controller runs.
#
# Alerts: with a prometheus dependency and `metrics.enabled`, two
# PrometheusRules select the metrics Service's and the PodMonitor's series.
#   EnvoyGatewayDown (warning)        no controller replica answers a scrape.
#                                     The proxies keep their last
#                                     configuration, and no change to a
#                                     Gateway or route reaches them.
#   EnvoyGatewayConfigRejected        a proxy refused (NACKed) the
#   (warning)                         configuration the controller sent,
#                                     and keeps serving the previous one.
#   EnvoyGatewayProxyApplyFailing     the controller cannot create or
#   (warning)                         update a proxy Deployment, Service,
#                                     or other object it owns.
#   EnvoyProxyDown (critical)         no proxy of the Gateway answers a
#                                     scrape, so the Gateway serves nothing.
#   EnvoyProxyControlPlaneLost        a proxy has lost its xDS connection to
#   (warning)                         the controller for 10 minutes.
# Fewer ready replicas than desired is left to prometheus-default-rules,
# and request errors and latency to the site's own objectives.
#
# Escape hatches: `settings` (the EnvoyGateway configuration file),
# `proxySpec` (the EnvoyProxy spec), `listeners` and `addresses` (the
# Gateway's), the CRD handles on `out.crds`, and the instance's
# `partsOverlays`.
#
# Limits: under network policy, the proxies reach only pods in the
# cluster. A Backend with an FQDN or IP outside the cluster, an external
# authorization or OIDC server, and a Wasm module fetched by URL need a
# policy written outside Kix, as do the controller's own fetches (Wasm
# images, extension servers). A pod in the cluster reaches the proxies only
# if its own egress allows it, because the graph does not show which pods
# call the Gateway. Global rate limiting needs a Redis the package does not
# wire, and its rate limit Deployment gets no policy. GatewayNamespace mode
# and a namespace-scoped watch are refused, because the roles and the
# policies assume the proxies run in the controller's namespace and the
# controller watches the whole cluster. The instance has one Gateway, which
# is the one the gateway contract publishes. Another Gateway on the class
# gets proxies with no network policy, and nothing routes to it through
# kix.expose. The certgen Job writes Secrets Kix does not track, so
# `kix gc` and pruning leave them behind.
#
# Upgrades: from a release of this package that left the controller to
# Helm, uninstall the Helm release first, delete the certgen hook objects
# and the topology injector webhook that Helm leaves behind, and deploy
# once with `--force-conflicts`, because Helm keeps owning fields of the
# CRDs it installed. Helm installed the experimental Gateway API channel:
# experimental-only fields are dropped from stored objects, and the
# experimental-only CRDs stay until deleted. Proxies that ran in Helm's
# namespace are left running; delete them once the Gateway's new address
# serves, or before the deploy when `addresses` keeps the old one.
#
# Moving to another release: set `release` and the digest of `image`
# (`crane digest docker.io/envoyproxy/gateway:<release>`), set
# `operandImages` to the DefaultEnvoyProxyImage and DefaultRateLimitImage of
# that release (api/v1alpha1/shared_types.go), move the tag in
# crds/sources.txt and rbac/sources.txt, run
# `uv run scripts/vendor-crds.py envoy-gateway`, compare the Deployment,
# certgen Job, and webhook below with the release's charts/gateway-helm
# templates, and check the gateway-api package's release against the
# release's go.mod.

{
  scope,
  lib,
  kix,
  availability,
}:

let
  # meta.version, image.tag, and the tag in crds/sources.txt and
  # rbac/sources.txt.
  release = "v1.10.0";
  minorOf = tag: lib.versions.majorMinor (lib.removePrefix "v" tag);

  name = scope.instanceName;
  ns = scope.namespaceName;
  who = "envoy-gateway ${ns}/${name}";

  # The controller name Envoy Gateway's GatewayClass controller watches for
  # (api/v1alpha1/envoygateway_helpers.go).
  controllerName = "gateway.envoyproxy.io/gatewayclass-controller";

  # Names Envoy Gateway fixes. The proxies dial the controller at
  # envoy-gateway.<namespace> (internal/xds/bootstrap/bootstrap.go), certgen
  # issues the controller's certificate for that name and writes it to the
  # Secret envoy-gateway (internal/crypto/certgen.go,
  # internal/provider/kubernetes/secrets.go), and patches the webhook of
  # this name (internal/cmd/certgen.go).
  serviceName = "envoy-gateway";
  certSecretName = "envoy-gateway";
  # With rate limiting on, the controller reads the UIDs of its own
  # Deployment, ServiceAccount, and Service by this name
  # (internal/infrastructure/kubernetes/ratelimit_infra.go), so they all
  # take it. The ConfigMap and the certgen ServiceAccount follow the names
  # the controller reserves beside it
  # (internal/infrastructure/kubernetes/proxy/resource_provider.go).
  controllerName' = serviceName;
  webhookName = "envoy-gateway-topology-injector.${ns}";

  ports = {
    xds = 18000;
    rateLimitXds = 18001;
    wasm = 18002;
    metrics = 19001;
    health = 8081;
    webhook = 9443;
  };
  # The proxy's stats port (internal/xds/bootstrap/bootstrap.go).
  proxyStatsPort = 19001;

  controllerLabels = {
    "app.kubernetes.io/name" = "envoy-gateway";
    "app.kubernetes.io/instance" = name;
    "app.kubernetes.io/component" = "controller";
  };
  certgenLabels = controllerLabels // {
    "app.kubernetes.io/component" = "certgen";
  };

  # Labels Envoy Gateway puts on every proxy pod and rate limit pod it
  # creates (internal/infrastructure/kubernetes/proxy/resource.go,
  # internal/infrastructure/kubernetes/ratelimit/resource.go).
  proxyLabels = {
    "app.kubernetes.io/name" = "envoy";
    "app.kubernetes.io/component" = "proxy";
    "app.kubernetes.io/managed-by" = "envoy-gateway";
  };
  rateLimitLabels = {
    "app.kubernetes.io/name" = "envoy-ratelimit";
    "app.kubernetes.io/component" = "ratelimit";
    "app.kubernetes.io/managed-by" = "envoy-gateway";
  };

  gatewayListeners = import ./listeners.nix { inherit lib; };

  readJSON = file: builtins.fromJSON (builtins.readFile file);
  vendored = file: (readJSON ./crds/${file}).spec;

  # Options of earlier releases of this package, when it rendered only the
  # GatewayClass and Gateway for a controller installed outside Kix.
  removedOptions = {
    controllerName = "Remove `controllerName` to use Envoy Gateway, or switch `package` to another Gateway API package such as `packages.experimental.traefik`.";
    proxyNamespace = "Remove `proxyNamespace`. Envoy proxy pods now always run in this instance's namespace alongside the controller.";
    gatewayClassName = "Remove `gatewayClassName`. The GatewayClass now always uses the instance name.";
    gatewayName = "Remove `gatewayName`. The Gateway now always uses the instance name.";
  };

  # Paths of the EnvoyGateway configuration that the package writes or that
  # the roles and policies depend on.
  lockedSettings = [
    [ "gateway" ]
    [
      "provider"
      "type"
    ]
    [
      "provider"
      "kubernetes"
      "deploy"
    ]
    [
      "provider"
      "kubernetes"
      "watch"
    ]
    [
      "provider"
      "kubernetes"
      "shutdownManager"
    ]
    [
      "provider"
      "kubernetes"
      "rateLimitDeployment"
      "container"
      "image"
    ]
    [ "proxyTopologyInjector" ]
    # A default EnvoyProxy would sit beside the one the package renders;
    # set proxySpec instead.
    [ "envoyProxy" ]
  ];
in
{
  meta = {
    version = lib.removePrefix "v" release;
    description = "Envoy Gateway controller, Envoy proxy data plane, GatewayClass, and Gateway";
    owner = "platform";
    defaultAliases = [
      "gateway"
      "envoyGateway"
    ];
    conflictsWith = [ "cluster:envoyGateway" ];
    # One Gateway accepts HTTPRoutes from every namespace, so consumers in
    # any namespace find it by name.
    scope = "cluster";
    # Envoy Gateway 1.10 supports Kubernetes 1.34 to 1.37
    # (site/content/en/news/releases/matrix.md upstream).
    k8s.minVersion = "1.34";
    network.intents.webhook.ingress = [
      {
        from = "apiserver";
        ports = [
          {
            port = ports.webhook;
            protocol = "TCP";
          }
        ];
      }
    ];
  };

  assertions =
    { config, ... }:
    let
      imageTag = builtins.unsafeDiscardStringContext config.image.tag;
    in
    lib.mapAttrsToList (option: fix: {
      assertion = config.${option} == null;
      id = "K5531";
      inherit option fix;
      message = "option '${option}' was removed; envoy-gateway now deploys and configures the Envoy Gateway controller itself.";
    }) removedOptions
    ++ [
      {
        assertion = minorOf imageTag == minorOf release;
        option = "image.tag";
        message = "image.tag is \"${imageTag}\", which does not match Envoy Gateway ${minorOf release}. This package bundles CRDs and RBAC manifests from ${release}, so running a different minor version can fail at deploy or runtime.";
        fix = "Set image.tag to a v${minorOf release}.x release (and matching image.digest).";
      }
    ];

  options = {
    image = kix.options.image {
      repository = "docker.io/envoyproxy/gateway";
      tag = release;
      digest = "sha256:c2243d43518bed91d3ed8c2db849a4b7a14ac9b96eb019f2ab104bb1ca8572b1";
      description = "Container image for the Envoy Gateway controller, the certificate-generation Job, and the shutdown-manager sidecar in each proxy pod. Must be a v${minorOf release}.x release to match the bundled CRDs and RBAC.";
    };

    operandImages = {
      envoy = kix.options.image {
        repository = "docker.io/envoyproxy/envoy";
        tag = "distroless-v1.40.2";
        digest = "sha256:09ca6f2140a61ad8df11779a4a30d52b48433d444466328494f9188c9c35eded";
        description = "Container image for the Envoy proxy pods that the controller deploys for each Gateway. Defaults to the Envoy image shipped with Envoy Gateway ${release}.";
      };
      rateLimit = kix.options.image {
        repository = "docker.io/envoyproxy/ratelimit";
        tag = "5ae0682e";
        digest = "sha256:b95206e32b1a5f824fb06062fbb85bbdfb7f5de54135e92afe8462f22c979681";
        description = "Container image for the rate-limit service that the controller deploys when `settings.rateLimit` is configured. Defaults to the rate-limit image shipped with Envoy Gateway ${release}.";
      };
    };

    # The release's chart values. The controller's memory grows with the
    # number of Gateway API objects it translates.
    resources = kix.options.resources {
      requests = {
        cpu = "100m";
        memory = "256Mi";
      };
      limits.memory = "1024Mi";
    };

    # The release chart sets none. certgen generates four certificates and
    # exits.
    certgen.resources = kix.options.resources {
      requests = {
        cpu = "10m";
        memory = "32Mi";
      };
      limits.memory = "128Mi";
    };

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
        into the `EnvoyProxy` resource for this `GatewayClass`.

        By default, the package sets `provider.type = "Kubernetes"`, the
        Envoy image (`operandImages.envoy`), the replica count from the
        cluster's availability level
        (`provider.kubernetes.envoyDeployment.replicas`), pod topology spread
        constraints and a `PodDisruptionBudget` when running multiple
        replicas, and the proxy Service type (`NodePort` when
        `cluster.roles.loadBalancer.binding = "absent"`, or `LoadBalancer`
        otherwise).

        You can override the replica count, Service type, and other
        `EnvoyProxy` fields here. Setting `mergeGateways = true` shares one
        proxy Deployment across all Gateways in the class and updates
        `out.podSelector` to match. Kix rejects overrides to `provider.type`
        (must be `"Kubernetes"`),
        `provider.kubernetes.envoyDeployment.container.image` (set
        `operandImages.envoy` instead), and
        `provider.kubernetes.envoyDeployment.pod.topologySpreadConstraints`.
      '';
    };

    settings = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      example = lib.literalExpression ''
        {
          logging.level.default = "debug";
          extensionApis.enableBackend = true;
        }
      '';
      description = ''
        EnvoyGateway controller configuration fields
        (`gateway.envoyproxy.io/v1alpha1` `EnvoyGateway`), merged over the
        package defaults.

        By default, the package sets `logging.level.default = "info"` (which
        you can override here) and configures `gateway`, `provider.type`,
        `provider.kubernetes.shutdownManager`, and the rate-limit container
        image (`operandImages.rateLimit`).

        Kix rejects overrides to `gateway`, `provider.type`,
        `provider.kubernetes.deploy`, `provider.kubernetes.watch`,
        `provider.kubernetes.shutdownManager`,
        `provider.kubernetes.rateLimitDeployment.container.image` (set
        `operandImages.rateLimit` instead), `proxyTopologyInjector`, and
        `envoyProxy` (set `proxySpec` instead).
      '';
    };

    metrics = kix.options.monitor // {
      nackWindow = lib.mkOption {
        type = kix.types.promDuration;
        default = "15m";
        description = "Prometheus lookback window (such as `15m`) for the `EnvoyGatewayConfigRejected` alert. The alert fires when a proxy rejects a configuration update within this window and resolves once this duration passes without another rejection.";
      };
    };
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
        gatewayApi ? null,
        prometheus ? null,
        ...
      }:
      let
        netpol = scope.networkPolicyEnforcer.netpol;
        inherit (scope.rbac) mkClusterRoleSet mkRoleSet;
        rbacRules = file: (readJSON ./rbac/${file}).rules;

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

        controllerReplicas = kix.availability.pick availability {
          none = 1;
          pod = 1;
          node = 2;
          zone = 2;
        };

        # The EnvoyProxy the GatewayClass names. The user's proxySpec
        # merges over it.
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
                container.image = kix.image.ref config.operandImages.envoy;
              };
              envoyService.type = if loadBalancerAbsent then "NodePort" else "LoadBalancer";
            };
          };
        };
        # The Kubernetes provider is the only one that runs proxies in a
        # cluster, and the roles and policies assume it.
        proxyProviderType = config.proxySpec.provider.type or "Kubernetes";
        proxyMerged =
          if proxyProviderType != "Kubernetes" then
            scope.fail {
              option = "proxySpec.provider.type";
              message = "proxySpec.provider.type is \"${toString proxyProviderType}\", which this package does not support. Envoy Gateway only deploys in-cluster proxy pods when provider.type is \"Kubernetes\".";
              fix = "Remove proxySpec.provider.type (it defaults to \"Kubernetes\").";
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
        mergeGateways = proxyMerged.mergeGateways or false;

        # The pods of this instance's Gateway. A merged GatewayClass shares
        # one proxy fleet across its Gateways
        # (internal/gatewayapi/helpers.go).
        gatewayProxySelector =
          proxyLabels
          // (
            if mergeGateways then
              { "gateway.envoyproxy.io/owning-gatewayclass" = name; }
            else
              {
                "gateway.envoyproxy.io/owning-gateway-name" = name;
                "gateway.envoyproxy.io/owning-gateway-namespace" = ns;
              }
          );

        proxySpread = lib.optionalAttrs (proxyReplicas > 1) {
          provider.kubernetes = {
            envoyDeployment.pod.topologySpreadConstraints = kix.availability.spreadConstraints {
              level = availability;
              selector = gatewayProxySelector;
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

        configBase = {
          gateway.controllerName = controllerName;
          provider = {
            type = "Kubernetes";
            kubernetes = {
              rateLimitDeployment.container.image = kix.image.ref config.operandImages.rateLimit;
              shutdownManager.image = kix.image.ref config.image;
            };
          };
          logging.level.default = "info";
        };
        envoyGatewayConfig = {
          apiVersion = "gateway.envoyproxy.io/v1alpha1";
          kind = "EnvoyGateway";
        }
        // kix.mergeGuarded {
          inherit who;
          what = "settings";
          locked = lockedSettings;
        } configBase config.settings;

        fieldRef = path: { valueFrom.fieldRef.fieldPath = path; };
        sharedEnv = {
          ENVOY_GATEWAY_NAMESPACE = fieldRef "metadata.namespace";
          KUBERNETES_CLUSTER_DOMAIN = clusterConfig.clusterDomain;
        };

        # The release chart's container security context, for the
        # controller and for certgen.
        containerSecurity = {
          allowPrivilegeEscalation = false;
          capabilities.drop = [ "ALL" ];
          readOnlyRootFilesystem = true;
          runAsNonRoot = true;
          runAsUser = 65532;
          runAsGroup = 65532;
          seccompProfile.type = "RuntimeDefault";
        };
        podSecurity = {
          runAsNonRoot = true;
          runAsUser = 65532;
          runAsGroup = 65532;
          fsGroup = 65532;
          seccompProfile.type = "RuntimeDefault";
        };

        tcp = port: {
          inherit port;
          protocol = "TCP";
        };

        gatewayCrds = kix.contracts.experimental.gatewayApi.helpers.crdsFor {
          who = "${ns}/${name}";
          inherit gatewayApi;
          # The controller needs these; it detects the other kinds at start.
          kinds = [
            "GatewayClass"
            "Gateway"
            "HTTPRoute"
            "ReferenceGrant"
          ];
          # The Gateway API release Envoy Gateway 1.10 is built against
          # (go.mod and site/content/en/news/releases/matrix.md upstream).
          minVersion = "1.6";
        };
      in
      {
        crds = {
          # The controller writes a Backend's Accepted condition only while
          # settings.extensionApis.enableBackend is true
          # (internal/provider/kubernetes/controller.go), so the kind
          # declares no readiness that a default install would never meet.
          backends = scope.mkCRD {
            spec = vendored "backends.gateway.envoyproxy.io.json";
            holdsData = false;
            usesAtLeast = _: { };
          };
        }
        //
          lib.genAttrs
            [
              "backendtrafficpolicies"
              "clienttrafficpolicies"
              "envoyextensionpolicies"
              "envoypatchpolicies"
              "envoyproxies"
              "httproutefilters"
              "securitypolicies"
            ]
            (
              plural:
              # Policies and filters report status per target in
              # status.ancestors, with no top-level conditions.
              scope.mkCRD {
                spec = vendored "${plural}.gateway.envoyproxy.io.json";
                holdsData = false;
                usesAtLeast = _: { };
              }
            );

        serviceAccount = scope.mkResource {
          apiVersion = "v1";
          kind = "ServiceAccount";
          name = controllerName';
          labels = controllerLabels;
        };

        clusterRole = mkClusterRoleSet scope {
          subjects = [
            {
              kind = "ServiceAccount";
              name = self.serviceAccount.out.name;
              namespace = ns;
            }
          ];
          labels = controllerLabels;
          roles."${name}-${ns}" = rbacRules "clusterrole-eg-gateway-helm-envoy-gateway-role.json";
        };

        # The infra manager role lets the controller create the proxy
        # Deployments, Services, and their companions in this namespace.
        role = mkRoleSet scope {
          subjects = [
            {
              kind = "ServiceAccount";
              name = self.serviceAccount.out.name;
              namespace = ns;
            }
          ];
          labels = controllerLabels;
          roles = {
            "${name}-infra-manager" = rbacRules "role-eg-gateway-helm-infra-manager.json";
            "${name}-leader-election" = rbacRules "role-eg-gateway-helm-leader-election-role.json";
          };
        };

        config = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "${controllerName'}-config";
          labels = controllerLabels;
          data."envoy-gateway.yaml" = builtins.toJSON envoyGatewayConfig;
        };

        certgenServiceAccount = scope.mkResource {
          apiVersion = "v1";
          kind = "ServiceAccount";
          name = "${controllerName'}-certgen";
          labels = certgenLabels;
        };

        certgenRole =
          let
            subjects = [
              {
                kind = "ServiceAccount";
                name = self.certgenServiceAccount.out.name;
                namespace = ns;
              }
            ];
          in
          mkRoleSet scope {
            inherit subjects;
            labels = certgenLabels;
            roles."${name}-certgen" = rbacRules "role-eg-gateway-helm-certgen.json";
          }
          // mkClusterRoleSet scope {
            inherit subjects;
            labels = certgenLabels;
            # The release manifest names the webhook of the namespace it
            # was rendered for; the rule names this namespace's.
            roles."${name}-certgen-${ns}" = map (
              rule:
              rule
              // lib.optionalAttrs (rule ? resourceNames) {
                resourceNames = [ webhookName ];
              }
            ) (rbacRules "clusterrole-eg-gateway-helm-certgen_envoy-gateway-system.json");
          };

        topologyInjector = scope.mkClusterResource {
          apiVersion = "admissionregistration.k8s.io/v1";
          kind = "MutatingWebhookConfiguration";
          name = webhookName;
          labels = controllerLabels // {
            "app.kubernetes.io/component" = "topology-injector";
          };
          extra.webhooks = [
            {
              name = "topology.webhook.gateway.envoyproxy.io";
              admissionReviewVersions = [ "v1" ];
              sideEffects = "None";
              # certgen writes caBundle; Kix never sets it. The fixed name,
              # without the Service's context: the Service selects the
              # Deployment's pods, and the Deployment needs certgen, which
              # needs this configuration.
              clientConfig.service = {
                name = serviceName;
                namespace = ns;
                path = "/inject-pod-topology";
                port = ports.webhook;
              };
              failurePolicy = "Ignore";
              rules = [
                {
                  operations = [ "CREATE" ];
                  apiGroups = [ "" ];
                  apiVersions = [ "v1" ];
                  resources = [ "pods/binding" ];
                }
              ];
              namespaceSelector.matchExpressions = [
                {
                  key = "kubernetes.io/metadata.name";
                  operator = "In";
                  values = [ ns ];
                }
              ];
            }
          ];
        };

        # `envoy-gateway certgen` creates the four Secrets when they are
        # missing, leaves existing ones alone, and writes the CA into the
        # topology injector, so a second run changes nothing.
        certgen = scope.mkJob {
          name = "${name}-certgen";
          labels = certgenLabels;
          annotations.${kix.keys.rerun} = kix.keyValues.rerunOnChange;
          requires = [ self.topologyInjector ] ++ builtins.attrValues self.certgenRole;
          spec = {
            backoffLimit = 3;
            template = {
              metadata.labels = certgenLabels;
              spec = {
                serviceAccount = self.certgenServiceAccount;
                restartPolicy = "Never";
                securityContext = podSecurity;
                containers = [
                  {
                    name = "envoy-gateway-certgen";
                    image = kix.image.ref config.image;
                    imagePullPolicy = config.image.pullPolicy;
                    command = [
                      "envoy-gateway"
                      "certgen"
                    ];
                    env = kix.mkEnvVars sharedEnv;
                    inherit (config.certgen) resources;
                    securityContext = containerSecurity;
                  }
                ];
              };
            };
          };
        };

        certSecret = scope.mkSecretRef {
          name = certSecretName;
          type = "kubernetes.io/tls";
          keys = [
            "ca.crt"
            "tls.crt"
            "tls.key"
          ];
          requires = [ self.certgen ];
        };

        deployment =
          {
            name = controllerName';
            labels = controllerLabels;
            # The controller checks at start which optional kinds have CRDs
            # (internal/provider/kubernetes/controller.go), so every CRD comes
            # first.
            requires =
              builtins.attrValues self.crds
              ++ builtins.attrValues gatewayCrds
              ++ builtins.attrValues self.clusterRole
              ++ builtins.attrValues self.role;
            spec = {
              replicas = controllerReplicas;
              selector.matchLabels = controllerLabels;
              template = {
                metadata = {
                  labels = controllerLabels;
                  # The controller reads its configuration file at start.
                  annotations."checksum/config" = self.config.out.contentHash;
                };
                spec = {
                  serviceAccount = self.serviceAccount;
                  securityContext = podSecurity;
                  # The release chart's value; the controller holds no
                  # connection it must drain.
                  terminationGracePeriodSeconds = 10;
                  containers = [
                    {
                      name = "envoy-gateway";
                      image = kix.image.ref config.image;
                      imagePullPolicy = config.image.pullPolicy;
                      args = [
                        "server"
                        "--config-path=/config/envoy-gateway.yaml"
                      ];
                      env = kix.mkEnvVars (
                        sharedEnv
                        // {
                          ENVOY_GATEWAY_SERVICE_ACCOUNT = fieldRef "spec.serviceAccountName";
                          # The prefix of the certgen ServiceAccount, which
                          # the controller keeps proxies from using
                          # (internal/infrastructure/kubernetes/proxy/resource_provider.go).
                          ENVOY_GATEWAY_FULLNAME = controllerName';
                        }
                      );
                      ports = [
                        (kix.port "grpc" ports.xds)
                        (kix.port "ratelimit" ports.rateLimitXds)
                        (kix.port "wasm" ports.wasm)
                        (kix.port "metrics" ports.metrics)
                        (kix.port "webhook" ports.webhook)
                      ];
                      # The release chart's probes.
                      startupProbe = {
                        httpGet = {
                          path = "/healthz";
                          port = ports.health;
                        };
                        failureThreshold = 30;
                        periodSeconds = 1;
                      };
                      livenessProbe = {
                        httpGet = {
                          path = "/healthz";
                          port = ports.health;
                        };
                        periodSeconds = 20;
                      };
                      readinessProbe = {
                        httpGet = {
                          path = "/readyz";
                          port = ports.health;
                        };
                        periodSeconds = 10;
                      };
                      inherit (config) resources;
                      securityContext = containerSecurity;
                    }
                  ];
                };
              };
            };
          }
          |> kix.withMounts [
            (kix.mount.configMap self.config {
              name = "config";
              mountPath = "/config";
              readOnly = true;
            })
            (kix.mount.secret self.certSecret {
              name = "certs";
              mountPath = "/certs";
              readOnly = true;
            })
            # The Wasm module cache; the root filesystem is read-only.
            (kix.mount.emptyDir {
              name = "wasm-cache";
              mountPath = "/var/lib/eg/wasm";
            })
          ]
          |> scope.mkDeployment;

        service = scope.mkResource {
          apiVersion = "v1";
          kind = "Service";
          name = serviceName;
          labels = controllerLabels;
          spec = {
            selector = self.deployment.out.selector;
            ports = map (p: p // { protocol = "TCP"; }) [
              {
                name = "grpc";
                port = ports.xds;
                targetPort = ports.xds;
              }
              {
                name = "ratelimit";
                port = ports.rateLimitXds;
                targetPort = ports.rateLimitXds;
              }
              {
                name = "wasm";
                port = ports.wasm;
                targetPort = ports.wasm;
              }
              {
                name = "metrics";
                port = ports.metrics;
                targetPort = ports.metrics;
              }
              {
                name = "webhook";
                port = ports.webhook;
                targetPort = ports.webhook;
              }
            ];
          };
        };

        metricsService =
          if config.metrics.enabled && prometheus != null then
            self.deployment
            |> kix.service.fromWorkload {
              name = "${name}-metrics";
              labels = controllerLabels // {
                "app.kubernetes.io/component" = "metrics";
              };
              ports = [
                {
                  name = "metrics";
                  port = ports.metrics;
                  targetPort = "metrics";
                }
              ];
            }
            |> scope.mkResource
          else
            null;

        proxyPodMonitor =
          if config.metrics.enabled && prometheus != null then
            prometheus.out.mkPodMonitor scope {
              name = "${name}-proxy";
              labels = controllerLabels // {
                "app.kubernetes.io/component" = "proxy";
              };
              spec = {
                selector.matchLabels = gatewayProxySelector;
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

        # The controller admits the proxies to xDS and Wasm, and the rate
        # limit pods to their xDS port. The callers are pods the controller
        # creates, which no intent can name, so the policy is built here.
        controllerIngress = kix.operandPolicy {
          inherit scope;
          name = "${name}-controller-from-proxies";
          spec = {
            endpointSelector.matchLabels = controllerLabels;
            ingress = [
              (netpol.mkCallerIngressRule {
                callerSelector = proxyLabels;
                callerNamespace = ns;
                ports = map tcp [
                  ports.xds
                  ports.wasm
                ];
              })
              (netpol.mkCallerIngressRule {
                callerSelector = rateLimitLabels;
                callerNamespace = ns;
                ports = [ (tcp ports.rateLimitXds) ];
              })
            ];
          };
        };

        proxyIngress =
          if frontDoorPorts == [ ] then
            null
          else
            kix.operandPolicy {
              inherit scope;
              name = "${name}-proxy-ingress";
              spec = {
                endpointSelector.matchLabels = gatewayProxySelector;
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
            endpointSelector.matchLabels = gatewayProxySelector;
            egress = [
              netpol.dnsEgressRule
            ]
            ++ (netpol.translateIntentRules {
              intents.backends.egress = [ { to = "pods"; } ];
            }).egressRules;
          };
        };

        envoyProxy =
          scope.mkCR self.crds.envoyproxies {
            inherit name;
            labels = controllerLabels;
            spec = proxySpec;
          }
          // {
            _warnings =
              lib.optional (loadBalancerBinding == null && proxyServiceType == "LoadBalancer") {
                clusterOption = "cluster.roles.loadBalancer.binding";
                message = "cluster.roles.loadBalancer.binding is not set, so Kix configured EnvoyProxy '${ns}/${name}' with a LoadBalancer Service for Gateway '${ns}/${name}'. If the cluster has no load balancer controller, that Service will never get an address, Gateway '${ns}/${name}' will never become Programmed, and `kix deploy` will time out.";
                fix = "Set `cluster.roles.loadBalancer.binding = \"shadowable\";` if the cluster provides a load balancer, or `\"absent\";` so Kix configures a NodePort Service instead.";
              }
              ++ lib.optional (scope.networkPolicyEnforcer != null && config.settings ? rateLimit) {
                option = "settings.rateLimit";
                message = "settings.rateLimit configures Envoy Gateway to deploy rate-limit pods in '${ns}', and Kix does not generate network policies for them. Because network policy is enabled, default-deny rules will block traffic between the Envoy proxies, the rate-limit pods, the controller, and Redis.";
                fix = "Add network policies for pods labelled `app.kubernetes.io/name=envoy-ratelimit` in namespace '${ns}' (via `namespaces.${ns}.networkPolicies` or outside Kix) to allow traffic with the Envoy proxies, the controller, and Redis, or remove `settings.rateLimit`.";
              };
          };

        gatewayClass = scope.mkCR gatewayCrds.GatewayClass {
          inherit name;
          labels = controllerLabels;
          # A GatewayClass is Accepted only once the controller runs.
          requires = [ self.deployment ];
          spec = {
            inherit controllerName;
            parametersRef = {
              group = "gateway.envoyproxy.io";
              kind = "EnvoyProxy";
              name = self.envoyProxy.out.name;
              namespace = ns;
            };
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
              labels = controllerLabels;
              # The proxies need their network policy to become ready.
              requires = builtins.filter (p: p != null) [
                self.proxyIngress
                self.proxyEgress
                self.controllerIngress
              ];
              spec = {
                gatewayClassName = self.gatewayClass.out.name;
                listeners = activeListeners;
              }
              // lib.optionalAttrs (config.addresses != [ ]) {
                addresses = map (lib.filterAttrs (_: v: v != null)) config.addresses;
              };
            };

        # The root is the controller; the Gateway is listed so the instance
        # is ready only once its proxies serve.
        root = {
          resource = self.deployment;
          requires = [
            self.gateway
            self.service
          ];
          out = kix.contracts.gateway.check who {
            gatewayRef = {
              name = self.gateway.out.name;
              namespace = ns;
            };
            listeners = activeListeners;
            # Raw labels: the reader writes a policy selector from them and
            # already depends on this instance through gatewayRef.
            podSelector = gatewayProxySelector;
            podNamespace = ns;
            version = kix.image.version config.image;
            crds = {
              Backend = self.crds.backends;
              BackendTrafficPolicy = self.crds.backendtrafficpolicies;
              ClientTrafficPolicy = self.crds.clienttrafficpolicies;
              EnvoyExtensionPolicy = self.crds.envoyextensionpolicies;
              EnvoyPatchPolicy = self.crds.envoypatchpolicies;
              EnvoyProxy = self.crds.envoyproxies;
              HTTPRouteFilter = self.crds.httproutefilters;
              SecurityPolicy = self.crds.securitypolicies;
            };
            extraImages = [
              (kix.image.ref config.operandImages.envoy)
              (kix.image.ref config.operandImages.rateLimit)
            ];
          };
        };
      }
    )

    ./alerts.nix
  ];
}
