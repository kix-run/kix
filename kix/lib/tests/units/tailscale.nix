# Tests for kix/packages/tailscale (refusals, the operator Deployment, the
# custom resource builders, out.mkIngress, out.mkBackendPolicy, and the
# CRD source tag) and for
# Services whose loadBalancerClass comes from kix.providedLoadBalancerClass:
# checkLoadBalancer skips the loadBalancer role for them, and derived policy
# gives them no ingress from outside the cluster. The operator runs in namespace
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
  inherit (import ../../vocab { inherit lib; }) untrackedRef providedLoadBalancerClass;

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
  # "provider" (tailscale's out.loadBalancerClass), "untracked" (the class
  # wrapped in kix.untrackedRef), "context" (the class with the context of
  # a resource and no provider marker), or a raw string.
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
            loadBalancerClass =
              if class == "provider" then
                tailscale.out.loadBalancerClass
              else if class == "untracked" then
                untrackedRef "tailscale"
              else if class == "context" then
                builtins.appendContext "tailscale" (builtins.getContext self.deployment.out.name)
              else
                class;
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
        clientIdEnv = clusterWith { config.env.CLIENT_ID = "x"; };
        apiServerProxyEnv = clusterWith { config.env.APISERVER_PROXY = "true"; };
        priorityClassEnv = clusterWith { config.env.PROXY_PRIORITY_CLASS_NAME = "x"; };
        proxyClassRoot = clusterWith {
          config = {
            proxyClasses.root = { };
            defaultProxyClass = "root";
          };
        };
        connectorMeta = clusterWith {
          config.connectors.meta.subnetRouter.advertiseRoutes = [ "10.0.0.0/8" ];
        };
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

  # Builder refusals: a plain-string proxyClass or Recorder Secret, a
  # Recorder Secret named by an instance outside the operator's namespace
  # (built there or from kix.untrackedRef), a
  # kube-apiserver ProxyGroup in auth mode, Ingress fields the package
  # sets, a port the Service lacks (checked without an enforcer), and a
  # Service without a selector.
  tailscale-builder-refusals =
    let
      withParts = extraParts: clusterWith { consumer = mkConsumer { inherit extraParts; }; };
      cases = {
        untrackedProxyGroup = withParts (
          { scope, tailscale, ... }:
          {
            extra = tailscale.out.mkProxyGroup scope {
              name = "extra";
              spec = {
                type = "egress";
                proxyClass = "small";
              };
            };
          }
        );
        untrackedRecorderSecret = withParts (
          { scope, tailscale, ... }:
          {
            extra = tailscale.out.mkRecorder scope {
              name = "extra";
              spec.storage.s3.credentials.secret.name = "s3";
            };
          }
        );
        untrackedRecorderSecretElsewhere = withParts (
          { scope, tailscale, ... }:
          {
            extra = tailscale.out.mkRecorder scope {
              name = "extra";
              spec.storage.s3.credentials.secret.name = untrackedRef "s3";
            };
          }
        );
        recorderSecretElsewhere = withParts (
          {
            self,
            scope,
            tailscale,
            ...
          }:
          {
            s3 = scope.mkSecret {
              name = "s3";
              stringData.AWS_ACCESS_KEY_ID = "x";
            };
            extra = tailscale.out.mkRecorder scope {
              name = "extra";
              spec.storage.s3.credentials.secret.name = self.s3.out.name;
            };
          }
        );
        ingressTls = clusterWith { consumer = mkConsumer { ingressSpec.tls = [ ]; }; };
        ingressClassName = clusterWith {
          consumer = mkConsumer { ingressSpec.ingressClassName = "other"; };
        };
        ingressDefaultBackend = clusterWith {
          consumer = mkConsumer { ingressSpec.defaultBackend.service.name = "web"; };
        };
        ingressMissingPort = withParts (
          {
            self,
            scope,
            tailscale,
            ...
          }:
          {
            extra = tailscale.out.mkIngress scope {
              name = "extra";
              service = self.service;
              port = 81;
            };
          }
        );
        pathMissingPort = clusterWith {
          consumer = mkConsumer {
            ingressSpec.rules = [
              {
                http.paths = [
                  {
                    path = "/";
                    pathType = "Prefix";
                    backend.service = {
                      name = "web";
                      port.number = 81;
                    };
                  }
                ];
              }
            ];
          };
        };
        selectorlessService = withParts (
          {
            self,
            scope,
            tailscale,
            ...
          }:
          {
            bare = scope.mkResource {
              apiVersion = "v1";
              kind = "Service";
              name = "bare";
              spec.ports = [ { port = 80; } ];
            };
            extra = tailscale.out.mkBackendPolicy scope { service = self.bare; };
          }
        );
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
      && podSpec.terminationGracePeriodSeconds == 30
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

  # mkIngress sets the class, the TLS host, and the default backend and
  # keeps the caller's paths; its policy is null without an enforcer. With
  # one, the Ingress policy admits the proxies on the pod port behind the
  # default backend and behind every path to the same Service, and the
  # LoadBalancer Service gets its own policy.
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
      withPaths = clusterWith {
        consumer = mkConsumer { ingressSpec.rules = [ { http.paths = paths; } ]; };
      };
      ingress = byName "web" (ofKind "Ingress" (manifests withPaths));
      policiesOf = c: ofKind "CiliumNetworkPolicy" (manifests c);
      enforced = policiesOf (clusterWith {
        modules = [ netpolOn ];
      });
      enforcedPaths = policiesOf (clusterWith {
        consumer = mkConsumer { ingressSpec.rules = [ { http.paths = paths; } ]; };
        modules = [ netpolOn ];
      });
      ruleOf = ps: name: builtins.head (byName name ps).spec.ingress;
      rule = ruleOf enforced "web-ingress-from-tailscale";
      targetPorts = ps: name: map (p: p.targetPort) (ruleOf ps name).ports;
      unenforced = builtins.filter (m: m.metadata.namespace or null == "demo") (policiesOf withPaths);
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
      && unenforced == [ ]
      && rule.callerSelector == { "tailscale.com/managed" = "true"; }
      && rule.callerNamespace == "tailscale"
      && targetPorts enforced "web-ingress-from-tailscale" == [ 8080 ]
      &&
        targetPorts enforcedPaths "web-ingress-from-tailscale" == [
          8080
          9090
        ]
      && byName "web-lb-from-tailscale" enforced != null
      &&
        (byName "web-ingress-from-tailscale" enforced).spec.endpointSelector.matchLabels
        == (find "Service" "web").spec.selector
    )
    || throw "tailscale ingress: ${builtins.toJSON ingress}, rule ${builtins.toJSON rule}";

  # One Service behind two Ingresses and two out.mkBackendPolicy calls gets
  # four policies with distinct names; a path that names the Service port
  # by name selects that port.
  tailscale-backend-policy-names =
    let
      consumer = mkConsumer {
        extraParts =
          {
            self,
            scope,
            tailscale,
            ...
          }:
          {
            adminIngress = tailscale.out.mkIngress scope {
              name = "admin";
              service = self.service;
              port = 9000;
              spec.rules = [
                {
                  http.paths = [
                    {
                      path = "/";
                      pathType = "Prefix";
                      backend.service = {
                        name = self.service.out.name;
                        port.name = "http";
                      };
                    }
                  ];
                }
              ];
            };
            adminPolicy = tailscale.out.mkBackendPolicy scope {
              service = self.service;
              port = "admin";
            };
            httpPolicy = tailscale.out.mkBackendPolicy scope {
              service = self.service;
              port = 80;
              name = "web-http";
            };
          };
      };
      policies = builtins.filter (m: m.metadata.namespace or null == "demo") (
        ofKind "CiliumNetworkPolicy" (
          manifests (clusterWith {
            inherit consumer;
            modules = [ netpolOn ];
          })
        )
      );
      portsOf = name: map (p: p.targetPort) (builtins.head (byName name policies).spec.ingress).ports;
    in
    (
      portsOf "web-ingress-from-tailscale" == [ 8080 ]
      &&
        portsOf "admin-ingress-from-tailscale" == [
          9090
          8080
        ]
      && portsOf "web-from-tailscale" == [ 9090 ]
      && portsOf "web-http-from-tailscale" == [ 8080 ]
    )
    || throw "tailscale backend policy names: ${builtins.toJSON (map (m: m.metadata.name) policies)}";

  # mkRecorder defaults the recorder image and pull policy, and accepts an
  # S3 Secret from kix.untrackedRef or from a Kix resource when it runs in
  # the operator's namespace.
  tailscale-recorder =
    let
      recorderPackage = secretName: {
        meta = {
          version = "test";
          description = "Recorder";
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
            s3 = scope.mkSecret {
              name = "s3";
              stringData.AWS_ACCESS_KEY_ID = "x";
            };
            recorder = tailscale.out.mkRecorder scope {
              name = "rec";
              spec.storage.s3.credentials.secret.name = secretName self;
            };
            root = self.recorder;
          };
      };
      recorderIn =
        ns: secretName:
        byName "rec" (
          ofKind "Recorder" (
            manifests (clusterWith {
              modules = [ { instances.${ns}.recorder.package = recorderPackage secretName; } ];
            })
          )
        );
      untracked = recorderIn "tailscale" (_: untrackedRef "s3");
      tracked = recorderIn "tailscale" (self: self.s3.out.name);
    in
    (
      untracked.spec.statefulSet.pod.container == {
        image = "docker.io/tailscale/tsrecorder:v1.102.4@sha256:47b602ddee9e97d2060fb017496f7758551e7e619ebfd984e94fb8541f581aea";
        imagePullPolicy = "IfNotPresent";
      }
      && untracked.spec.storage.s3.credentials.secret.name == "s3"
      && tracked.spec.storage.s3.credentials.secret.name == "s3"
    )
    || throw "tailscale recorder: ${builtins.toJSON untracked}";

  # Every URL in crds/sources.txt fetches from the tag of the package's
  # release, so the vendored CRDs match meta.version.
  tailscale-sources =
    let
      version =
        (tailscalePackage {
          inherit lib;
          scope = { };
          kix = { };
        }).meta.version;
      urls = builtins.filter (l: l != "" && !lib.hasPrefix "#" l) (
        lib.splitString "\n" (builtins.readFile ../../../packages/tailscale/crds/sources.txt)
      );
    in
    (builtins.length urls == 8 && builtins.all (lib.hasInfix "/v${version}/") urls)
    || throw "tailscale sources: crds/sources.txt does not fetch every CRD from v${version}: ${builtins.toJSON urls}";

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
  # tailscale builds, and the class adds the operator Deployment to its
  # depends-on and no entry for the marker. A raw class, one from
  # kix.untrackedRef, or one with other context still fails.
  tailscale-load-balancer-role =
    let
      cluster = lbCluster "provider" [ noLoadBalancer ];
      serviceDeps = c: lib.sort (a: b: a < b) (dependsOn (byName "lb" (ofKind "Service" (manifests c))));
      rawDeps = serviceDeps (lbCluster "x" [ ]);
      operator = hashOf cluster "tailscale" "tailscale" "deployment";
    in
    (
      !(evalFails cluster)
      && serviceDeps cluster == lib.sort (a: b: a < b) (rawDeps ++ [ operator ])
      && evalFails (lbCluster "tailscale" [ noLoadBalancer ])
      && evalFails (lbCluster "untracked" [ noLoadBalancer ])
      && evalFails (lbCluster "context" [ noLoadBalancer ])
    )
    || throw "tailscale load balancer role: provider class refused or its depends-on is ${builtins.toJSON (serviceDeps cluster)}, or a class without the provider marker accepted";

  # kix.providedLoadBalancerClass needs a class string and a resource in
  # `by`, and refuses other attributes.
  tailscale-provided-class-arguments =
    let
      throws = v: !(builtins.tryEval (builtins.deepSeq v true)).success;
      by = {
        outPath = "/nix/store/00000000000000000000000000000000-x";
      };
    in
    (
      throws (providedLoadBalancerClass { class = "x"; })
      && throws (providedLoadBalancerClass {
        class = "x";
        by = "operator";
      })
      && throws (providedLoadBalancerClass {
        class = "";
        inherit by;
      })
      && throws (providedLoadBalancerClass {
        class = "x";
        inherit by;
        extra = 1;
      })
    )
    || throw "kix.providedLoadBalancerClass accepted a malformed argument";

  # Derived policy gives a LoadBalancer Service's pods ingress from outside
  # the cluster unless its class comes from kix.providedLoadBalancerClass.
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
    (
      supplements "provider" == [ ]
      && supplements "other" != [ ]
      && supplements "untracked" != [ ]
      && supplements "context" != [ ]
    )
    || throw "tailscale external ingress: provider ${builtins.toJSON (supplements "provider")}";
}
