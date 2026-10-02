# Tests for the cilium package's deliveries, the platform-cilium import it
# takes as a dependency, and the rke2 flavour's cni list and platform
# intents. None renders
# the cilium chart: chart-delivery tests use a Helm stub whose importChart
# emits the values it receives as one ConfigMap.

{
  lib,
  k8s,
  eval,
  mkCluster,
  manifests,
  ofKind,
  namesOf,
  hasName,
  byName,
  evalFails,
  ...
}:

let
  ciliumPackage = import ../../../packages/cilium;
  rke2 = import ../../flavors/rke2.nix;

  # Stands in for kix/lib/helm.nix, which needs nixpkgs to render a chart.
  # The chart delivery's root and parts are kept; the chart's own resources
  # are replaced by the ConfigMap `cilium-values`.
  stubHelm = {
    fetchHelmChart = _: "cilium-chart";
    importChart =
      { scope, values, ... }:
      let
        rendered = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "cilium-values";
          data.values = builtins.toJSON values;
        };
      in
      {
        workloads = [ ];
        get = _kind: _name: rendered;
        mkParts =
          {
            root,
            extraParts ? { },
            extraRequires ? [ ],
            out ? { },
          }:
          extraParts
          // {
            chartValues = rendered;
            root = {
              resource = root;
              requires = extraRequires;
              inherit out;
            };
          };
      };
  };
  stubEval = import ../../eval {
    inherit lib k8s;
    helm = stubHelm;
  };

  # A chart-delivery cluster (cni binding absent), built with the Helm stub.
  chartCluster =
    {
      podCidr ? "10.244.0.0/16",
      netpol ? false,
      binding ? "absent",
      multiNode ? null,
      config ? { },
    }:
    stubEval.buildCluster {
      name = "test";
      modules = [
        {
          cluster.capabilities = lib.optionalAttrs (multiNode != null) { inherit multiNode; };
          cluster.roles.cni = lib.optionalAttrs (binding != null) {
            inherit binding;
            provider = null;
          };
          cluster.network.podCidr = podCidr;
          networkPolicy.enable = netpol;
          instances.kube-system.cilium = {
            package = ciliumPackage;
            inherit config;
          };
        }
      ];
    };

  chartValuesOf =
    cluster:
    builtins.fromJSON (byName "cilium-values" (ofKind "ConfigMap" (manifests cluster))).data.values;

  # Reads the cluster facts the cilium package derives its delivery from:
  # the cni binding and the out of the platform-cilium dependency.
  factsProbe = {
    meta.version = "test";
    build =
      {
        self,
        scope,
        clusterConfig,
        platform-cilium ? null,
        ...
      }:
      {
        cm = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "facts";
          data = {
            binding = builtins.toJSON (clusterConfig.cluster.roles.cni.binding or null);
            provider = builtins.toJSON (clusterConfig.cluster.roles.cni.provider or null);
            platformCilium = builtins.toJSON (if platform-cilium == null then null else platform-cilium.out);
          };
        };
        root = self.cm;
      };
  };

  rke2Facts =
    cni:
    let
      cluster = mkCluster [
        rke2
        (
          { lib, ... }:
          {
            cluster.flavor.rke2.cni = lib.mkIf (cni != null) cni;
            instances.probe.facts.package = factsProbe;
          }
        )
      ];
    in
    lib.mapAttrs (_: builtins.fromJSON) (byName "facts" (ofKind "ConfigMap" (manifests cluster))).data;

  rke2HelmChartConfig = {
    helmChartConfig = {
      name = "rke2-cilium";
      namespace = "kube-system";
    };
  };

  # An RKE2 cluster whose server config sets `cni: cilium`.
  rke2CiliumCluster =
    {
      netpol ? false,
      namespace ? "kube-system",
      config ? { },
      extra ? { },
    }:
    mkCluster [
      rke2
      {
        cluster.flavor.rke2.cni = [ "cilium" ];
        cluster.network.podCidr = "10.42.0.0/16";
        networkPolicy.enable = netpol;
        instances.${namespace}.cilium = {
          package = ciliumPackage;
          inherit config;
        };
      }
      extra
    ];

  # A platform import for an environment-installed Cilium.
  platformCilium =
    out:
    eval.mkImport {
      roles = [ "cni" ];
      inherit out;
    };

  # An environment that installed Cilium and exposes no HelmChartConfig.
  platformCiliumCluster =
    {
      netpol ? false,
      config ? { },
      extra ? { },
    }:
    mkCluster [
      {
        cluster.roles.cni = {
          binding = "shadowable";
          provider = "cilium (environment)";
        };
        networkPolicy.enable = netpol;
        instances.net.cilium = {
          package = ciliumPackage;
          inherit config;
        };
        instances.net.platform-cilium.package = platformCilium { helmChartConfig = null; };
      }
      extra
    ];

  valuesOf =
    cluster:
    builtins.fromJSON (byName "rke2-cilium" (ofKind "HelmChartConfig" (manifests cluster)))
      .spec.valuesContent;
