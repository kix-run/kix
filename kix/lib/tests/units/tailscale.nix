# Tests for kix/packages/tailscale (refusals, the operator Deployment, the
# custom resource builders, out.mkIngress and out.mkBackendPolicy) and for
# Services whose loadBalancerClass carries a dependency: checkLoadBalancer
# skips the loadBalancer role for them, and derived policy gives them no
# ingress from outside the cluster. The operator runs in namespace
# `tailscale`, the consumer in `demo`.

{
  lib,
  kixKeys,
  mkCluster,
  netpolOn,
  manifests,
  ofKind,
  byName,
  evalFails,
  ...
}:

let
  tailscalePackage = import ../../../packages/tailscale;
  secretPackage = import ../../../packages/secret;

  nameserverDigest = "sha256:3676e2277ad16da948caee7952b2a27859a66b905edd981e1bb58b2626bc92a4";

  # A backend Deployment with two Services on the tailnet: one behind
  # out.mkIngress and one LoadBalancer with out.loadBalancerClass. Also a
  # ProxyClass from out.crds, a Connector and a noauth kube-apiserver
  # ProxyGroup that name it, and a DNSConfig. `extraParts` adds parts for
  # the refusal cases.
  mkConsumer =
    {
      extraParts ? _: { },
      ingressSpec ? { },
    }:
    {
      meta = {
        version = "test";
        description = "tailscale consumer";
        owner = "test";
      };
      build =
        {
          self,
          scope,
          tailscale,
          ...
        }:
        {
          deployment = scope.mkDeployment {
            name = "web";
            spec = {
              replicas = 1;
              selector.matchLabels = scope.selectorLabels;
              template.spec.containers = [
                {
                  name = "web";
                  image = "web:1";
                  ports = [
                    {
                      name = "http";
                      containerPort = 8080;
                    }
                    {
                      name = "admin";
                      containerPort = 9090;
                    }
                  ];
                }
              ];
            };
          };
          service = scope.mkResource {
            apiVersion = "v1";
            kind = "Service";
            name = "web";
            labels."app.kubernetes.io/component" = "web";
            spec = {
              selector = scope.selectorLabels;
              ports = [
                {
                  name = "http";
                  port = 80;
                  targetPort = 8080;
                }
                {
                  name = "admin";
                  port = 9000;
                  targetPort = 9090;
                }
              ];
            };
          };
          tailnet = tailscale.out.mkIngress scope {
            name = "web";
            service = self.service;
            port = 80;
            spec = ingressSpec;
          };
          lbService = scope.mkResource {
            apiVersion = "v1";
            kind = "Service";
            name = "web-lb";
            labels."app.kubernetes.io/component" = "lb";
            spec = {
              type = "LoadBalancer";
              loadBalancerClass = tailscale.out.loadBalancerClass;
              selector = scope.selectorLabels;
              ports = [
                {
                  name = "http";
                  port = 80;
                  targetPort = 8080;
                }
              ];
            };
          };
          lbPolicy = tailscale.out.mkBackendPolicy scope { service = self.lbService; };
          proxyClass = scope.mkCR tailscale.out.crds.ProxyClass {
            name = "small";
            spec = { };
          };
          connector = tailscale.out.mkConnector scope {
            name = "router";
            spec = {
              proxyClass = self.proxyClass.out.name;
              subnetRouter.advertiseRoutes = [ "10.0.0.0/8" ];
            };
          };
          apiProxy = tailscale.out.mkProxyGroup scope {
            name = "api";
            spec = {
              type = "kube-apiserver";
              kubeAPIServer.mode = "noauth";
              proxyClass = self.proxyClass.out.name;
            };
          };
          dns = tailscale.out.mkDNSConfig scope { };
          root = {
            resource = self.deployment;
            requires = [
              self.tailnet.ingress
              self.lbService
              self.connector
              self.apiProxy
              self.dns
            ];
          };
        }
        // extraParts { inherit self scope tailscale; };
    };

  oauthCredentials = stringData: {
    package = secretPackage;
    aliases = [ "oauthCredentials" ];
    config = { inherit stringData; };
  };
  validCredentials = {
    client_id = "id";
    client_secret = "secret";
  };

  clusterWith =
    {
      config ? { },
      consumer ? mkConsumer { },
      credentials ? validCredentials,
      modules ? [ ],
    }:
    mkCluster (
      [
        {
          instances.tailscale.tailscale = {
            package = tailscalePackage;
            inherit config;
          };
          instances.tailscale.oauth-credentials = oauthCredentials credentials;
          instances.demo.consumer.package = consumer;
        }
      ]
      ++ modules
    );

  cluster = clusterWith { };
  ms = manifests cluster;
  find = kind: name: byName name (ofKind kind ms);
  readinessOf = m: (m.metadata.annotations or { }).${kixKeys.readiness} or null;
  dependsOn = m: lib.splitString "," ((m.metadata.annotations or { }).${kixKeys.dependsOn} or "");
  hashOf =
    c: ns: inst: part:
    builtins.unsafeDiscardStringContext c.instances.${ns}.${inst}.raw.${part}.out.identityHash;
  outOf = c: c.instances.tailscale.tailscale.raw.root.out;
  envOf =
    c:
    builtins.listToAttrs (
      map (e: lib.nameValuePair e.name (e.value or e.valueFrom))
        (builtins.head (byName "tailscale" (ofKind "Deployment" (manifests c)))
          .spec.template.spec.containers).env
    );

  # A one-Service package for the loadBalancerClass tests. `class` is
  # "provider" (tailscale's out.loadBalancerClass) or a raw string.
  mkLbPackage = class: {
    meta = {
      version = "test";
      description = "LoadBalancer Service";
      owner = "test";
    };
    build =
      {
        self,
        scope,
        tailscale,
        ...
      }:
      {
        deployment = scope.mkDeployment {
          name = "lb";
          spec = {
            replicas = 1;
            selector.matchLabels = scope.selectorLabels;
            template.spec.containers = [
              {
                name = "lb";
                image = "lb:1";
                ports = [
                  {
                    name = "http";
                    containerPort = 8080;
                  }
                ];
              }
            ];
          };
        };
        service = scope.mkResource {
          apiVersion = "v1";
          kind = "Service";
          name = "lb";
          spec = {
            type = "LoadBalancer";
            loadBalancerClass = if class == "provider" then tailscale.out.loadBalancerClass else class;
            selector = scope.selectorLabels;
            ports = [
              {
                port = 80;
                targetPort = 8080;
              }
            ];
          };
        };
        root = {
          resource = self.deployment;
          requires = [ self.service ];
        };
      };
  };
  lbCluster =
    class: modules:
    mkCluster (
      [
        {
          instances.tailscale.tailscale.package = tailscalePackage;
          instances.tailscale.oauth-credentials = oauthCredentials validCredentials;
          instances.demo.lb.package = mkLbPackage class;
        }
      ]
      ++ modules
    );
  noLoadBalancer = {
    cluster.roles.loadBalancer.binding = "absent";
  };
