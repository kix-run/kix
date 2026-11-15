# Infer intra-chart dependencies from Kubernetes resource references.
# Inference runs before wrapping so `requires` affects the resource hash and
# the kix.run/depends-on annotation.

{ lib }:

let
  inherit (import ./core/error.nix { inherit lib; }) fail;
  workloadKinds = [
    "Deployment"
    "StatefulSet"
    "DaemonSet"
    "Job"
    "CronJob"
  ];

  isWorkloadKind = kind: builtins.elem kind workloadKinds;

  podSpec = import ./core/pod-spec.nix { inherit lib; };
  inherit (podSpec) podSpecOf;

  podLabelsOf =
    r:
    if r.kind == "CronJob" then
      ((((r.spec or { }).jobTemplate or { }).spec or { }).template.metadata or { }).labels or { }
    else
      (((r.spec or { }).template or { }).metadata or { }).labels or { };

  # Return true when every key in selector matches labels.
  isSubsetMatch =
    selector: labels:
    selector != { }
    && builtins.all (k: labels ? ${k} && labels.${k} == selector.${k}) (builtins.attrNames selector);

  # Return v when it is a list, or [ ] when a Helm chart emits explicit null
  # for a list field (which `or` does not catch because the key exists).
  safeList = v: if builtins.isList v then v else [ ];

