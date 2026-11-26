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
  eval,
  kixlib,
  ...
}:

let
  corednsPackage = import ../../../packages/experimental/coredns;
  corefile = import ../../../packages/experimental/coredns/corefile.nix { inherit lib; };

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
      scope = "cluster";
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

  # Each Corefile check returns its message for the servers an instance
  # config evaluates to. The instance config is evaluated on its own, so a
  # build that throws for another reason cannot hide which check fired.
  coredns-check-messages =
    let
      domain = "corp.internal";
      package = corednsPackage {
        scope = { };
        inherit lib;
        kix = kixlib;
        availability = "node";
      };
      checksOf =
        config:
        corefile.checks {
          servers =
            (eval.evaluateInstanceConfig {
              packageOptions = package.options;
              packageConfig = package.config;
              instCfg.config.imports = [
                { clusterIP = "10.96.0.10"; }
                config
              ];
              clusterConfig = {
                clusterDomain = domain;
                cluster.network.dnsUpstream = [ ];
              };
            }).servers;
          clusterDomain = domain;
        };
      noDomain = "no server block on port 53 without a view serves the cluster domain '${domain}' with the kubernetes plugin, and pods query port 53, so Service names would not resolve. Keep servers.default on port 53 with the zone \".\" and its kubernetes plugin enabled with '${domain}' in its args, or give another block the same.";
      forwardOnly = {
        zones = [ "example.org" ];
        plugins.forward.args = [
          "."
          "192.0.2.1"
        ];
      };
      cases = {
        "default" = {
          config = { };
          expect = [ ];
        };
        "cluster domain in a block of its own" = {
          config.servers = {
            default.plugins.kubernetes.enabled = false;
            cluster = {
              zones = [ domain ];
              plugins.kubernetes = { };
            };
          };
          expect = [ ];
        };
        "no block enabled" = {
          config.servers.default.enabled = false;
          expect = [ "no server block is enabled. Set servers.default.enabled = true or add a block." ];
        };
        "kubernetes disabled" = {
          config.servers.default.plugins.kubernetes.enabled = false;
          expect = [ noDomain ];
        };
        "default block on port 5353" = {
          config.servers.default.port = 5353;
          expect = [ noDomain ];
        };
        "cluster domain outside the block's zones" = {
          config.servers.default.zones = [ "example.org" ];
          expect = [ noDomain ];
        };
        "ready disabled" = {
          config.servers.default.plugins.ready.enabled = false;
          expect = [
            "no server block enables the ready plugin; the readiness probe calls it. Set servers.default.plugins.ready.enabled = true."
          ];
        };
        "prometheus on localhost" = {
          config.servers.default.plugins.prometheus.args = [ ];
          expect = [
            "the prometheus plugin listens on localhost:9153, which the kubelet (or Prometheus) cannot reach from outside the pod. Set servers.default.plugins.prometheus.args = [ \":9153\" ]."
          ];
        };
        "health on two ports" = {
          config.servers.b-other = forwardOnly // {
            plugins = forwardOnly.plugins // {
              health.args = [ ":8081" ];
            };
          };
          expect = [
            "the health plugin listens on different ports in servers.default (:8080) and servers.b-other (:8081); the pod exposes one. Give every block the same address."
          ];
        };
        "health address without a port" = {
          config.servers.default.plugins.health.args = [ "0.0.0.0" ];
          expect = [
            "the health plugin's address '0.0.0.0' in servers.default has no port. Write it as \":<port>\"."
          ];
        };
        "two view-less blocks on .:53" = {
          config.servers.second.plugins.errors = { };
          expect = [
            "servers default and second both serve .:53 without a view plugin; CoreDNS refuses to start (duplicate zone). To replace the default block, set servers.default.enabled = false; otherwise give every block but one a view, or merge them."
          ];
        };
        "two views in one block" = {
          config.servers.a-office = forwardOnly // {
            zones = [ "." ];
            plugins = forwardOnly.plugins // {
              view.args = [ "office" ];
              view-lab = {
                name = "view";
                args = [ "lab" ];
              };
            };
          };
          expect = [
            "servers.a-office has more than one enabled view plugin; CoreDNS accepts one per block."
          ];
        };
      };
      wrong = lib.filterAttrs (_: c: checksOf c.config != c.expect) cases;
    in
    wrong == { }
    || throw "Corefile check messages differ: ${
      builtins.toJSON (lib.mapAttrs (_: c: checksOf c.config) wrong)
    }";

  # Values the option types refuse, a Corefile check reached through the
  # build, and metrics enabled with no prometheus plugin fail evaluation.
  # The namespace check is in coredns-namespace-under-netpol.
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
    && fails "clusterIP None" { clusterIP = "None"; }
    && fails "tls zone" { servers.default.zones = [ "tls://." ]; }
    && fails "zone with a port" {
      servers.ex = {
        zones = [ "example.org:53" ];
        plugins.forward.args = [
          "."
          "192.0.2.1"
        ];
      };
    }
    && fails "empty zone" { servers.default.zones = [ "" ]; }
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

  # An IPv6 reverse zone keeps its colons.
  coredns-ipv6-reverse-zone =
    let
      cfg = corefileOf (corednsCluster {
        config.servers.v6 = {
          zones = [ "fd00::/8" ];
          plugins.forward.args = [
            "."
            "192.0.2.1"
          ];
        };
      });
    in
    lib.hasInfix "fd00::/8:53 {" cfg || throw "Corefile with an IPv6 reverse zone:\n${cfg}";

  # coredns declares its pods as the cluster's DNS peers in its metadata, so
  # under network policy it can run outside kube-system: the DNS rule of
  # every workload, its own included, names the instance's namespace. Kix
  # reads the metadata without evaluating the instance, so the coredns
  # instance's own policies do not recurse.
  coredns-namespace-under-netpol =
    let
      cluster = mkCluster [
        { instances = removeAttrs baseInstances.instances [ "dns" ]; }
        {
          instances.dns.coredns = {
            package = corednsPackage;
            config.clusterIP = "10.96.0.10";
          };
        }
        netpolOn
      ];
      peers = [
        {
          namespace = "dns";
          podSelector."k8s-app" = "kube-dns";
        }
      ];
      dnsRuleOf =
        name:
        lib.findFirst (r: (r.stubRule or null) == "dns-egress") null (
          (byName name (manifests cluster)).spec.egress or [ ]
        );
      app = dnsRuleOf "app-deployment-app-egress";
      own = dnsRuleOf "coredns-deployment-coredns-egress";
    in
    (app.dnsPeers == peers && own.dnsPeers == peers)
    || throw "coredns in namespace dns: app DNS rule ${builtins.toJSON app}, own ${builtins.toJSON own}";

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

  # The alerts keep `namespace` and `service` in every result, the SERVFAIL
  # ratio has a traffic floor, and `out.scrapedByPrometheus` says whether
  # the instance's own monitor scrapes it.
  coredns-alerts =
    let
      with' = corednsCluster { module = withPrometheus; };
      cm = byName "coredns-alerts-rules" (ofKind "ConfigMap" (manifests with'));
      rules = lib.listToAttrs (
        map (r: lib.nameValuePair r.alert r) (
          lib.concatMap (g: g.rules) (builtins.fromJSON cm.data.spec).groups
        )
      );
      sel = ''namespace="kube-system", service="coredns"'';
      scraped = cluster: cluster.instances.kube-system.coredns.out.scrapedByPrometheus;
    in
    (
      builtins.attrNames rules == [
        "CoreDNSDown"
        "CoreDNSErrorsHigh"
        "CoreDNSLatencyHigh"
      ]
      && lib.all (r: lib.hasInfix sel r.expr && !(lib.hasInfix "== 1)" r.expr)) (lib.attrValues rules)
      && lib.all (r: lib.hasInfix "by (namespace, service" r.expr) (lib.attrValues rules)
      && lib.hasSuffix "[5m])) > 1" rules.CoreDNSErrorsHigh.expr
      && rules.CoreDNSErrorsHigh.labels.severity == "warning"
      && scraped with'
      && !(scraped (corednsCluster { }))
    )
    || throw "coredns alerts: ${builtins.toJSON rules}";
}
