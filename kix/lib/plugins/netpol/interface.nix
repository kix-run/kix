{ lib }:

let
  inherit (import ../../core/error.nix { inherit lib; }) fail;

  requiredAttrs = {
    policyKinds = "[kind]. the policy kinds this enforcer emits; the hasNetworkPolicy rule accepts them as a namespace's policy";

    mkPolicy = "{ mkResource, extraArgs } -> resource. build a network-policy resource";

    mkDefaultDenySpec = "{ denyIngress, denyEgress } -> spec attrs for a default-deny policy";

    dnsEgressRule = "rule. egress to kube-dns (UDP+TCP 53)";

    apiServerEgressRule = "rule. egress to kube-apiserver";

    mkExternalIngressRule = "{ entities } -> rule. ingress from external sources";

    mkExternalEgressRule = "{ entities } -> rule. egress to external destinations";

    mkServiceEgressRule = "{ selector, namespace, sourceNamespace, ports } -> rule. egress to a Service's pods";

    mkHostNetworkEgressRule = "{ ports } -> rule. egress to pods on the host network of any node, on these pod ports";

    mkSelfRules = "{ selector } -> { egress, ingress }. peer-to-peer for StatefulSets";

    mkCallerIngressRule = "{ callerSelector, callerNamespace, ports } -> rule. ingress from a specific caller";

    portsToCilium = "[svc-port] -> [enforcer-port-spec]. convert K8s Service ports";

    mkEndpointSelector = "matchLabels -> selector. wrap labels into the enforcer's selector format";

    translateIntentRules = "{ intents } -> { egressRules, ingressRules }. translate intent rules to native enforcer rules";

    materializePlatformIntent = "{ intent, mkResource, namespaceResource?, clusterScoped } -> resource. materialize a platform intent into a policy resource";
  };

  validateEnforcerInterface =
    {
      enforcerNetpol,
      enforcerName ? "<unknown>",
    }:
    let
      missing = lib.filter (attr: !(builtins.hasAttr attr enforcerNetpol)) (
        builtins.attrNames requiredAttrs
      );

      descriptions = map (attr: "  - ${attr}: ${requiredAttrs.${attr}}") missing;
    in
    if missing == [ ] then
      null
    else
      fail {
        message =
          "network-policy enforcer '${enforcerName}' is missing required `out.netpol` attributes:\n"
          + builtins.concatStringsSep "\n" descriptions;
        fix = "Add them to the enforcer's `out.netpol`. See kix/lib/plugins/netpol/interface.nix for the full contract.";
      };

in
{
  inherit requiredAttrs validateEnforcerInterface;
}
