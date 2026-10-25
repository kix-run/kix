# traefik: the Traefik proxy as a Gateway API implementation. Traefik is its
# own controller and data plane: the pods that watch Gateways and HTTPRoutes
# are the pods that serve the traffic.
#
# Installs the Traefik Deployment, its ServiceAccount and RBAC, the Service in
# front of it, a GatewayClass with Traefik's controller name, and a Gateway
# with the instance's listeners. Only the kubernetesGateway provider is on.
# `metrics.enabled` turns on Traefik's Prometheus metrics; with the optional
# `prometheus` dep it also adds Service <name>-metrics and a ServiceMonitor.
# The package ships no alerts.
#
# The Gateway API standard-channel CRDs (v1.6.1 or later) arrive outside Kix,
# as for envoy-gateway. The package references every kind Traefik watches,
# so the Deployment starts only after those CRDs are Established; with a
# kind missing, Traefik's Gateway provider never starts.
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
# No dependency or option is required:
#
#   instances.gateway-system.traefik.package = packages.traefik;
#
# Exposes (the gateway contract, kix.contracts.gateway):
#   out.gatewayRef    the Gateway, the parentRef of every HTTPRoute kix.expose
#                     renders.
#   out.listeners     the rendered listeners, from which kix.expose picks a
#                     route's URL scheme and port.
#   out.podSelector, out.podNamespace
#                     the Traefik pods, for the policy kix.expose writes so
#                     they can reach each exposed backend.
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
  release = "v3.7.13";

  # Traefik's GatewayClass controller, pkg/provider/kubernetes/gateway/kubernetes.go.
  controllerName = "traefik.io/gateway-controller";

  name = scope.instanceName;
  who = "traefik ${scope.namespaceName}/${name}";
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
    k8s.minVersion = "1.26";
    network.intents = {
      # HTTPRoutes name their backends at runtime, on any port, so the graph
      # cannot see Traefik's upstream connections.
      backends.egress = [ { to = "all-pods"; } ];
      # Clients outside the cluster, plus in-cluster clients and NodePort
      # traffic that arrives SNATed from a node.
      front-door.ingress = [
        {
          from = "world";
          ports = map tcp openPorts;
        }
        {
          from = "all-pods";
          ports = map tcp openPorts;
        }
      ];
    };
  };

  options = {
    image = kix.options.image {
      repository = "docker.io/library/traefik";
      tag = release;
      digest = "sha256:24841fe2de7304c149343d877d2923b4c8800a38ba015dea9174c23b20e344a0";
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
    metrics = kix.options.monitor;
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
            throw (
              lib.concatMapStringsSep "\n" (
                k: "${who}: service.spec.${k} is set by the package, which ${serviceSpecOwned.${k}}"
              ) serviceSpecOwnedHits
            )
          else if serviceType == "ClusterIP" && config.service.spec.externalTrafficPolicy != null then
            throw "${who}: service.spec.externalTrafficPolicy applies to NodePort and LoadBalancer Services, and the API server rejects it on ClusterIP. Change service.spec.type or remove it."
          else
            kix.mergeGuarded
              {
                inherit who;
                what = "service.spec";
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

        # Traefik matches flag names in any case, accepts one or two leading
        # dashes (paerser flag/flagparser.go), and turns a provider on when
        # any key under it is set, so kix.guardArgs, which matches exact
        # flags, cannot express these rules. flagOf gives "--<lowercase
        # name>" for a flag and null for a value argument.
        flagOf =
          arg:
          let
            name = builtins.head (lib.splitString "=" arg);
          in
          if lib.hasPrefix "-" name then
            "--${lib.toLower (lib.removePrefix "-" (lib.removePrefix "-" name))}"
          else
            null;
        ownedFlags =
          lib.listToAttrs (
            map (
              ep:
              lib.nameValuePair "--entrypoints.${lib.toLower ep.name}.address" "the package derives it from the listener on port ${toString ep.port}; change the listeners instead."
            ) entryPoints
          )
          // {
            "--entrypoints.traefik.address" =
              "the probes and the metrics Service use port ${toString internalPort}; remove it.";
            "--ping" = "the probes use /ping on the internal entrypoint; remove it.";
            "--ping.entrypoint" = "the probes use /ping on the internal entrypoint; remove it.";
            "--metrics.prometheus" = "the package sets it from metrics.enabled; set that instead.";
            "--metrics.prometheus.entrypoint" =
              "the metrics Service scrapes the internal entrypoint on port ${toString internalPort}; remove it.";
            "--providers.kubernetesgateway" = "the package turns the Gateway provider on; remove it.";
            "--providers.kubernetesgateway.labelselector" =
              "the package selects this instance's GatewayClass; remove it.";
            "--providers.kubernetesgateway.statusaddress.service.name" =
              "the package points it at the Traefik Service; remove it.";
            "--providers.kubernetesgateway.statusaddress.service.namespace" =
              "the package points it at the Traefik Service; remove it.";
            "--providers.kubernetesgateway.experimentalchannel" =
              "it makes Traefik watch TCPRoute, which needs experimental-channel CRDs and RBAC the package does not grant; remove it.";
            "--configfile" =
              "with a configuration file Traefik ignores every flag, including the ones the package sets; use extraArgs instead.";
          };
        # Any key under these turns the provider on.
        refusedFamilies = {
          "--providers.kubernetescrd" =
            "Traefik's CRD provider needs Traefik's CRDs and RBAC, which the package does not install; route through the Gateway with kix.expose.";
          "--providers.kubernetesingress" =
            "the Ingress provider needs RBAC the package does not grant; route through the Gateway with kix.expose.";
          "--providers.kubernetesingressnginx" =
            "the ingress-nginx provider needs RBAC the package does not grant; route through the Gateway with kix.expose.";
          "--providers.knative" = "the Knative provider needs RBAC the package does not grant; remove it.";
        };
        reasonFor =
          arg:
          let
            flag = flagOf arg;
            family = lib.findFirst (f: flag == f || lib.hasPrefix "${f}." flag) null (
              builtins.attrNames refusedFamilies
            );
          in
          if flag == null then
            null
          else if ownedFlags ? ${flag} then
            "which the package owns: ${ownedFlags.${flag}}"
          else if family != null then
            "which this package refuses: ${refusedFamilies.${family}}"
          else
            null;
        argProblems = builtins.concatMap (
          arg:
          let
            reason = reasonFor arg;
          in
          lib.optional (reason != null) "${who}: extraArgs sets \"${arg}\", ${reason}"
        ) config.extraArgs;

        args = [
          "--global.checkNewVersion=false"
          "--entryPoints.traefik.address=:${toString internalPort}"
          "--ping=true"
          "--providers.kubernetesGateway=true"
          "--providers.kubernetesGateway.labelSelector=${
            lib.concatStringsSep "," (lib.mapAttrsToList (k: v: "${k}=${v}") selectorLabels)
          }"
          "--providers.kubernetesGateway.statusAddress.service.name=${self.service.out.name}"
          "--providers.kubernetesGateway.statusAddress.service.namespace=${scope.namespaceName}"
        ]
        # Traefik matches a listener to an entrypoint by the address suffix
        # ":<port>", so the address carries no "/tcp".
        ++ map (ep: "--entryPoints.${ep.name}.address=:${toString ep.port}") entryPoints
        # The flag follows the toggle alone, so adding a prometheus instance
        # does not restart Traefik.
        ++ lib.optional config.metrics.enabled "--metrics.prometheus=true"
        ++ config.extraArgs;

        traefikEnv = builtins.filter (lib.hasPrefix "TRAEFIK_") (builtins.attrNames config.env);
        env =
          if traefikEnv != [ ] then
            throw "${who}: env sets ${lib.concatStringsSep ", " traefikEnv}, which Traefik ignores because it reads its configuration from flags. Pass the setting in extraArgs."
          else
            kix.mkEnvVars (kix.mergeEnv { inherit who; } config.env);

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

        # The CRD refs give the Deployment its CRD-before-pod edge: Traefik's
        # Gateway provider does not start while any watched kind is missing.
        crdRef =
          kind: plural: version: extra:
          scope.mkCRDRef (
            {
              group = gatewayApiGroup;
              inherit kind plural version;
            }
            // extra
          );
      in
      if listenerProblems != [ ] then
        throw (lib.concatMapStringsSep "\n" (p: "${who}: ${p}") listenerProblems)
      else if argProblems != [ ] then
        throw (lib.concatStringsSep "\n" argProblems)
      else
        {
          # The same markers envoy-gateway and kix.expose emit, with the
          # Gateway API's readiness: a GatewayClass is usable once
          # Accepted=True, a Gateway once Programmed=True.
          gatewayClassCrd = crdRef "GatewayClass" "gatewayclasses" "v1" {
            crdScope = "Cluster";
            readiness.condition = {
              type = "Accepted";
              status = "True";
            };
          };
          gatewayCrd = crdRef "Gateway" "gateways" "v1" {
            crdScope = "Namespaced";
            readiness.condition = {
              type = "Programmed";
              status = "True";
            };
          };
          httpRouteCrd = crdRef "HTTPRoute" "httproutes" "v1" { };
          grpcRouteCrd = crdRef "GRPCRoute" "grpcroutes" "v1" { };
          tlsRouteCrd = crdRef "TLSRoute" "tlsroutes" "v1" { };
          referenceGrantCrd = crdRef "ReferenceGrant" "referencegrants" "v1beta1" { };
          backendTlsPolicyCrd = crdRef "BackendTLSPolicy" "backendtlspolicies" "v1" { };

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
              self.gatewayClassCrd
              self.gatewayCrd
              self.httpRouteCrd
              self.grpcRouteCrd
              self.tlsRouteCrd
              self.referenceGrantCrd
              self.backendTlsPolicyCrd
            ];
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

          gatewayClass = self.gatewayClassCrd.out.mkCR scope {
            inherit name;
            labels = selectorLabels;
            spec.controllerName = controllerName;
          };

          gateway = self.gatewayCrd.out.mkCR scope {
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
              self.serviceMonitor
            ];
            out = kix.contracts.gateway.check who {
              gatewayRef = {
                name = self.gateway.out.name;
                namespace = scope.namespaceName;
              };
              listeners = activeListeners;
              # Raw labels: the reader writes a policy selector from them and
              # already depends on this instance through gatewayRef.
              podSelector = selectorLabels;
              podNamespace = scope.namespaceName;
            };
          };
        }
    )

    (kix.monitor {
      service = "metricsService";
      port = "metrics";
    })
  ];
}
