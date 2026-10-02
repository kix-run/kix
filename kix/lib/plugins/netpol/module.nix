{
  config,
  lib,
  ...
}:

let
  cfg = config.networkPolicy;

  interface = import ./interface.nix { inherit lib; };
  derive = import ./derive.nix { inherit lib; };
  scrape = import ./scrape.nix { inherit lib; };

  enforcerRole = "network-policy-enforcer";

  resolveEnforcerOut =
    {
      cluster,
      instanceName,
      namespaceName,
    }:
    let
      provider = cluster.findRoleProvider enforcerRole;
    in
    # Self-dep guard: the enforcer's own instance must not depend on itself.
    if provider == null || (provider.ns == namespaceName && provider.inst == instanceName) then
      null
    else
      provider.out;
in
{
  options.networkPolicy = lib.mkOption {
    type = lib.types.submodule {
      options = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Generate CiliumNetworkPolicies from DI graph.";
        };
        defaultDeny = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Generate deny-all CiliumNetworkPolicy per namespace.";
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
        platformIntents = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = { };
          description = ''
            Platform connectivity intents for non-kix-managed pods (e.g.
            CoreDNS, local-path-provisioner in kind). Each intent declares
            enforcer-agnostic connectivity requirements; the enforcer
            materializes them into native policy CRs. Set by flavors.
            Also used for a Kix workload whose egress depends on its
            configuration, when the package's error or description asks
            for one (infisical-operator `address`, coredns `servers`).
            See v2_discussions/archive/92_declarative_network_policy_intents.md.
          '';
        };
      };
    };
    default = { };
    description = ''
      CiliumNetworkPolicy generation from DI graph. See v2_discussions/37
      and v2_discussions/83. The enforcer that CNPs depend on is looked up
      automatically via `meta.roles ∋ "network-policy-enforcer"` (see
      `kix/packages/cilium`). No explicit wiring is required, but an
      enforcer instance MUST be declared when `enable = true`. kix throws
      at cluster eval time if no enforcer is resolved: without the
      store-path edge to cilium, CNPs would race the operator at apply
      time. Where the environment installs Cilium, a flavour sets
      cluster.roles.cni.binding = "shadowable" and
      cluster.network.environmentCilium, and the `cilium` instance
      configures or uses that Cilium instead of installing one.
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
          networkConfig = cfg;
          networkPolicyEnforcer = resolveEnforcerOut { inherit (ctx) cluster instanceName namespaceName; };
          packageIntents = (ctx.packageMeta.network or { }).intents or { };
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
            allPartResources
            packageMeta
            ;
          networkConfig = cfg;
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
        enforcerOut = if provider == null then null else provider.out;

        defaultDenyPolicies =
          if cfg.defaultDeny then
            map (
              nsName:
              derive.generateDefaultDeny {
                namespaceName = nsName;
                nsResource = ctx.nsResources.${nsName};
                directions = cfg.directions;
                networkPolicyEnforcer = enforcerOut;
              }
            ) ctx.realNsNames
          else
            [ ];

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
            }
          else
            scrape.derive {
              inherit (ctx) resources nsResources realNsNames;
              enforcerApi = enforcerOut.netpol;
              inherit (cfg) directions defaultDeny;
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
              throw (
                "kix: `networkPolicy.enable = true` but no instance declares "
                + "`meta.roles = [\"network-policy-enforcer\"]`. Declare a `cilium` "
                + "instance. Where the environment installs Cilium, a flavour sets "
                + "cluster.roles.cni.binding = \"shadowable\" and "
                + "cluster.network.environmentCilium (on RKE2: "
                + "cluster.flavor.rke2.cni = [ \"cilium\" ]), and the instance "
                + "configures or uses that Cilium instead of installing one."
              )
            else
              null
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