in
rec {
  inherit
    workloadKinds
    isWorkloadKind
    podLabelsOf
    isSubsetMatch
    ;

  # Return the "Kind/name" key for a raw JSON resource, which is unique within
  # a single Helm release.
  resourceId = r: "${r.kind}/${(r.metadata or { }).name or ""}";

  # Infer dependency edges `{ from, to, type }` between raw JSON resources
  # before wrapping. `from` depends on `to` and is deployed after it.
  inferEdges =
    resources:
    let
      byKindName = builtins.listToAttrs (
        map (r: {
          name = "${r.kind}/${(r.metadata or { }).name or ""}";
          value = r;
        }) resources
      );

      workloads = builtins.filter (r: isWorkloadKind r.kind) resources;

      saEdges = builtins.concatMap (
        r:
        let
          saName = (podSpecOf r).serviceAccountName or null;
          saKey = "ServiceAccount/${saName}";
        in
        if saName != null && byKindName ? ${saKey} then
          [
            {
              from = r;
              to = byKindName.${saKey};
              type = "uses-sa";
            }
          ]
        else
          [ ]
      ) workloads;

      volumeEdges = builtins.concatMap (
        r:
        map
          (key: {
            from = r;
            to = byKindName.${key};
            type = "mounts";
          })
          (
            builtins.filter (key: byKindName ? ${key}) (
              lib.unique (map (read: "${read.kind}/${read.name}") (podSpec.reads (podSpecOf r)))
            )
          )
      ) workloads;

      bindingEdges = builtins.concatMap (
        r:
        builtins.concatMap (
          s:
          let
            saKey = "ServiceAccount/${s.name or ""}";
          in
          if (s.kind or "") == "ServiceAccount" && byKindName ? ${saKey} then
            [
              {
                from = r;
                to = byKindName.${saKey};
                type = "binds";
              }
            ]
          else
            [ ]
        ) (safeList (r.subjects or [ ]))
      ) (builtins.filter (r: r.kind == "RoleBinding" || r.kind == "ClusterRoleBinding") resources);

      serviceEdges = builtins.concatMap (
        svc:
        let
          svcSelector = (svc.spec or { }).selector or { };
          matching = builtins.filter (w: isSubsetMatch svcSelector (podLabelsOf w)) workloads;
        in
        map (w: {
          from = svc;
          to = w;
          type = "selects";
        }) matching
      ) (builtins.filter (r: r.kind == "Service") resources);

      hpaEdges = builtins.concatMap (
        r:
        let
          targetRef = (r.spec or { }).scaleTargetRef or { };
          targetKey = "${targetRef.kind or ""}/${targetRef.name or ""}";
        in
        if targetRef != { } && byKindName ? ${targetKey} then
          [
            {
              from = r;
              to = byKindName.${targetKey};
              type = "scales";
            }
          ]
        else
          [ ]
      ) (builtins.filter (r: r.kind == "HorizontalPodAutoscaler") resources);

      pdbEdges = builtins.concatMap (
        r:
        let
          pdbSelector = ((r.spec or { }).selector or { }).matchLabels or { };
          matching = builtins.filter (w: isSubsetMatch pdbSelector (podLabelsOf w)) workloads;
        in
        map (w: {
          from = r;
          to = w;
          type = "selects";
        }) matching
      ) (builtins.filter (r: r.kind == "PodDisruptionBudget") resources);

      ingressEdges = builtins.concatMap (
        r:
        let
          defaultSvcName = ((r.spec or { }).defaultBackend.service or { }).name or null;
          defaultEdges =
            if defaultSvcName != null && byKindName ? "Service/${defaultSvcName}" then
              [
                {
                  from = r;
                  to = byKindName."Service/${defaultSvcName}";
                  type = "routes-to";
                }
              ]
            else
              [ ];
          ruleEdges = builtins.concatMap (
            rule:
            builtins.concatMap (
              path:
              let
                svcName = (path.backend.service or { }).name or null;
              in
              if svcName != null && byKindName ? "Service/${svcName}" then
                [
                  {
                    from = r;
                    to = byKindName."Service/${svcName}";
                    type = "routes-to";
                  }
                ]
              else
                [ ]
            ) (safeList ((rule.http or { }).paths or [ ]))
          ) (safeList ((r.spec or { }).rules or [ ]));
        in
        defaultEdges ++ ruleEdges
      ) (builtins.filter (r: r.kind == "Ingress") resources);

      httpRouteEdges = builtins.concatMap (
        r:
        builtins.concatMap (
          rule:
          builtins.concatMap (
            ref:
            let
              kind = ref.kind or "Service";
              svcName = ref.name or null;
            in
            if kind == "Service" && svcName != null && byKindName ? "Service/${svcName}" then
              [
                {
                  from = r;
                  to = byKindName."Service/${svcName}";
                  type = "routes-to";
                }
              ]
            else
              [ ]
          ) (safeList (rule.backendRefs or [ ]))
        ) (safeList ((r.spec or { }).rules or [ ]))
      ) (builtins.filter (r: r.kind == "HTTPRoute") resources);

      # Link custom resources to the chart's own CRD of the same group and kind
      # so deploy applies the CR after the CRD is served. Resources of kinds the
      # chart does not ship get no edge here and must depend on an external CRD
      # declaration (check 21).
      crdsByGroupKind = builtins.listToAttrs (
        map (crd: {
          name = "${crd.spec.group or ""}/${crd.spec.names.kind or ""}";
          value = crd;
        }) (builtins.filter (r: r.kind == "CustomResourceDefinition") resources)
      );
      groupOf =
        apiVersion:
        let
          parts = lib.splitString "/" apiVersion;
        in
        if builtins.length parts == 2 then builtins.head parts else "";
      instanceOfEdges = builtins.concatMap (
        r:
        let
          key = "${groupOf (r.apiVersion or "")}/${r.kind}";
        in
        if r.kind != "CustomResourceDefinition" && crdsByGroupKind ? ${key} then
          [
            {
              from = r;
              to = crdsByGroupKind.${key};
              type = "instance-of";
            }
          ]
        else
          [ ]
      ) resources;

      serviceMonitorEdges = builtins.concatMap (
        r:
        let
          smSelector = ((r.spec or { }).selector or { }).matchLabels or { };
          services = builtins.filter (s: s.kind == "Service") resources;
          matching = builtins.filter (
            svc: isSubsetMatch smSelector ((svc.metadata or { }).labels or { })
          ) services;
        in
        map (svc: {
          from = r;
          to = svc;
          type = "monitors";
        }) matching
      ) (builtins.filter (r: r.kind == "ServiceMonitor") resources);
    in
    saEdges
    ++ volumeEdges
    ++ bindingEdges
    ++ serviceEdges
    ++ hpaEdges
    ++ pdbEdges
    ++ ingressEdges
    ++ httpRouteEdges
    ++ serviceMonitorEdges
    ++ instanceOfEdges;

  # Convert edges to a map from each resourceId to the resourceIds it depends on.
  buildDepsMap =
    edges:
    builtins.foldl' (
      acc: edge:
      let
        key = resourceId edge.from;
        depId = resourceId edge.to;
        existing = acc.${key} or [ ];
      in
      if builtins.elem depId existing then acc else acc // { ${key} = existing ++ [ depId ]; }
    ) { } edges;

  # Return the chart's only Service, or its only Deployment, StatefulSet, or
  # DaemonSet when it has no Service. Fail when the choice is ambiguous,
  # because consumers read the root's `out.selector` and `out.fqdn`.
  pickRoot =
    releaseName: resources:
    let
      ofKinds = kinds: builtins.filter (r: builtins.elem r.kind kinds) resources;
      services = ofKinds [ "Service" ];
      workloads = ofKinds [
        "Deployment"
        "StatefulSet"
        "DaemonSet"
      ];
      names = rs: builtins.concatStringsSep ", " (map (r: "${r.kind}/${r.name}") rs);
      rootHint =
        kind: name:
        ''Name it: resources.mkParts { root = resources.get "${kind}" "${name}"; }, or kix.helmChart { root = { kind = "${kind}"; name = "${name}"; }; ... }.'';
      first = rs: builtins.head rs;
    in
    if builtins.length services == 1 then
      first services
    else if services != [ ] then
      fail {
        message = "importChart (${releaseName}): autoRoot cannot choose a root: the chart renders ${toString (builtins.length services)} Services (${names services}). Consumers read the root's out.selector and out.fqdn, so the root must be the resource they connect to.";
        fix = rootHint "Service" (first services).name;
      }
    else if builtins.length workloads == 1 then
      first workloads
    else if workloads != [ ] then
      fail {
        message = "importChart (${releaseName}): autoRoot cannot choose a root: the chart renders no Service and ${toString (builtins.length workloads)} workloads (${names workloads}). Consumers read the root's out.selector, so the root must be the workload they connect to.";
        fix = rootHint (first workloads).kind (first workloads).name;
      }
    else
      fail {
        message = "importChart (${releaseName}): autoRoot cannot choose a root: the chart renders no Service, Deployment, StatefulSet, or DaemonSet.";
        fix = "Name the root resource: resources.mkParts { root = resources.get \"<kind>\" \"<name>\"; }, or kix.helmChart { root = { kind = \"<kind>\"; name = \"<name>\"; }; ... }.";
      };
}
