# traefik: the Traefik proxy as a Gateway API implementation. Traefik is its
# own controller and data plane: the pods that watch Gateways and HTTPRoutes
# are the pods that serve the traffic.
#
# Installs the Traefik Deployment, its ServiceAccount and RBAC, the Service in
# front of it, a GatewayClass with Traefik's controller name, and a Gateway
# with the instance's listeners. Only the kubernetesGateway provider is on.
# `metrics.enabled` turns on Traefik's Prometheus metrics; with the optional
# `prometheus` dep it also adds Service <name>-metrics and a ServiceMonitor.
#
# The Gateway API CRDs come from the `gatewayApi` dependency, the role the
# gateway-api package claims. The Deployment requires every kind Traefik
# watches, so it starts only after those CRDs are Established; with a kind
# missing, Traefik's Gateway provider never starts.
#
# Each listener port becomes a Traefik entrypoint, a container port, and a
# Service port of the same number, because Traefik attaches a Gateway
# listener to the entrypoint whose address ends in the listener's port.
# The Service is a LoadBalancer, or a NodePort when
# `cluster.roles.loadBalancer.binding` is "absent" (the kind flavour sets
# that). Traefik copies the Service's load balancer addresses into the
# Gateway's status. The Gateway is ready once Traefik reports it
# Programmed, which does not wait for an address.
#
# Each instance serves only its own GatewayClass (a label selector on the
# class), so several instances can run in one cluster. GatewayClass and
# Gateway take the instance name, and GatewayClass names are cluster-scoped,
# so instances in two namespaces need different names.
#
# Dependencies:
#   gatewayApi (required)   the Gateway API CRDs (v1.6.1 or later, standard
#                           channel), from the gateway-api package or a
#                           platform import.
#   prometheus (optional)   scrapes Traefik while `metrics.enabled`.
#
#   instances.gateway-system.gateway-api.package = packages.experimental.gateway-api;
#   instances.gateway-system.traefik.package = packages.experimental.traefik;
#
# Exposes (the gateway contract, kix.contracts.gateway):
#   out.gatewayRef    the Gateway, the parentRef of every HTTPRoute kix.expose
#                     renders.
#   out.listeners     the rendered listeners, from which kix.expose picks a
#                     route's URL scheme and port.
#   out.version       the Traefik version `image.tag` names.
#   out.podSelector, out.podNamespace
#                     the Traefik pods, for the policy kix.expose writes so
#                     they can reach each exposed backend.
#
# Alerts: with a prometheus dependency and `metrics.enabled`, a
# PrometheusRule `<instance>-alerts` selects the metrics Service's series.
#   TraefikDown (critical)                    no Traefik replica answers a
#                                             scrape, so nothing serves the
#                                             Gateway's listeners.
#   TraefikCertificateExpiringSoon (warning)  a certificate Traefik serves
#                                             expires within
#                                             `metrics.minCertificateValidity`.
#   TraefikBackendErrorsHigh (warning)        more than
#                                             `metrics.backendErrorRatio` of a
#                                             backend's requests end in 502,
#                                             503, or 504, the answers Traefik
#                                             gives when it cannot reach a
#                                             backend or it has no endpoints.
# Traefik exposes no metric for a failed configuration reload: it logs
# provider errors and keeps the last good configuration. Fewer ready
# replicas than desired is left to prometheus-default-rules, and latency and
# other error rates to the site's own objectives.
#
# Upgrades: Traefik keeps no state of its own. It reads the Gateway API
# objects and writes their status, so a new version serves the Gateways and
# routes that the previous one left behind. Going back is a deploy of the
# previous package version. Both directions were tested on kind with an
# HTTPRoute serving traffic: the Gateway stayed Programmed, and the route
# returned 200 after each deploy.
#
# Escape hatches: `extraArgs`, `env`, `service.spec`, `service.annotations`,
# and the instance's `partsOverlays`.
#
# Known limits:
# - Under network policy, only listener ports 80 and 443 are opened to
#   clients; the package refuses other ports while an enforcer is present.
# - IngressRoute and the other Traefik CRDs, and the Kubernetes Ingress
#   provider, are not available: they need CRDs and RBAC the package does not
#   install, and kix.expose routes through the Gateway.
# - TCP and UDP listeners are refused. Traefik serves TCPRoute only with the
#   experimental channel, and UDPRoute not at all.