in
{
  # Every check that reads only the instance config fails the build, and
  # so does each owned env key and missing OAuth key.
  tailscale-refusals =
    let
      cases = {
        defaultProxyClass = clusterWith { config.defaultProxyClass = "missing"; };
        connectorProxyClass = clusterWith {
          config.connectors.office = {
            proxyClass = "missing";
            subnetRouter.advertiseRoutes = [ "10.0.0.0/8" ];
          };
        };
        proxyImageEnv = clusterWith { config.env.PROXY_IMAGE = "x"; };
        defaultLoadBalancerEnv = clusterWith { config.env.OPERATOR_DEFAULT_LOAD_BALANCER = "true"; };
        loginServerPort = clusterWith { config.env.OPERATOR_LOGIN_SERVER = "https://hs.example:8443"; };
        operandPullPolicy = clusterWith { config.operandImages.tailscale.pullPolicy = "Always"; };
        missingClientSecret = clusterWith { credentials.client_id = "id"; };
        otherRelease = clusterWith { config.image.tag = "v1.84.0"; };
      };
      passing = {
        declaredDefault = clusterWith {
          config = {
            proxyClasses.default = { };
            defaultProxyClass = "default";
          };
        };
        declaredConnector = clusterWith {
          config = {
            proxyClasses.default = { };
            connectors.office = {
              proxyClass = "default";
              subnetRouter.advertiseRoutes = [ "10.0.0.0/8" ];
            };
          };
        };
        loginServer443 = clusterWith { config.env.OPERATOR_LOGIN_SERVER = "https://hs.example"; };
        samePatch = clusterWith { config.image.tag = "v1.102.3"; };
      };
      notFailing = builtins.attrNames (lib.filterAttrs (_: c: !(evalFails c)) cases);
      notPassing = builtins.attrNames (lib.filterAttrs (_: c: evalFails c) passing);
    in
    (notFailing == [ ] && notPassing == [ ])
    || throw "tailscale refusals: accepted ${builtins.toJSON notFailing}, refused ${builtins.toJSON notPassing}";

  # Builder refusals: a plain-string proxyClass, a kube-apiserver
  # ProxyGroup in auth mode, an Ingress rule with a host, and a dotted
  # hostname.
  tailscale-builder-refusals =
    let
      withParts = extraParts: clusterWith { consumer = mkConsumer { inherit extraParts; }; };
      cases = {
        untrackedConnector = withParts (
          { scope, tailscale, ... }:
          {
            extra = tailscale.out.mkConnector scope {
              name = "extra";
              spec.proxyClass = "small";
            };
          }
        );
        authProxyGroup = withParts (
          { scope, tailscale, ... }:
          {
            extra = tailscale.out.mkProxyGroup scope {
              name = "extra";
              spec.type = "kube-apiserver";
            };
          }
        );
        ruleHost = clusterWith {
          consumer = mkConsumer { ingressSpec.rules = [ { host = "web.example"; } ]; };
        };
        dottedHostname = withParts (
          {
            self,
            scope,
            tailscale,
            ...
          }:
          {
            extra = tailscale.out.mkIngress scope {
              name = "extra";
              hostname = "web.example";
              service = self.service;
              port = 80;
            };
          }
        );
      };
      notFailing = builtins.attrNames (lib.filterAttrs (_: c: !(evalFails c)) cases);
    in
    (notFailing == [ ] && !(evalFails cluster))
    || throw "tailscale builder refusals: accepted ${builtins.toJSON notFailing}";

  # The operator runs as uid 65532 with a read-only root, mounts the two
  # OAuth keys, and gets the operand images pinned.
  tailscale-deployment =
    let
      deployment = find "Deployment" "tailscale";
      podSpec = deployment.spec.template.spec;
      container = builtins.head podSpec.containers;
      oauth = lib.findFirst (v: v.name == "oauth") null podSpec.volumes;
      env = envOf cluster;
    in
    (
      podSpec.securityContext.runAsNonRoot
      && podSpec.securityContext.runAsUser == 65532
      && container.securityContext.readOnlyRootFilesystem
      && oauth.secret.secretName == "oauth-credentials"
      &&
        map (i: i.key) oauth.secret.items == [
          "client_id"
          "client_secret"
        ]
      &&
        env.PROXY_IMAGE
        == "docker.io/tailscale/tailscale:v1.102.4@sha256:2667499ed87ae29218f292556ba062918402dd5e92e93637af14867e4df12dd3"
      && env.OPERATOR_INGRESS_CLASS_NAME == "tailscale"
      && !(env ? PROXY_DEFAULT_CLASS)
      && find "IngressClass" "tailscale" != null
      && ofKind "Service" (builtins.filter (m: m.metadata.namespace or null == "tailscale") ms) == [ ]
    )
    || throw "tailscale deployment: ${builtins.toJSON podSpec}";

  # out.crds is keyed by Kind; every kind but ProxyGroupPolicy declares
  # readiness; the Connector waits for its ProxyClass; out.extraImages
  # lists the four operand images, each pinned.
  tailscale-out =
    let
      out = outOf cluster;
      connector = find "Connector" "router";
    in
    (
      builtins.attrNames out.crds == [
        "Connector"
        "DNSConfig"
        "PeerRelay"
        "ProxyClass"
        "ProxyGroup"
        "ProxyGroupPolicy"
        "Recorder"
        "Tailnet"
      ]
      &&
        readinessOf connector == builtins.toJSON {
          condition = {
            status = "True";
            type = "ConnectorReady";
          };
        }
      && builtins.elem (hashOf cluster "demo" "consumer" "proxyClass") (dependsOn connector)
      && connector.spec.proxyClass == "small"
      && readinessOf (find "ProxyClass" "small") != null
      && (find "ProxyGroup" "api").spec.kubeAPIServer.mode == "noauth"
      && builtins.length out.extraImages == 4
      && builtins.all (lib.hasInfix "@sha256:") out.extraImages
      && builtins.unsafeDiscardStringContext out.loadBalancerClass == "tailscale"
      && builtins.hasContext out.loadBalancerClass
    )
    || throw "tailscale out: crds ${builtins.toJSON (builtins.attrNames out.crds)}, connector ${builtins.toJSON connector}";

  # The DNSConfig is named ts-dns and carries the nameserver image with its
  # digest on the tag; a moved nameserver tag drops the digest.
  tailscale-dnsconfig =
    let
      imageOf = c: (byName "ts-dns" (ofKind "DNSConfig" (manifests c))).spec.nameserver.image;
      moved = clusterWith { config.operandImages.k8s-nameserver.tag = "v1.102.3"; };
    in
    (
      imageOf cluster == {
        repo = "docker.io/tailscale/k8s-nameserver";
        tag = "v1.102.4@${nameserverDigest}";
      }
      &&
        imageOf moved == {
          repo = "docker.io/tailscale/k8s-nameserver";
          tag = "v1.102.3";
        }
    )
    || throw "tailscale dnsconfig: ${builtins.toJSON (imageOf cluster)}, moved ${builtins.toJSON (imageOf moved)}";

  # mkIngress sets the class, the TLS host and the default backend and
  # keeps the caller's paths; its policy is null without an enforcer. With
  # one, both backends get a policy from the proxies on the pod port
  # behind the chosen Service port.
  tailscale-ingress =
    let
      paths = [
        {
          path = "/admin";
          pathType = "Prefix";
          backend.service = {
            name = "web";
            port.number = 9000;
          };
        }
      ];
      c = clusterWith { consumer = mkConsumer { ingressSpec.rules = [ { http.paths = paths; } ]; }; };
      ingress = byName "web" (ofKind "Ingress" (manifests c));
      enforced = manifests (clusterWith {
        modules = [ netpolOn ];
      });
      policy = name: byName name (ofKind "CiliumNetworkPolicy" enforced);
      rule = builtins.head (policy "web-from-tailscale").spec.ingress;
      policies = builtins.filter (m: m.metadata.namespace or null == "demo") (
        ofKind "CiliumNetworkPolicy" (manifests c)
      );
    in
    (
      ingress.spec.ingressClassName == "tailscale"
      && ingress.spec.tls == [ { hosts = [ "web" ]; } ]
      &&
        ingress.spec.defaultBackend.service == {
          name = "web";
          port.number = 80;
        }
      && (builtins.head ingress.spec.rules).http.paths == paths
      && policies == [ ]
      && rule.callerSelector == { "tailscale.com/managed" = "true"; }
      && rule.callerNamespace == "tailscale"
      && map (p: p.targetPort) rule.ports == [ 8080 ]
      && policy "web-lb-from-tailscale" != null
      &&
        (policy "web-from-tailscale").spec.endpointSelector.matchLabels == (find "Service" "web")
        .spec.selector
    )
    || throw "tailscale ingress: ${builtins.toJSON ingress}, rule ${builtins.toJSON rule}";

  # metricsService renders only with a prometheus provider; the operand
  # policies render only with an enforcer.
  tailscale-gated-parts =
    let
      enforced = manifests (clusterWith {
        modules = [ netpolOn ];
      });
      operandPolicies = builtins.filter (
        m: (m.metadata.labels or { }).${kixKeys.policyType} or null == "operator-managed-workload"
      ) enforced;
    in
    (
      cluster.instances.tailscale.tailscale.raw.metricsService == null
      &&
        map (m: m.metadata.name) operandPolicies == [
          "tailscale-nameservers"
          "tailscale-proxies"
          "tailscale-proxy-groups"
          "tailscale-recorders"
          "tailscale-service-proxies"
        ]
    )
    || throw "tailscale gated parts: ${builtins.toJSON (map (m: m.metadata.name) operandPolicies)}";

  # With the loadBalancer role absent, a Service whose class comes from
  # tailscale builds and a raw class still fails.
  tailscale-load-balancer-role =
    (
      !(evalFails (lbCluster "provider" [ noLoadBalancer ]))
      && evalFails (lbCluster "tailscale" [ noLoadBalancer ])
    )
    || throw "tailscale load balancer role: provider class refused, or raw class accepted";

  # Derived policy gives a LoadBalancer Service's pods ingress from outside
  # the cluster only when its class is a raw string.
  tailscale-external-ingress =
    let
      supplements =
        class:
        builtins.filter (
          m:
          m.metadata.namespace or null == "demo"
          && (m.metadata.labels or { }).${kixKeys.policyType} or null == "external-ingress-supplement"
        ) (ofKind "CiliumNetworkPolicy" (manifests (lbCluster class [ netpolOn ])));
    in
    (supplements "provider" == [ ] && supplements "other" != [ ])
    || throw "tailscale external ingress: provider ${builtins.toJSON (supplements "provider")}";
}
