# Tests for the coredns package and the kix/lib behaviour it relies on:
# package and instance config modules receive `clusterConfig` as a module
# argument, the Corefile follows cluster facts, Corefiles CoreDNS would
# reject fail evaluation, and workloads order after a managed DNS provider.

{
  lib,
  k8s,
  kixKeys,
  mkCluster,
  baseInstances,
  netpolOn,
  manifests,
  ofKind,
  byName,
  evalFails,
  ...
}:

let
  corednsPackage = import ../../../packages/coredns;

  # A cluster with one coredns instance. `module` adds cluster settings.
  corednsCluster =
    {
      config ? { },
      namespace ? "kube-system",
      module ? { },
    }:
    mkCluster [
      {
        instances.${namespace}.coredns = {
          package = corednsPackage;
          config = {
            clusterIP = "10.96.0.10";
          }
          // config;
        };
      }
      module
    ];

  corefileOf = cluster: (byName "coredns" (ofKind "ConfigMap" (manifests cluster))).data.Corefile;

  # The Prometheus builders coredns calls, returning plain ConfigMaps so the
  # cluster needs no monitoring CRDs.
  prometheusStub = {
    meta = {
      version = "test";
      defaultAliases = [ "prometheus" ];
    };
    build =
      { self, scope, ... }:
      let
        stubResource =
          suffix: consumerScope: args:
          consumerScope.mkResource {
            apiVersion = "v1";
            kind = "ConfigMap";
            name = "${args.name}-${suffix}";
            data.spec = builtins.toJSON args.spec;
          };
      in
      {
        cm = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "prometheus";
        };
        root = {
          resource = self.cm;
          out = {
            mkServiceMonitor = stubResource "monitor";
            mkPrometheusRule = stubResource "rules";
          };
        };
      };
  };

  withPrometheus = {
    instances.monitoring.prometheus.package = prometheusStub;
  };

  servicePortNames =
    cluster: map (p: p.name) (byName "coredns" (ofKind "Service" (manifests cluster))).spec.ports;

  # Two options whose defaults come from the cluster: `zone` from the
  # package's own config module, `upstream` from the instance's.
  clusterFactsPackage = {
    meta.version = "test";
    options = {
      zone = lib.mkOption { type = lib.types.str; };
      upstream = lib.mkOption { type = lib.types.str; };
    };
    config =
      { clusterConfig, ... }:
      {
        zone = lib.mkDefault clusterConfig.clusterDomain;
      };
    build =
      { self, scope, ... }:
      {
        cm = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "facts";
        };
        root = self.cm;
      };
  };