{
  scope,
  lib,
  kix,
  availability,
}:

let
  release = "v3.7.19";

  # Traefik's GatewayClass controller, pkg/provider/kubernetes/gateway/kubernetes.go.
  controllerName = "traefik.io/gateway-controller";

  name = scope.instanceName;
  # Cluster-scoped RBAC carries the namespace too, so instances with the
  # same name in two namespaces do not collide.
  clusterName = "${scope.namespaceName}-${name}";

  selectorLabels = {
    "app.kubernetes.io/name" = "traefik";
    "app.kubernetes.io/instance" = name;
    "app.kubernetes.io/component" = "gateway";
  };

  gatewayListeners = import ../envoy-gateway/listeners.nix { inherit lib; };

  # Ping, and metrics when enabled, on Traefik's internal entrypoint.
  internalPort = 8080;

  # Ports the network policy intents below open.
  openPorts = [
    80
    443
  ];

  tcp = port: {
    inherit port;
    protocol = "TCP";
  };

  inherit (scope.rbac)
    group
    core
    grant
    watch
    allow
    mkClusterRoleSet
    ;
  disco = group "discovery.k8s.io" [ "endpointslices" ];
  gatewayApiGroup = "gateway.networking.k8s.io";
  # The kinds Traefik's Gateway provider watches without experimentalChannel,
  # pkg/provider/kubernetes/gateway/client.go WatchAll.
  watchedKinds = [
    "gatewayclasses"
    "gateways"
    "httproutes"
    "grpcroutes"
    "tlsroutes"
    "referencegrants"
    "backendtlspolicies"
  ];
  gwApi = group gatewayApiGroup watchedKinds;
