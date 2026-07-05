{ lib }:

let
  requiredAttrs = {
    mkPolicy = "{ mkResource, extraArgs } -> resource — build a network-policy resource";

    mkDefaultDenySpec = "{ denyIngress, denyEgress } -> spec attrs for a default-deny policy";

    dnsEgressRule = "rule — egress to kube-dns (UDP+TCP 53)";

    apiServerEgressRule = "rule — egress to kube-apiserver";

    mkExternalIngressRule = "{ entities } -> rule — ingress from external sources";

    mkExternalEgressRule = "{ entities } -> rule — egress to external destinations";

    mkServiceEgressRule = "{ selector, namespace, sourceNamespace, ports } -> rule — egress to a Service's pods";

    mkSelfRules = "{ selector } -> { egress, ingress } — peer-to-peer for StatefulSets";

    mkCallerIngressRule = "{ callerSelector, callerNamespace, ports } -> rule — ingress from a specific caller";

    portsToCilium = "[svc-port] -> [enforcer-port-spec] — convert K8s Service ports";

    mkEndpointSelector = "matchLabels -> selector — wrap labels into the enforcer's selector format";

    translateIntentRules = "{ intents } -> { egressRules, ingressRules } — translate intent rules to native enforcer rules";

    materializePlatformIntent = "{ intent, mkResource, namespaceResource?, clusterScoped } -> resource — materialize a platform intent into a policy resource";
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
      throw (
        "kix: network-policy enforcer '${enforcerName}' is missing required "
        + "`out.netpol` attributes:\n"
        + builtins.concatStringsSep "\n" descriptions
        + "\n\nSee kix/lib/plugins/netpol/interface.nix for the full contract."
      );

in
{
  inherit requiredAttrs validateEnforcerInterface;
}
