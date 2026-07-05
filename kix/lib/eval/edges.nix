{ k8s }:

let
  workloadKinds = [
    "Deployment"
    "StatefulSet"
    "DaemonSet"
    "Job"
  ];
in

rec {
  isWorkload = r: builtins.elem (r.kind or "") workloadKinds;

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
    && (r.rawManifest.metadata.annotations."kix.dev/mode" or "") == "import"
    && (r.rawManifest.metadata.annotations."kix.dev/import-kind" or "") == "Service";

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
          targetSelector = builtins.fromJSON (annotations."kix.dev/service-selector" or "{}");
          targetNamespace = k8s.nsOf r;
          ports = builtins.fromJSON (annotations."kix.dev/service-ports" or "[]");
        };
      }
    ) { } (builtins.filter isServiceRef resources);

  extractServiceEdgesFromJson =
    {
      json,
      serviceRegistry,
      serviceRefRegistry ? { },
    }:
    let
      ctx = builtins.getContext json;

      serviceMatchedPaths = builtins.filter (p: builtins.hasAttr p serviceRegistry) (
        builtins.attrNames ctx
      );
      serviceEdges = map (
        p:
        let
          svc = serviceRegistry.${p};
        in
        {
          service = svc;
          ports = svc.rawManifest.spec.ports or [ ];
          targetSelector = svc.rawManifest.spec.selector or { };
          targetNamespace = k8s.nsOf svc;
        }
      ) serviceMatchedPaths;

      refMatchedPaths = builtins.filter (p: builtins.hasAttr p serviceRefRegistry) (
        builtins.attrNames ctx
      );
      serviceRefEdges = map (
        p:
        let
          ref = serviceRefRegistry.${p};
        in
        {
          service = ref.marker;
          inherit (ref) targetSelector targetNamespace ports;
        }
      ) refMatchedPaths;
    in
    serviceEdges ++ serviceRefEdges;
}
