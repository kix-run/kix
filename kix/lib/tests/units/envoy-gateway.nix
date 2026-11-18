# Tests for kix/packages/experimental/envoy-gateway-controller,
# kix/packages/experimental/envoy-gateway, and
# kix/packages/experimental/gateway-api: what the controller install
# renders and how it is ordered, the EnvoyProxy each Gateway names, the
# settings and proxySpec locks, the removed options, one controller and
# several Gateways per cluster, the network policy for the proxies and the
# controller, and the alert rules. The controller is
# `envoy-gateway-system/eg` and the Gateway `envoy-gateway-system/gw`,
# beside a gateway-api instance.

{
  lib,
  k8s,
  kixKeys,
  kixlib,
  eval,
  mkCluster,
  manifests,
  ofKind,
  byName,
  evalFails,
  prometheusStub,
  netpolOn,
  alertRulesOf,
  allSelect,
  multiZone,
  ...
}:

let
  envoyGatewayController = import ../../../packages/experimental/envoy-gateway-controller;
  envoyGateway = import ../../../packages/experimental/envoy-gateway;
  gatewayApi = import ../../../packages/experimental/gateway-api;
  ns = "envoy-gateway-system";
  contract = kixlib.contracts.experimental.gatewayApi;

  # A platform import that claims the gatewayApi role with the kinds
  # envoy-gateway needs. `readiness = false` drops the conditions, and
  # `version = null` drops out.version.
  importApi =
    {
      readiness ? true,
      version ? "1.6.1",
    }:
    let
      entry =
        kind: plural: extra:
        {
          group = "gateway.networking.k8s.io";
          inherit kind plural;
          version = "v1";
        }
        // extra;
      ready =
        type:
        lib.optionalAttrs readiness {
          readiness.condition = {
            inherit type;
            status = "True";
          };
        };
    in
    {
      cluster.roles.gatewayApi.binding = "exclusive";
      instances.gatewayapi.platform-gateway-api.package = eval.mkImport {
        roles = [ "gatewayApi" ];
        out = lib.optionalAttrs (version != null) { inherit version; };
        crds = [
          (entry "GatewayClass" "gatewayclasses" ({ crdScope = "Cluster"; } // ready "Accepted"))
          (entry "Gateway" "gateways" (ready "Programmed"))
          (entry "HTTPRoute" "httproutes" { })
          (entry "ReferenceGrant" "referencegrants" { })
        ];
      };
    };

  withGatewayApi = {
    instances.${ns}.gateway-api.package = gatewayApi;
  };

  clusterWith =
    {
      config ? { },
      controllerConfig ? { },
      extra ? { },
      availability ? null,
    }:
    let
      level = lib.optionalAttrs (availability != null) { inherit availability; };
    in
    mkCluster [
      withGatewayApi
      extra
      {
        instances.${ns} = {
          eg = {
            package = envoyGatewayController;
            config = controllerConfig;
          }
          // level;
          gw = {
            package = envoyGateway;
            inherit config;
          }
          // level;
        };
      }
    ];
  # The controller and one Gateway, with no gateway-api instance.
  bare.instances.${ns} = {
    eg.package = envoyGatewayController;
    gw.package = envoyGateway;
  };
  msWith = args: manifests (clusterWith args);
  plain = msWith { };

  envoyProxyOf = ms: (byName "gw" (ofKind "EnvoyProxy" ms)).spec;
  configOf =
    ms:
    builtins.fromJSON (byName "envoy-gateway-config" (ofKind "ConfigMap" ms)).data."envoy-gateway.yaml";
  dependsOn = m: m.metadata.annotations.${kixKeys.dependsOn} or "";
  hashOf = cluster: part: k8s.extractStoreHash cluster.instances.${ns}.eg.raw.${part}.outPath;
  gatewayHashOf = cluster: part: k8s.extractStoreHash cluster.instances.${ns}.gw.raw.${part}.outPath;
in
{
  # The controller instance installs the controller and its pieces, under
  # the names Envoy Gateway fixes, and a GatewayClass. The Gateway instance
  # adds a Gateway of that class that names its own EnvoyProxy.
  envoy-gateway-renders-controller =
    let
      deployment = byName "envoy-gateway" (ofKind "Deployment" plain);
      container = builtins.head deployment.spec.template.spec.containers;
      class = byName "eg" (ofKind "GatewayClass" plain);
      gateway = byName "gw" (ofKind "Gateway" plain);
      classProxy = (byName "eg" (ofKind "EnvoyProxy" plain)).spec;
      crdNames = map (m: m.metadata.name) (ofKind "CustomResourceDefinition" plain);
      proxy = envoyProxyOf plain;
      cfg = configOf plain;
    in
    (
      byName "envoy-gateway" (ofKind "Service" plain) != null
      && byName "eg-certgen" (ofKind "Job" plain) != null
      && byName "envoy-gateway-certgen" (ofKind "ServiceAccount" plain) != null
      &&
        byName "envoy-gateway-topology-injector.${ns}" (ofKind "MutatingWebhookConfiguration" plain) != null
      && lib.hasPrefix "docker.io/envoyproxy/gateway:v1.10.0@sha256:" container.image
      && builtins.elem "envoyproxies.gateway.envoyproxy.io" crdNames
      && builtins.elem "gateways.gateway.networking.k8s.io" crdNames
      && cfg.gateway.controllerName == "gateway.envoyproxy.io/gatewayclass-controller"
      && lib.hasPrefix "docker.io/envoyproxy/gateway:" cfg.provider.kubernetes.shutdownManager.image
      && class.spec.controllerName == "gateway.envoyproxy.io/gatewayclass-controller"
      &&
        class.spec.parametersRef == {
          group = "gateway.envoyproxy.io";
          kind = "EnvoyProxy";
          name = "eg";
          namespace = ns;
        }
      && gateway.spec.gatewayClassName == "eg"
      &&
        gateway.spec.infrastructure.parametersRef == {
          group = "gateway.envoyproxy.io";
          kind = "EnvoyProxy";
          name = "gw";
        }
      && lib.hasPrefix "docker.io/envoyproxy/envoy:distroless-v1.40.2@sha256:" classProxy.provider.kubernetes.envoyDeployment.container.image
      && lib.hasPrefix "docker.io/envoyproxy/envoy:distroless-v1.40.2@sha256:" proxy.provider.kubernetes.envoyDeployment.container.image
      && proxy.provider.kubernetes.envoyService.type == "LoadBalancer"
    )
    || throw "envoy-gateway default render: ${builtins.toJSON { inherit proxy cfg; }}";

  # The controller starts after every CRD and the certgen Job; the
  # GatewayClass waits for the controller, and the Gateway for its class.
  envoy-gateway-ordering =
    let
      cluster = clusterWith { };
      netpolCluster = clusterWith { extra = netpolOn; };
      ms = manifests cluster;
      deployment = byName "envoy-gateway" (ofKind "Deployment" ms);
      class = byName "eg" (ofKind "GatewayClass" ms);
      gateway = byName "gw" (ofKind "Gateway" ms);
      certSecret = byName "secret-ref-eg-envoy-gateway" (ofKind "PackageInstance" ms);
    in
    (
      lib.hasInfix (hashOf cluster "certgen") (dependsOn certSecret)
      && lib.hasInfix (hashOf cluster "certSecret") (dependsOn deployment)
      && lib.hasInfix (hashOf cluster "deployment") (dependsOn class)
      && lib.hasInfix (hashOf cluster "envoyProxy") (dependsOn class)
      && lib.hasInfix (hashOf cluster "service") (dependsOn class)
      && lib.hasInfix (hashOf netpolCluster "controllerIngress") (
        dependsOn (byName "eg" (ofKind "GatewayClass" (manifests netpolCluster)))
      )
      && lib.hasInfix (hashOf cluster "gatewayClass") (dependsOn gateway)
      && lib.hasInfix (gatewayHashOf cluster "envoyProxy") (dependsOn gateway)
      && lib.hasInfix (hashOf cluster "topologyInjector") (
        dependsOn (byName "eg-certgen" (ofKind "Job" ms))
      )
    )
    || throw "envoy-gateway ordering: deployment depends-on '${dependsOn deployment}'";

  # Without the Gateway API CRDs the instance does not evaluate, and the
  # refusal is the contract's, with the change record id; the control has
  # them.
  envoy-gateway-needs-gateway-api =
    let
      errors = contract.helpers.errorsFor {
        who = "${ns}/eg";
        gatewayApi = null;
        kinds = [
          "GatewayClass"
          "Gateway"
          "HTTPRoute"
          "ReferenceGrant"
        ];
        minVersion = "1.6";
      };
    in
    evalFails (mkCluster [ bare ])
    && builtins.length errors == 1
    && (builtins.head errors).id == "K5531"
    && lib.hasInfix "packages.experimental.gateway-api" (builtins.head errors).fix
    && (builtins.tryEval (builtins.deepSeq plain true)).success;

  # A second controller is refused. The guard is the cluster-wide conflict
  # on the package's own alias; one instance evaluates (the control above).
  envoy-gateway-one-per-cluster =
    let
      meta =
        (envoyGatewayController {
          scope = { };
          inherit lib;
          kix = { };
          availability = "none";
        }).meta;
    in
    builtins.elem "cluster:envoyGateway" meta.conflictsWith
    && builtins.elem "envoyGateway" meta.defaultAliases
    && evalFails (mkCluster [
      withGatewayApi
      {
        instances.${ns}.eg.package = envoyGatewayController;
        instances.other.eg2.package = envoyGatewayController;
      }
    ]);

  # A cluster runs several Gateways on the one controller. Each has its own
  # EnvoyProxy, so its own Service type, and its own proxy pods in the
  # policies and the contract.
  envoy-gateway-several-gateways =
    let
      two = mkCluster [
        withGatewayApi
        netpolOn
        {
          instances.monitoring.prometheus.package = prometheusStub;
          instances.${ns} = {
            eg.package = envoyGatewayController;
            public.package = envoyGateway;
            private = {
              package = envoyGateway;
              aliases = [ "privateGateway" ];
              config.proxySpec.provider.kubernetes.envoyService.type = "ClusterIP";
            };
          };
        }
      ];
      ms = manifests two;
      typeOf = n: (byName n (ofKind "EnvoyProxy" ms)).spec.provider.kubernetes.envoyService.type;
      out = n: two.instances.${ns}.${n}.out;
      ownerOf = n: (out n).podSelector."gateway.envoyproxy.io/owning-gateway-name";
      cnps = ofKind "CiliumNetworkPolicy" ms;
    in
    (
      typeOf "public" == "LoadBalancer"
      && typeOf "private" == "ClusterIP"
      && (out "public").gatewayRef.name == "public"
      && (out "private").gatewayRef.name == "private"
      && ownerOf "public" == "public"
      && ownerOf "private" == "private"
      && byName "public-proxy-ingress" cnps != null
      && byName "private-proxy-egress" cnps != null
      && byName "public-proxy" (ofKind "PodMonitor" ms) != null
      && byName "private-proxy" (ofKind "PodMonitor" ms) != null
      && alertRulesOf "PrometheusRule" "public-proxy" ms != null
      && alertRulesOf "PrometheusRule" "private-proxy" ms != null
      && builtins.length (ofKind "GatewayClass" ms) == 1
    )
    || throw "envoy-gateway several gateways: ${builtins.toJSON (map (m: m.metadata.name) cnps)}";

  # A Gateway with no controller is refused, as is one outside the
  # controller's namespace and one whose controller is a kix.mkImport, which
  # names no GatewayClass. The control is the default cluster.
  envoy-gateway-needs-the-controller =
    evalFails (mkCluster [
      withGatewayApi
      { instances.${ns}.gw.package = envoyGateway; }
    ])
    && evalFails (mkCluster [
      withGatewayApi
      {
        instances.${ns}.eg.package = envoyGatewayController;
        instances.other.gw.package = envoyGateway;
      }
    ])
    && evalFails (mkCluster [
      withGatewayApi
      {
        instances.${ns} = {
          eg = {
            package = eval.mkImport { };
            aliases = [ "envoyGateway" ];
          };
          gw.package = envoyGateway;
        };
      }
    ])
    && (builtins.tryEval (builtins.deepSeq plain true)).success;

  # A platform import answers the gatewayApi role when it declares the kinds
  # a consumer needs, the readiness of GatewayClass and Gateway, and a
  # version. envoy-gateway's Gateway then carries the readiness the deploy
  # waits on.
  envoy-gateway-gateway-api-import =
    let
      ms = manifests (mkCluster [
        (importApi { })
        bare
      ]);
      gw = byName "gw" (ofKind "Gateway" ms);
    in
    builtins.fromJSON gw.metadata.annotations.${kixKeys.readiness} == {
      condition = {
        type = "Programmed";
        status = "True";
      };
    };

  # An import that leaves out a kind, the readiness, or the version, or that
  # is too old, is refused by the contract with a message that names it.
  envoy-gateway-gateway-api-import-refused =
    let
      importOut =
        args:
        let
          c = mkCluster [ (importApi args) ];
        in
        c.instances.gatewayapi.platform-gateway-api;
      errorsWith =
        args: kinds:
        contract.helpers.errorsFor {
          who = "${ns}/eg";
          gatewayApi = importOut args;
          inherit kinds;
          minVersion = "1.6";
        };
      says = text: errors: errors != [ ] && lib.hasInfix text (builtins.head errors).message;
      traefikKinds = [
        "GatewayClass"
        "Gateway"
        "GRPCRoute"
      ];
    in
    errorsWith { } traefikKinds != [ ]
    && says "GRPCRoute" (errorsWith { } traefikKinds)
    && errorsWith { } [ "Gateway" ] == [ ]
    && says "has no readiness condition" (errorsWith { readiness = false; } [ "Gateway" ])
    && says "provides Gateway API 1.5.1" (errorsWith { version = "1.5.1"; } [ "Gateway" ])
    && says "out.version is missing" (errorsWith { version = null; } [ "Gateway" ])
    && evalFails (mkCluster [
      (importApi { })
      { instances.${ns}.traefik.package = import ../../../packages/experimental/traefik; }
    ])
    && evalFails (mkCluster [
      (importApi { readiness = false; })
      bare
    ]);

  # The options of the package that also named a controller installed
  # outside Kix fail with the change record's id.
  envoy-gateway-removed-options-refused =
    let
      pkg = envoyGateway {
        scope = { };
        inherit lib;
        kix = { };
        availability = "none";
      };
      assertionsFor = config: pkg.assertions { config = removed // config; };
      removed = {
        controllerName = null;
        proxyNamespace = null;
        gatewayClassName = null;
        gatewayName = null;
      };
      failing = config: builtins.filter (a: !a.assertion) (assertionsFor config);
      one = failing { proxyNamespace = "gwns"; };
    in
    (
      builtins.length one == 1
      && (builtins.head one).id == "K5531"
      && (builtins.head one).option == "proxyNamespace"
      && failing { } == [ ]
      && evalFails (clusterWith {
        config.controllerName = "example.com/other";
      })
    )
    || throw "envoy-gateway removed options: ${builtins.toJSON one}";

  # An image of another minor release than the vendored CRDs is refused.
  envoy-gateway-image-minor-checked =
    evalFails (clusterWith {
      controllerConfig.image.tag = "v1.9.3";
    })
    && (builtins.tryEval (builtins.deepSeq (msWith { controllerConfig.image.tag = "v1.10.1"; }) true))
      .success;

  # settings merges over the package's configuration; the paths the
  # package owns are refused.
  envoy-gateway-settings-locked =
    let
      cfg = configOf (msWith {
        controllerConfig.settings.logging.level.default = "debug";
      });
    in
    cfg.logging.level.default == "debug"
    && cfg.gateway.controllerName == "gateway.envoyproxy.io/gatewayclass-controller"
    && evalFails (clusterWith {
      controllerConfig.settings.provider.kubernetes.deploy.type = "GatewayNamespace";
    })
    && evalFails (clusterWith {
      controllerConfig.settings.gateway.controllerName = "example.com/x";
    })
    && evalFails (clusterWith {
      controllerConfig.settings.envoyProxy.logging.level.default = "debug";
    });

  # proxySpec merges over the package's EnvoyProxy: the replica count and
  # the Service type may change, the image and the spread may not.
  envoy-gateway-proxyspec-locked =
    let
      proxy = envoyProxyOf (msWith {
        config.proxySpec = {
          provider.kubernetes.envoyService.type = "ClusterIP";
          provider.kubernetes.envoyDeployment.replicas = 3;
          logging.level.default = "warn";
        };
      });
    in
    (
      proxy.provider.kubernetes.envoyService.type == "ClusterIP"
      && proxy.provider.kubernetes.envoyDeployment.replicas == 3
      && proxy.provider.kubernetes.envoyPDB.minAvailable == 1
      && proxy.logging.level.default == "warn"
      && evalFails (clusterWith {
        config.proxySpec.provider.kubernetes.envoyDeployment.container.image = "example.com/envoy:1";
      })
      && evalFails (clusterWith {
        config.proxySpec.provider.type = "Host";
      })
      && evalFails (clusterWith {
        config.proxySpec.mergeGateways = true;
      })
      &&
        (envoyProxyOf (msWith {
          config.proxySpec.provider.type = "Kubernetes";
        })).provider.type == "Kubernetes"
    )
    || throw "envoy-gateway proxySpec: ${builtins.toJSON proxy}";

  # Replicas follow the availability level: one proxy and one controller
  # at none, and at zone two of each, the proxies spread by zone with a
  # PodDisruptionBudget.
  envoy-gateway-availability =
    let
      zoned = msWith {
        extra = multiZone;
        availability = "zone";
      };
      proxy = envoyProxyOf zoned;
      spread = proxy.provider.kubernetes.envoyDeployment.pod.topologySpreadConstraints;
      single = envoyProxyOf (msWith {
        availability = "none";
      });
    in
    (
      single.provider.kubernetes.envoyDeployment.replicas == 1
      && !(single.provider.kubernetes ? envoyPDB)
      && proxy.provider.kubernetes.envoyDeployment.replicas == 2
      && proxy.provider.kubernetes.envoyPDB.minAvailable == 1
      && builtins.any (
        c: c.topologyKey == "topology.kubernetes.io/zone" && c.whenUnsatisfiable == "DoNotSchedule"
      ) spread
      &&
        (builtins.head spread).labelSelector.matchLabels."gateway.envoyproxy.io/owning-gateway-name" == "gw"
      && (byName "envoy-gateway" (ofKind "Deployment" zoned)).spec.replicas == 2
    )
    || throw "envoy-gateway availability: ${builtins.toJSON proxy}";

  # A cluster with no load balancer gets a NodePort proxy Service.
  envoy-gateway-nodeport-without-load-balancer =
    (envoyProxyOf (msWith {
      extra.cluster.roles.loadBalancer.binding = "absent";
    })).provider.kubernetes.envoyService.type == "NodePort";

  # Under network policy: the proxies take client traffic on the shifted
  # listener ports and reach every pod; the controller admits the proxies
  # to xDS and Wasm.
  envoy-gateway-network-policy =
    let
      cnps = ofKind "CiliumNetworkPolicy" (msWith {
        extra = netpolOn;
        config.listeners = [
          {
            name = "http";
            port = 80;
            protocol = "HTTP";
          }
          {
            name = "alt";
            port = 8443;
            protocol = "HTTP";
          }
        ];
      });
      proxyIn = byName "gw-proxy-ingress" cnps;
      proxyOut = byName "gw-proxy-egress" cnps;
      controllerIn = byName "eg-controller-from-proxies" cnps;
      ports = lib.concatMap (r: map (p: p.port) r.ports) proxyIn.spec.ingress;
      callerPorts = map (p: p.port) (builtins.head controllerIn.spec.ingress).ports;
    in
    (
      proxyIn.spec.endpointSelector.matchLabels."gateway.envoyproxy.io/owning-gateway-name" == "gw"
      && builtins.elem 10080 ports
      && builtins.elem 8443 ports
      && !(builtins.elem 80 ports)
      && proxyOut != null
      &&
        callerPorts == [
          18000
          18002
        ]
    )
    || throw "envoy-gateway policies: ${builtins.toJSON { inherit proxyIn controllerIn; }}";

  # With a prometheus dependency and metrics on, the controller's and the
  # proxies' rules render and select their own series; with metrics off,
  # neither does.
  envoy-gateway-alerts =
    let
      withProm =
        enabled:
        msWith {
          extra.instances.monitoring.prometheus.package = prometheusStub;
          config.metrics.enabled = enabled;
          controllerConfig.metrics.enabled = enabled;
        };
      on = withProm true;
      controller = alertRulesOf "PrometheusRule" "eg" on;
      proxy = alertRulesOf "PrometheusRule" "gw-proxy" on;
      off = withProm false;
    in
    (
      builtins.attrNames controller == [
        "EnvoyGatewayConfigRejected"
        "EnvoyGatewayDown"
        "EnvoyGatewayProxyApplyFailing"
      ]
      &&
        builtins.attrNames proxy == [
          "EnvoyProxyControlPlaneLost"
          "EnvoyProxyDown"
        ]
      && allSelect ''namespace="${ns}",service="eg-metrics"'' controller
      && allSelect ''namespace="${ns}",job="${ns}/gw-proxy"'' proxy
      && byName "gw-proxy" (ofKind "PodMonitor" on) != null
      && alertRulesOf "PrometheusRule" "eg" off == null
      && alertRulesOf "PrometheusRule" "gw-proxy" off == null
      && byName "gw-proxy" (ofKind "PodMonitor" off) == null
    )
    || throw "envoy-gateway alerts: ${builtins.toJSON (builtins.attrNames controller)}";

  # gateway-api carries the bundle's annotations onto each CRD, renders the
  # safe-upgrades policy, and claims the role, so a second set is refused.
  envoy-gateway-gateway-api-crds =
    let
      crd = byName "httproutes.gateway.networking.k8s.io" (ofKind "CustomResourceDefinition" plain);
    in
    crd.metadata.annotations."gateway.networking.k8s.io/channel" == "standard"
    && crd.metadata.annotations ? "api-approved.kubernetes.io"
    &&
      byName "safe-upgrades.gateway.networking.k8s.io" (ofKind "ValidatingAdmissionPolicy" plain) != null
    && evalFails (mkCluster [
      withGatewayApi
      { instances.other.gateway-api.package = gatewayApi; }
    ]);

  # A Gateway with no rendered listener is refused; HTTPS without
  # certificateRefs is a placeholder.
  envoy-gateway-needs-a-listener = evalFails (clusterWith {
    config.listeners = [
      {
        name = "https";
        port = 443;
        protocol = "HTTPS";
        tls.certificateRefs = [ ];
      }
    ];
  });

  # With useListenerPortAsContainerPort the proxies listen on the listener
  # port itself, and the policy opens that port.
  envoy-gateway-listener-port-as-container-port =
    let
      cnps = ofKind "CiliumNetworkPolicy" (msWith {
        extra = netpolOn;
        config.proxySpec.provider.kubernetes.useListenerPortAsContainerPort = true;
      });
      ports = lib.concatMap (r: map (p: p.port) r.ports) (byName "gw-proxy-ingress" cnps).spec.ingress;
    in
    builtins.elem 80 ports && !(builtins.elem 10080 ports);

  # The proxies' egress, and that of the other Gateway and Ingress
  # controllers, reaches pods only. Cilium renders the `pods` target as an
  # endpoint selector over every namespace, with no entity, so the nodes,
  # the kubelet, and the API server stay closed.
  envoy-gateway-proxy-egress-reaches-pods-only =
    let
      cilium = import ../../../packages/experimental/cilium/netpol-rules.nix { inherit lib; };
      rendered =
        (cilium.translateIntentRules { intents.backends.egress = [ { to = "pods"; } ]; }).egressRules;
      cnps = ofKind "CiliumNetworkPolicy" (msWith {
        extra = netpolOn;
      });
      proxyOut = (byName "gw-proxy-egress" cnps).spec.egress;
      intentTargets = builtins.concatMap (r: lib.optional (r ? to) r.to) proxyOut;
      metaOf =
        pkg:
        (pkg {
          scope = { };
          inherit lib;
          kix = { };
          availability = "none";
        }).meta;
      backendsOf = pkg: (metaOf pkg).network.intents.backends.egress;
    in
    (
      lib.all (r: !(r ? toEntities) && r ? toEndpoints) rendered
      && intentTargets == [ "pods" ]
      && backendsOf (import ../../../packages/experimental/traefik) == [ { to = "pods"; } ]
      && backendsOf (import ../../../packages/experimental/ingress-nginx) == [ { to = "pods"; } ]
    )
    || throw "proxy egress: ${builtins.toJSON { inherit rendered proxyOut; }}";

  # A PodDisruptionBudget set in proxySpec replaces the package's, so the
  # EnvoyProxy never carries both minAvailable and maxUnavailable.
  envoy-gateway-proxy-pdb-replaced =
    let
      pdb =
        (envoyProxyOf (msWith {
          availability = "node";
          extra = multiZone;
          config.proxySpec.provider.kubernetes.envoyPDB.maxUnavailable = 1;
        })).provider.kubernetes.envoyPDB;
    in
    pdb == { maxUnavailable = 1; } || throw "envoy-gateway PDB: ${builtins.toJSON pdb}";
}
