# Tests for kix/packages/experimental/envoy-gateway and
# kix/packages/experimental/gateway-api: what the controller install
# renders and how it is ordered, the EnvoyProxy the GatewayClass names, the
# settings and proxySpec locks, the removed options, one instance per
# cluster, the network policy for the proxies and the controller, and the
# alert rules. The instance is `envoy-gateway-system/eg` beside a
# gateway-api instance.

{
  lib,
  k8s,
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
  envoyGateway = import ../../../packages/experimental/envoy-gateway;
  gatewayApi = import ../../../packages/experimental/gateway-api;
  ns = "envoy-gateway-system";

  withGatewayApi = {
    instances.${ns}.gateway-api.package = gatewayApi;
  };

  clusterWith =
    {
      config ? { },
      extra ? { },
      availability ? null,
    }:
    mkCluster [
      withGatewayApi
      extra
      {
        instances.${ns}.eg = {
          package = envoyGateway;
          inherit config;
        }
        // lib.optionalAttrs (availability != null) { inherit availability; };
      }
    ];
  msWith = args: manifests (clusterWith args);
  plain = msWith { };

  envoyProxyOf = ms: (byName "eg" (ofKind "EnvoyProxy" ms)).spec;
  configOf =
    ms: builtins.fromJSON (byName "eg-config" (ofKind "ConfigMap" ms)).data."envoy-gateway.yaml";
  dependsOn = m: m.metadata.annotations."kix.run/depends-on" or "";
  hashOf = cluster: part: k8s.extractStoreHash cluster.instances.${ns}.eg.raw.${part}.outPath;
in
{
  # The default instance installs the controller and its pieces, under the
  # names Envoy Gateway fixes, and a GatewayClass that names the EnvoyProxy.
  envoy-gateway-renders-controller =
    let
      deployment = byName "eg" (ofKind "Deployment" plain);
      container = builtins.head deployment.spec.template.spec.containers;
      class = byName "eg" (ofKind "GatewayClass" plain);
      gateway = byName "eg" (ofKind "Gateway" plain);
      crdNames = map (m: m.metadata.name) (ofKind "CustomResourceDefinition" plain);
      proxy = envoyProxyOf plain;
      cfg = configOf plain;
    in
    (
      byName "envoy-gateway" (ofKind "Service" plain) != null
      && byName "eg-certgen" (ofKind "Job" plain) != null
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
      && lib.hasPrefix "docker.io/envoyproxy/envoy:distroless-v1.40.2@sha256:" proxy.provider.kubernetes.envoyDeployment.container.image
      && proxy.provider.kubernetes.envoyService.type == "LoadBalancer"
    )
    || throw "envoy-gateway default render: ${builtins.toJSON { inherit proxy cfg; }}";

  # The controller starts after every CRD and the certgen Job; the
  # GatewayClass waits for the controller, and the Gateway for its class.
  envoy-gateway-ordering =
    let
      cluster = clusterWith { };
      ms = manifests cluster;
      deployment = byName "eg" (ofKind "Deployment" ms);
      class = byName "eg" (ofKind "GatewayClass" ms);
      gateway = byName "eg" (ofKind "Gateway" ms);
      certSecret = byName "secret-ref-eg-envoy-gateway" (ofKind "PackageInstance" ms);
    in
    (
      lib.hasInfix (hashOf cluster "certgen") (dependsOn certSecret)
      && lib.hasInfix (hashOf cluster "certSecret") (dependsOn deployment)
      && lib.hasInfix (hashOf cluster "deployment") (dependsOn class)
      && lib.hasInfix (hashOf cluster "envoyProxy") (dependsOn class)
      && lib.hasInfix (hashOf cluster "gatewayClass") (dependsOn gateway)
      && lib.hasInfix (hashOf cluster "topologyInjector") (
        dependsOn (byName "eg-certgen" (ofKind "Job" ms))
      )
    )
    || throw "envoy-gateway ordering: deployment depends-on '${dependsOn deployment}'";

  # Without the Gateway API CRDs the instance does not evaluate; the
  # control has them.
  envoy-gateway-needs-gateway-api =
    evalFails (mkCluster [
      {
        instances.${ns}.eg.package = envoyGateway;
      }
    ])
    && (builtins.tryEval (builtins.deepSeq plain true)).success;

  # A second instance is refused; one evaluates (the control above).
  envoy-gateway-one-per-cluster = evalFails (mkCluster [
    withGatewayApi
    {
      instances.${ns}.eg.package = envoyGateway;
      instances.other.eg2.package = envoyGateway;
    }
  ]);

  # The options of the package that rendered only the GatewayClass and
  # Gateway fail with the change record's id.
  envoy-gateway-removed-options-refused =
    let
      pkg = envoyGateway {
        scope = { };
        inherit lib;
        kix = { };
        availability = "none";
      };
      assertionsFor = config: pkg.assertions { config = removed // config // tagOk; };
      removed = {
        controllerName = null;
        proxyNamespace = null;
        gatewayClassName = null;
        gatewayName = null;
      };
      tagOk.image.tag = "v1.10.0";
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
      config.image.tag = "v1.9.3";
    })
    && (builtins.tryEval (builtins.deepSeq (msWith { config.image.tag = "v1.10.1"; }) true)).success;

  # settings merges over the package's configuration; the paths the
  # package owns are refused.
  envoy-gateway-settings-locked =
    let
      cfg = configOf (msWith {
        config.settings.logging.level.default = "debug";
      });
    in
    cfg.logging.level.default == "debug"
    && cfg.gateway.controllerName == "gateway.envoyproxy.io/gatewayclass-controller"
    && evalFails (clusterWith {
      config.settings.provider.kubernetes.deploy.type = "GatewayNamespace";
    })
    && evalFails (clusterWith {
      config.settings.gateway.controllerName = "example.com/x";
    })
    && evalFails (clusterWith {
      config.settings.envoyProxy.logging.level.default = "debug";
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
        (builtins.head spread).labelSelector.matchLabels."gateway.envoyproxy.io/owning-gateway-name" == "eg"
      && (byName "eg" (ofKind "Deployment" zoned)).spec.replicas == 2
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
      proxyIn = byName "eg-proxy-ingress" cnps;
      proxyOut = byName "eg-proxy-egress" cnps;
      controllerIn = byName "eg-controller-from-proxies" cnps;
      ports = lib.concatMap (r: map (p: p.port) r.ports) proxyIn.spec.ingress;
      callerPorts = map (p: p.port) (builtins.head controllerIn.spec.ingress).ports;
    in
    (
      proxyIn.spec.endpointSelector.matchLabels."gateway.envoyproxy.io/owning-gateway-name" == "eg"
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
        };
      on = withProm true;
      controller = alertRulesOf "PrometheusRule" "eg" on;
      proxy = alertRulesOf "PrometheusRule" "eg-proxy" on;
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
      && allSelect ''namespace="${ns}",job="${ns}/eg-proxy"'' proxy
      && byName "eg-proxy" (ofKind "PodMonitor" on) != null
      && alertRulesOf "PrometheusRule" "eg" off == null
      && byName "eg-proxy" (ofKind "PodMonitor" off) == null
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
}
