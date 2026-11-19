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
#   instances.kube-system.cilium.package = packages.experimental.cilium;
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
# Dependencies:
#   platform-cilium (optional)  the environment's Cilium, as above. Without
#                               it the instance installs the chart.
#
# Policy enforcement follows networkPolicy.enable: "always" when Kix writes
# allow rules, "default" otherwise. Under "always" the instance also writes
# two CiliumClusterwideNetworkPolicies: cluster DNS for every pod, and
# Cilium's health probes between nodes.
#
# `out`: `out.crds.CiliumNetworkPolicy` and
# `out.crds.CiliumClusterwideNetworkPolicy` (build CRs with
# `scope.mkCR dep.out.crds.<Kind>`), and `out.netpol`, the enforcer
# contract the netpol plugin builds generated policy with. Every delivery
# provides both.
#
# Escape hatch: `values`, Helm values merged over the delivery's defaults.
# The none delivery writes no Cilium configuration and refuses them.
#
# Restarts: the package sets `rollOutCiliumPods` and `operator.rollOutPods`
# in both deliveries that configure Cilium. A change to `values` that
# changes Cilium's ConfigMap then restarts the agent on every node and the
# operator. The agent reads most settings only at start, so without the
# restart a deploy succeeds while every agent keeps the old setting.
# Restarting the agent on a node that holds an L2 announcement moves that
# address to another node. A cluster that sets
# values.rollOutCiliumPods = false restarts the agents itself, with
# `kubectl -n kube-system rollout restart ds/cilium`. The operator still
# restarts unless values.operator.rollOutPods is false too.
#
# helmChartConfig delivery, failed installs: `failurePolicy` sets what
# helm-controller does when the environment's Helm job fails to install or
# upgrade Cilium. Unset, the HelmChartConfig carries no policy and the
# environment's own applies. RKE2 releases from 4 August 2026 (1.33.13,
# 1.34.10, 1.35.7, 1.36.3) set "retry" on their bundled charts. Older ones
# use helm-controller's default, "reinstall", which uninstalls the release
# first and so removes Cilium from every node until the install succeeds.
# On those, set failurePolicy = "abort".
#
# helmChartConfig delivery, a cluster that already has the HelmChartConfig:
# Kix replaces the whole of `spec.valuesContent`. Copy every setting from
# the live object into `values` before the first deploy, or that deploy
# removes them:
#
#   kubectl -n kube-system get helmchartconfig rke2-cilium \
#     -o jsonpath='{.spec.valuesContent}'
#
# `kix plan` shows valuesContent as changed even when the settings match,
# because Kix writes JSON and adds the settings it sets itself. Compare the
# settings. If another writer owns the field, the plan refuses the write and
# names the owner. Remove that writer first (see Known limits for RKE2's
# manifests directory), then `kix deploy --force-conflicts` takes the field
# over. The first deploy restarts the agents once, because it turns on
# `rollOutCiliumPods`.

{
  scope,
  lib,
  kix,
  availability,
}:

