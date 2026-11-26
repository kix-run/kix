# Extract workload-to-Service network dependencies from typed facts and string
# contexts.
#
# The primary signal is the `endpoint` fact (`core/facts.nix`). Address-shaped
# Service `out` fields carry a self-describing token with `{ name, namespace,
# selector, ports }`. Any endpoint token still present in a workload's manifest
# JSON context at seal time (directly or via ConfigMaps and Secrets) identifies
# a Service the workload's pods connect to. Reading the token payload avoids
# cross-instance fixpoint constraints.
#
# Service store-path references in string context (identity hits) serve three
# secondary purposes:
#   1. DNS ordering: referencing a Service adds a conservative DNS startup
#      dependency even when no address token flowed.
#   2. Helm workloads: chart rendering can strip address tokens, so workloads
#      with `_helmNetworkDeps` also derive network policy rules from identity
#      hits.
#   3. Diagnostics: an identity hit without a matching `endpoint` or `refonly`
#      fact warns when a workload references a Service without connecting to it
#      or marking `facts.refOnly`.

{ lib, k8s }:

let
  inherit (import ../core/pod-spec.nix { inherit lib; }) podTemplateOf;
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
      templateLabels = (podTemplateOf w.rawManifest).metadata.labels or { };
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

  # Map each Service store path to its resource.
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
          # Use the imported Service's name rather than the marker's so the edge
          # key matches the endpoint fact payload.
          name = annotations.${kixKeys.importName} or r.name;
          targetSelector = builtins.fromJSON (annotations.${kixKeys.serviceSelector} or "{}");
          targetNamespace = k8s.nsOf r;
          ports = builtins.fromJSON (annotations.${kixKeys.servicePorts} or "[]");
        };
      }
    ) { } (builtins.filter isServiceRef resources);

  # Map `"<namespace>/<name>"` to the Service or import marker resource in this
  # instance's resolved dependencies so network policies can attach `extraDeps`
  # to the target Service. Real Services take precedence over import markers.
  mkServiceIndex =
    resources:
    builtins.foldl' (
      acc: r:
      acc
      // {
        "${k8s.nsOf r}/${r.rawManifest.metadata.annotations.${kixKeys.importName} or r.name}" = r;
      }
    ) { } (builtins.filter isServiceRef resources)
    // builtins.foldl' (
      acc: r:
      acc
      // {
        "${k8s.nsOf r}/${r.name}" = r;
      }
    ) { } (builtins.filter isService resources);

  # Analyze a serialized workload manifest and return `{ edges, dnsEdges, warnings }`,
  # where each edge has `{ name, targetSelector, targetNamespace, ports, service,
  # targetDeployed }`. `targetDeployed` is false when an import minted the
  # endpoint fact, so Kix does not deploy the target pods.
  analyzeEdges =
    {
      json,
      serviceRegistry ? { },
      serviceRefRegistry ? { },
      serviceIndex ? { },
      # Include identity hits in network policy `edges` for Helm workloads whose
      # chart templates may drop address tokens.
      conservative ? false,
    }:
    let
      endpointFacts = facts.factsOfKind "endpoint" json;

      factEdges = map (f: {
        inherit (f.payload) name ports;
        targetSelector = f.payload.selector;
        targetNamespace = f.payload.namespace;
        service = serviceIndex."${f.payload.namespace}/${f.payload.name}" or null;
        targetDeployed = !(f.payload.imported or false);
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
            targetDeployed = true;
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
            targetDeployed = true;
          }
        ) (builtins.filter (p: builtins.hasAttr p serviceRefRegistry) ctxPaths);

      edgeKey = e: "${e.targetNamespace}/${e.name}";
      factKeys = map edgeKey factEdges;

      ackedKeys = map (f: "${f.payload.namespace}/${f.payload.name}") (facts.factsOfKind "refonly" json);

      unmatchedIdentity = builtins.filter (
        e: !(builtins.elem (edgeKey e) (factKeys ++ ackedKeys))
      ) identityEdges;

      # Sort by namespace and name because Nix string context is ordered by
      # token hash, which changes whenever a payload changes.
      bySortedKey = builtins.sort (a: b: edgeKey a < edgeKey b);
    in
    {
      edges = bySortedKey (if conservative then factEdges ++ unmatchedIdentity else factEdges);

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
