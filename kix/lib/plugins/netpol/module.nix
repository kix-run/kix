{
  config,
  lib,
  ...
}:

let
  inherit (import ../../core/error.nix { inherit lib; }) fail;
  cfg = config.networkPolicy;

  interface = import ./interface.nix { inherit lib; };
  derive = import ./derive.nix { inherit lib; };
  scrape = import ./scrape.nix { inherit lib; };

  enforcerRole = "network-policy-enforcer";

  inherit (cfg) enforced;

  # Return the namespaces where Kix isolates every pod with
  # `<namespace>-default-deny`: those that hold an active instance Kix
  # deploys (`cluster.deployedNsNames`) or that the cluster definition
  # declares, except `platformNamespaces`. Imports run on pods Kix does not
  # deploy, and a platform namespace runs pods the platform changes, so a
  # default deny there would cut traffic Kix cannot see. Default deny,
  # scrape ingress, and caller ingress all read this list.
  defaultDenyNamespacesOf =
    cluster:
    lib.optionals cfg.defaultDeny (
      builtins.filter (
        nsName:
        (builtins.elem nsName cluster.deployedNsNames || config.namespaces ? ${nsName})
        && !(builtins.elem nsName cfg.platformNamespaces)
      ) cluster.realNsNames
    );

  # An exclusive `cni` binding means the environment owns the pod network, so
  # a `cilium` instance would be refused. The missing-enforcer error must not
  # recommend one there.
  cniRole = config.cluster.roles.cni or { };
  cniExclusive = (cniRole.binding or null) == "exclusive";
  cniName =
    if (cniRole.provider or null) != null then "`${cniRole.provider}`" else "managed by the platform";

  ciliumFix =
    "Declare a `cilium` instance (`instances.kube-system.cilium.package = packages.experimental.cilium;`), or set `networkPolicy.enable = false`. "
    + "If the cluster already runs Cilium, set `cluster.flavor.rke2.cni = [ \"cilium\" ]` on RKE2, or set "
    + "`cluster.roles.cni.binding = \"shadowable\"` and declare a `platform-cilium` import so the `cilium` instance uses the existing installation.";

  exclusiveCniFix =
    "Set `networkPolicy.enable = false`. This cluster's pod network is ${cniName} (`cluster.roles.cni.binding = \"exclusive\"`), "
    + "so Kix cannot install Cilium here, and Kix only generates Cilium network policies today. "
    + "If you disabled the built-in CNI so Kix can install Cilium, set `cluster.roles.cni.binding = \"absent\"` and add `packages.experimental.cilium` under `instances`. "
    + "If the cluster already runs Cilium, set `cluster.roles.cni.binding = \"shadowable\"`, add a `platform-cilium` import, and add `packages.experimental.cilium` under `instances`.";

  resolveEnforcerOut =
    {
      cluster,
      instanceName,
      namespaceName,
    }:
    let
      provider = cluster.findRoleProvider enforcerRole;
    in
    # Return null for the enforcer's own instance so it does not depend on itself.
    if provider == null || (provider.ns == namespaceName && provider.inst == instanceName) then
      null
    else
      interface.bindDnsPeers cluster.dnsPeers provider.out;