in
{
  # A package `config = { clusterConfig, ... }: ...` and an instance config
  # function both read clusterDomain "corp.internal".
  coredns-lib-cluster-config-special-arg =
    let
      cluster = mkCluster [
        {
          clusterDomain = "corp.internal";
          instances.dns.facts = {
            package = clusterFactsPackage;
            config =
              { clusterConfig, ... }:
              {
                upstream = "upstream.${clusterConfig.clusterDomain}";
              };
          };
        }
      ];
      cfg = cluster.instances.dns.facts._meta.config;
    in
    (cfg.zone == "corp.internal" && cfg.upstream == "upstream.corp.internal")
    || throw "clusterConfig module argument: zone ${builtins.toJSON cfg.zone}, upstream ${builtins.toJSON cfg.upstream}";

  # The zone and the cache exemptions follow clusterDomain; with no
  # cluster.network.dnsUpstream, forward reads /etc/resolv.conf.
  coredns-domain =
    let
      corefile = corefileOf (corednsCluster {
        module.clusterDomain = "corp.internal";
      });
    in
    (
      lib.hasInfix "kubernetes corp.internal in-addr.arpa ip6.arpa {" corefile
      && lib.hasInfix "disable success corp.internal" corefile
      && lib.hasInfix "disable denial corp.internal" corefile
      && lib.hasInfix "forward . /etc/resolv.conf {" corefile
    )
    || throw "Corefile for clusterDomain corp.internal:\n${corefile}";

  # cluster.network.dnsUpstream replaces /etc/resolv.conf in forward.
  coredns-upstream =
    let
      corefile = corefileOf (corednsCluster {
        module.cluster.network.dnsUpstream = [ "192.0.2.1" ];
      });
    in
    lib.hasInfix "forward . 192.0.2.1 {" corefile || throw "Corefile with dnsUpstream:\n${corefile}";

  # A block with a view renders before the view-less default block on the
  # same zone and port, although its name sorts after it.
  coredns-view-order =
    let
      corefile = corefileOf (corednsCluster {
        config.servers.z-office.plugins = {
          view = {
            args = [ "office" ];
            block = [ "expr incidr(client_ip(), '192.0.2.0/24')" ];
          };
          forward.args = [
            "."
            "192.0.2.1"
          ];
        };
      });
      firstBlock = builtins.head (lib.splitString "\n}\n" corefile);
    in
    lib.hasInfix "view office" firstBlock || throw "view block is not first:\n${corefile}";

  # Corefiles CoreDNS rejects or that leave a probe or the scrape without a
  # listener fail evaluation, as do values the option types refuse.
  coredns-refusals =
    let
      fails =
        name: config:
        evalFails (corednsCluster {
          inherit config;
        })
        || throw "${name} evaluated";
    in
    fails "kubernetes disabled" { servers.default.plugins.kubernetes.enabled = false; }
    && fails "prometheus on localhost" { servers.default.plugins.prometheus.args = [ ]; }
    && fails "ready disabled" { servers.default.plugins.ready.enabled = false; }
    && fails "clusterIP None" { clusterIP = "None"; }
    && fails "tls zone" { servers.default.zones = [ "tls://." ]; }
    && fails "two blocks on .:53" { servers.second.plugins.errors = { }; }
    && (
      evalFails (mkCluster [
        withPrometheus
        {
          instances.kube-system.coredns = {
            package = corednsPackage;
            config = {
              clusterIP = "10.96.0.10";
              servers.default.plugins.prometheus.enabled = false;
            };
          };
        }
      ])
      || throw "metrics enabled with a Prometheus and no prometheus plugin evaluated"
    );

  # Under network policy the enforcer's DNS egress rule allows only
  # kube-system, so coredns elsewhere fails evaluation; in kube-system it
  # builds.
  coredns-namespace-under-netpol =
    (
      evalFails (corednsCluster {
        namespace = "dns";
        module = netpolOn;
      })
      || throw "coredns in namespace dns under network policy evaluated"
    )
    && (
      !evalFails (corednsCluster {
        module = netpolOn;
      })
      || throw "coredns in kube-system under network policy failed to evaluate"
    );

  # coredns claims the dns role, so a workload in another namespace that
  # dials a Service orders after the coredns Service.
  coredns-dns-edge =
    let
      cluster = mkCluster [
        { instances = removeAttrs baseInstances.instances [ "dns" ]; }
        {
          instances.kube-system.coredns = {
            package = corednsPackage;
            config.clusterIP = "10.96.0.10";
          };
        }
      ];
      rootRes =
        let
          r = cluster.instances.kube-system.coredns.raw.root;
        in
        r.resource or r;
      corednsHash = k8s.extractStoreHash rootRes.outPath;
      app = byName "app" (ofKind "Deployment" (manifests cluster));
      annot = app.metadata.annotations.${kixKeys.dependsOn} or "";
    in
    lib.hasInfix corednsHash annot
    || throw "app does not depend on the coredns Service; depends-on: ${annot}";

  # The Service carries the metrics port only when a Prometheus scrapes it.
  coredns-metrics-port =
    let
      without = servicePortNames (corednsCluster { });
      with' = servicePortNames (corednsCluster {
        module = withPrometheus;
      });
    in
    (
      without == [
        "dns"
        "dns-tcp"
      ]
      && builtins.elem "metrics" with'
    )
    || throw "Service ports without Prometheus ${builtins.toJSON without}, with ${builtins.toJSON with'}";
}
