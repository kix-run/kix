# cilium — eBPF-based CNI with network policy, load balancing, and observability.
#
# Full standalone Cilium deployment (as opposed to cilium-rke2, which only
# emits a HelmChartConfig for RKE2's bundled Cilium). Wraps the upstream
# Cilium Helm chart via `kix.fromHelmChart`, following the same pattern as
# loki/promtail/descheduler: this file exports `{ meta, chart, defaultValues }`
# and the cluster module / definition instantiates it.
#
# This file ALSO exports `external`, a small inline package for
# externally-managed Cilium (helm-installed out-of-band by the distro or
# by a bootstrap script, e.g. k3s with --flannel-backend=none or kind
# with deploy-ludo-kind.sh). The external variant advertises the
# `network-policy-enforcer` capability and emits the CiliumNetworkPolicy
# CRD ref marker — it does NOT deploy cilium itself. kix/lib/netpol.nix
# routes every generated CNP through this marker so the CNPs still
# depend on (a proxy for) cilium's readiness, even though cilium itself
# is not part of the kix-managed store closure.
#
# Usage (externally-managed):
#
#   instances.kube-system.cilium = {
#     package = packages."cilium".external;
#   };
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
# CiliumNetworkPolicy CRD with `installedBy = workloads` (the full list of
# helm-emitted workloads, surfaced by helm.nix). kix/lib discovers any
# instance providing `"network-policy-enforcer"` at cluster evaluation time
# and exposes its `out.cnpCrdRef` to scopes via `scope.networkPolicyEnforcer`.
# `kix/lib/netpol.nix` emits every generated CiliumNetworkPolicy through
# that `cnpCrdRef.out.cr` builder, so every CNP transitively depends on the
# CRD import marker → *every* cilium workload (agent DaemonSet + operator
# Deployment + Hubble components). That's the "whole chart Ready" gate the
# CNP validating webhook needs — pinning the marker only to the DaemonSet
# root leaves cilium-operator in the same wave as every other helm sibling,
# so its readiness is checked once at that wave boundary and never re-gated
# when the CR wave lands. See v2_discussions/83.
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
  # through `cnpCrdRef.out.cr` so the CRD marker → cilium workloads edge is
  # installed transitively.
  #
  # `installedBy = workloads` wires the marker against *every* helm-emitted
  # workload (cilium agent DaemonSet + cilium-operator Deployment + Hubble
  # relay/ui when enabled). Gating only on the DaemonSet root is not enough:
  # CiliumNetworkPolicy is served by a validating webhook running in
  # cilium-operator, and in the helm layout that Deployment is just another
  # non-root resource sitting in the same wave as every other helm sibling.
  # Its readiness would be observed once at that wave boundary and never
  # re-gated when the CR wave lands two waves later, so a slow/rolling
  # operator can be mid-restart by the time CNPs are applied and the webhook
  # returns 503. Listing every workload forces the wave engine to re-observe
  # all of them at the marker's wave, which is the "whole chart Ready" gate
  # the CRs actually need.
  rootOut =
    { scope, workloads, ... }:
    {
      cnpCrdRef = scope.mkCRDRef {
        group = "cilium.io";
        kind = "CiliumNetworkPolicy";
        plural = "ciliumnetworkpolicies";
        version = "v2";
        crdScope = "Namespaced";
        installedBy = workloads;
      };
    };

  # Externally-managed cilium variant — inline package that emits only
  # the CiliumNetworkPolicy CRD ref marker (no helm chart, no DaemonSet).
  #
  # The CLI deploy engine polls for the externally-installed CRD via the
  # marker's import semantics (see scope.mkImportMarker in scope.nix) and
  # waits for `Established=True` before any dependent CNP wave runs. No
  # `installedBy` is set, so the marker has no store-path edge — the
  # "cilium is ready" guarantee comes from the external bootstrap, not
  # the DI graph.
  #
  # Declares `meta.provides = ["network-policy-enforcer" "cilium"]` so
  # the cluster-level enforcer lookup resolves this instance, and
  # exposes `out.cnpCrdRef` so kix/lib/netpol.nix can route CNPs through
  # `cnpCrdRef.out.cr`.
  external = {
    meta = {
      description = "Cilium (externally managed) — CNP CRD ref marker only";
      provides = [
        "network-policy-enforcer"
        "cilium"
      ];
      # Intentionally does NOT provide "cni" / "network-policy": the real
      # cilium DaemonSet is not part of this package. Capability lookups
      # that need the datapath should rely on `cluster.capabilities.cni`
      # being set by the cluster definition.
    };

    build =
      { scope, ... }:
      let
        crdRef = scope.mkCRDRef {
          group = "cilium.io";
          kind = "CiliumNetworkPolicy";
          plural = "ciliumnetworkpolicies";
          version = "v2";
          crdScope = "Namespaced";
          # No `installedBy` — CRD is installed out-of-band by the
          # external cilium. The CLI readiness check polls the cluster
          # for the CRD and gates the wave until it's Established=True.
        };
      in
      {
        # Expose the crdRef at the top level of parts so
        # `collectResources` picks it up and the PackageInstance import
        # marker is emitted as a yaml file (the cluster-level resource
        # collector excludes the `root` key, so resources must live on
        # a sibling key to be serialized).
        cnpCrdRef = crdRef;

        root = {
          # The crdRef is itself a k8s-resource (PackageInstance import
          # marker), so it serves as the instance root directly — same
          # store path as `parts.cnpCrdRef`, deduped by the collector.
          resource = crdRef;
          requires = [ ];
          # Surface the crdRef on the instance's `out` so the cluster-
          # level enforcer lookup (cluster.nix → enforcerOut) can read
          # `out.cnpCrdRef` and feed it to every scope.
          out = {
            cnpCrdRef = crdRef;
          };
        };
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
