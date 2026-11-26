# Tests for the scrape policies of the netpol plugin
# (kix/lib/plugins/netpol/scrape.nix) with the real prometheus-operator and
# prometheus packages: the server's egress to every target it selects, the
# target-side ingress, host-network targets, named ports, the Prometheus
# selectors, `networkPolicy.directions` and `defaultDeny`, namespace
# selection, two servers, the warnings for targets Kix cannot open, and the
# remote-write egress that the Prometheus CRD's `factBehavior` derives.

{
  lib,
  mkCluster,
  baseInstances,
  netpolOn,
  manifests,
  ofKind,
  byName,
  containerBase,
  kixKeys,
  evalFails,
  ...
}:

let
  pkg = name: (import ../../../packages/by-level.nix { inherit lib; }).byName.${name};

  # A Deployment with a named metrics port behind a Service whose
  # targetPort is that name, a ServiceMonitor over the Service, and a
  # PodMonitor with a port number over pods an operator would create (no Kix
  # workload carries their labels).
  scraped = {
    meta.version = "test";
    build =
      {
        self,
        scope,
        prometheus,
        ...
      }:
      {
        deployment = scope.mkDeployment {
          name = "web";
          spec = {
            selector.matchLabels = scope.selectorLabels;
            template = {
              metadata.labels = scope.selectorLabels;
              spec.containers = [
                (
                  {
                    name = "web";
                    image = "example/web:1";
                    ports = [
                      {
                        name = "metrics";
                        containerPort = 8080;
                      }
                    ];
                  }
                  // containerBase
                )
              ];
            };
          };
        };
        service = scope.mkResource {
          apiVersion = "v1";
          kind = "Service";
          name = "web";
          labels = scope.selectorLabels;
          spec = {
            selector = scope.selectorLabels;
            ports = [
              {
                name = "metrics";
                port = 80;
                targetPort = "metrics";
              }
            ];
          };
        };
        serviceMonitor = prometheus.out.mkServiceMonitor scope {
          name = "web";
          labels.team = "apps";
          spec = {
            selector.matchLabels = scope.selectorLabels;
            endpoints = [ { port = "metrics"; } ];
          };
        };
        podMonitor = prometheus.out.mkPodMonitor scope {
          name = "operand";
          spec = {
            selector.matchLabels.app = "operand";
            podMetricsEndpoints = [ { portNumber = 9187; } ];
          };
        };
        root = {
          resource = self.deployment;
          requires = [
            self.service
            self.serviceMonitor
            self.podMonitor
          ];
        };
      };
  };

  configMap = scope: name: {
    cm = scope.mkResource {
      apiVersion = "v1";
      kind = "ConfigMap";
      inherit name;
    };
  };

  # Stands in for a custom resource whose operator creates the `app=operand`
  # pods, with an operand policy on `endpointSelector` that admits only
  # their peers.
  operandPeers = operandPeersOn { matchLabels.app = "operand"; };
  operandPeersOn =
    endpointSelector:
    { kix, ... }:
    {
      meta.version = "test";
      build =
        { self, scope, ... }:
        configMap scope "operand-cr"
        // {
          peers = kix.operandPolicy {
            inherit scope;
            name = "operand-peers";
            spec = {
              inherit endpointSelector;
              ingress = [ { fromEndpoints = [ { matchLabels.app = "operand"; } ]; } ];
            };
          };
          root = {
            resource = self.cm;
            requires = lib.optional (self.peers != null) self.peers;
          };
        };
    };

  # A namespace with custom resources only.
  crOnly = {
    meta.version = "test";
    build =
      { self, scope, ... }:
      configMap scope "listener-cr"
      // {
        root = self.cm;
      };
  };

  # A package with one PodMonitor and no workload.
  podMonitorOnly = name: spec: {
    meta.version = "test";
    build =
      {
        self,
        scope,
        prometheus,
        ...
      }:
      {
        podMonitor = prometheus.out.mkPodMonitor scope { inherit name spec; };
        root = self.podMonitor;
      };
  };

  # A Deployment whose pods carry `tier=api` beside the Service selector, a
  # ServiceMonitor over the Service, and an ingress policy with
  # `endpointSelector` that admits only the pods' peers.
  tiered = endpointSelector: {
    meta.version = "test";
    build =
      {
        self,
        scope,
        kix,
        prometheus,
        ...
      }:
      let
        podLabels = scope.selectorLabels // {
          tier = "api";
        };
      in
      {
        deployment = scope.mkDeployment {
          name = "api";
          spec = {
            selector.matchLabels = scope.selectorLabels;
            template = {
              metadata.labels = podLabels;
              spec.containers = [
                (
                  {
                    name = "api";
                    image = "example/api:1";
                    ports = [ { containerPort = 8081; } ];
                  }
                  // containerBase
                )
              ];
            };
          };
        };
        service = scope.mkResource {
          apiVersion = "v1";
          kind = "Service";
          name = "api";
          labels = scope.selectorLabels;
          spec = {
            selector = scope.selectorLabels;
            ports = [ { port = 8081; } ];
          };
        };
        serviceMonitor = prometheus.out.mkServiceMonitor scope {
          name = "api";
          spec = {
            selector.matchLabels = scope.selectorLabels;
            endpoints = [ { targetPort = 8081; } ];
          };
        };
        peers = kix.operandPolicy {
          inherit scope;
          name = "api-peers";
          spec = {
            inherit endpointSelector;
            ingress = [ { fromEndpoints = [ { matchLabels = podLabels; } ]; } ];
          };
        };
        root = {
          resource = self.deployment;
          requires = [
            self.service
            self.serviceMonitor
            self.peers
          ];
        };
      };
  };

  # Two Deployments behind one Service declare the container port `metrics`
  # with different numbers, and the Service's targetPort is that name.
  twoNumbers = {
    meta.version = "test";
    build =
      {
        self,
        scope,
        prometheus,
        ...
      }:
      let
        deployment =
          name: containerPort:
          let
            podLabels = scope.selectorLabels // {
              role = name;
            };
          in
          scope.mkDeployment {
            inherit name;
            spec = {
              selector.matchLabels = podLabels;
              template = {
                metadata.labels = podLabels;
                spec.containers = [
                  (
                    {
                      name = "app";
                      image = "example/app:1";
                      ports = [
                        {
                          name = "metrics";
                          inherit containerPort;
                        }
                      ];
                    }
                    // containerBase
                  )
                ];
              };
            };
          };
      in
      {
        first = deployment "amb-a" 8080;
        second = deployment "amb-b" 9090;
        service = scope.mkResource {
          apiVersion = "v1";
          kind = "Service";
          name = "amb";
          labels = scope.selectorLabels;
          spec = {
            selector = scope.selectorLabels;
            ports = [
              {
                name = "metrics";
                port = 80;
                targetPort = "metrics";
              }
            ];
          };
        };
        serviceMonitor = prometheus.out.mkServiceMonitor scope {
          name = "amb";
          spec = {
            selector.matchLabels = scope.selectorLabels;
            endpoints = [ { port = "metrics"; } ];
          };
        };
        root = {
          resource = self.service;
          requires = [
            self.first
            self.second
            self.serviceMonitor
          ];
        };
      };
  };

  # A host-network DaemonSet whose ServiceMonitor endpoint names a target
  # port no container declares, so the scrape port has no number.
  hostExporter = {
    meta.version = "test";
    build =
      {
        self,
        scope,
        prometheus,
        ...
      }:
      {
        daemonSet = scope.mkDaemonSet {
          name = "hostexp";
          spec = {
            selector.matchLabels = scope.selectorLabels;
            template = {
              metadata.labels = scope.selectorLabels;
              spec = {
                hostNetwork = true;
                containers = [
                  (
                    {
                      name = "exp";
                      image = "example/exp:1";
                      ports = [ { containerPort = 9999; } ];
                    }
                    // containerBase
                  )
                ];
              };
            };
          };
        };
        service = scope.mkResource {
          apiVersion = "v1";
          kind = "Service";
          name = "hostexp";
          labels = scope.selectorLabels;
          spec = {
            selector = scope.selectorLabels;
            ports = [
              {
                name = "web";
                port = 9999;
              }
            ];
          };
        };
        serviceMonitor = prometheus.out.mkServiceMonitor scope {
          name = "hostexp";
          spec = {
            selector.matchLabels = scope.selectorLabels;
            endpoints = [ { targetPort = "metrics"; } ];
          };
        };
        root = {
          resource = self.daemonSet;
          requires = [
            self.service
            self.serviceMonitor
          ];
        };
      };
  };

  # A remote-write receiver and a Prometheus CR that writes to it.
  receiver = {
    meta.version = "test";
    build =
      { self, scope, ... }:
      {
        deployment = scope.mkDeployment {
          name = "receiver";
          spec = {
            selector.matchLabels = scope.selectorLabels;
            template = {
              metadata.labels = scope.selectorLabels;
              spec.containers = [
                (
                  {
                    name = "receiver";
                    image = "example/receiver:1";
                    ports = [ { containerPort = 9201; } ];
                  }
                  // containerBase
                )
              ];
            };
          };
        };
        service = scope.mkResource {
          apiVersion = "v1";
          kind = "Service";
          name = "receiver";
          spec = {
            selector = scope.selectorLabels;
            ports = [ { port = 9201; } ];
          };
        };
        root = {
          resource = self.service;
          requires = [ self.deployment ];
        };
      };
  };
  remoteWriter = {
    meta.version = "test";
    build =
      {
        self,
        scope,
        prometheus,
        receiver,
        ...
      }:
      {
        writer = scope.mkCR prometheus.out.crds.Prometheus {
          name = "writer";
          spec.remoteWrite = [ { url = "http://${receiver.out.fqdn}:9201/api/v1/write"; } ];
        };
        root = self.writer;
      };
  };

  clusterWith =
    {
      server ? { },
      extra ? { },
    }:
    mkCluster [
      { instances.dns = baseInstances.instances.dns; }
      netpolOn
      {
        instances.monitoring = {
          prometheus-operator.package = pkg "prometheus-operator";
          prometheus-server = {
            package = pkg "prometheus";
            config = server;
          };
          node-exporter.package = pkg "node-exporter";
        };
        instances.apps.scraped.package = scraped;
      }
      extra
    ];

  matchExpressionsPods = {
    instances.watch.expr.package = podMonitorOnly "expr" {
      selector.matchExpressions = [
        {
          key = "app";
          operator = "In";
          values = [ "expr" ];
        }
      ];
      podMetricsEndpoints = [ { portNumber = 9090; } ];
    };
  };

  unnamedServer = {
    cluster.factBehavior."monitoring.coreos.com/Prometheus".endpoint = "conduct";
  };

  noDefaultDeny = {
    networkPolicy.defaultDeny = false;
  };

  # PodMonitor `watch/named` over pods an operator would create, scraped on
  # a port name that no Kix container declares.
  namedPortPods = {
    instances.watch.named.package = podMonitorOnly "named" {
      selector.matchLabels.app = "named";
      podMetricsEndpoints = [ { port = "pgexporter"; } ];
    };
  };

  scrapeLib = import ../../plugins/netpol/scrape.nix { inherit lib; };

  # Runs `scrape.derive` under default deny over the cluster's resources and
  # reports its errors as warnings prefixed "scrape error: ".
  errorProbe.hooks.clusterProcessors.scrape-error-probe = ctx: {
    warnings =
      map (e: "scrape error: ${e}")
        (scrapeLib.derive {
          inherit (ctx) resources nsResources realNsNames;
          enforcerApi = (ctx.cluster.findRoleProvider "network-policy-enforcer").out.netpol;
          enforced = {
            ingress = true;
            egress = true;
          };
          defaultDeny = true;
        }).errors;
  };

  # True when `extra` fails evaluation under default deny and the scrape
  # derivation reports an error containing `infix` for it. The errors are
  # read from a cluster without default deny, which evaluates.
  failsUnderDefaultDeny =
    infix: extra:
    let
      probed = clusterWith {
        extra.imports = [
          extra
          noDefaultDeny
          errorProbe
        ];
      };
      errors = map (lib.removePrefix "scrape error: ") (
        builtins.filter (lib.hasPrefix "scrape error: ") (warningsOf probed)
      );
    in
    (
      evalFails (clusterWith {
        inherit extra;
      })
      && builtins.any (lib.hasInfix infix) errors
    )
    || throw "expected a default-deny scrape error containing '${infix}'; errors: ${show errors}";

  cnpsOf = cluster: ofKind "CiliumNetworkPolicy" (manifests cluster);
  # Target ingress policies end in a hash of the server and the target.
  byPrefix =
    prefix: ms:
    lib.findFirst (m: builtins.match "${prefix}-[0-9a-f]{8}" m.metadata.name != null) null ms;
  allByPrefix =
    prefix: ms: builtins.filter (m: builtins.match "${prefix}-[0-9a-f]{8}" m.metadata.name != null) ms;
  warningsOf = cluster: map (w: w.message) cluster.diagnostics.warnings;
  hasWarning = infix: cluster: builtins.any (lib.hasInfix infix) (warningsOf cluster);
  scrapeEgress = cluster: byName "prometheus-server-scrape-egress" (cnpsOf cluster);
  egressRules = cluster: (scrapeEgress cluster).spec.egress;
  rulesOf = kind: rules: builtins.filter (r: r.stubRule == kind) rules;
  # Service egress rules by the target's pod selector `app.kubernetes.io/name`
  # or `app`.
  serviceRuleFor =
    cluster: label: value:
    lib.findFirst (r: (r.selector.${label} or null) == value) null (
      rulesOf "service-egress" (egressRules cluster)
    );
  webName = "scraped";

  serverSelector = {
    "app.kubernetes.io/name" = "prometheus";
    "operator.prometheus.io/name" = "prometheus-server";
  };

  show = builtins.toJSON;
