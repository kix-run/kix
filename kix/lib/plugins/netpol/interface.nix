{ lib }:

let
  inherit (import ../../core/error.nix { inherit lib; }) fail;
  dnsPeers = import ../../core/dns-peers.nix { inherit lib; };

  requiredAttrs = {
    policyKinds = "[kind]. the policy kinds this enforcer emits; the hasNetworkPolicy rule accepts them as a namespace's policy";

    mkPolicy = "{ mkResource, extraArgs, selector ? null, ingress ? [ ], egress ? [ ] } -> resource. Build a network policy resource selecting pods with `matchLabels = selector` and rules from `ingress` and `egress` (omitting any direction whose list is empty). When `selector` is null, read the full policy spec from `extraArgs.spec` (such as from `mkDefaultDenySpec`).";

    mkDefaultDenySpec = "{ denyIngress, denyEgress } -> spec attrs for a default-deny policy";

    dnsEgressRule = "rule. Allow egress on UDP and TCP port 53 to the configured DNS peers (see `withDnsPeers`).";

    withDnsPeers = "[dnsPeer] -> netpol. Return a copy of `out.netpol` whose `dnsEgressRule` and `\"dns\"` intent target allow the given DNS peers instead of the default `kube-dns` pods.";

    apiServerEgressRule = "rule. egress to kube-apiserver";

    mkExternalIngressRule = "{ entities, ports ? [ ] } -> rule. ingress from external sources on these pod ports (Service ports, whose `targetPort` is read), or on every port when `ports` is empty";

    mkExternalEgressRule = "{ entities } -> rule. egress to external destinations";

    mkServiceEgressRule = "{ selector, namespace, sourceNamespace, ports } -> rule. egress to a Service's pods";

    mkHostNetworkEgressRule = "{ ports } -> rule. egress to pods on the host network of any node, on these pod ports";

    mkSelfRules = "{ selector } -> { egress, ingress }. peer-to-peer for StatefulSets";

    mkCallerIngressRule = "{ callerSelector, callerNamespace, ports } -> rule. ingress from pods matching callerSelector in callerNamespace (or any namespace when callerNamespace is null)";

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

  # The entities an intent rule (`entities` on `meta.network.intents` or a
  # platform intent) and `meta.network.externalIngressEntities` may name.
  # Each enforcer maps them to its own peers.
  entityNames = [
    "world"
    "host"
    "remote-node"
    "kube-apiserver"
    "cluster"
    "all"
  ];

  # Return `entities` when every name is in `entityNames`, or fail naming
  # `where` and the unknown names.
  checkEntities =
    where: entities:
    let
      unknown = builtins.filter (e: !(builtins.elem e entityNames)) entities;
    in
    if unknown == [ ] then
      entities
    else
      fail {
        id = "K2060";
        message = "${where} lists unsupported network entities ${builtins.toJSON unknown}, so Kix rejected the network policy.";
        fix = "Replace ${builtins.toJSON unknown} with supported entity names (${
          lib.concatMapStringsSep ", " (e: "\"${e}\"") entityNames
        }). For Cilium-only entities such as \"health\" or \"ingress\", build a custom policy resource with `cilium.out.crds.CiliumNetworkPolicy` instead.";
      };

  # Return `intents` (an attrset of `{ ingress, egress }` rule lists) after
  # checking the `entities` of every rule with `checkEntities`.
  checkIntentEntities =
    where: intents:
    let
      rulesOf = i: (i.ingress or [ ]) ++ (i.egress or [ ]);
      allRules = builtins.concatMap rulesOf (builtins.attrValues intents);
    in
    builtins.foldl' (
      acc: rule: if rule ? entities then builtins.seq (checkEntities where rule.entities) acc else acc
    ) intents allRules;

in
{
  inherit (dnsPeers)
    defaultDnsPeers
    checkDnsPeers
    dnsPeersOf
    bindDnsPeers
    ;
  inherit
    requiredAttrs
    validateEnforcerInterface
    entityNames
    checkEntities
    checkIntentEntities
    ;
}
