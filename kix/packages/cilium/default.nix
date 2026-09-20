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
# Version: 1.19.6

{
  scope,
  lib,
  kix,
  availability,
}:

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
    version = "1.19.6";
    hash = "sha256-IcQ89ThB+asDdQR9lapMZAUepSu9LGeUFuZAj18ckXk=";
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
      # The operator is leader-elected, so the second replica is a warm
      # standby: it only buys anything once it can sit on another node.
      # Two is also the chart's own default.
      replicas = kix.availability.pick availability {
        none = 1;
        pod = 1;
        node = 2;
        zone = 2;
      };
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
    version = "1.19.6";
    description = "Cilium — eBPF CNI, load balancer, and CiliumNetworkPolicy enforcer";
    owner = "platform";
    # A CNI programs the node's own networking and loads BPF into the
    # kernel, so the agent, envoy and operator pods run on the host
    # network with a privileged mount. Declared here rather than
    # downgraded per namespace in every cluster that installs cilium:
    # the grant is scoped to this package and listed by
    # `architecture.unsafeGrants` in every build.
    unsafe = [
      "host-network"
      "privileged"
      "run-as-root"
    ];
    roles = [
      "cni"
      "network-policy-enforcer"
    ];
    k8s.minVersion = "1.27";
  };

  options = {
    values = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = "Helm values to deep-merge with the chart's package-level values.";
    };

    clusterDnsEgress = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Allow every pod in the cluster to reach cluster DNS, as one
        CiliumClusterwideNetworkPolicy. Only emitted when
        `policyEnforcementMode` is "always", which is this package's
        default.

        In that mode every pod in the cluster is in default deny, including
        the ones Kix never writes a policy for: a `kubectl run` debug pod,
        an operator's own Job, anything in a namespace Kix does not manage.
        Kix writes DNS egress for the workloads it renders and for nothing
        else, so without this those pods cannot resolve a name, and the
        failure reads as a DNS outage rather than as a policy decision.

        Set it false to write that policy yourself. Turning it off while
        leaving enforcement at "always" means anything outside a Kix
        namespace has no DNS.
      '';
    };
  };

  build =
    { config, scope, ... }:
    let
      # Since 1.17 the chart defaults `tls.secretsNamespace` to a dedicated
      # `cilium-secrets` Namespace (plus a Role/RoleBinding inside it) for
      # TLS-aware CiliumNetworkPolicies and ingress/gateway TLS interception.
      # We use none of that, and a foreign namespace would have to exist in
      # every cluster scope — so keep the (unused) secrets namespace pointed
      # at the instance's own namespace and don't create anything.
      nsValues = {
        tls.secretsNamespace = {
          create = false;
          name = scope.namespaceName;
        };
      };

      resources = scope.helm.importChart {
        inherit chart scope;
        values = lib.recursiveUpdate (lib.recursiveUpdate defaultValues nsValues) (config.values or { });
        releaseName = "cilium";
        includeCrds = true;
      };

      # The enforcement mode actually in effect, after the cluster's own
      # values are merged over this package's.
      effectiveEnforcement = config.values.policyEnforcementMode or defaultValues.policyEnforcementMode;

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
        readiness = ciliumNetpol.policyReadiness;
      };

      ccnpCrdRef = scope.mkCRDRef {
        group = "cilium.io";
        kind = "CiliumClusterwideNetworkPolicy";
        plural = "ciliumclusterwidenetworkpolicies";
        version = "v2";
        crdScope = "Cluster";
        installedBy = resources.workloads;
        readiness = ciliumNetpol.policyReadiness;
      };
      # Everything Kix does not render still has to resolve a name.
      #
      # `policyEnforcementMode = "always"` puts every pod in the cluster
      # into default deny, not just the ones in Kix namespaces. Kix writes
      # DNS egress for the workloads it renders and for nothing else, so a
      # `kubectl run` debug pod, an operator's own Job, or anything in a
      # namespace Kix does not manage gets "Temporary failure in name
      # resolution" on every lookup, and reads as a DNS outage rather than
      # as the policy decision it is. This package chose `always`, so it
      # opens the one port that makes the rest of the cluster diagnosable.
      # It is an allow rule and adds nothing to what a Kix-managed workload
      # could already reach.
      clusterDnsEgress =
        if config.clusterDnsEgress && effectiveEnforcement == "always" then
          scope.mkClusterResource (
            ccnpCrdRef.out.cr {
              name = "cilium-cluster-dns-egress";
              labels = {
                ${kix.keys.derived} = "true";
              };
              spec = {
                endpointSelector = { };
                egress = [ ciliumNetpol.dnsEgressRule ];
              };
            }
          )
        else
          null;
    in
    resources.mkParts {
      root = resources.get "DaemonSet" "cilium";
      extraParts = {
        inherit cnpCrdRef ccnpCrdRef;
      }
      // lib.optionalAttrs (clusterDnsEgress != null) { inherit clusterDnsEgress; };
      # The policy hangs off nothing in the chart, so root has to name it or
      # it is a part no dependency reaches and the build says so. An allow
      # rule needs no ordering against the agent; it needs the CRD, which it
      # already requires.
      extraRequires = lib.optional (clusterDnsEgress != null) clusterDnsEgress;
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
                  ${kix.keys.derived} = "true";
                  ${kix.keys.policyType} = "platform-intent";
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
