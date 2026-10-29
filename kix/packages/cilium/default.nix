# cilium: Cilium as the cluster's pod network (the `cni` role) and its
# CiliumNetworkPolicy enforcer (the `network-policy-enforcer` role).
#
# Who installs Cilium, the delivery, follows from cluster.roles.cni.binding,
# which a flavour sets, and the optional `platform-cilium` dependency, a
# kix.mkImport that stands for a Cilium the environment installed:
#
#   binding      platform-cilium out.helmChartConfig   delivery         emits
#   "absent"     (no dependency)                       chart            the upstream chart
#   "shadowable" { name; namespace; }                  helmChartConfig  one HelmChartConfig
#   "shadowable" null                                  none             CRD references only
#
# Every other combination is an evaluation error. In the helmChartConfig
# delivery the environment's helm-controller merges the HelmChartConfig into
# the Cilium chart it installed (RKE2: kube-system/rke2-cilium).
#
# Minimal instance, on kind created with disableDefaultCNI:
#
#   imports = [ kix.flavors.kind ];
#   cluster.roles.cni.binding = "absent";
#   instances.kube-system.cilium.package = packages.cilium;
#
# The chart delivery uses Cilium's cluster-pool IPAM unless
# values.ipam.mode selects another mode, and then takes the pool from
# cluster.network.podCidr, which the kind, k3s, and rke2 flavours default.
# On RKE2 with `cni: cilium` in the server config, set
# cluster.flavor.rke2.cni = [ "cilium" ] and declare the instance in
# kube-system; the flavour then declares kube-system/platform-cilium. Where
# another environment installed Cilium and merges no HelmChartConfig:
#
#   cluster.roles.cni.binding = "shadowable";
#   instances.kube-system.platform-cilium.package = kix.mkImport {
#     roles = [ "cni" ];
#     out.helmChartConfig = null;
#   };
#
# DI deps:
#   platform-cilium (optional)  the environment's Cilium, as above. Without
#                               it the instance installs the chart.
#
# Policy enforcement follows networkPolicy.enable: "always" when Kix writes
# allow rules, "default" otherwise. Under "always" the instance also writes
# two CiliumClusterwideNetworkPolicies: cluster DNS for every pod, and
# Cilium's health probes between nodes.
#
# out: `out.crds.CiliumNetworkPolicy` and
# `out.crds.CiliumClusterwideNetworkPolicy` (build CRs with
# `scope.mkCR dep.out.crds.<Kind>`), and `out.netpol`, the enforcer
# contract the netpol plugin builds generated policy with. Every delivery
# provides both.
#
# Escape hatch: `values`, Helm values merged over the delivery's defaults.
# The none delivery writes no Cilium configuration and refuses them.
#
# Known limits:
# - Cilium as an enforcer beside another CNI (chaining) is not supported;
#   the package always claims `cni`.
# - meta.version is the chart version. In the other deliveries the
#   environment picks the Cilium version.
# - Agent, operator, and Hubble metrics are off and not wired to
#   kix.monitor.
# - helmChartConfig delivery: RKE2 also applies any rke2-cilium
#   HelmChartConfig in the server's manifests directory, so a cluster that
#   keeps that file has two writers for one object. Remove the file.
# - helmChartConfig delivery: removing the instance makes
#   `kix deploy --prune` delete the HelmChartConfig, and helm-controller
#   then reinstalls the environment's Cilium with its chart defaults.

{
  scope,
  lib,
  kix,
  availability,
}:

let
  rules = import ./netpol-rules.nix { inherit lib; };

  release = "1.19.6";

  chart = scope.helm.fetchHelmChart {
    repo = "https://helm.cilium.io/";
    name = "cilium";
    version = release;
    hash = "sha256-IcQ89ThB+asDdQR9lapMZAUepSu9LGeUFuZAj18ckXk=";
  };