let
  rules = import ./netpol-rules.nix { inherit lib; };

  release = "1.20.5";

  chart = scope.helm.fetchHelmChart {
    repo = "https://helm.cilium.io/";
    name = "cilium";
    version = release;
    hash = "sha256-DHWS63UXns9G3T7CIUWRbwFkxEASFOoVr7WyMLHRGiE=";
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
    # Cilium lists the Kubernetes versions it runs end-to-end tests on in
    # its requirements page (Documentation/network/kubernetes/requirements.rst)
    # and says newer versions depend on Kubernetes' own compatibility. The
    # agent's own startup check (pkg/k8s/version) only requires 1.21, which
    # is far below any version Kix targets. No version is known to fail, so
    # none is refused. Move `supported` with `release`.
    k8s.supported = {
      minVersion = "1.33";
      maxVersion = "1.36";
      source = "the requirements page in Cilium's documentation";
    };
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

    failurePolicy = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.enum [
          "abort"
          "reinstall"
          "retry"
        ]
      );
      default = null;
      description = ''
        What the environment's helm-controller does when its Helm job fails
        to install or upgrade Cilium. Written to `spec.failurePolicy` of
        the HelmChartConfig, so it applies in the helmChartConfig delivery
        only. The other deliveries refuse it.

        Unset, the HelmChartConfig carries no policy and the environment's
        own applies. RKE2 releases from 4 August 2026 (1.33.13, 1.34.10,
        1.35.7, 1.36.3) set "retry" on their bundled charts. Older ones
        use "reinstall".

        "abort" leaves the failed release for a person to fix. The Cilium
        that is running stays as it was.

        "reinstall" uninstalls the release and installs it again. Until
        the install succeeds, no node runs Cilium: flows that are already
        open keep going, and new pods get no network.

        "retry" tries the install or upgrade again without uninstalling.
        An RKE2 release older than the ones above does not know this value,
        and its API server refuses the HelmChartConfig.
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
          scope.fail {
            package = "cilium";
            clusterOption = "cluster.roles.cni.binding";
            message = "installs or uses Cilium as the pod network, but cluster.roles.cni.binding is unset, so Kix cannot tell whether the cluster already runs a CNI.";
            fix = "Use a flavour, or set cluster.roles.cni.binding = \"absent\" on a cluster created without a CNI (kind with disableDefaultCNI).";
          }
        else if platform-cilium != null && !(environmentOut ? helmChartConfig) then
          scope.fail {
            package = "cilium";
            message = "dependency platform-cilium has no out.helmChartConfig.";
            fix = "Set it to { name; namespace; }, the HelmChartConfig the environment's helm-controller merges into its Cilium chart, or to null if the environment reads none.";
          }
        else if helmChartConfigRef != null && !(isHelmChartConfigRef helmChartConfigRef) then
          scope.fail {
            package = "cilium";
            message = "dependency platform-cilium has out.helmChartConfig = ${builtins.toJSON helmChartConfigRef}.";
            fix = "It takes { name; namespace; } as strings, or null.";
          }
        else if platform-cilium != null && binding != "shadowable" then
          scope.fail {
            package = "cilium";
            clusterOption = "cluster.roles.cni.binding";
            message = "dependency platform-cilium says the environment installed Cilium, but cluster.roles.cni.binding is ${builtins.toJSON binding}. An environment-installed Cilium is a shadowable cni binding: the environment runs the CNI and this instance configures or uses it.";
            fix = "Set cluster.roles.cni.binding = \"shadowable\", or remove the platform-cilium import so the instance installs the chart.";
          }
        else if binding == "shadowable" && platform-cilium == null then
          scope.fail {
            package = "cilium";
            clusterOption = "cluster.roles.cni.binding";
            message = "cluster.roles.cni.binding is \"shadowable\", but no platform-cilium dependency says the environment's CNI is Cilium.";
            fix = "If it is, declare it: on RKE2 set cluster.flavor.rke2.cni = [ \"cilium\" ]; elsewhere add instances.<namespace>.platform-cilium.package = kix.mkImport { roles = [ \"cni\" ]; out.helmChartConfig = null; }. If an import for the environment's Cilium already exists under another name, point this instance at it with deps.platform-cilium = ref.<namespace>.<instance> instead of adding a second import. An import declared with optional = true answers this optional dependency only after something else activates it, so remove optional = true from it. If it is another CNI, a cilium instance cannot stand for it: remove the instance, or set the binding to \"exclusive\".";
          }
        else if delivery == "helmChartConfig" && scope.namespaceName != helmChartConfigRef.namespace then
          scope.fail {
            package = "cilium";
            message = "writes HelmChartConfig ${helmChartConfigRef.name}, which the environment reads only in namespace ${helmChartConfigRef.namespace}.";
            fix = "Declare the instance under instances.${helmChartConfigRef.namespace}.";
          }
        else if delivery == "none" && config.values != { } then
          scope.fail {
            package = "cilium";
            option = "values";
            message = "does not install or configure Cilium: the platform-cilium dependency's out.helmChartConfig is null, so the environment's Cilium keeps its own settings and `values` would be ignored.";
            fix = "Remove `values`, or set the import's out.helmChartConfig if the environment merges a HelmChartConfig into its Cilium chart (on RKE2: cluster.flavor.rke2.cni = [ \"cilium\" ]).";
          }
        else if delivery != "helmChartConfig" && config.failurePolicy != null then
          scope.fail {
            package = "cilium";
            option = "failurePolicy";
            message =
              if delivery == "chart" then
                "sets failurePolicy, but this instance installs the Cilium chart itself. failurePolicy is a field of the HelmChartConfig that an environment's helm-controller reads, and this instance writes none."
              else
                "sets failurePolicy, but the platform-cilium dependency's out.helmChartConfig is null, so this instance writes no HelmChartConfig to put it in.";
            fix =
              if delivery == "chart" then
                "Remove `failurePolicy`."
              else
                "Remove `failurePolicy`, or set the import's out.helmChartConfig if the environment merges a HelmChartConfig into its Cilium chart (on RKE2: cluster.flavor.rke2.cni = [ \"cilium\" ]).";
          }
        else if !(builtins.elem effectiveEnforcement enforcementModes) then
          scope.fail {
            package = "cilium";
            option = "values.policyEnforcementMode";
            message = "values.policyEnforcementMode is ${builtins.toJSON effectiveEnforcement}.";
            fix = "Cilium accepts \"default\", \"always\", or \"never\".";
          }
        else if !(builtins.isBool effectiveAudit) then
          scope.fail {
            package = "cilium";
            option = "values.policyAuditMode";
            message = "values.policyAuditMode is ${builtins.toJSON effectiveAudit}.";
            fix = "It takes true or false.";
          }
        else if delivery == "chart" && ipamMode == "cluster-pool" && podCidr == null then
          scope.fail {
            package = "cilium";
            clusterOption = "cluster.network.podCidr";
            message = "installs Cilium with cluster-pool IPAM and needs the pod range.";
            fix = "Set cluster.network.podCidr to the range the cluster assigns pods: kind's networking.podSubnet, RKE2's cluster-cidr (default 10.42.0.0/16), kubeadm's --pod-network-cidr. The kind, k3s, and rke2 flavours set their defaults. Or select another IPAM mode in values.ipam.mode.";
          }
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
        holdsData = false;
        usesAtLeast = _: { };
      };

      ccnpCrd = scope.mkCRDRef {
        group = "cilium.io";
        kind = "CiliumClusterwideNetworkPolicy";
        plural = "ciliumclusterwidenetworkpolicies";
        version = "v2";
        crdScope = "Cluster";
        inherit installedBy;
        readiness = rules.policyReadiness;
        holdsData = false;
        usesAtLeast = _: { };
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
        holdsData = false;
        usesAtLeast = _: { };
      };

      helmChartConfig = scope.mkCR helmChartConfigCrd {
        name = helmChartConfigRef.name;
        spec = {
          valuesContent = builtins.toJSON values;
        }
        // lib.optionalAttrs (config.failurePolicy != null) {
          inherit (config) failurePolicy;
        };
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
