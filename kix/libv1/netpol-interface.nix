# netpol-interface.nix — Formal contract for network-policy enforcers.
#
# Any package that declares `meta.provides = ["network-policy-enforcer"]`
# must expose `out.netpol` conforming to this interface.  Cluster eval
# validates the enforcer's `out.netpol` against this spec at eval time
# (see cluster.nix → validateEnforcerInterface), so a missing or
# mistyped function produces a clear error rather than a cryptic failure
# deep inside netpol.nix.
#
# The interface is intentionally high-level: enforcers own the rule
# *shape* (Cilium uses toEndpoints/toEntities, native K8s NetworkPolicy
# would use podSelector/ipBlock, Calico uses selector expressions, etc.)
# while netpol.nix owns the *orchestration* (when to emit, what signals
# to watch, how to wire store-path deps).

{ lib }:

let
  # The set of attribute names every enforcer's `out.netpol` must provide.
  # Each entry maps to a short description used in error messages.
  requiredAttrs = {
    # Build a complete network-policy resource from an attrset.
    # { mkResource, extraArgs } -> resource
    # mkResource is the scope's or k8s's mkResource; extraArgs carries
    # name, namespace, labels, spec, extraDeps.
    mkPolicy = "{ mkResource, extraArgs } -> resource — build a network-policy resource";

    # Build a default-deny policy for a namespace.
    # { mkResource, name, namespace, denyIngress, denyEgress } -> spec attrs
    # Returns the `spec` portion; the caller wraps it via mkPolicy.
    mkDefaultDenySpec = "{ denyIngress, denyEgress } -> spec attrs for a default-deny policy";

    # Rule builders — each returns a rule attrset in the enforcer's
    # native format (e.g. Cilium's {toEndpoints, toPorts} shape).

    # DNS egress rule (allow queries to cluster DNS).
    dnsEgressRule = "rule — egress to kube-dns (UDP+TCP 53)";

    # API server egress rule.
    apiServerEgressRule = "rule — egress to kube-apiserver";

    # External ingress rule (traffic from outside the cluster).
    # { entities ? ["world"] } -> rule
    mkExternalIngressRule = "{ entities } -> rule — ingress from external sources";

    # External egress rule (traffic to outside the cluster).
    # { entities ? ["world"] } -> rule
    mkExternalEgressRule = "{ entities } -> rule — egress to external destinations";

    # Egress rule targeting a specific Service's backing pods.
    # { selector, namespace, sourceNamespace, ports } -> rule
    # `namespace` is the target's namespace, `sourceNamespace` is the
    # caller's namespace (needed for cross-namespace selectors).
    mkServiceEgressRule = "{ selector, namespace, sourceNamespace, ports } -> rule — egress to a Service's pods";

    # Self-communication rules for StatefulSet peer traffic.
    # { selector } -> { egress = [rule]; ingress = [rule]; }
    mkSelfRules = "{ selector } -> { egress, ingress } — peer-to-peer for StatefulSets";

    # Ingress rule from a specific caller workload.
    # { callerSelector, callerNamespace, ports } -> rule
    # Used by caller-side inverted-ingress emission.
    mkCallerIngressRule = "{ callerSelector, callerNamespace, ports } -> rule — ingress from a specific caller";

    # Convert K8s Service ports to the enforcer's port format.
    # [{ port, targetPort?, protocol? }] -> [port-spec]
    portsToCilium = "[svc-port] -> [enforcer-port-spec] — convert K8s Service ports";

    # Build an endpoint/pod selector for the policy's subject.
    # matchLabels -> selector
    # e.g. Cilium: { endpointSelector.matchLabels = ... }
    mkEndpointSelector = "matchLabels -> selector — wrap labels into the enforcer's selector format";

    # Translate declarative intent rules to enforcer-native rules.
    # Intents use an enforcer-agnostic vocabulary (to="world", to="dns",
    # to="apiserver", from="all-pods", from="world", ports=[...]).
    # Returns { egressRules = [rule]; ingressRules = [rule]; }.
    # See v2_discussions/92_declarative_network_policy_intents.md.
    translateIntentRules = "{ intents } -> { egressRules, ingressRules } — translate intent rules to native enforcer rules";

    # Materialize a platform intent into a standalone policy resource.
    # Used for non-kix-managed pods (CoreDNS, local-path-provisioner, etc.)
    # declared via networkPolicy.platformIntents in flavor configs.
    # { intent, mkResource, namespaceResource?, clusterScoped } -> resource
    # `intent` has: name, scope?, namespace?, targetNamespace?, podSelector,
    # egress?, ingress?. `namespaceResource` is the Namespace resource object
    # (required for namespaced intents). `clusterScoped` is the k8s sentinel.
    materializePlatformIntent = "{ intent, mkResource, namespaceResource?, clusterScoped } -> resource — materialize a platform intent into a policy resource";
  };

  # Validate that an enforcer's `out.netpol` attrset has all required keys.
  # Returns null on success, throws with a descriptive message on failure.
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
        + "\n\nSee kix/lib/netpol-interface.nix for the full contract."
      );

in
{
  inherit requiredAttrs validateEnforcerInterface;
}
