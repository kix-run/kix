# cilium — eBPF-based CNI with network policy, load balancing, and observability.
#
# Full standalone Cilium deployment (as opposed to cilium-rke2, which only
# emits a HelmChartConfig for RKE2's bundled Cilium). Wraps the upstream
# Cilium Helm chart via `kix.fromHelmChart`, following the same pattern as
# loki/promtail/descheduler: this file exports `{ meta, chart, defaultValues }`
# and the cluster module / definition instantiates it.
#
# Why this package matters for kix/lib/netpol.nix:
#   netpol.nix emits `CiliumNetworkPolicy` resources. Those require the
#   Cilium CRDs plus a running cilium-agent/operator in the cluster. Pairing
#   this package with `networkPolicy.enable = true` gives you an end-to-end
#   working setup — the cluster definition declares a `cilium` instance in
#   kube-system, and every generated CNP is backed by a real enforcer.
#
# The helm chart is deployed with `includeCrds = true`, so the
# CiliumNetworkPolicy / CiliumClusterwideNetworkPolicy / CiliumIdentity /
# CiliumEndpoint / CiliumBGP* CRDs are installed as part of the package.
#
# This package declares `meta.provides = [ ... "network-policy-enforcer" ]`
# and exposes `rootOut.cnpCrdRef`, a `scope.mkCRDRef` handle for the
# CiliumNetworkPolicy CRD with `installedBy = self.root.resource`. kix/lib
# discovers any instance providing `"network-policy-enforcer"` at cluster
# evaluation time and exposes its `out.cnpCrdRef` to scopes via
# `scope.networkPolicyEnforcer`. `kix/lib/netpol.nix` emits every generated
# CiliumNetworkPolicy through that `cnpCrdRef.out.cr` builder, so every CNP
# transitively depends on the CRD import marker → cilium package root →
# cilium DaemonSet + CRDs. No `networkPolicy.ciliumInstance` threading,
# no user-facing plumbing. See v2_discussions/83.
#
# Chart:   https://helm.cilium.io/
# Name:    cilium
# Version: 1.16.5
#
# Usage in a cluster definition:
#
#   let ciliumPkg = import ./kix/packages/cilium; in
#   instances.kube-system.cilium = {
#     package = kix.fromHelmChart {
#       chart = kix.fetchHelmChart {
#         repo    = "https://helm.cilium.io/";
#         name    = "cilium";
#         version = "1.16.5";
#         hash    = "sha256-FIXME"; # nix-prefetch on first build
#       };
#       values       = ciliumPkg.defaultValues;
#       releaseName  = "cilium";
#       includeCrds  = true;
#       rootSelector = { kind = "DaemonSet"; name = "cilium"; };
#       extraMeta    = ciliumPkg.meta;     # surfaces `provides`
#       rootOut      = ciliumPkg.rootOut;  # surfaces `cnpCrdRef`
#     };
#     config.values = {
#       # Cluster-specific overrides. Common knobs:
#       # k8sServiceHost = "<api-server-ip>";
#       # k8sServicePort = 6443;
#       # ipam.operator.clusterPoolIPv4PodCIDRList = [ "10.44.0.0/16" ];
#       # nodePort.addresses = [ "<node-ip>/32" ];
#     };
#   };
#
# Pair with:
#   networkPolicy.enable                  = true;
#   cluster.capabilities.cni              = "cilium";
#   cluster.capabilities.networkPolicyAPI = "cilium";

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
    # Cilium agents run as a DaemonSet using hostNetwork + privileged
    # containers. NetworkPolicy does not constrain cilium itself (hostNetwork
    # bypass) — the netpol lib emits a warning for hostNetwork workloads,
    # which is expected here.
    k8s.minVersion = "1.27";
  };

  # Exposed via fromHelmChart's `rootOut` hook. The returned attrset becomes
  # `root.out` on the cilium instance; kix/lib reads `cnpCrdRef` off
  # `networkPolicyEnforcer.out.cnpCrdRef` and routes every generated CNP
  # through `cnpCrdRef.out.cr` so the CRD marker → cilium root edge is
  # installed transitively. `installedBy = self.root.resource` orders the
  # CRD import marker AFTER the cilium chart's root (the DaemonSet, which
  # itself depends on every helm-emitted resource including the CRDs).
  rootOut =
    { scope, self, ... }:
    {
      cnpCrdRef = scope.mkCRDRef {
        group = "cilium.io";
        kind = "CiliumNetworkPolicy";
        plural = "ciliumnetworkpolicies";
        version = "v2";
        crdScope = "Namespaced";
        installedBy = self.root.resource;
      };
    };

  chart = {
    repo = "https://helm.cilium.io/";
    name = "cilium";
    version = "1.16.5";
  };

  # Sensible defaults for a standalone Cilium deployment.
  #
  # These are intentionally minimal and cluster-agnostic. Cluster-specific
  # knobs (pod CIDR, service host/port, node addresses, MTU, devices)
  # must be set per-cluster via `config.values`. See cilium-rke2 for an
  # example of a fully-derived value set driven by cluster topology.
  defaultValues = {
    # --- Policy enforcement ---
    # "always" is the only mode that makes sense when we're generating
    # netpol from the DI graph: the CNPs emitted by kix/lib/netpol.nix
    # become the source of truth.
    policyEnforcementMode = "always";
    # Audit mode logs drops without enforcing — safe default during rollout.
    # Flip to `false` once the generated policies are validated.
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
      serviceMonitor.enabled = false; # flip on when kube-prometheus-stack is present
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
}
