# cilium — eBPF-based CNI with network policy, load balancing, and observability.
#
# Full standalone Cilium deployment wrapping the upstream Helm chart via
# scope.helm.importChart. Exposes `cnpCrdRef` for CiliumNetworkPolicy
# CRD marker so kix/lib/netpol.nix can route generated CNPs through it.
#
# Also exports `external`, a small inline package for externally-managed
# Cilium (helm-installed out-of-band). See the `external` variant below.
#
# Chart:   https://helm.cilium.io/
# Name:    cilium
# Version: 1.16.5

{ scope, lib }:
let
  chart = scope.helm.fetchHelmChart {
    repo = "https://helm.cilium.io/";
    name = "cilium";
    version = "1.16.5";
    hash = "sha256-GCA1rnws+NGUkOzs9hj2oRrcRg7R59vTiyMGXwLxi00=";
  };

  defaultValues = {
    # --- Policy enforcement ---
    policyEnforcementMode = "always";
    policyAuditMode = true;

    # --- Datapath ---
    kubeProxyReplacement = true;
    routingMode = "tunnel";
    tunnelProtocol = "vxlan";
    enableIPv4Masquerade = true;
    enableIPv6 = false;

    bpf = {
      masquerade = true;
      lbExternalClusterIP = true;
    };

    socketLB.hostNamespaceOnly = true;

    # --- IPAM ---
    ipam = {
      mode = "cluster-pool";
      operator = {
        clusterPoolIPv4PodCIDRList = [ "10.244.0.0/16" ];
        clusterPoolIPv4MaskSize = 24;
      };
    };

    # --- LoadBalancer / NodePort ---
    loadBalancer = {
      mode = "snat";
    };
    externalIPs.enabled = true;
    nodePort.enabled = true;

    # --- Operator ---
    operator = {
      replicas = 1;
      prometheus.enabled = false;
      rollOutPods = true;
    };
    rollOutCiliumPods = true;

    # --- Encryption (off by default; enable per-cluster) ---
    encryption = {
      enabled = false;
      type = "wireguard";
    };

    # --- Observability ---
    prometheus = {
      enabled = true;
      serviceMonitor.enabled = false;
    };

    hubble = {
      enabled = false;
      relay.enabled = false;
      ui.enabled = false;
      metrics = {
        enableOpenMetrics = false;
        enabled = [
          "dns"
          "drop"
          "tcp"
          "flow"
          "port-distribution"
          "icmp"
        ];
      };
    };

    # --- BGP / L2 announcements (off by default) ---
    bgpControlPlane.enabled = false;
    l2announcements.enabled = false;

    # --- CNI chaining / installation ---
    cni = {
      install = true;
      exclusive = true;
    };
  };
in
{
  meta = {
    version = "1.16.5";
    description = "Cilium — eBPF CNI, load balancer, and CiliumNetworkPolicy enforcer";
    provides = [
      "cni"
      "network-policy"
      "network-policy-enforcer"
      "cilium"
    ];
    k8s.minVersion = "1.27";
  };

  options.values = lib.mkOption {
    type = lib.types.attrsOf lib.types.anything;
    default = { };
    description = "Helm values to deep-merge with the chart's package-level values.";
  };

  build =
    { config, scope, ... }:
    let
      resources = scope.helm.importChart {
        inherit chart scope;
        values = lib.recursiveUpdate defaultValues (config.values or { });
        releaseName = "cilium";
        includeCrds = true;
      };

      # CRD ref — wired against ALL workloads so the wave engine gates
      # CNP application on the entire cilium stack being Ready.
      cnpCrdRef = scope.mkCRDRef {
        group = "cilium.io";
        kind = "CiliumNetworkPolicy";
        plural = "ciliumnetworkpolicies";
        version = "v2";
        crdScope = "Namespaced";
        installedBy = resources.workloads;
      };
    in
    resources.mkParts {
      root = resources.get "DaemonSet" "cilium";
      extraParts = { inherit cnpCrdRef; };
      out = { inherit cnpCrdRef; };
    };

}