in
{
  meta = {
    version = release;
    description = "Traefik proxy as a Gateway API implementation (GatewayClass, Gateway, and data plane)";
    owner = "platform";
    defaultAliases = [ "gateway" ];
    # One Gateway accepts HTTPRoutes from every namespace, so consumers in
    # any namespace find it by name.
    scope = "cluster";
    # Traefik's docs say it supports the latest three Kubernetes minor
    # versions (docs/content/includes/kubernetes-requirements.md). Nothing is
    # known to fail outside that range, so Kix only warns. Kubernetes v1.37
    # is the newest minor release at this Traefik release. Move `supported`
    # with `release`.
    k8s.supported = {
      minVersion = "1.35";
      maxVersion = "1.37";
      source = "the Kubernetes requirements in Traefik's docs";
    };
    network.intents = {
      # HTTPRoutes name their backends at runtime, on any port, so the graph
      # cannot see Traefik's upstream connections.
      backends.egress = [ { to = "pods"; } ];
      # Clients outside the cluster, plus in-cluster clients and NodePort
      # traffic that arrives SNATed from a node. The `cluster` entity names
      # the nodes as well as the pods.
      front-door.ingress = [
        {
          from = "world";
          ports = map tcp openPorts;
        }
        {
          from = "world";
          entities = [ "cluster" ];
          ports = map tcp openPorts;
        }
      ];
    };
  };

  options = {
    image = kix.options.image {
      repository = "docker.io/library/traefik";
      tag = release;
      digest = "sha256:a6c0194dda77bcb804824580f36fa7edc56e315b1acfe933366c8b52844a78a4";
      description = "Image of Traefik.";
    };
    replicas = lib.mkOption {
      type = lib.types.ints.positive;
      # Two proxies once a pod restart must not drop traffic, spread so
      # either survives a lost node or zone.
      default = kix.availability.pick availability {
        none = 1;
        pod = 2;
        node = 2;
        zone = 2;
      };
      defaultText = lib.literalMD "1, 2, 2, or 3 for the cluster's availability level `none`, `pod`, `node`, or `zone`";
      description = "Traefik replicas. Every replica serves traffic and writes Gateway status.";
    };
    listeners = lib.mkOption {
      type = lib.types.listOf gatewayListeners.type;
      default = gatewayListeners.defaults;
      description = ''
        Gateway API v1 `Listener` entries for the Gateway's `spec.listeners`,
        with the upstream field names. Protocols HTTP, HTTPS, and TLS. An
        HTTPS listener with no `tls.certificateRefs` is a placeholder and is
        not rendered.

        Each distinct port becomes a Traefik entrypoint and a Service port,
        so a listener port needs no other setting. Port ${toString internalPort} is
        Traefik's internal entrypoint and is refused.

        kix.expose reads the rendered listeners: `protocol`, `hostname`,
        `port` and `allowedRoutes.namespaces.from` decide whether an
        HTTPRoute can attach and which URL scheme and port it gets.
      '';
    };
    service = {
      annotations = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        description = "Annotations on the Traefik Service, such as a cloud provider's load balancer settings.";
      };
      spec = lib.mkOption {
        default = { };
        description = ''
          Fields of the Traefik Service's `spec`, with Kubernetes field names
          (`loadBalancerClass`, `loadBalancerSourceRanges`,
          `ipFamilyPolicy`, ...). The package sets `selector` and `ports`
          from the listeners.
        '';
        type = lib.types.submodule {
          freeformType = lib.types.attrsOf lib.types.anything;
          options = {
            type = lib.mkOption {
              type = lib.types.enum [
                "ClusterIP"
                "NodePort"
                "LoadBalancer"
              ];
              default = "LoadBalancer";
              defaultText = lib.literalMD ''"NodePort" when `cluster.roles.loadBalancer.binding` is "absent", "LoadBalancer" otherwise'';
              description = "Service type. LoadBalancer needs a load balancer provider in the cluster.";
            };
            externalTrafficPolicy = lib.mkOption {
              type = lib.types.nullOr (
                lib.types.enum [
                  "Cluster"
                  "Local"
                ]
              );
              default = null;
              description = "`Local` keeps client source addresses on NodePort and LoadBalancer Services. Null leaves the Kubernetes default, `Cluster`.";
            };
          };
        };
      };
    };
    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "--log.level=INFO" ];
      description = ''
        Flags appended to Traefik's arguments. Flags the package sets or
        derives from are refused: each listener entrypoint's address and
        `--entryPoints.traefik.address`, `--ping`, `--metrics.prometheus`,
        `--providers.kubernetesGateway` and its label selector, status
        Service, and experimental channel, `--configFile`, and every flag of
        the other Kubernetes providers. Traefik reads flag names in any case.
      '';
    };
    env = kix.options.env // {
      description = ''
        Extra environment variables for Traefik. A value is a string, a
        `fieldRef` source, or a `secretKeyRef` source naming a Secret managed
        outside Kix with `kix.untrackedRef`. `TRAEFIK_*` variables are
        refused: Traefik reads its configuration from them only when it has
        no flags, and the package always passes flags. Use `extraArgs`.
      '';
    };
    resources = kix.options.resources {
      requests = {
        cpu = "100m";
        memory = "64Mi";
      };
      description = ''
        Resource requests and limits for the Traefik container. There is no
        default limit: memory grows with the number of routes and open
        connections. Each field keeps its default until set, and null
        removes a default.
      '';
    };
    metrics = kix.options.monitor // {
      minCertificateValidity = lib.mkOption {
        type = kix.types.promDuration;
        default = "7d";
        example = "21d";
        description = "How long a certificate Traefik serves must still be valid before TraefikCertificateExpiringSoon fires, as a Prometheus duration. cert-manager and Traefik's ACME resolver renew a 90-day certificate 30 days before it expires, so 7 days left means renewal has failed for weeks. Lower it for certificates that live only a few days.";
      };
      backendErrorRatio = lib.mkOption {
        type = lib.types.numbers.between 0 1;
        default = 0.05;
        example = 0.01;
        description = "Share of a backend's requests that may end in 502, 503, or 504 before TraefikBackendErrorsHigh fires.";
      };
      backendErrorMinRate = lib.mkOption {
        type = lib.types.numbers.nonnegative;
        default = 0.1;
        example = 1;
        description = "Requests per second a backend must receive before TraefikBackendErrorsHigh considers its error ratio, so a few failures on a rarely used route do not fire it.";
      };
    };
  };

  config =
    { clusterConfig, ... }:
    {
      service.spec.type = lib.mkIf (
        ((clusterConfig.cluster.roles or { }).loadBalancer or { }).binding or null == "absent"
      ) (lib.mkDefault "NodePort");
    };

  build = [
    (
      {
        self,
        config,
        gatewayApi ? null,
        prometheus ? null,
        ...
      }:
      let
        metricsOn = config.metrics.enabled && prometheus != null;
        activeListeners = gatewayListeners.active config.listeners;

        # One entrypoint per distinct listener port, named after the first
        # listener on it when that name is a legal Service port name.
        ports = lib.unique (map (l: l.port) activeListeners);
        portName =
          port:
          let
            first = lib.findFirst (l: l.port == port) null activeListeners;
          in
          if
            builtins.match "[a-z]([-a-z0-9]{0,13}[a-z0-9])?" first.name != null && first.name != "traefik"
          then
            first.name
          else
            "port-${toString port}";
        entryPoints = map (port: {
          inherit port;
          name = portName port;
        }) ports;

        listenerProblems =
          lib.concatMap (
            l:
            lib.optional (l.port == internalPort)
              "listener \"${l.name}\" uses port ${toString internalPort}, Traefik's internal entrypoint for ping and metrics. Choose another port."
            ++
              lib.optional
                (builtins.elem l.protocol [
                  "TCP"
                  "UDP"
                ])
                "listener \"${l.name}\" has protocol ${l.protocol}, which this package does not serve. Use HTTP, HTTPS, or TLS."
            ++
              lib.optional (scope.networkPolicyEnforcer != null && !(builtins.elem l.port openPorts))
                "listener \"${l.name}\" uses port ${toString l.port}, but under network policy the package opens only ports 80 and 443 to clients. Use one of those."
          ) activeListeners
          ++
            lib.optional (activeListeners == [ ])
              "no listener is rendered (an HTTPS listener needs tls.certificateRefs). Add an HTTP listener or set certificateRefs.";

        serviceType = config.service.spec.type;
        serviceSpecOwned = {
          selector = "selects the Traefik pods. Remove it.";
          ports = "defines one port per listener port. Change the listeners instead.";
        };
        serviceSpecOwnedHits = builtins.filter (k: (config.service.spec.${k} or null) != null) (
          builtins.attrNames serviceSpecOwned
        );
        serviceSpec =
          if serviceSpecOwnedHits != [ ] then
            scope.fail (
              map (k: {
                option = "service.spec.${k}";
                message = "service.spec.${k} is set by the package, which ${serviceSpecOwned.${k}}";
              }) serviceSpecOwnedHits
            )
          else if serviceType == "ClusterIP" && config.service.spec.externalTrafficPolicy != null then
            scope.fail {
              option = "service.spec.externalTrafficPolicy";
              message = "service.spec.externalTrafficPolicy applies to NodePort and LoadBalancer Services, and the API server rejects it on ClusterIP.";
              fix = "Change service.spec.type or remove it.";
            }
          else
            kix.mergeGuarded
              {
                inherit scope;
                option = "service.spec";
                locked = [
                  [ "selector" ]
                  [ "ports" ]
                ];
              }
              {
                # rawSelector reads the Deployment's labels without forcing
                # its manifest, which requires this Service.
                selector = self.deployment.rawSelector;
                ports = map (ep: {
                  inherit (ep) name port;
                  targetPort = ep.port;
                  protocol = "TCP";
                }) entryPoints;
              }
              (lib.filterAttrs (_: v: v != null) config.service.spec);

        # Traefik's flag parser (paerser flag/flagparser.go) matches flag
        # names in any case and accepts one or two leading dashes.
        args = kix.mergeArgs {
          inherit scope;
          parser = "paerser";
          args = [
            "--global.checkNewVersion=false"
            {
              flags = [ "--entryPoints.traefik.address=:${toString internalPort}" ];
              reason = "the probes and the metrics Service use port ${toString internalPort}.";
            }
            {
              flags = [ "--ping=true" ];
              names = [ "--ping.entrypoint" ];
              reason = "the probes use /ping on the internal entrypoint.";
            }
            {
              flags = [ "--providers.kubernetesGateway=true" ];
              reason = "this package runs Traefik as a Gateway API controller.";
            }
            {
              flags = [
                "--providers.kubernetesGateway.labelSelector=${
                  lib.concatStringsSep "," (lib.mapAttrsToList (k: v: "${k}=${v}") selectorLabels)
                }"
              ];
              reason = "Traefik must select this instance's GatewayClass.";
            }
            {
              flags = [
                "--providers.kubernetesGateway.statusAddress.service.name=${self.service.out.name}"
                "--providers.kubernetesGateway.statusAddress.service.namespace=${scope.namespaceName}"
              ];
              reason = "Gateway status must publish the address of this instance's Service.";
            }
          ]
          # Traefik matches a listener to an entrypoint by the address suffix
          # ":<port>", so the address carries no "/tcp".
          ++ map (ep: {
            flags = [ "--entryPoints.${ep.name}.address=:${toString ep.port}" ];
            from = "the listener on port ${toString ep.port} in listeners";
            fix = "Remove it from extraArgs and edit listeners instead.";
          }) entryPoints
          ++ [
            # The flag follows the toggle alone, so adding a prometheus
            # instance does not restart Traefik.
            {
              flags = lib.optional config.metrics.enabled "--metrics.prometheus=true";
              names = [ "--metrics.prometheus" ];
              from = "the metrics.enabled option";
              fix = "Remove it from extraArgs and set metrics.enabled instead.";
            }
            {
              names = [ "--metrics.prometheus.entrypoint" ];
              reason = "the metrics Service scrapes the internal entrypoint on port ${toString internalPort}.";
            }
            {
              names = [ "--providers.kubernetesGateway.experimentalChannel" ];
              reason = "enabling the experimental channel makes Traefik watch TCPRoute, which requires experimental Gateway API CRDs and RBAC permissions this package does not grant.";
            }
            {
              names = [ "--configFile" ];
              reason = "when given a configuration file, Traefik ignores all CLI flags, including those set by this package.";
              fix = "Remove --configFile from extraArgs and pass static configuration as CLI flags in extraArgs instead.";
            }
            # A provider turns on when any key under it is set, so these are
            # refused as families.
            {
              families = [ "--providers.kubernetesCRD" ];
              reason = "Traefik's CRD provider requires Traefik CRDs and RBAC permissions that this package does not install.";
              fix = "Remove it from extraArgs and route traffic through Traefik's Gateway with HTTPRoute resources instead (packages using kix.expose create HTTPRoutes automatically).";
            }
            {
              families = [ "--providers.kubernetesIngress" ];
              reason = "the Ingress provider requires RBAC permissions that this package does not grant.";
              fix = "Remove it from extraArgs and route traffic through Traefik's Gateway with HTTPRoute resources instead (packages using kix.expose create HTTPRoutes automatically).";
            }
            {
              families = [ "--providers.kubernetesIngressNGINX" ];
              reason = "the ingress-nginx provider requires RBAC permissions that this package does not grant.";
              fix = "Remove it from extraArgs and route traffic through Traefik's Gateway with HTTPRoute resources instead (packages using kix.expose create HTTPRoutes automatically).";
            }
            {
              families = [ "--providers.knative" ];
              reason = "the Knative provider requires RBAC permissions that this package does not grant.";
            }
          ];
        } config.extraArgs;

        traefikEnv = builtins.filter (lib.hasPrefix "TRAEFIK_") (builtins.attrNames config.env);
        env =
          if traefikEnv != [ ] then
            scope.fail {
              option = "env";
              message = "env sets ${lib.concatStringsSep ", " traefikEnv}, which Traefik ignores because it reads its configuration from flags.";
              fix = "Pass the setting in extraArgs.";
            }
          else
            kix.mkEnvVars (kix.mergeEnv { inherit scope; } config.env);

        clusterRbac = mkClusterRoleSet scope {
          subjects = [
            {
              kind = "ServiceAccount";
              name = self.serviceAccount.out.name;
              namespace = scope.namespaceName;
            }
          ];
          labels = selectorLabels;
          roles.${clusterName} = grant [
            (
              core.namespaces
              |> allow [
                "list"
                "watch"
              ]
            )
            # A listener's certificateRefs and a BackendTLSPolicy's CA may
            # name Secrets and ConfigMaps in any namespace a ReferenceGrant
            # admits.
            (
              [
                core.services
                core.secrets
                core.configmaps
              ]
              |> watch
            )
            (
              disco.endpointslices
              |> allow [
                "list"
                "watch"
              ]
            )
            (map (k: gwApi.${k}) watchedKinds |> watch)
            (
              map (k: gwApi "${k}/status") (builtins.filter (k: k != "referencegrants") watchedKinds)
              |> allow [ "update" ]
            )
          ];
        };

        # Traefik's Gateway provider does not start while any watched kind
        # is missing, so the Deployment requires each CRD.
        crds = kix.contracts.experimental.gatewayApi.helpers.crdsFor {
          inherit scope;
          inherit gatewayApi;
          kinds = [
            "GatewayClass"
            "Gateway"
            "HTTPRoute"
            "GRPCRoute"
            "TLSRoute"
            "ReferenceGrant"
            "BackendTLSPolicy"
          ];
          # Traefik watches TLSRoute and BackendTLSPolicy at v1; the package
          # is tested with Gateway API 1.6.1.
          minVersion = "1.6.1";
        };
        watchedCrds = [
          crds.GatewayClass
          crds.Gateway
          crds.HTTPRoute
          crds.GRPCRoute
          crds.TLSRoute
          crds.ReferenceGrant
          crds.BackendTLSPolicy
        ];
      in
      if listenerProblems != [ ] then
        scope.fail (
          map (p: {
            message = p;
          }) listenerProblems
        )
      else
        {
          serviceAccount = scope.mkResource {
            apiVersion = "v1";
            kind = "ServiceAccount";
            inherit name;
            labels = selectorLabels;
          };

          clusterRole = clusterRbac.${clusterName};
          clusterRoleBinding = clusterRbac."${clusterName}-binding";

          deployment = scope.mkDeployment {
            inherit name;
            labels = selectorLabels;
            # Without its RBAC and the watched CRDs, Traefik's informers
            # never sync.
            requires = [
              self.clusterRole
              self.clusterRoleBinding
            ]
            ++ watchedCrds;
            spec = {
              inherit (config) replicas;
              selector.matchLabels = selectorLabels;
              template = {
                metadata.labels = selectorLabels;
                spec = {
                  serviceAccount = self.serviceAccount;
                  # Traefik drains open connections for
                  # entryPoints.<name>.transport.lifeCycle.graceTimeOut,
                  # 10s by default.
                  terminationGracePeriodSeconds = 30;
                  securityContext = {
                    runAsNonRoot = true;
                    runAsUser = 65532;
                    runAsGroup = 65532;
                    seccompProfile.type = "RuntimeDefault";
                  }
                  # A safe sysctl since Kubernetes 1.22. It lets the non-root
                  # process bind listener ports below 1024.
                  // lib.optionalAttrs (builtins.any (p: p < 1024) ports) {
                    sysctls = [
                      {
                        name = "net.ipv4.ip_unprivileged_port_start";
                        value = "0";
                      }
                    ];
                  };
                  containers = [
                    {
                      name = "traefik";
                      image = kix.image.ref config.image;
                      imagePullPolicy = config.image.pullPolicy;
                      inherit args env;
                      ports = map (ep: kix.port ep.name ep.port) entryPoints ++ [ (kix.port "traefik" internalPort) ];
                      livenessProbe = {
                        httpGet = {
                          path = "/ping";
                          port = "traefik";
                        };
                      };
                      readinessProbe = {
                        httpGet = {
                          path = "/ping";
                          port = "traefik";
                        };
                      };
                      inherit (config) resources;
                      securityContext = {
                        allowPrivilegeEscalation = false;
                        readOnlyRootFilesystem = true;
                        capabilities.drop = [ "ALL" ];
                      };
                    }
                  ];
                  nodeSelector."kubernetes.io/os" = "linux";
                };
              };
            };
          };

          service = scope.mkResource {
            apiVersion = "v1";
            kind = "Service";
            inherit name;
            labels = selectorLabels;
            annotations = config.service.annotations;
            spec = serviceSpec;
          };

          metricsService =
            if metricsOn then
              self.deployment
              |> kix.service.fromWorkload {
                name = "${name}-metrics";
                ports = [
                  {
                    name = "metrics";
                    port = internalPort;
                    targetPort = "traefik";
                  }
                ];
                labels = selectorLabels // {
                  "app.kubernetes.io/component" = "metrics";
                };
              }
              |> scope.mkResource
            else
              null;

          gatewayClass = scope.mkCR crds.GatewayClass {
            inherit name;
            labels = selectorLabels;
            spec.controllerName = controllerName;
          };

          gateway = scope.mkCR crds.Gateway {
            inherit name;
            labels = selectorLabels;
            spec = {
              gatewayClassName = self.gatewayClass.out.name;
              listeners = activeListeners;
            };
          };

          # The root is the Deployment; the Gateway is listed so the instance
          # is Ready only once Traefik has programmed it.
          root = {
            resource = self.deployment;
            requires = builtins.filter (r: r != null) [
              self.gateway
            ];
            out = kix.contracts.gateway.check scope {
              gatewayRef = {
                name = self.gateway.out.name;
                namespace = scope.namespaceName;
              };
              listeners = activeListeners;
              # Raw labels: the reader writes a policy selector from them and
              # already depends on this instance through gatewayRef.
              podSelector = selectorLabels;
              podNamespace = scope.namespaceName;
              # A ClusterIP Service is reachable from inside the cluster
              # only.
              public = serviceType != "ClusterIP";
              version = kix.image.version config.image;
            };
          };
        }
    )

    # DI passes a build function only the arguments its formals name, so
    # the wrapper names every argument kix.monitor reads.
    (
      {
        self,
        config,
        scope,
        lib,
        prometheus ? null,
        ...
      }@args:
      let
        sel = ''namespace="${scope.namespaceName}",service="${name}-metrics"'';
        instance = "Traefik ${scope.namespaceName}/${name}";
        # The metric's own `service` label names Traefik's backend service.
        # Prometheus keeps the scrape target's `service` and renames the
        # metric's to `exported_service`.
        backendRequests =
          filter:
          "sum by (namespace, service, exported_service) (rate(traefik_service_requests_total{${sel}${filter}}[5m]))";
        failed = backendRequests '',code=~"502|503|504"'';
        total = backendRequests "";
      in
      kix.monitor {
        service = "metricsService";
        port = "metrics";
        alerts = {
          TraefikDown = {
            expr = "sum by (namespace, service) (up{${sel}}) == 0 or absent(up{${sel}})";
            "for" = "10m";
            severity = "critical";
            summary = "Traefik is down.";
            description = "No replica of ${instance} has answered a scrape for 10 minutes, so requests to its Gateway's listeners get no answer. Check the Deployment ${name} in ${scope.namespaceName} and its pods' events.";
          };
          # A renewed certificate keeps its old serial's series until
          # Traefik restarts, so the newest expiry per name counts.
          TraefikCertificateExpiringSoon = {
            expr = "max by (namespace, service, cn, sans) (traefik_tls_certs_not_after{${sel}}) - time() < ${toString (kix.durations.toSeconds config.metrics.minCertificateValidity)}";
            "for" = "15m";
            severity = "warning";
            summary = "A certificate Traefik serves expires soon.";
            description = "The certificate for {{ $labels.cn }} ({{ $labels.sans }}) that ${instance} serves expires in {{ $value | humanizeDuration }}; after that clients refuse the connection. Check the Secret a Gateway listener names in certificateRefs, and the Certificate that renews it. A certificate Traefik stopped serving keeps its series until Traefik restarts.";
          };
          TraefikBackendErrorsHigh = {
            expr = "${failed} / ${total} > ${toString config.metrics.backendErrorRatio} and ${total} > ${toString config.metrics.backendErrorMinRate}";
            "for" = "15m";
            severity = "warning";
            summary = "Traefik cannot reach a backend for many requests.";
            description = "{{ $value | humanizePercentage }} of the requests ${instance} sent to backend {{ $labels.exported_service }} have ended in 502, 503, or 504 for 15 minutes. Traefik answers so when the backend Service has no ready endpoints, refuses the connection, or times out. The count also includes 503s the backend returns itself, such as while it is overloaded or in maintenance. Check the backend's pods and the HTTPRoute's backendRefs.";
          };
        };
      } args
    )
  ];
}
