# cilium — eBPF-based CNI with network policy, load balancing, and observability.
#
# Full standalone Cilium deployment wrapping the upstream Helm chart via
# scope.helm.importChart. Exposes `cnpCrdRef` for CiliumNetworkPolicy
# and `ccnpCrdRef` for CiliumClusterwideNetworkPolicy CRD markers so
# consumers can route generated CNPs/CCNPs through them.
#
# For externally-managed Cilium (helm-installed out-of-band) see the
# sibling `cilium-external` package — auto-discovered alongside this one.
#
# Chart:   https://helm.cilium.io/
# Name:    cilium
# Version: 1.16.5

{ scope, lib }:

let
  # Shared Cilium-native network-policy rule builders.
  # See netpol-rules.nix for the implementation and kix/lib/netpol-interface.nix
  # for the contract.
  ciliumNetpol = import ./netpol-rules.nix { inherit lib; };

in

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
    policyAuditMode = false;

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
    roles = [
      "cni"
      "network-policy-enforcer"
    ];
    provides = [
      "network-policy"
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

      # CRD refs — wired against ALL workloads so the wave engine gates
      # CNP/CCNP application on the entire cilium stack being Ready.
      # Phase 3 auto-discovery doesn't apply here: the cilium chart
      # installs its CRDs at runtime via INSTALL_CRDS, so they don't
      # appear in `helm template --include-crds` output.
      cnpCrdRef = scope.mkCRDRef {
        group = "cilium.io";
        kind = "CiliumNetworkPolicy";
        plural = "ciliumnetworkpolicies";
        version = "v2";
        crdScope = "Namespaced";
        installedBy = resources.workloads;
      };

      ccnpCrdRef = scope.mkCRDRef {
        group = "cilium.io";
        kind = "CiliumClusterwideNetworkPolicy";
        plural = "ciliumclusterwidenetworkpolicies";
        version = "v2";
        crdScope = "Cluster";
        installedBy = resources.workloads;
      };
    in
    resources.mkParts {
      root = resources.get "DaemonSet" "cilium";
      extraParts = { inherit cnpCrdRef ccnpCrdRef; };
      out = {
        inherit cnpCrdRef ccnpCrdRef;
        # Network-policy rule builder API — see kix/lib/netpol-interface.nix.
        # Bind `mkPolicy` to this package's cnpCrdRef so callers don't need
        # to thread the CRD ref separately.
        netpol = ciliumNetpol // {
          mkPolicy =
            { mkResource, extraArgs }:
            ciliumNetpol.mkPolicy {
              crdRef = cnpCrdRef;
              inherit mkResource extraArgs;
            };

          # Materialize a platform intent into a standalone CNP or CCNP.
          # Used by cluster.nix for networkPolicy.platformIntents (flavor-
          # declared connectivity for non-kix-managed pods like CoreDNS).
          # Unlike mkPolicy (which gets namespace from the scope), this
          # takes an explicit namespaceResource or clusterScoped sentinel
          # because platform intents target pods outside any kix scope.
          materializePlatformIntent =
            {
              intent,
              mkResource,
              namespaceResource ? null,
              clusterScoped,
            }:
            let
              isClusterwide = (intent.scope or "namespaced") == "clusterwide";
              translated = ciliumNetpol.translateIntentRules {
                intents = {
                  _single = intent;
                };
              };
              basePodSelector = intent.podSelector or { };
              # Clusterwide policies targeting a specific namespace need the
              # namespace stamped into the selector (Cilium convention).
              podSelector =
                if isClusterwide && intent ? targetNamespace then
                  basePodSelector
                  // {
                    "k8s:io.kubernetes.pod.namespace" = intent.targetNamespace;
                  }
                else
                  basePodSelector;
              spec = {
                endpointSelector.matchLabels = podSelector;
              }
              // lib.optionalAttrs (translated.egressRules != [ ]) { egress = translated.egressRules; }
              // lib.optionalAttrs (translated.ingressRules != [ ]) { ingress = translated.ingressRules; };
              crdRef = if isClusterwide then ccnpCrdRef else cnpCrdRef;
              enriched = crdRef.out.cr {
                name = intent.name;
                labels = {
                  "kix.dev/derived" = "true";
                  "kix.dev/policy-type" = "platform-intent";
                };
                inherit spec;
              };
            in
            mkResource (
              enriched
              // {
                namespace = if isClusterwide then clusterScoped else namespaceResource;
              }
            );
        };
      };
    };

}