in
{
  # The rke2 cni list sets the cni binding and, for cilium, declares the
  # platform-cilium import naming the environment's HelmChartConfig.
  # Invalid lists fail evaluation.
  cilium-flavour-rke2-cni-list =
    let
      cilium = rke2Facts [ "cilium" ];
      multusCilium = rke2Facts [
        "multus"
        "cilium"
      ];
      none = rke2Facts [ "none" ];
      default = rke2Facts null;
      invalid =
        cni:
        evalFails (mkCluster [
          rke2
          {
            cluster.flavor.rke2.cni = cni;
            instances.probe.facts.package = factsProbe;
          }
        ]);
    in
    (
      cilium.binding == "shadowable"
      && cilium.platformCilium == rke2HelmChartConfig
      && multusCilium.binding == "shadowable"
      && multusCilium.platformCilium == rke2HelmChartConfig
      && none.binding == "absent"
      && none.platformCilium == null
      && default.binding == "exclusive"
      && default.provider == "canal"
      && default.platformCilium == null
      && invalid [
        "cilium"
        "canal"
      ]
      && invalid [
        "none"
        "multus"
      ]
      && invalid [
        "cilium"
        "multus"
      ]
    )
    || throw "rke2 cni list: ${
      builtins.toJSON {
        inherit
          cilium
          multusCilium
          none
          default
          ;
      }
    }";

  # A platform-cilium dependency on a cni binding other than shadowable
  # fails evaluation. Control: the shadowable binding builds.
  cilium-platform-import-requires-shadowable =
    let
      withBinding =
        binding:
        mkCluster [
          {
            cluster.roles.cni = lib.optionalAttrs (binding != null) {
              inherit binding;
              provider = "test";
            };
            instances.net.cilium.package = ciliumPackage;
            instances.net.platform-cilium.package = platformCilium { helmChartConfig = null; };
          }
        ];
    in
    (
      evalFails (withBinding "absent")
      && evalFails (withBinding "exclusive")
      && evalFails (withBinding null)
      && !(evalFails (withBinding "shadowable"))
    )
    || throw "platform-cilium was accepted on a binding other than shadowable";

  # The import's out must name the HelmChartConfig or say there is none with
  # null; a missing or malformed out.helmChartConfig fails evaluation instead
  # of selecting the none delivery.
  cilium-platform-import-out-checked =
    let
      withOut =
        out:
        platformCiliumCluster {
          extra.instances.net.platform-cilium.package = lib.mkForce (platformCilium out);
        };
    in
    (
      evalFails (withOut { })
      && evalFails (withOut {
        helmchartconfig = null;
      })
      && evalFails (withOut {
        helmChartConfig.name = "rke2-cilium";
      })
      && evalFails (withOut {
        helmChartConfig = "rke2-cilium";
      })
      && !(evalFails (withOut {
        helmChartConfig = null;
      }))
    )
    || throw "platform-cilium out.helmChartConfig: refusal or control wrong";

  # Under the rke2 flavour with cni = [ "cilium" ], the instance writes
  # exactly HelmChartConfig kube-system/rke2-cilium and the CRD-reference
  # markers, with no chart workloads and no IPAM values.
  cilium-helmchartconfig-delivery =
    let
      cluster = rke2CiliumCluster { };
      ms = manifests cluster;
      hccs = ofKind "HelmChartConfig" ms;
      hcc = builtins.head hccs;
      values = valuesOf cluster;
      markers = builtins.filter (n: lib.hasPrefix "crd-ref-cilium-" n) (
        namesOf (ofKind "PackageInstance" ms)
      );
    in
    (
      builtins.length hccs == 1
      && hcc.metadata.name == "rke2-cilium"
      && hcc.metadata.namespace == "kube-system"
      && ofKind "DaemonSet" ms == [ ]
      && ofKind "Deployment" ms == [ ]
      && values.policyAuditMode == false
      && values.policyEnforcementMode == "default"
      && values.operator.rollOutPods
      && values.rollOutCiliumPods
      && !(values ? ipam)
      &&
        lib.sort lib.lessThan markers == [
          "crd-ref-cilium-ciliumclusterwidenetworkpolicies-cilium-io"
          "crd-ref-cilium-ciliumnetworkpolicies-cilium-io"
          "crd-ref-cilium-helmchartconfigs-helm-cattle-io"
        ]
      # Not under "default" enforcement.
      && !(hasName "cilium-cluster-dns-egress" ms)
    )
    || throw "helmChartConfig delivery: ${builtins.toJSON { inherit values markers; }}";

  # User values merge over the package's defaults in the HelmChartConfig,
  # and enforcement is "always" with network policy on.
  cilium-helmchartconfig-values-merge =
    let
      cluster = rke2CiliumCluster {
        netpol = true;
        config.values = {
          kubeProxyReplacement = true;
          operator.replicas = 3;
        };
      };
      values = valuesOf cluster;
    in
    (
      values.kubeProxyReplacement
      && values.operator.replicas == 3
      && values.operator.rollOutPods
      && values.policyEnforcementMode == "always"
      && hasName "cilium-cluster-dns-egress" (manifests cluster)
    )
    || throw "helmChartConfig values merge: ${builtins.toJSON values}";

  # With the import's out.helmChartConfig = null the instance writes no
  # Cilium configuration, and refuses `values`.
  cilium-none-delivery =
    let
      ms = manifests (platformCiliumCluster {
        netpol = true;
      });
      markers = builtins.filter (n: lib.hasPrefix "crd-ref-cilium-" n) (
        namesOf (ofKind "PackageInstance" ms)
      );
    in
    (
      ofKind "HelmChartConfig" ms == [ ]
      && ofKind "DaemonSet" ms == [ ]
      && !(hasName "cilium-cluster-dns-egress" ms)
      && builtins.length markers == 2
      && evalFails (platformCiliumCluster {
        config.values.policyAuditMode = true;
      })
    )
    || throw "none delivery: ${builtins.toJSON (namesOf ms)}";

  # The HelmChartConfig must live where the environment reads it.
  cilium-namespace-mismatch = evalFails (rke2CiliumCluster {
    namespace = "cilium-system";
  });

  # A clusterwide platform intent becomes a CiliumClusterwideNetworkPolicy
  # with the target namespace in its selector; a namespaced one becomes a
  # CiliumNetworkPolicy.
  cilium-clusterwide-intent-is-ccnp =
    let
      ms = manifests (platformCiliumCluster {
        netpol = true;
        extra = {
          namespaces.agents = { };
          networkPolicy.platformIntents = {
            wide = {
              scope = "clusterwide";
              targetNamespace = "agents";
              podSelector.app = "agent";
              egress = [ { to = "dns"; } ];
            };
            narrow = {
              namespace = "agents";
              podSelector.app = "agent";
              egress = [ { to = "apiserver"; } ];
            };
          };
        };
      });
      wide = byName "wide" ms;
      narrow = byName "narrow" ms;
    in
    (
      wide.kind == "CiliumClusterwideNetworkPolicy"
      && !(wide.metadata ? namespace)
      &&
        wide.spec.endpointSelector.matchLabels == {
          app = "agent";
          "k8s:io.kubernetes.pod.namespace" = "agents";
        }
      && narrow.kind == "CiliumNetworkPolicy"
      && narrow.metadata.namespace == "agents"
    )
    || throw "platform intents: ${builtins.toJSON { inherit wide narrow; }}";

  # A shadowable cni binding without a platform-cilium import cannot say
  # whether the environment's CNI is Cilium. Control: the same cluster with
  # the import builds.
  cilium-shadowable-without-platform-import =
    let
      withImport =
        withIt:
        mkCluster [
          {
            cluster.roles.cni.binding = "shadowable";
            cluster.network.podCidr = "10.244.0.0/16";
            instances.net = {
              cilium.package = ciliumPackage;
            }
            // lib.optionalAttrs withIt {
              platform-cilium.package = platformCilium { helmChartConfig = null; };
            };
          }
        ];
    in
    (evalFails (withImport false) && !(evalFails (withImport true)))
    || throw "shadowable without platform-cilium: refusal or control wrong";

  # Without a cni binding Kix cannot tell whether a CNI is already
  # running. The refusal comes before the chart would be rendered.
  # Control: the same chart-delivery cluster with binding "absent" builds.
  cilium-null-binding =
    (
      evalFails (chartCluster {
        binding = null;
      })
      && !(evalFails (chartCluster { }))
    )
    || throw "null cni binding: refusal or control wrong";

  # The chart delivery needs the pod range for its default cluster-pool
  # IPAM, and writes it as the pool. Another IPAM mode needs no pod range.
  cilium-chart-needs-podcidr =
    let
      withPool = chartValuesOf (chartCluster { });
      kubernetesIpam = chartValuesOf (chartCluster {
        podCidr = null;
        config.values.ipam.mode = "kubernetes";
      });
    in
    (
      evalFails (chartCluster {
        podCidr = null;
      })
      && withPool.ipam.operator.clusterPoolIPv4PodCIDRList == [ "10.244.0.0/16" ]
      && kubernetesIpam.ipam == { mode = "kubernetes"; }
    )
    || throw "chart IPAM: ${builtins.toJSON { inherit withPool kubernetesIpam; }}";

  # The chart delivery's defaults: enforcement follows networkPolicy.enable,
  # audit is off, the operator's metrics port and Hubble are off, and the
  # operator runs one replica on a single-node cluster.
  cilium-chart-delivery-values =
    let
      off = chartValuesOf (chartCluster { });
      on = chartValuesOf (chartCluster {
        netpol = true;
        multiNode = false;
      });
    in
    (
      off.policyEnforcementMode == "default"
      && on.policyEnforcementMode == "always"
      && on.policyAuditMode == false
      && on.operator.prometheus.enabled == false
      && on.hubble.enabled == false
      && on.operator.replicas == 1
      && off.operator.replicas == 2
      && !(on ? kubeProxyReplacement)
    )
    || throw "chart values: ${builtins.toJSON { inherit off on; }}";

  # Under "always" the instance writes the cluster DNS and health-probe
  # CiliumClusterwideNetworkPolicies; under "default" it writes neither,
  # because a policy that selects an endpoint puts it into default deny.
  cilium-always-writes-clusterwide-policies =
    let
      on = manifests (chartCluster {
        netpol = true;
      });
      off = manifests (chartCluster { });
      health = byName "cilium-health-probes" on;
      named = ms: namesOf (ofKind "CiliumClusterwideNetworkPolicy" ms);
    in
    (
      lib.sort lib.lessThan (named on) == [
        "cilium-cluster-dns-egress"
        "cilium-health-probes"
      ]
      && named off == [ ]
      && health.spec.endpointSelector.matchLabels == { "reserved:health" = ""; }
      &&
        (builtins.head health.spec.ingress).fromEntities == [
          "health"
          "remote-node"
        ]
      &&
        (builtins.head health.spec.egress).toEntities == [
          "health"
          "remote-node"
        ]
    )
    || throw "clusterwide policies: ${
      builtins.toJSON {
        on = named on;
        off = named off;
      }
    }";

  # The build branches on values.policyEnforcementMode, so a value Cilium's
  # agent rejects fails evaluation. Control: "never" builds.
  cilium-enforcement-mode-checked =
    (
      evalFails (rke2CiliumCluster {
        config.values.policyEnforcementMode = "Always";
      })
      && !(evalFails (rke2CiliumCluster {
        config.values.policyEnforcementMode = "never";
      }))
    )
    || throw "policyEnforcementMode: refusal or control wrong";

  # The rke2 default (canal, exclusive) refuses a cilium instance, because
  # it would install a second CNI. Control: cni = [ "cilium" ] builds.
  cilium-refused-beside-rke2-canal =
    let
      withCni =
        cni:
        mkCluster [
          rke2
          (
            { lib, ... }:
            {
              cluster.flavor.rke2.cni = lib.mkIf (cni != null) cni;
              instances.kube-system.cilium.package = ciliumPackage;
            }
          )
        ];
    in
    (evalFails (withCni null) && !(evalFails (withCni [ "cilium" ])))
    || throw "rke2 canal default: refusal or control wrong";

  # An explicit "always" with network policy off warns and still builds,
  # with the cluster DNS egress policy.
  cilium-always-without-netpol-evaluates =
    let
      cluster = rke2CiliumCluster { config.values.policyEnforcementMode = "always"; };
      values = valuesOf cluster;
    in
    (
      values.policyEnforcementMode == "always" && hasName "cilium-cluster-dns-egress" (manifests cluster)
    )
    || throw "explicit always without netpol: ${builtins.toJSON values}";

  # With network policy on, the rke2 flavour declares an intent for each
  # bundled component, and kube-system gets its default-deny policy.
  cilium-flavour-rke2-platform-intents =
    let
      ms = manifests (rke2CiliumCluster {
        netpol = true;
      });
      cnps = namesOf (ofKind "CiliumNetworkPolicy" ms);
      expected = [
        "kube-system-default-deny"
        "rke2-coredns-egress"
        "rke2-coredns-ingress"
        "rke2-coredns-autoscaler-egress"
        "rke2-metrics-server-egress"
        "rke2-metrics-server-ingress"
        "rke2-snapshot-controller-egress"
        "rke2-ingress-nginx-controller-egress"
        "rke2-ingress-nginx-controller-ingress"
        "rke2-ingress-nginx-admission-egress"
        "rke2-traefik-egress"
        "rke2-traefik-ingress"
        "rke2-security-responder-egress"
        "helm-install-rke2-ingress-nginx-egress"
        "helm-install-rke2-traefik-egress"
        "helm-install-rke2-metrics-server-egress"
      ];
      missing = builtins.filter (n: !(builtins.elem n cnps)) expected;
      dnsIngress = byName "rke2-coredns-ingress" ms;
      helmInstall = byName "helm-install-rke2-traefik-egress" ms;
    in
    (
      missing == [ ]
      && dnsIngress.metadata.namespace == "kube-system"
      && dnsIngress.spec.endpointSelector.matchLabels == { "k8s-app" = "kube-dns"; }
      &&
        (builtins.head dnsIngress.spec.ingress).toPorts == [
          {
            ports = [
              {
                port = "53";
                protocol = "UDP";
              }
              {
                port = "53";
                protocol = "TCP";
              }
            ];
          }
        ]
      &&
        helmInstall.spec.endpointSelector.matchLabels == {
          "helmcharts.helm.cattle.io/chart" = "rke2-traefik";
        }
    )
    || throw "rke2 platform intents, missing ${builtins.toJSON missing}: ${builtins.toJSON cnps}";
}