in
{
  options.networkPolicy = lib.mkOption {
    type = lib.types.submodule (
      { config, ... }:
      {
        options = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Generate CiliumNetworkPolicies from DI graph.";
          };
          defaultDeny = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = ''
              Write a `<namespace>-default-deny` policy in every namespace that
              contains an active deployed instance or is declared under
              `namespaces`, except namespaces listed in `platformNamespaces`.
              Namespaces that contain only `kix.mkImport` instances or inactive
              `optional` instances do not get a default-deny policy.
            '';
          };
          directions = lib.mkOption {
            type = lib.types.enum [
              "ingress"
              "egress"
              "both"
            ];
            default = "both";
            description = "Which policy directions to generate.";
          };
          enforced = lib.mkOption {
            type = lib.types.attrsOf lib.types.bool;
            readOnly = true;
            internal = true;
            default = {
              ingress = config.directions != "egress";
              egress = config.directions != "ingress";
            };
            description = ''
              `directions` as `{ ingress; egress; }`, the directions default
              deny and every derived policy cover. The netpol plugin's policy
              builders take it, and `kix.operandPolicy` reads it through
              `scope.networkPolicyEnforced`.
            '';
          };
          platformNamespaces = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            example = [ "kube-system" ];
            description = ''
              Namespaces where the cluster platform manages its own pods, such
              as `kube-system` on managed cloud providers. Kix omits
              `<namespace>-default-deny` in these namespaces so platform pods
              are not blocked. Any workload Kix deploys in these namespaces
              still gets its own generated policies, which isolate only that
              workload's pods. Defaults to `[ "kube-system" ]` on the `gke`,
              `gke-autopilot`, `eks`, and `aks` flavors. Use `platformIntents`
              to write policies for platform-managed pods.
            '';
          };
          platformIntents = lib.mkOption {
            type = lib.types.attrsOf lib.types.anything;
            default = { };
            description = ''
              Allowed ingress and egress rules for pods managed outside Kix,
              such as CoreDNS or `local-path-provisioner` in kind. Each entry
              selects pods by label and lists the traffic they need, and the
              cluster's network policy enforcer turns it into a policy
              resource. Built-in flavors set entries for pre-installed
              components. Add entries here for other external pods, or for a
              Kix workload whose outbound traffic depends on its configuration
              when the package's error or option description asks for one (such
              as `infisical-operator` `address` or `coredns` `servers`). The
              "Network policy" page of the Kix docs explains them.
            '';
          };
        };
      }
    );
    default = { };
    description = ''
      Automatic `CiliumNetworkPolicy` generation from the cluster's dependency
      graph. Kix finds the policy enforcer automatically from the instance that
      claims `"network-policy-enforcer"` in `meta.roles` (see
      `kix/packages/experimental/cilium`). You do not need to wire `deps`, but
      you must declare an enforcer instance when `enable = true` or evaluation
      fails. Every generated policy depends on that enforcer so Kix waits for
      Cilium and its CRDs before applying policies. When the cluster environment
      already runs Cilium, a flavor or cluster module sets
      `cluster.roles.cni.binding = "shadowable"` and declares a
      `platform-cilium` import, and the `cilium` instance configures or uses
      that Cilium instead of installing a new one. The "Network policy"
      page of the Kix docs explains how Kix derives the policies.
    '';
  };

  config = lib.mkIf cfg.enable {
    hooks.workloadInterceptors.netpol =
      ctx:
      let
        workloadResult = derive.buildWorkloadCnps {
          inherit (ctx)
            emit
            instanceName
            namespaceName
            workloadInput
            workloadKind
            hostNetwork
            edges
            ;
          wSelector = ctx.selector;
          inherit enforced;
          networkPolicyEnforcer = resolveEnforcerOut { inherit (ctx) cluster instanceName namespaceName; };
          packageIntents = ctx.packageMeta.network.intents or { };
          defaultDenyNamespaces = defaultDenyNamespacesOf ctx.cluster;
          cloudIdentityEgress = ctx.cloudIdentityEgress or [ ];
        };
      in
      {
        requires = workloadResult.cnps;
        resources = workloadResult.cnps;
      };

    hooks.instanceProcessors.netpol =
      ctx:
      let
        instanceResult = derive.processInstance {
          inherit (ctx)
            emit
            instanceName
            namespaceName
            allPartResources
            packageMeta
            ;
          inherit enforced;
          defaultDenyNamespaces = defaultDenyNamespacesOf ctx.cluster;
          networkPolicyEnforcer = resolveEnforcerOut { inherit (ctx) cluster instanceName namespaceName; };
        };
      in
      {
        resources = instanceResult.policies;
        inherit (instanceResult) warnings;
      };

    hooks.clusterProcessors.netpol =
      ctx:
      let
        provider = ctx.cluster.findRoleProvider enforcerRole;

        defaultDenyNamespaces = defaultDenyNamespacesOf ctx.cluster;
        enforcerOut =
          if provider == null then null else interface.bindDnsPeers ctx.cluster.dnsPeers provider.out;

        defaultDenyPolicies = map (
          nsName:
          derive.generateDefaultDeny {
            namespaceName = nsName;
            nsResource = ctx.nsResources.${nsName};
            inherit enforced;
            networkPolicyEnforcer = enforcerOut;
          }
        ) defaultDenyNamespaces;

        platformIntentPolicies = derive.materializePlatformIntents {
          networkConfig = cfg;
          networkPolicyEnforcer = enforcerOut;
          inherit (ctx) nsResources;
        };

        scrapePolicies =
          if enforcerOut == null then
            {
              egressPolicies = [ ];
              ingressPolicies = [ ];
              warnings = [ ];
              errors = [ ];
            }
          else
            scrape.derive {
              inherit (ctx) resources nsResources realNsNames;
              enforcerApi = enforcerOut.netpol;
              inherit enforced defaultDenyNamespaces;
              inherit (cfg) defaultDeny;
              extraPolicies = platformIntentPolicies;
            };
      in
      {
        # This order flows into the Activation extraDeps and is
        # content-addressed into the output.
        resources =
          defaultDenyPolicies
          ++ platformIntentPolicies
          ++ scrapePolicies.egressPolicies
          ++ scrapePolicies.ingressPolicies;
        inherit (scrapePolicies) warnings;
        checks = [
          (
            if provider == null then
              fail {
                clusterOption = "networkPolicy.enable";
                message = "`networkPolicy.enable = true` but no instance declares `meta.roles = [\"network-policy-enforcer\"]`.";
                fix = if cniExclusive then exclusiveCniFix else ciliumFix;
              }
            else
              null
          )
          (
            if scrapePolicies.errors == [ ] then
              null
            else
              fail {
                clusterOption = "networkPolicy.defaultDeny";
                message =
                  "networkPolicy.defaultDeny is on, and Kix cannot derive these scrape paths:\n"
                  + lib.concatMapStringsSep "\n" (e: "- ${e}") scrapePolicies.errors;
              }
          )
          (
            if enforcerOut == null then
              null
            else
              interface.validateEnforcerInterface {
                enforcerNetpol = enforcerOut.netpol or { };
                enforcerName = "${provider.ns}/${provider.inst}";
              }
          )
        ];
      };
  };
}