in
{
  meta = {
    # The chart version, which only the chart delivery deploys. In the other
    # deliveries the environment picks the Cilium version and
    # meta.compatibleWith still compares against this one.
    version = release;
    description = "Cilium: CNI and CiliumNetworkPolicy enforcer. Installs the chart, configures an environment's bundled Cilium, or uses one the environment installed";
    owner = "platform";
    # A CNI programs the node's own networking and loads BPF into the
    # kernel, so the agent, envoy, and operator pods run on the host
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
        be empty when the platform-cilium dependency's out.helmChartConfig
        is null, because the instance then writes no Cilium configuration.
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
      platform-cilium ? null,
      ...
    }:
    let
      who = "cilium ${scope.namespaceName}/${scope.instanceName}";

      binding = (clusterConfig.cluster.roles.cni or { }).binding or null;
      podCidr = clusterConfig.cluster.network.podCidr;
      netpolEnabled = (clusterConfig.networkPolicy or { }).enable or false;

      environmentOut = if platform-cilium == null then { } else platform-cilium.out or { };
      # A missing key is an error below rather than the none delivery, so a
      # misspelt key cannot drop the HelmChartConfig.
      helmChartConfigRef = environmentOut.helmChartConfig or null;
      isHelmChartConfigRef =
        v:
        builtins.isAttrs v && builtins.isString (v.name or null) && builtins.isString (v.namespace or null);

      delivery =
        if platform-cilium == null then
          "chart"
        else if helmChartConfigRef != null then
          "helmChartConfig"
        else
          "none";

      # The modes Cilium's agent accepts. The build branches on the mode, so
      # an unknown one is refused below.
      enforcementModes = [
        "default"
        "always"
        "never"
      ];
      # Under "always" every endpoint without an allow rule loses its
      # traffic, so the default follows whether Kix writes allow rules.
      effectiveEnforcement =
        config.values.policyEnforcementMode or (if netpolEnabled then "always" else "default");
      effectiveAudit = config.values.policyAuditMode or false;
      # The chart's default IPAM mode.
      ipamMode = config.values.ipam.mode or "cluster-pool";

      # The operator is leader-elected, so a second replica is a warm
      # standby. The chart gives it a required hostname anti-affinity, so
      # a second replica on a single-node cluster stays Pending; the
      # availability level is "none" there.
      operatorReplicas = kix.availability.pick availability {
        none = 1;
        pod = 1;
        node = 2;
        zone = 2;
      };

      # Values the package sets in both deliveries that configure Cilium.
      # No `ipam` here: RKE2's chart sets `ipam.mode = "kubernetes"`, which
      # ignores a cluster-pool list unless `ipam.mode` is set beside it.
      configureValues = {
        policyEnforcementMode = effectiveEnforcement;
        policyAuditMode = false;
        operator = {
          replicas = operatorReplicas;
          rollOutPods = true;
        };
        rollOutCiliumPods = true;
      };

      chartValues = lib.recursiveUpdate configureValues (
        lib.optionalAttrs (ipamMode == "cluster-pool") {
          ipam.operator.clusterPoolIPv4PodCIDRList = [ podCidr ];
        }
        // {
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
        }
      );

      values = lib.recursiveUpdate (
        if delivery == "chart" then chartValues else configureValues
      ) config.values;

      checks =
        if binding == null then
          throw "${who}: installs or uses Cilium as the pod network, but cluster.roles.cni.binding is unset, so Kix cannot tell whether the cluster already runs a CNI. Use a flavour, or set cluster.roles.cni.binding = \"absent\" on a cluster created without a CNI (kind with disableDefaultCNI)."
        else if platform-cilium != null && !(environmentOut ? helmChartConfig) then
          throw "${who}: dependency platform-cilium has no out.helmChartConfig. Set it to { name; namespace; }, the HelmChartConfig the environment's helm-controller merges into its Cilium chart, or to null if the environment reads none."
        else if helmChartConfigRef != null && !(isHelmChartConfigRef helmChartConfigRef) then
          throw "${who}: dependency platform-cilium has out.helmChartConfig = ${builtins.toJSON helmChartConfigRef}; it takes { name; namespace; } as strings, or null."
        else if platform-cilium != null && binding != "shadowable" then
          throw "${who}: dependency platform-cilium says the environment installed Cilium, but cluster.roles.cni.binding is ${builtins.toJSON binding}. An environment-installed Cilium is a shadowable cni binding: the environment runs the CNI and this instance configures or uses it. Set cluster.roles.cni.binding = \"shadowable\", or remove the platform-cilium import so the instance installs the chart."
        else if binding == "shadowable" && platform-cilium == null then
          throw "${who}: cluster.roles.cni.binding is \"shadowable\", but no platform-cilium dependency says the environment's CNI is Cilium. If it is, declare it: on RKE2 set cluster.flavor.rke2.cni = [ \"cilium\" ]; elsewhere add instances.<namespace>.platform-cilium.package = kix.mkImport { roles = [ \"cni\" ]; out.helmChartConfig = null; }. If an import for the environment's Cilium already exists under another name, point this instance at it with deps.platform-cilium = ref.<namespace>.<instance> instead of adding a second import. An import declared with optional = true answers this optional dependency only after something else activates it, so remove optional = true from it. If it is another CNI, a cilium instance cannot stand for it: remove the instance, or set the binding to \"exclusive\"."
        else if delivery == "helmChartConfig" && scope.namespaceName != helmChartConfigRef.namespace then
          throw "${who}: writes HelmChartConfig ${helmChartConfigRef.name}, which the environment reads only in namespace ${helmChartConfigRef.namespace}. Declare the instance under instances.${helmChartConfigRef.namespace}."
        else if delivery == "none" && config.values != { } then
          throw "${who}: does not install or configure Cilium: the platform-cilium dependency's out.helmChartConfig is null, so the environment's Cilium keeps its own settings and `values` would be ignored. Remove `values`, or set the import's out.helmChartConfig if the environment merges a HelmChartConfig into its Cilium chart (on RKE2: cluster.flavor.rke2.cni = [ \"cilium\" ])."
        else if !(builtins.elem effectiveEnforcement enforcementModes) then
          throw "${who}: values.policyEnforcementMode is ${builtins.toJSON effectiveEnforcement}; Cilium accepts \"default\", \"always\", or \"never\"."
        else if !(builtins.isBool effectiveAudit) then
          throw "${who}: values.policyAuditMode is ${builtins.toJSON effectiveAudit}; it takes true or false."
        else if delivery == "chart" && ipamMode == "cluster-pool" && podCidr == null then
          throw "${who}: installs Cilium with cluster-pool IPAM and needs the pod range. Set cluster.network.podCidr to the range the cluster assigns pods: kind's networking.podSubnet, RKE2's cluster-cidr (default 10.42.0.0/16), kubeadm's --pod-network-cidr. The kind, k3s, and rke2 flavours set their defaults. Or select another IPAM mode in values.ipam.mode."
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

      # Under "always" Cilium's health endpoint is in default deny too, and
      # its probes between nodes fail. Cilium's documentation pairs that
      # mode with this rule.
      clusterHealth =
        if delivery != "none" && effectiveEnforcement == "always" then
          scope.mkCR ccnpCrd {
            name = "cilium-health-probes";
            labels = {
              ${kix.keys.derived} = "true";
            };
            spec = {
              endpointSelector.matchLabels."reserved:health" = "";
              ingress = [
                {
                  fromEntities = [
                    "health"
                    "remote-node"
                  ];
                }
              ];
              egress = [
                {
                  toEntities = [
                    "health"
                    "remote-node"
                  ];
                }
              ];
            };
          }
        else
          null;

      clusterPolicies = lib.filterAttrs (_: p: p != null) { inherit clusterDnsEgress clusterHealth; };
      clusterPolicyRequires = builtins.attrValues clusterPolicies;

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
        // clusterPolicies;
        # The clusterwide policies hang off nothing in the chart, so root
        # names them.
        extraRequires = clusterPolicyRequires;
        inherit out;
      };

      helmChartConfigCrd = scope.mkCRDRef {
        group = "helm.cattle.io";
        kind = "HelmChartConfig";
        plural = "helmchartconfigs";
        version = "v1";
      };

      helmChartConfig = scope.mkCR helmChartConfigCrd {
        name = helmChartConfigRef.name;
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
          ++ clusterPolicyRequires;
          inherit out;
        };
      }
      // clusterPolicies;

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
      # A warning because another tool may write the allow rules. Candidate for an
      # evaluation error with an explicit opt-in for that case.
      lib.warnIf warnAlwaysWithoutRules
        "${who}: enforces policy on every endpoint (policyEnforcementMode = \"always\"), but networkPolicy.enable is false, so Kix writes no allow rules. Every pod without a policy from another source loses all traffic except cluster DNS. Enable networkPolicy, set values.policyAuditMode = true, or remove values.policyEnforcementMode."
        parts
    );
}
