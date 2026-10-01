# cilium: Cilium as the cluster's pod network (the `cni` role) and its
# CiliumNetworkPolicy enforcer (the `network-policy-enforcer` role).
#
# Who installs Cilium, the delivery, follows from two cluster facts that a
# flavour sets, cluster.roles.cni.binding and
# cluster.network.environmentCilium:
#
#   binding      environmentCilium                 delivery         emits
#   "absent"     null                              chart            the upstream chart
#   "shadowable" { helmChartConfig = { ... }; }    helmChartConfig  one HelmChartConfig
#   "shadowable" { helmChartConfig = null; }       none             CRD references only
#
# Every other combination is an evaluation error. In the helmChartConfig
# delivery the environment's helm-controller merges the HelmChartConfig into
# the Cilium chart it installed (RKE2: kube-system/rke2-cilium). In every
# delivery the instance provides `out.netpol` and the CRD references that
# generated policies wait on.
#
# Chart: https://helm.cilium.io/ cilium 1.19.6

{
  scope,
  lib,
  kix,
  availability,
}:

let
  rules = import ./netpol-rules.nix { inherit lib; };

  chart = scope.helm.fetchHelmChart {
    repo = "https://helm.cilium.io/";
    name = "cilium";
    version = "1.19.6";
    hash = "sha256-IcQ89ThB+asDdQR9lapMZAUepSu9LGeUFuZAj18ckXk=";
  };
