{
  config,
  lib,
  ...
}:

let
  cfg = config.networkPolicy;

  interface = import ./interface.nix { inherit lib; };
  derive = import ./derive.nix { inherit lib; };

  enforcerCapability = "network-policy-enforcer";

  resolveEnforcerOut =
    {
      cluster,
      instanceName,
      namespaceName,
    }:
    let
      provider = cluster.findCapabilityProvider enforcerCapability;
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
            See v2_discussions/92_declarative_network_policy_intents.md.
          '';
        };
      };
    };
    default = { };
    description = ''
      CiliumNetworkPolicy generation from DI graph. See v2_discussions/37
      and v2_discussions/83. The enforcer that CNPs depend on is looked up
      automatically via `meta.provides ∋ "network-policy-enforcer"` (see
      `kix/packages/cilium`) — no explicit wiring is required, but an
      enforcer instance MUST be declared when `enable = true`. kix throws
      at cluster eval time if no enforcer is resolved: without the
      store-path edge to cilium, CNPs would race the operator at apply
      time. For externally-managed cilium (k3s with cilium helm-installed,
      kind with bootstrap-installed cilium, RKE2's bundled cilium, etc.)
      use `packages."cilium".external`, which emits only the CNP CRD ref
      marker without deploying cilium itself.
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
        provider = ctx.cluster.findCapabilityProvider enforcerCapability;
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
      in
      {
        # default-deny before platform intents: this order flows into the
        # Activation extraDeps and is content-addressed into the output.
        resources = defaultDenyPolicies ++ platformIntentPolicies;
        checks = [
          (
            if provider == null then
              throw (
                "kix: `networkPolicy.enable = true` but no instance declares "
                + "`meta.provides = [\"network-policy-enforcer\"]`. Declare a cilium "
                + "instance in the cluster. For externally-managed cilium (k3s with "
                + "--flannel-backend=none, kind with helm-installed cilium, RKE2's "
                + "bundled cilium, etc.) use the external variant that emits only "
                + "the CRD ref marker, e.g.:\n\n"
                + "  instances.kube-system.cilium = {\n"
                + "    package = packages.\"cilium\".external;\n"
                + "  };\n"
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
