# Edge analysis: who dials whom, read back from typed facts.
#
# The primary signal is the `endpoint` fact (core/facts.nix): a Service's
# address-shaped out fields carry a self-describing token whose payload is
# {name, namespace, selector, ports}. Whatever a workload's manifest JSON
# still holds in context at seal time, directly or through ConfigMaps and
# Secrets, is the set of endpoints its pods dial.
# `readFile` on the token replaces the old registry intersection, so edges
# work across instances and through indirection with no collectibility or
# fixpoint constraints.
#
# Identity hits (a Service's *store path* in context, the pre-fact signal)
# are kept for three demoted roles:
#   1. DNS conservatism: naming a Service is weak evidence of dialing it;
#      an extra DNS-ordering dep is harmless, a missing one breaks startup.
#   2. Helm workloads: the lossy chart pipeline cannot always flow address
#      values, so `_helmNetworkDeps` workloads keep identity-derived netpol
#      edges (conservative = extra holes, never missing ones).
#   3. The observed-vs-declared lint: identity without a matching fact
#      means "you name it but no address flowed": either a structural use
#      (silence with facts.refOnly) or a missed dial (use out.fqdn, out.url,
#      or facts.connect to create the network policy edge).

{ k8s }:

let
  # Kix's own annotation keys and API names, spelled once in
  # core/annotations.nix.
  kixAnnotations = import ../core/annotations.nix;
  kixKeys = kixAnnotations.keys;
  inherit (k8s) facts;
in

rec {
  isWorkload = r: builtins.elem (r.kind or "") facts.terminatorKinds;

  getWorkloadSelector =
    w:
    let
      selectorLabels = w.rawManifest.spec.selector.matchLabels or null;
      templateLabels = w.rawManifest.spec.template.metadata.labels or { };
    in
    if selectorLabels != null then selectorLabels else templateLabels;

  isService =
    r:
    (r.kind or "") == "Service"
    && (r.rawManifest.spec.selector or { }) != { }
    && (r.rawManifest.spec.type or "ClusterIP") != "ExternalName";

  isServiceRef =
    r:
    (r.kind or "") == "PackageInstance"
    && (r.rawManifest.metadata.annotations.${kixKeys.mode} or "") == "import"
    && (r.rawManifest.metadata.annotations.${kixKeys.importKind} or "") == "Service";

  # Identity-keyed map from store path to Service resource.
  mkServiceRegistry =
    resources:
    builtins.foldl' (
      acc: r:
      acc
      // {
        ${builtins.unsafeDiscardStringContext r.outPath} = r;
      }
    ) { } (builtins.filter isService resources);

  mkServiceRefRegistry =
    resources:
    builtins.foldl' (
      acc: r:
      let
        annotations = r.rawManifest.metadata.annotations or { };
      in
      acc
      // {
        ${builtins.unsafeDiscardStringContext r.outPath} = {
          marker = r;
          # Use the imported Service's name rather than the marker's; edge identity
          # must match what the ref's endpoint fact claims
          name = annotations.${kixKeys.importName} or r.name;
          targetSelector = builtins.fromJSON (annotations.${kixKeys.serviceSelector} or "{}");
          targetNamespace = k8s.nsOf r;
          ports = builtins.fromJSON (annotations.${kixKeys.servicePorts} or "[]");
        };
      }
    ) { } (builtins.filter isServiceRef resources);

  # "ns/name"-keyed: enrichment map from fact payload back to the producing
  # resource, when it exists in this instance's resolved deps. Only used to
  # give netpol a `service` for CNP extraDeps. Edges through indirection or
  # import-mode refs have service = null, and wave ordering still holds via
  # store-DAG transitivity.
  mkServiceIndex =
    resources:
    # ref markers first, real Services second (a real Service wins the key)
    builtins.foldl' (
      acc: r:
      acc
      // {
        "${k8s.nsOf r}/${(r.rawManifest.metadata.annotations or { }).${kixKeys.importName} or r.name}" = r;
      }
    ) { } (builtins.filter isServiceRef resources)
    // builtins.foldl' (
      acc: r:
      acc
      // {
        "${k8s.nsOf r}/${r.name}" = r;
      }
    ) { } (builtins.filter isService resources);

  # One edge shape for every source:
  #   { name, targetSelector, targetNamespace, ports, service (nullable) }
  analyzeEdges =
    {
      json,
      serviceRegistry ? { },
      serviceRefRegistry ? { },
      serviceIndex ? { },
      # helm-sourced workloads: identity hits stay netpol edges (lossy
      # pipeline, so preserve conservative edges.)
      conservative ? false,
    }:
    let
      endpointFacts = facts.factsOfKind "endpoint" json;

      factEdges = map (f: {
        inherit (f.payload) name ports;
        targetSelector = f.payload.selector;
        targetNamespace = f.payload.namespace;
        service = serviceIndex."${f.payload.namespace}/${f.payload.name}" or null;
      }) endpointFacts;

      ctxPaths = builtins.attrNames (builtins.getContext json);

      identityEdges =
        map (
          p:
          let
            svc = serviceRegistry.${p};
          in
          {
            inherit (svc) name;
            service = svc;
            ports = svc.rawManifest.spec.ports or [ ];
            targetSelector = svc.rawManifest.spec.selector or { };
            targetNamespace = k8s.nsOf svc;
          }
        ) (builtins.filter (p: builtins.hasAttr p serviceRegistry) ctxPaths)
        ++ map (
          p:
          let
            ref = serviceRefRegistry.${p};
          in
          {
            inherit (ref)
              name
              targetSelector
              targetNamespace
              ports
              ;
            service = ref.marker;
          }
        ) (builtins.filter (p: builtins.hasAttr p serviceRefRegistry) ctxPaths);

      edgeKey = e: "${e.targetNamespace}/${e.name}";
      factKeys = map edgeKey factEdges;

      # deliberate non-dials, declared at the use site via facts.refOnly
      ackedKeys = map (f: "${f.payload.namespace}/${f.payload.name}") (facts.factsOfKind "refonly" json);

      # identity present, no address flowed, not acknowledged
      unmatchedIdentity = builtins.filter (
        e: !(builtins.elem (edgeKey e) (factKeys ++ ackedKeys))
      ) identityEdges;

      # Sort by namespace and name. Context sets are ordered by token hash,
      # which churns whenever a payload changes; CNP rule order must not
      bySortedKey = builtins.sort (a: b: edgeKey a < edgeKey b);
    in
    {
      edges = bySortedKey (if conservative then factEdges ++ unmatchedIdentity else factEdges);

      # DNS ordering is always conservative: fact edges ∪ identity hits
      dnsEdges = factEdges ++ unmatchedIdentity;

      warnings =
        if conservative then
          [ ]
        else
          map (
            e:
            "workload references Service '${edgeKey e}' without using its address. "
            + "Kix has not generated a network policy for this connection. Use out.fqdn/out.url (or facts.connect) to connect to it; "
            + "if you only need its name or labels, use facts.refOnly to mark that intent."
          ) unmatchedIdentity;
    };
}