in
{
  prometheus-scrape-server-egress-has-dns-and-apiserver =
    let
      p = byName "prometheus-server-server-egress" (cnpsOf (clusterWith { }));
    in
    (
      p != null
      && p.metadata.namespace == "monitoring"
      && p.spec.endpointSelector.matchLabels == serverSelector
      &&
        map (r: r.stubRule) p.spec.egress == [
          "dns-egress"
          "apiserver-egress"
        ]
    )
    || throw "server egress: ${show p}";

  prometheus-scrape-egress-reaches-named-port-as-number =
    let
      cluster = clusterWith { };
      p = scrapeEgress cluster;
      rule = serviceRuleFor cluster "app.kubernetes.io/name" webName;
    in
    (
      p.metadata.namespace == "monitoring"
      && p.spec.endpointSelector.matchLabels == serverSelector
      && rule.namespace == "apps"
      &&
        rule.ports == [
          {
            port = "8080";
            protocol = "TCP";
          }
        ]
    )
    || throw "web egress rule: ${show rule}; policy: ${show p}";

  prometheus-scrape-target-ingress-admits-the-server =
    let
      p = byPrefix "monitoring-prometheus-server-scrape-svc-web" (cnpsOf (clusterWith { }));
      rule = builtins.head p.spec.ingress;
    in
    (
      p.metadata.namespace == "apps"
      && rule.stubRule == "caller-ingress"
      && rule.callerSelector == serverSelector
      && rule.callerNamespace == "monitoring"
      &&
        rule.ports == [
          {
            port = "8080";
            protocol = "TCP";
          }
        ]
    )
    || throw "web ingress: ${show p}";

  # The PodMonitor's pods are not Kix workloads, so the port name stays a
  # name. Without default deny the target gets no egress rule (a rule
  # without ports would admit every port) and a warning.
  prometheus-scrape-unresolved-port-name-gets-no-egress =
    let
      cluster = clusterWith {
        extra = noDefaultDeny // namedPortPods;
      };
    in
    (
      serviceRuleFor cluster "app" "named" == null
      && serviceRuleFor cluster "app" "operand" != null
      && hasWarning "target watch/pods-named has port pgexporter, a name no Kix container declares" cluster
    )
    || throw "named port: rules ${show (egressRules cluster)}; warnings ${show (warningsOf cluster)}";

  # Under default deny the same target fails evaluation.
  prometheus-scrape-unresolved-port-name-fails-under-default-deny = failsUnderDefaultDeny "target watch/pods-named has port pgexporter, a name no Kix container declares" namedPortPods;

  # The target ingress rule keeps the name, which the receiving pod
  # resolves.
  prometheus-scrape-unresolved-port-name-ingress-keeps-name =
    let
      ingress = byPrefix "monitoring-prometheus-server-scrape-pods-named" (
        cnpsOf (clusterWith {
          extra = namedPortPods // {
            networkPolicy.directions = "ingress";
          };
        })
      );
    in
    (builtins.head ingress.spec.ingress).ports == [
      {
        port = "pgexporter";
        protocol = "TCP";
      }
    ]
    || throw "named port ingress: ${show ingress}";

  # node-exporter runs on the host network: a host rule on its port and no
  # ingress policy.
  prometheus-scrape-host-network-target =
    let
      cluster = clusterWith { };
      hostRules = rulesOf "host-network-egress" (egressRules cluster);
      names = map (m: m.metadata.name) (cnpsOf cluster);
    in
    (
      hostRules == [
        {
          stubRule = "host-network-egress";
          ports = [
            {
              port = "9100";
              protocol = "TCP";
            }
          ];
        }
      ]
      && !(builtins.any (lib.hasInfix "scrape-svc-node-exporter") names)
    )
    || throw "host rules: ${show hostRules}; names: ${show names}";

  # A serviceMonitorSelector that the web monitor's labels do not satisfy
  # leaves it out; node-exporter's monitor carries no `team` label either.
  prometheus-scrape-honours-monitor-selector =
    let
      cluster = clusterWith { server.extraSpec.serviceMonitorSelector.matchLabels.team = "platform"; };
      names = map (m: m.metadata.name) (cnpsOf cluster);
    in
    (
      serviceRuleFor cluster "app.kubernetes.io/name" webName == null
      && !(builtins.any (lib.hasPrefix "monitoring-prometheus-server-scrape-svc-web") names)
      && rulesOf "host-network-egress" (egressRules cluster) == [ ]
      && serviceRuleFor cluster "app" "operand" != null
    )
    || throw "selector not honoured: ${show (egressRules cluster)}";

  # A null namespace selector means the Prometheus's own namespace, so the
  # PodMonitor in `apps` is not selected.
  prometheus-scrape-null-namespace-selector-is-own-namespace =
    let
      cluster = clusterWith { server.extraSpec.podMonitorNamespaceSelector = null; };
    in
    (
      serviceRuleFor cluster "app" "operand" == null
      && serviceRuleFor cluster "app.kubernetes.io/name" webName != null
    )
    || throw "podMonitorNamespaceSelector null: ${show (egressRules cluster)}";

  prometheus-scrape-egress-only-direction =
    let
      cluster = clusterWith { extra.networkPolicy.directions = "egress"; };
      names = map (m: m.metadata.name) (cnpsOf cluster);
    in
    (scrapeEgress cluster != null && !(builtins.any (lib.hasInfix "-scrape-svc-") names))
    || throw "egress-only: ${show names}";

  prometheus-scrape-alertmanager-target =
    let
      # The prometheus package names the Alertmanager it binds in
      # spec.alerting.
      cluster = clusterWith {
        extra.instances.monitoring.alertmanager.package = pkg "alertmanager";
      };
      ingress = byPrefix "monitoring-prometheus-server-scrape-svc-alertmanager" (cnpsOf cluster);
    in
    (
      ingress != null
      &&
        (builtins.head ingress.spec.ingress).ports == [
          {
            port = "9093";
            protocol = "TCP";
          }
        ]
    )
    || throw "alertmanager ingress: ${show ingress}";

  # Without enforced egress, neither the server's operand policy nor the
  # scrape egress exists, so the server pods keep open egress. Target
  # ingress is still emitted, including the server's own for its
  # self-scrape.
  prometheus-scrape-ingress-only-direction =
    let
      cluster = clusterWith { extra.networkPolicy.directions = "ingress"; };
      cnps = cnpsOf cluster;
      names = map (m: m.metadata.name) cnps;
      serverPolicies = builtins.filter (
        p: (p.spec.endpointSelector.matchLabels or null) == serverSelector && p.spec ? egress
      ) cnps;
    in
    (
      serverPolicies == [ ]
      && !(builtins.elem "prometheus-server-server-egress" names)
      && byPrefix "monitoring-prometheus-server-scrape-svc-web" cnps != null
    )
    || throw "ingress-only: server policies ${show serverPolicies}; names ${show names}";

  # Without default deny, a target gets scrape ingress only when another
  # ingress policy already isolates its pods. The web Deployment has none,
  # and the operand pods have one only when operand-peers is present.
  prometheus-scrape-no-default-deny-only-isolated-targets =
    let
      withoutPeers = cnpsOf (clusterWith {
        extra.networkPolicy.defaultDeny = false;
      });
      withPeers = cnpsOf (clusterWith {
        extra = {
          networkPolicy.defaultDeny = false;
          instances.apps.operand-peers.package = operandPeers;
        };
      });
      web = byPrefix "monitoring-prometheus-server-scrape-svc-web";
      operand = byPrefix "monitoring-prometheus-server-scrape-pods-operand";
    in
    (
      web withoutPeers == null
      && operand withoutPeers == null
      && web withPeers == null
      && operand withPeers != null
      && byName "prometheus-server-scrape-egress" withoutPeers != null
    )
    || throw "defaultDeny = false: ${show (map (m: m.metadata.name) withPeers)}";

  # A target in a namespace without its own default deny (here a platform
  # namespace) is treated as default deny off: it gets scrape ingress only
  # when another policy already isolates its pods.
  prometheus-scrape-platform-namespace-only-isolated-targets =
    let
      withoutPeers = cnpsOf (clusterWith {
        extra.networkPolicy.platformNamespaces = [ "apps" ];
      });
      withPeers = cnpsOf (clusterWith {
        extra = {
          networkPolicy.platformNamespaces = [ "apps" ];
          instances.apps.operand-peers.package = operandPeers;
        };
      });
      web = byPrefix "monitoring-prometheus-server-scrape-svc-web";
      operand = byPrefix "monitoring-prometheus-server-scrape-pods-operand";
    in
    (
      web withoutPeers == null
      && operand withoutPeers == null
      && web withPeers == null
      && operand withPeers != null
      && byName "apps-default-deny" withoutPeers == null
      && byName "monitoring-default-deny" withoutPeers != null
    )
    || throw "platform namespace: ${show (map (m: m.metadata.name) withPeers)}";

  # Without default deny, isolation is read from the labels of the pods
  # behind the target, not from the Service selector. A policy selecting
  # `tier=api`, which only the pods carry, isolates them, so the target gets
  # scrape ingress; a policy selecting pods without `tier` matches the
  # Service selector but not the pods, so the target gets none.
  prometheus-scrape-isolation-reads-pod-labels =
    let
      apiIngress =
        endpointSelector:
        byPrefix "monitoring-prometheus-server-scrape-svc-api" (
          cnpsOf (clusterWith {
            extra = noDefaultDeny // {
              instances.apps.tiered.package = tiered endpointSelector;
            };
          })
        );
      byExtraLabel = apiIngress { matchLabels.tier = "api"; };
      byMissingLabel = apiIngress {
        matchExpressions = [
          {
            key = "tier";
            operator = "DoesNotExist";
          }
        ];
      };
    in
    (byExtraLabel != null && byMissingLabel == null)
    || throw "isolation: by extra label ${show byExtraLabel}; by missing label ${show byMissingLabel}";

  # Pods Kix did not build are known by the target selector alone. A policy
  # the selector implies isolates all of them, including one with NotIn on
  # a key the selector fixes. A policy with DoesNotExist on a key outside the
  # selector may isolate only some, so the target gets no scrape ingress and
  # a warning.
  prometheus-scrape-isolation-of-unknown-pods =
    let
      clusterOn =
        endpointSelector:
        clusterWith {
          extra = noDefaultDeny // {
            instances.apps.operand-peers.package = operandPeersOn endpointSelector;
          };
        };
      operandIngress =
        cluster: byPrefix "monitoring-prometheus-server-scrape-pods-operand" (cnpsOf cluster);
      byNotIn = clusterOn {
        matchExpressions = [
          {
            key = "app";
            operator = "NotIn";
            values = [ "other" ];
          }
        ];
      };
      byDoesNotExist = clusterOn {
        matchLabels.app = "operand";
        matchExpressions = [
          {
            key = "role";
            operator = "DoesNotExist";
          }
        ];
      };
    in
    (
      operandIngress byNotIn != null
      && operandIngress byDoesNotExist == null
      && hasWarning "scrapes target apps/pods-operand. Another ingress policy may isolate only some of the target's pods" byDoesNotExist
      && builtins.any (
        w:
        lib.hasInfix "Another ingress policy" w.message
        && (w.object.kind or null) == "Prometheus"
        && (w.object.namespace or null) == "monitoring"
        && (w.instance or null) != null
      ) byDoesNotExist.diagnostics.warnings
    )
    || throw "unknown pods: NotIn ${show (operandIngress byNotIn)}; DoesNotExist ${show (operandIngress byDoesNotExist)}, warnings ${show (warningsOf byDoesNotExist)}";

  # A Kubernetes NetworkPolicy from `namespaces.<ns>.networkPolicies`
  # isolates ingress when its policyTypes include Ingress or are absent, with
  # or without an `ingress` key. One with only Egress does not.
  prometheus-scrape-isolation-reads-kubernetes-network-policies =
    let
      webIngress =
        policy:
        byPrefix "monitoring-prometheus-server-scrape-svc-web" (
          cnpsOf (clusterWith {
            extra = noDefaultDeny // {
              namespaces.apps.networkPolicies.lockdown = policy;
            };
          })
        );
      noTypes = webIngress { podSelector = { }; };
      ingressType = webIngress {
        podSelector = { };
        policyTypes = [ "Ingress" ];
      };
      egressType = webIngress {
        podSelector = { };
        policyTypes = [ "Egress" ];
      };
    in
    (noTypes != null && ingressType != null && egressType == null)
    || throw "NetworkPolicy isolation: no types ${show noTypes}; Ingress ${show ingressType}; Egress ${show egressType}";

  # A port name the Kix workloads behind a Service declare with two numbers
  # resolves to both, on the egress and the ingress rule.
  prometheus-scrape-port-name-with-two-numbers =
    let
      cluster = clusterWith { extra.instances.apps.amb.package = twoNumbers; };
      sortPorts = ports: lib.sort (a: b: a.port < b.port) ports;
      expected = [
        {
          port = "8080";
          protocol = "TCP";
        }
        {
          port = "9090";
          protocol = "TCP";
        }
      ];
      egress = serviceRuleFor cluster "app.kubernetes.io/name" "amb";
      ingress = byPrefix "monitoring-prometheus-server-scrape-svc-amb" (cnpsOf cluster);
    in
    (
      sortPorts egress.ports == expected
      && sortPorts (builtins.head ingress.spec.ingress).ports == expected
    )
    || throw "two numbers: egress ${show egress}; ingress ${show ingress}";

  # `namespaceSelector.any` covers every Kix namespace: the monitor's own,
  # which has no workload, and one that holds only custom resources.
  prometheus-scrape-any-namespace =
    let
      cnps = cnpsOf (clusterWith {
        extra.instances = {
          watch.listeners.package = podMonitorOnly "listeners" {
            namespaceSelector.any = true;
            selector.matchLabels.app = "listener";
            podMetricsEndpoints = [ { portNumber = 8080; } ];
          };
          runners.cr.package = crOnly;
        };
      });
      namespaces = map (p: p.metadata.namespace) (
        allByPrefix "monitoring-prometheus-server-scrape-pods-listeners" cnps
      );
    in
    (
      builtins.elem "watch" namespaces
      && builtins.elem "runners" namespaces
      && builtins.elem "apps" namespaces
    )
    || throw "any: ingress namespaces ${show namespaces}";

  # Prometheus `c` in `a-b` and `b-c` in `a` join to the same readable name;
  # each gets its own target ingress.
  prometheus-scrape-two-servers =
    let
      cnps = cnpsOf (clusterWith {
        extra.instances = {
          "a-b".c.package = pkg "prometheus";
          a."b-c".package = pkg "prometheus";
        };
      });
      operand = allByPrefix "a-b-c-scrape-pods-operand" cnps;
      callers = lib.sort (x: y: x < y) (map (p: (builtins.head p.spec.ingress).callerNamespace) operand);
    in
    (
      callers == [
        "a"
        "a-b"
      ]
      && builtins.all (p: p.metadata.namespace == "apps") operand
    )
    || throw "two servers: ${show (map (p: p.metadata.name) operand)}";

  prometheus-scrape-warns-on-match-expressions =
    let
      cluster = clusterWith {
        extra = noDefaultDeny // matchExpressionsPods;
      };
    in
    (
      hasWarning "PodMonitor watch/expr: its selector uses matchExpressions" cluster
      && !(builtins.any (lib.hasInfix "scrape-pods-expr") (map (m: m.metadata.name) (cnpsOf cluster)))
    )
    || throw "matchExpressions warning: ${show (warningsOf cluster)}";

  prometheus-scrape-match-expressions-fails-under-default-deny = failsUnderDefaultDeny "PodMonitor watch/expr: its selector uses matchExpressions" matchExpressionsPods;

  # A host rule without ports would open every node port, so the target
  # gets none and a warning instead.
  prometheus-scrape-host-network-without-port-number =
    let
      cluster = clusterWith {
        extra = noDefaultDeny // {
          instances.apps.hostexp.package = hostExporter;
        };
      };
      hostRules = rulesOf "host-network-egress" (egressRules cluster);
    in
    (
      builtins.all (r: r.ports != [ ]) hostRules
      && hasWarning "target apps/svc-hostexp runs on the host network" cluster
    )
    || throw "portless host target: rules ${show hostRules}; warnings ${show (warningsOf cluster)}";

  prometheus-scrape-host-network-without-port-number-fails-under-default-deny =
    failsUnderDefaultDeny "target apps/svc-hostexp runs on the host network"
      {
        instances.apps.hostexp.package = hostExporter;
      };

  # A Prometheus CRD without a podSelector (here through the cluster
  # override) gives no scrape policy and a warning.
  prometheus-scrape-warns-without-pod-selector =
    let
      cluster = clusterWith {
        extra = noDefaultDeny // unnamedServer;
      };
    in
    (
      scrapeEgress cluster == null
      && hasWarning "Prometheus monitoring/prometheus-server: the Prometheus CRD declares no factBehavior.podSelector" cluster
    )
    || throw "no podSelector: ${show (warningsOf cluster)}";

  prometheus-scrape-without-pod-selector-fails-under-default-deny = failsUnderDefaultDeny "Prometheus monitoring/prometheus-server: the Prometheus CRD declares no factBehavior.podSelector" unnamedServer;

  # The CRD's `endpoint = "terminate"` gives a remote-write URL built from a
  # dependency's address an operand egress from the server pods and an
  # ingress at the receiver.
  prometheus-scrape-remote-write-operand-egress =
    let
      cnps = cnpsOf (clusterWith {
        extra =
          { ref, ... }:
          {
            instances.sink.receiver.package = receiver;
            instances.monitoring.writer = {
              package = remoteWriter;
              deps.receiver = ref.sink.receiver;
            };
          };
      });
      crOperand = builtins.filter (
        p: (p.metadata.labels.${kixKeys.policyType} or null) == "cr-operand"
      ) cnps;
      egress = lib.findFirst (p: p.metadata.name == "writer-prometheus-writer-egress") null crOperand;
      ingress = lib.findFirst (
        p: p.metadata.namespace == "sink" && lib.hasPrefix "writer-prometheus-writer-to-" p.metadata.name
      ) null cnps;
      serviceRule = lib.findFirst (r: r.stubRule == "service-egress") null egress.spec.egress;
    in
    (
      egress != null
      &&
        egress.spec.endpointSelector.matchLabels == {
          "app.kubernetes.io/name" = "prometheus";
          "operator.prometheus.io/name" = "writer";
        }
      && serviceRule.namespace == "sink"
      && ingress != null
      && (builtins.head ingress.spec.ingress).callerNamespace == "monitoring"
    )
    || throw "remote write: ${show (map (p: "${p.metadata.namespace}/${p.metadata.name}") cnps)}";

  prometheus-scrape-netpol-off-emits-nothing =
    let
      cluster = mkCluster [
        { instances.dns = baseInstances.instances.dns; }
        {
          instances.monitoring = {
            prometheus-operator.package = pkg "prometheus-operator";
            prometheus-server.package = pkg "prometheus";
          };
          instances.apps.scraped.package = scraped;
        }
      ];
    in
    cnpsOf cluster == [ ] || throw "netpol off: ${show (map (m: m.metadata.name) (cnpsOf cluster))}";

  # Targets in additionalScrapeConfigs get no policy, and Kix names them in
  # a warning, with or without default deny.
  prometheus-scrape-warns-on-additional-scrape-configs =
    let
      says = hasWarning "Prometheus monitoring/prometheus-server sets spec.additionalScrapeConfigs";
      warned = clusterWith {
        server.extraSpec.additionalScrapeConfigs = {
          name = "extra-scrapes";
          key = "scrapes.yaml";
        };
      };
    in
    (says warned && !(says (clusterWith { })) && scrapeEgress warned != null)
    || throw "additionalScrapeConfigs warnings: ${show (warningsOf warned)}";
}
