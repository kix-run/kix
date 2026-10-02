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
  ...
}:

let
  pkg = name: import (../../../packages + "/${name}");

  # A Deployment with a named metrics port behind a Service whose
  # targetPort is that name, a ServiceMonitor over the Service, and a
  # PodMonitor over pods an operator would create (no Kix workload carries
  # their labels).
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
            podMetricsEndpoints = [ { port = "pgexporter"; } ];
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
  # pods, with an operand policy that admits only their peers.
  operandPeers =
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
              endpointSelector.matchLabels.app = "operand";
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

  cnpsOf = cluster: ofKind "CiliumNetworkPolicy" (manifests cluster);
  # Target ingress policies end in a hash of the server and the target.
  byPrefix =
    prefix: ms: lib.findFirst (m: builtins.match "${prefix}-[0-9a-f]{8}" m.metadata.name != null) null ms;
  allByPrefix =
    prefix: ms: builtins.filter (m: builtins.match "${prefix}-[0-9a-f]{8}" m.metadata.name != null) ms;
  warningsOf = cluster: cluster.diagnostics.warnings;
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
  inherit (import ../../plugins/netpol/scrape.nix { inherit lib; }) matchesSelector;
in
{
  prometheus-scrape-label-selector-semantics =
    let
      labels = {
        team = "apps";
        tier = "web";
      };
      cases = [
        (matchesSelector { } labels)
        (matchesSelector { matchLabels.team = "apps"; } labels)
        (!matchesSelector { matchLabels.team = "platform"; } labels)
        (matchesSelector {
          matchExpressions = [
            {
              key = "team";
              operator = "In";
              values = [
                "apps"
                "data"
              ];
            }
            {
              key = "env";
              operator = "DoesNotExist";
            }
          ];
        } labels)
        (
          !matchesSelector {
            matchExpressions = [
              {
                key = "tier";
                operator = "NotIn";
                values = [ "web" ];
              }
            ];
          } labels
        )
        (matchesSelector {
          matchExpressions = [
            {
              key = "tier";
              operator = "Exists";
            }
          ];
        } labels)
      ];
    in
    builtins.all (c: c) cases || throw "label selector cases: ${show cases}";

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
  # name: the ingress rule keeps it and the egress rule drops the ports.
  prometheus-scrape-unresolved-port-name =
    let
      cluster = clusterWith { };
      egress = serviceRuleFor cluster "app" "operand";
      ingress = byPrefix "monitoring-prometheus-server-scrape-pods-operand" (cnpsOf cluster);
    in
    (
      egress.ports == [ ]
      &&
        (builtins.head ingress.spec.ingress).ports == [
          {
            port = "pgexporter";
            protocol = "TCP";
          }
        ]
    )
    || throw "operand rules: egress ${show egress}; ingress ${show ingress}";

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
      ingress = byPrefix "monitoring-prometheus-server-scrape-svc-alertmanager-operated" (cnpsOf cluster);
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
      withoutPeers = cnpsOf (clusterWith { extra.networkPolicy.defaultDeny = false; });
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

  # `namespaceSelector.any` covers every Kix namespace: the monitor's own,
  # which has no workload, and one that holds only custom resources.
  prometheus-scrape-any-namespace =
    let
      cnps = cnpsOf (clusterWith {
        extra.instances = {
          watch.listeners.package = podMonitorOnly "listeners" {
            namespaceSelector.any = true;
            selector.matchLabels.app = "listener";
            podMetricsEndpoints = [ { port = "metrics"; } ];
          };
          runners.cr.package = crOnly;
        };
      });
      namespaces = map (p: p.metadata.namespace) (
        allByPrefix "monitoring-prometheus-server-scrape-pods-listeners" cnps
      );
    in
    (builtins.elem "watch" namespaces && builtins.elem "runners" namespaces && builtins.elem "apps" namespaces)
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
        extra.instances.watch.expr.package = podMonitorOnly "expr" {
          selector.matchExpressions = [
            {
              key = "app";
              operator = "In";
              values = [ "expr" ];
            }
          ];
          podMetricsEndpoints = [ { port = "metrics"; } ];
        };
      };
    in
    (
      hasWarning "PodMonitor watch/expr: its selector uses matchExpressions" cluster
      && !(builtins.any (lib.hasInfix "scrape-pods-expr") (map (m: m.metadata.name) (cnpsOf cluster)))
    )
    || throw "matchExpressions warning: ${show (warningsOf cluster)}";

  # A host rule without ports would open every node port, so the target
  # gets none and a warning instead.
  prometheus-scrape-host-network-without-port-number =
    let
      cluster = clusterWith { extra.instances.apps.hostexp.package = hostExporter; };
      hostRules = rulesOf "host-network-egress" (egressRules cluster);
    in
    (
      builtins.all (r: r.ports != [ ]) hostRules
      && hasWarning "target apps/svc-hostexp runs on the host network" cluster
    )
    || throw "portless host target: rules ${show hostRules}; warnings ${show (warningsOf cluster)}";

  # A Prometheus CRD without a podSelector (here through the cluster
  # override) gives no scrape policy and a warning.
  prometheus-scrape-warns-without-pod-selector =
    let
      cluster = clusterWith {
        extra.cluster.factBehavior."monitoring.coreos.com/Prometheus".endpoint = "conduct";
      };
    in
    (
      scrapeEgress cluster == null
      && hasWarning "Prometheus monitoring/prometheus-server: the Prometheus CRD declares no factBehavior.podSelector" cluster
    )
    || throw "no podSelector: ${show (warningsOf cluster)}";

  # The CRD's `endpoint = "terminate"` gives a remote-write URL built from a
  # dependency's address an operand egress from the server pods and an
  # ingress at the receiver.
  prometheus-scrape-remote-write-operand-egress =
    let
      cnps = cnpsOf (clusterWith {
        extra.instances = {
          sink.receiver.package = receiver;
          monitoring.writer.package = remoteWriter;
        };
      });
      crOperand = builtins.filter (
        p: (p.metadata.labels.${kixKeys.policyType} or null) == "cr-operand"
      ) cnps;
      egress = lib.findFirst (p: p.metadata.name == "writer-prometheus-writer-egress") null crOperand;
      ingress = lib.findFirst (
        p:
        p.metadata.namespace == "sink"
        && lib.hasPrefix "writer-prometheus-writer-to-" p.metadata.name
      ) null cnps;
      serviceRule = lib.findFirst (r: r.stubRule == "service-egress") null egress.spec.egress;
    in
    (
      egress != null
      && egress.spec.endpointSelector.matchLabels == {
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
}
