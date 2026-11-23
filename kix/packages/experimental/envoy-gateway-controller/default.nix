# envoy-gateway-controller: the Envoy Gateway controller, which runs Envoy
# proxies for each Gateway of its GatewayClass.
#
# Installs Envoy Gateway's own CRDs (gateway.envoyproxy.io, crds/, vendored
# from the release's envoy-gateway-crds.yaml); the controller Deployment, its
# ServiceAccount, ConfigMap, and Service; its roles (rbac/, vendored from the
# release's install.yaml); the certgen Job that writes the control plane's
# certificates; and a GatewayClass and an EnvoyProxy named after the
# instance. With the optional
# `prometheus` dependency and `metrics.enabled`, it also adds a metrics
# Service, a ServiceMonitor, and alerts.
#
# The package renders no Gateway. Each Gateway is an instance of the
# envoy-gateway package, which takes this one as its `envoyGateway`
# dependency and answers the `gateway` alias that kix.expose routes through.
#
# Dependencies:
#   gatewayApi (required)   the Gateway API CRDs (1.6 or later), the role
#                           the gateway-api package claims. The
#                           GatewayClass is built from its `out.crds`.
#   prometheus (optional)   scrapes the controller while `metrics.enabled`.
#
# Minimal instance, with one Gateway:
#
#   instances.envoy-gateway-system = {
#     gateway-api.package = packages.experimental.gateway-api;
#     envoy-gateway-controller.package = packages.experimental.envoy-gateway-controller;
#     gateway.package = packages.experimental.envoy-gateway;
#   };
#
# A cluster runs one instance (`conflictsWith`). The controller watches
# Gateway API objects in every namespace, the CRDs are cluster-wide, and
# Envoy Gateway fixes the names of its Service and certificate Secrets. The
# controller's Deployment, ServiceAccount, Service, and ConfigMap are named
# envoy-gateway (the ConfigMap envoy-gateway-config), because the controller
# looks them up by those names; the GatewayClass and its EnvoyProxy take the
# instance name.
#
# The controller creates the data plane, in GatewayNamespace mode: for
# each Gateway it starts an Envoy Deployment and a Service, named after the
# Gateway, in the Gateway's namespace
# (internal/infrastructure/kubernetes/proxy/resource.go). A Gateway of the
# envoy-gateway package names its own EnvoyProxy, which says how its
# proxies run, and grants the controller `out.infraManagerRules` in its
# namespace. The controller's own ClusterRole only reads those objects, so
# a Gateway in a namespace with no such grant gets no proxies. The
# EnvoyProxy this package renders is the GatewayClass's: it pins the Envoy
# image for a Gateway that names none.
#
# The proxies check the controller's certificate, and the controller
# checks each proxy's ServiceAccount token with a TokenReview
# (site/content/en/v1.10/tasks/operations/gateway-namespace-mode.md
# upstream). The certgen Job (`envoy-gateway certgen`) writes the CA and
# the certificates into the Secrets envoy-gateway, envoy, envoy-rate-limit,
# and envoy-oidc-hmac in the instance's namespace. It leaves existing
# Secrets alone, so it can run again (internal/cmd/certgen.go). The
# certificates are valid for five years (internal/crypto/certgen.go) and
# nothing renews them. Delete the four Secrets and run the Job again to
# renew them.
#
# Leader election is on, as upstream ships it. Every replica serves xDS to
# the proxies, and the leader writes status and the proxy Deployments. The
# controller runs one replica at availability none and pod, and two from
# node up. The proxies keep their last configuration while the controller
# is down.
#
# The topology injector is off. It is a mutating webhook on pods/binding
# that copies the node's zone onto each proxy pod for zone-aware routing,
# and in GatewayNamespace mode upstream registers it for every namespace
# (charts/gateway-helm/templates/envoy-proxy-topology-injector-webhook.yaml),
# so every pod binding in the cluster would call the controller.
#
# Network policy: the proxies of every Gateway, in any namespace, and the
# rate limit pods, which the controller creates in this namespace, reach
# the controller's xDS (18000), rate limit xDS (18001), and Wasm (18002)
# ports. The policy for a Gateway's proxies is the envoy-gateway package's.
#
# `out`:
#   out.gatewayClassName  the GatewayClass a Gateway names.
#   out.namespace         the controller's namespace.
#   out.serviceAccount    the controller's ServiceAccount, name and namespace.
#   out.infraManagerRules the rules a Gateway grants that ServiceAccount in
#                         its own namespace, so the controller can create
#                         the Gateway's proxies there.
#   out.proxyImage        the Envoy image, for a Gateway's EnvoyProxy.
#   out.proxyLabels       the labels of every proxy pod the controller
#                         creates.
#   out.version           the Envoy Gateway version `image.tag` names.
#   out.crds.<Kind>       CRD handles for Envoy Gateway's policy kinds:
#                         Backend, BackendTrafficPolicy, ClientTrafficPolicy,
#                         EnvoyExtensionPolicy, EnvoyPatchPolicy, EnvoyProxy,
#                         HTTPRouteFilter, and SecurityPolicy.
#   out.extraImages       the Envoy and rate limit images the controller
#                         runs.
#
# Alerts: with a prometheus dependency and `metrics.enabled`, a
# PrometheusRule selects the metrics Service's series.
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
# Fewer ready replicas than desired is left to prometheus-default-rules.
# The proxies' alerts are the envoy-gateway package's.
#
# Escape hatches: `settings` (the EnvoyGateway configuration file), the CRD
# handles on `out.crds`, and the instance's `partsOverlays`.
#
# Limits: under network policy, the controller's own fetches (Wasm images,
# extension servers) need a policy written outside Kix. Global rate
# limiting needs a Redis the package does not wire, and its rate limit
# Deployment gets no policy. ControllerNamespace mode and a
# namespace-scoped watch are refused, because the roles and the policies
# assume each Gateway's proxies run in its own namespace and the controller
# watches the whole cluster. A Gateway on the class that is not an
# envoy-gateway instance gets no proxies, because nothing grants the
# controller its namespace. Zone-aware routing is not available while the
# topology injector is off. The certgen Job writes Secrets Kix does not track, so
# `kix gc` and pruning leave them behind.
#
# Upgrades: from a release of the envoy-gateway package that ran the
# controller itself, delete the Deployment envoy-gateway in the instance's
# namespace before the deploy. Its selector carries the instance's name,
# which changes with the package, and Kubernetes does not let a selector
# change. The proxies keep serving while the controller is away: on kind
# the same proxy pod answered every request across the deploy. The Gateway
# keeps its name and moves to the new GatewayClass, and `--prune` removes
# the old class, roles, policies, and the topology injector's webhook. The
# controller then starts new proxies in the Gateway's namespace, with a new
# Service named after the Gateway, and removes the old ones. A LoadBalancer
# Service gets a new address unless the Gateway's `addresses` or the
# Service's annotations pin it.
#
# From an Envoy Gateway that Helm installed, uninstall the Helm
# release first, delete the certgen hook objects and the topology injector
# webhook that Helm leaves behind, and deploy once with
# `--force-conflicts`, because Helm keeps owning fields of the CRDs it
# installed. Helm installed the experimental Gateway API channel:
# experimental-only fields are dropped from stored objects, and the
# experimental-only CRDs stay until deleted. Proxies that ran in Helm's
# namespace are left running; delete them once the Gateway's new address
# serves, or before the deploy when the Gateway's `addresses` keeps the old
# one.
#
# Moving to another release: set `release` and the digest of `image`
# (`crane digest docker.io/envoyproxy/gateway:<release>`), set
# `operandImages` to the DefaultEnvoyProxyImage and DefaultRateLimitImage of
# that release (api/v1alpha1/shared_types.go), move the tag in
# crds/sources.txt and rbac/sources.txt, run
# `uv run scripts/vendor-crds.py envoy-gateway-controller`, compare the
# Deployment and certgen Job below with the release's
# charts/gateway-helm templates, and check the gateway-api package's
# release against the release's go.mod.

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

  # The controller name Envoy Gateway's GatewayClass controller watches for
  # (api/v1alpha1/envoygateway_helpers.go).
  controllerName = "gateway.envoyproxy.io/gatewayclass-controller";

  # Names Envoy Gateway fixes. The proxies dial the controller at
  # envoy-gateway.<namespace> (internal/xds/bootstrap/bootstrap.go), certgen
  # issues the controller's certificate for that name and writes it to the
  # Secret envoy-gateway (internal/crypto/certgen.go,
  # internal/provider/kubernetes/secrets.go).
  serviceName = "envoy-gateway";
  certSecretName = "envoy-gateway";
  # With rate limiting on, the controller reads the UIDs of its own
  # Deployment, ServiceAccount, and Service by this name
  # (internal/infrastructure/kubernetes/ratelimit_infra.go), so they all
  # take it. The ConfigMap and the certgen ServiceAccount follow the names
  # the controller reserves beside it
  # (internal/infrastructure/kubernetes/proxy/resource_provider.go).
  controllerName' = serviceName;

  ports = {
    xds = 18000;
    rateLimitXds = 18001;
    wasm = 18002;
    metrics = 19001;
    health = 8081;
  };

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

  readJSON = file: builtins.fromJSON (builtins.readFile file);
  vendored = file: (readJSON ./crds/${file}).spec;

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
    [
      "provider"
      "kubernetes"
      "proxyTopologyInjector"
    ]
    # A default EnvoyProxy would sit beside the one each Gateway names;
    # set proxySpec on the envoy-gateway instance instead.
    [ "envoyProxy" ]
  ];