in
{
  meta = {
    # The chart version, which only the chart delivery deploys. In the other
    # deliveries the environment picks the Cilium version and
    # meta.compatibleWith still compares against this one
    # (housekeeping/2026-10-01-platform-providers-carry-placeholder-versions.md).
    version = "1.19.6";
    description = "Cilium: CNI, load balancer, and CiliumNetworkPolicy enforcer. Installs the chart, configures an environment's bundled Cilium, or uses one the environment installed";
    owner = "platform";
    # A CNI programs the node's own networking and loads BPF into the
    # kernel, so the agent, envoy and operator pods run on the host
    # network with a privileged mount. Declared here rather than
    # downgraded per namespace in every cluster that installs cilium:
    # the grant is scoped to this package and listed by
    # `architecture.unsafeGrants` in every build. `meta` is static, so the
    # grant is listed in every delivery, although only the chart delivery
    # renders pods.
    unsafe = [
      "host-network"
      "privileged"
      "run-as-root"
    ];
    # The `cni` role admits one managed claimant, which also keeps a second
    # cilium instance out of the cluster.
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
      description = ''
        Helm values, merged with `lib.recursiveUpdate` over the package's
        defaults for the delivery; a list replaces the default list.

        Chart delivery: values for the cilium chart. helmChartConfig
        delivery: the values written to the environment's HelmChartConfig,
        which its helm-controller merges over its own chart defaults. Must
        be empty when cluster.network.environmentCilium.helmChartConfig is
        null, because the instance then writes no Cilium configuration.
      '';
    };

    clusterDnsEgress = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Allow every pod in the cluster to reach cluster DNS, as the
        CiliumClusterwideNetworkPolicy `cilium-cluster-dns-egress`. Emitted
        only when the instance configures Cilium (chart or helmChartConfig
        delivery) and the effective `policyEnforcementMode` is "always",
        which it is by default when networkPolicy.enable is true.

        In that mode every pod in the cluster is in default deny, including
        the ones Kix never writes a policy for: a `kubectl run` debug pod,
        an operator's own Job, anything in a namespace Kix does not manage.
        Kix writes DNS egress for the workloads it renders and for nothing
        else, so without this those pods cannot resolve a name, and the
        failure reads as a DNS outage rather than as a policy decision.

        Set it false to write that policy yourself.
      '';
    };
  };

  build =
    {
      config,
      scope,
      clusterConfig,
      ...
    }:
    let
      who = "cilium ${scope.namespaceName}/${scope.instanceName}";

      binding = (clusterConfig.cluster.roles.cni or { }).binding or null;
      env = clusterConfig.cluster.network.environmentCilium;
      podCidr = clusterConfig.cluster.network.podCidr;
      netpolEnabled = (clusterConfig.networkPolicy or { }).enable or false;

      delivery =
        if env == null then
          "chart"
        else if env.helmChartConfig != null then
          "helmChartConfig"
        else
          "none";

      # Under "always" every endpoint without an allow rule loses its
      # traffic, so the default follows whether Kix writes allow rules.
      effectiveEnforcement =
        config.values.policyEnforcementMode or (if netpolEnabled then "always" else "default");
      effectiveAudit = config.values.policyAuditMode or false;

      # The operator is leader-elected, so a second replica is a warm
      # standby. The chart gives it a required hostname anti-affinity, so
      # a second replica on a single-node cluster stays Pending.
      operatorReplicas =
        if (clusterConfig.cluster.capabilities.multiNode or null) == false then
          1
        else
          kix.availability.pick availability {
            none = 1;
            pod = 1;
            node = 2;
            zone = 2;
          };

      # Values the package sets in both deliveries that configure Cilium.
      configureValues = {
        policyEnforcementMode = effectiveEnforcement;
        policyAuditMode = false;
        operator = {
          replicas = operatorReplicas;
          rollOutPods = true;
        };
        rollOutCiliumPods = true;
      };

      chartValues = lib.recursiveUpdate configureValues {
        ipam.operator.clusterPoolIPv4PodCIDRList = [ podCidr ];
        # The operator runs on the host network, so its metrics port
        # (chart default on) is a host port that nothing scrapes.
        operator.prometheus.enabled = false;
        # The chart's default Hubble TLS (`hubble.tls.auto.method = "helm"`)
        # generates certificates at template time, so every render differs.
        hubble.enabled = false;
        # Since 1.17 the chart defaults `tls.secretsNamespace` to a dedicated
        # `cilium-secrets` Namespace (plus a Role/RoleBinding inside it) for
        # TLS-aware CiliumNetworkPolicies and ingress/gateway TLS interception.
        # Kix uses none of that, and a foreign namespace would have to exist in
        # every cluster scope, so the unused secrets namespace points at the
        # instance's own namespace and nothing is created.
        tls.secretsNamespace = {
          create = false;
          name = scope.namespaceName;
        };
      };

      # No `ipam` here: RKE2's chart sets `ipam.mode = "kubernetes"`, which
      # ignores a cluster-pool list unless `ipam.mode` is set beside it.
      values = lib.recursiveUpdate (
        if delivery == "chart" then chartValues else configureValues
      ) config.values;

      checks =
        if binding == null then
          throw "${who}: installs or uses Cilium as the pod network, but cluster.roles.cni.binding is unset, so Kix cannot tell whether the cluster already runs a CNI. Use a flavour, or set cluster.roles.cni.binding = \"absent\" on a cluster created without a CNI (kind with disableDefaultCNI)."
        else if binding == "shadowable" && env == null then
          throw "${who}: cluster.roles.cni.binding is \"shadowable\", but cluster.network.environmentCilium is null, so Kix cannot tell whether the environment's CNI is Cilium. If it is, set cluster.network.environmentCilium (on RKE2: cluster.flavor.rke2.cni = [ \"cilium\" ]). If it is another CNI, a cilium instance cannot stand for it: remove the instance, or set the binding to \"exclusive\"."
        else if delivery == "helmChartConfig" && scope.namespaceName != env.helmChartConfig.namespace then
          throw "${who}: writes HelmChartConfig ${env.helmChartConfig.name}, which the environment reads only in namespace ${env.helmChartConfig.namespace}. Declare the instance under instances.${env.helmChartConfig.namespace}."
        else if delivery == "none" && config.values != { } then
          throw "${who}: does not install or configure Cilium: cluster.network.environmentCilium.helmChartConfig is null, so the environment's Cilium keeps its own settings and `values` would be ignored. Remove `values`, or set environmentCilium.helmChartConfig if the environment merges a HelmChartConfig into its Cilium chart (on RKE2: cluster.flavor.rke2.cni = [ \"cilium\" ])."
        else if delivery == "chart" && podCidr == null then
          throw "${who}: installs Cilium with cluster-pool IPAM and needs the pod range. Set cluster.network.podCidr to the range the cluster assigns pods: kind's networking.podSubnet, RKE2's cluster-cidr (default 10.42.0.0/16), kubeadm's --pod-network-cidr. The kind and k3s flavours set their defaults."
        else
          null;

      resources = scope.helm.importChart {
        inherit chart scope values;
        releaseName = "cilium";
        includeCrds = true;
      };

      # The chart installs Cilium's CRDs at runtime (the agent's
      # INSTALL_CRDS), so they are not in the rendered chart. In the chart
      # delivery the references wait for every chart workload, so policies
      # apply only once the whole Cilium stack is Ready.
      installedBy = if delivery == "chart" then resources.workloads else null;

      cnpCrd = scope.mkCRDRef {
        group = "cilium.io";
        kind = "CiliumNetworkPolicy";
        plural = "ciliumnetworkpolicies";
        version = "v2";
        crdScope = "Namespaced";
        inherit installedBy;
        readiness = rules.policyReadiness;
      };

      ccnpCrd = scope.mkCRDRef {
        group = "cilium.io";
        kind = "CiliumClusterwideNetworkPolicy";
        plural = "ciliumclusterwidenetworkpolicies";
        version = "v2";
        crdScope = "Cluster";
        inherit installedBy;
        readiness = rules.policyReadiness;
      };

      # Under "always", a `kubectl run` debug pod, an operator's own Job, or
      # anything in a namespace Kix does not manage gets no DNS egress from
      # Kix. This allow rule lets them resolve names. Under "default" a
      # policy selecting every endpoint would put each one into egress
      # default deny, so it is emitted only under "always".
      clusterDnsEgress =
        if config.clusterDnsEgress && delivery != "none" && effectiveEnforcement == "always" then
          scope.mkCR ccnpCrd {
            name = "cilium-cluster-dns-egress";
            labels = {
              ${kix.keys.derived} = "true";
            };
            spec = {
              endpointSelector = { };
              egress = [ rules.dnsEgressRule ];
            };
          }
        else
          null;
      dnsEgressParts = lib.optionalAttrs (clusterDnsEgress != null) { inherit clusterDnsEgress; };
      dnsEgressRequires = lib.optional (clusterDnsEgress != null) clusterDnsEgress;

      crdParts = {
        ciliumNetworkPolicies = cnpCrd;
        ciliumClusterwideNetworkPolicies = ccnpCrd;
      };

      out = {
        crds = {
          CiliumNetworkPolicy = cnpCrd;
          CiliumClusterwideNetworkPolicy = ccnpCrd;
        };
        netpol = rules.mkNetpolOut {
          inherit cnpCrd ccnpCrd;
          inherit (kix) keys;
        };
      };

      chartParts = resources.mkParts {
        root = resources.get "DaemonSet" "cilium";
        extraParts = {
          crds = crdParts;
        }
        // dnsEgressParts;
        # The DNS policy hangs off nothing in the chart, so root names it.
        extraRequires = dnsEgressRequires;
        inherit out;
      };

      helmChartConfigCrd = scope.mkCRDRef {
        group = "helm.cattle.io";
        kind = "HelmChartConfig";
        plural = "helmchartconfigs";
        version = "v1";
      };

      helmChartConfig = scope.mkCR helmChartConfigCrd {
        name = env.helmChartConfig.name;
        spec.valuesContent = builtins.toJSON values;
      };

      helmChartConfigParts = {
        crds = crdParts // {
          helmChartConfigs = helmChartConfigCrd;
        };
        inherit helmChartConfig;
        root = {
          resource = helmChartConfig;
          requires = [
            cnpCrd
            ccnpCrd
          ]
          ++ dnsEgressRequires;
          inherit out;
        };
      }
      // dnsEgressParts;

      noneParts = {
        crds = crdParts;
        root = {
          resource = cnpCrd;
          requires = [ ccnpCrd ];
          inherit out;
        };
      };

      parts =
        if delivery == "chart" then
          chartParts
        else if delivery == "helmChartConfig" then
          helmChartConfigParts
        else
          noneParts;

      warnAlwaysWithoutRules =
        delivery != "none" && effectiveEnforcement == "always" && !netpolEnabled && !effectiveAudit;
    in
    builtins.seq checks (
      lib.warnIf warnAlwaysWithoutRules
        "${who}: enforces policy on every endpoint (policyEnforcementMode = \"always\"), but networkPolicy.enable is false, so Kix writes no allow rules. Every pod without a policy from another source loses its traffic. Enable networkPolicy, set values.policyAuditMode = true, or remove values.policyEnforcementMode."
        parts
    );
}
