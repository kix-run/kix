# Tests for the scrape policies of the netpol plugin
# (kix/lib/plugins/netpol/scrape.nix) with the real prometheus-operator and
# prometheus packages: the server's egress to every target it selects, the
# target-side ingress, host-network targets, named ports, the Prometheus
# selectors, and `networkPolicy.directions`.

{
  lib,
  mkCluster,
  baseInstances,
  netpolOn,
  manifests,
  ofKind,
  byName,
  containerBase,
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
      && map (r: r.stubRule) p.spec.egress == [
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
      && rule.ports == [
        {
          port = "8080";
          protocol = "TCP";
        }
      ]
    )
    || throw "web egress rule: ${show rule}; policy: ${show p}";

  prometheus-scrape-target-ingress-admits-the-server =
    let
      p = byName "monitoring-prometheus-server-scrape-svc-web" (cnpsOf (clusterWith { }));
      rule = builtins.head p.spec.ingress;
    in
    (
      p.metadata.namespace == "apps"
      && rule.stubRule == "caller-ingress"
      && rule.callerSelector == serverSelector
      && rule.callerNamespace == "monitoring"
      && rule.ports == [
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
      ingress = byName "monitoring-prometheus-server-scrape-pods-operand" (cnpsOf cluster);
    in
    (
      egress.ports == [ ]
      && (builtins.head ingress.spec.ingress).ports == [
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
      cluster = clusterWith { server.serviceMonitorSelector.matchLabels.team = "platform"; };
      names = map (m: m.metadata.name) (cnpsOf cluster);
    in
    (
      serviceRuleFor cluster "app.kubernetes.io/name" webName == null
      && !(builtins.elem "monitoring-prometheus-server-scrape-svc-web" names)
      && rulesOf "host-network-egress" (egressRules cluster) == [ ]
      && serviceRuleFor cluster "app" "operand" != null
    )
    || throw "selector not honoured: ${show (egressRules cluster)}";

  # A null namespace selector means the Prometheus's own namespace, so the
  # PodMonitor in `apps` is not selected.
  prometheus-scrape-null-namespace-selector-is-own-namespace =
    let
      cluster = clusterWith { server.podMonitorNamespaceSelector = null; };
    in
    (serviceRuleFor cluster "app" "operand" == null && serviceRuleFor cluster "app.kubernetes.io/name" webName != null)
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
      cluster = clusterWith {
        extra.instances.monitoring.alertmanager.package = pkg "alertmanager";
        server.alerting.alertmanagers = [
          {
            namespace = "monitoring";
            name = "alertmanager-operated";
            port = "web";
          }
        ];
      };
      ingress = byName "monitoring-prometheus-server-scrape-svc-alertmanager-operated" (cnpsOf cluster);
    in
    (
      ingress != null
      && (builtins.head ingress.spec.ingress).ports == [
        {
          port = "9093";
          protocol = "TCP";
        }
      ]
    )
    || throw "alertmanager ingress: ${show ingress}";

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