in
{
  meta = {
    version = lib.removePrefix "v" release;
    description = "Envoy Gateway controller, CRDs, and GatewayClass for envoy-gateway instances";
    owner = "platform";
    defaultAliases = [ "envoyGateway" ];
    conflictsWith = [ "cluster:envoyGateway" ];
    # The one controller serves Gateways for the whole cluster.
    scope = "cluster";
    # Envoy Gateway 1.10 supports Kubernetes 1.34 to 1.37
    # (site/content/en/news/releases/matrix.md upstream).
    k8s.minVersion = "1.34";
  };

  assertions =
    { config, ... }:
    let
      imageTag = builtins.unsafeDiscardStringContext config.image.tag;
    in
    [
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
        `provider.kubernetes.deploy`,
        `provider.kubernetes.proxyTopologyInjector`,
        `provider.kubernetes.shutdownManager`, and the rate-limit container
        image (`operandImages.rateLimit`).

        Kix rejects overrides to `gateway`, `provider.type`,
        `provider.kubernetes.deploy`, `provider.kubernetes.watch`,
        `provider.kubernetes.shutdownManager`,
        `provider.kubernetes.rateLimitDeployment.container.image` (set
        `operandImages.rateLimit` instead),
        `provider.kubernetes.proxyTopologyInjector`, and `envoyProxy` (set
        `proxySpec` on each `envoy-gateway` instance instead).
      '';
    };

    metrics = kix.options.monitor // {
      nackWindow = lib.mkOption {
        type = kix.types.promDuration;
        default = "15m";
        description = "Prometheus lookback window (such as `15m`) for the `EnvoyGatewayConfigRejected` alert. The alert fires when a proxy rejects a configuration update within this window and resolves once this duration passes without another rejection.";
      };
    };
  };

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
        # What the controller needs to create and update a Gateway's proxy
        # Deployment, Service, ServiceAccount, ConfigMap, autoscaler, and
        # PodDisruptionBudget.
        infraManagerRules = rbacRules "role-eg-gateway-helm-infra-manager.json";

        controllerReplicas = kix.availability.pick availability {
          none = 1;
          pod = 1;
          node = 2;
          zone = 2;
        };

        configBase = {
          gateway.controllerName = controllerName;
          provider = {
            type = "Kubernetes";
            kubernetes = {
              # Each Gateway's proxies run in the Gateway's namespace.
              deploy.type = "GatewayNamespace";
              # In this mode the injector's webhook would see every pod
              # binding in the cluster, so it stays off.
              proxyTopologyInjector.disable = true;
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
          inherit scope;
          option = "settings";
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
          # The release's controller role, and what GatewayNamespace mode
          # adds to it (charts/gateway-helm/templates/_rbac.tpl): the
          # controller checks each proxy's ServiceAccount token with a
          # TokenReview, and its cache lists the proxy objects in every
          # namespace. It writes them only where an envoy-gateway instance
          # grants `out.infraManagerRules`.
          roles."${name}-${ns}" =
            rbacRules "clusterrole-eg-gateway-helm-envoy-gateway-role.json"
            ++ [
              {
                apiGroups = [ "authentication.k8s.io" ];
                resources = [ "tokenreviews" ];
                verbs = [ "create" ];
              }
            ]
            ++ map (
              rule:
              rule
              // {
                verbs = [
                  "get"
                  "list"
                  "watch"
                ];
              }
            ) infraManagerRules;
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
            # For the rate limit Deployment, which runs here.
            "${name}-infra-manager" = infraManagerRules;
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

        certgenRole = mkRoleSet scope {
          subjects = [
            {
              kind = "ServiceAccount";
              name = self.certgenServiceAccount.out.name;
              namespace = ns;
            }
          ];
          labels = certgenLabels;
          roles."${name}-certgen" = rbacRules "role-eg-gateway-helm-certgen.json";
        };

        # `envoy-gateway certgen` creates the four Secrets when they are
        # missing and leaves existing ones alone, so a second run changes
        # nothing.
        certgen = scope.mkJob {
          name = "${name}-certgen";
          labels = certgenLabels;
          annotations.${kix.keys.rerun} = kix.keyValues.rerunOnChange;
          requires = builtins.attrValues self.certgenRole;
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
                      # No webhook exists for certgen to write the CA into.
                      "--disable-topology-injector"
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

        # The controller admits the proxies to xDS and Wasm, and the rate
        # limit pods to their xDS port. The callers are pods the controller
        # creates, which no intent can name, so the policy is built here.
        controllerIngress = kix.operandPolicy {
          inherit scope;
          name = "${name}-controller-from-proxies";
          spec = {
            endpointSelector.matchLabels = controllerLabels;
            ingress = [
              # A Gateway's proxies run in the Gateway's namespace.
              (netpol.mkCallerIngressRule {
                callerSelector = proxyLabels;
                callerNamespace = null;
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

        # The class's EnvoyProxy, for a Gateway that names none of its own,
        # such as one a Helm chart writes. It pins the Envoy image. A
        # Gateway of the envoy-gateway package names its own.
        envoyProxy =
          scope.mkCR self.crds.envoyproxies {
            inherit name;
            labels = controllerLabels;
            spec.provider = {
              type = "Kubernetes";
              kubernetes.envoyDeployment.container.image = kix.image.ref config.operandImages.envoy;
            };
          }
          // {
            _warnings = lib.optional (scope.networkPolicyEnforcer != null && config.settings ? rateLimit) {
              option = "settings.rateLimit";
              message = "settings.rateLimit configures Envoy Gateway to deploy rate-limit pods in '${ns}', and Kix does not generate network policies for them. Because network policy is enabled, default-deny rules will block traffic between the Envoy proxies, the rate-limit pods, the controller, and Redis.";
              fix = "Add network policies for pods labelled `app.kubernetes.io/name=envoy-ratelimit` in namespace '${ns}' (via `namespaces.${ns}.networkPolicies` or outside Kix) to allow traffic with the Envoy proxies, the controller, and Redis, or remove `settings.rateLimit`.";
            };
          };

        gatewayClass = scope.mkCR gatewayCrds.GatewayClass {
          inherit name;
          labels = controllerLabels;
          # A GatewayClass is Accepted only once the controller runs. A
          # Gateway waits for the class, so the class also waits for what
          # the Gateway's proxies need to reach the controller: its Service
          # and, under an enforcer, the policy that admits them.
          requires = builtins.filter (p: p != null) [
            self.deployment
            self.service
            self.controllerIngress
          ];
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

        # The GatewayClass is listed so the instance is ready only once
        # the controller has accepted it.
        root = {
          resource = self.deployment;
          # The policy is null without an enforcer.
          requires = builtins.filter (p: p != null) [
            self.gatewayClass
            self.service
            self.controllerIngress
          ];
          out = {
            # The class's name, with its context, so a Gateway built from
            # it waits for the controller.
            gatewayClassName = self.gatewayClass.out.name;
            namespace = ns;
            # A Gateway grants these rules to this ServiceAccount in its
            # own namespace, where the controller creates its proxies.
            serviceAccount = {
              name = self.serviceAccount.out.name;
              namespace = ns;
            };
            inherit infraManagerRules;
            # What a Gateway's own EnvoyProxy and network policy need:
            # the pinned Envoy image and the labels of every proxy pod.
            proxyImage = kix.image.ref config.operandImages.envoy;
            inherit proxyLabels;
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
