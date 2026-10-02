# Infer intra-chart dependencies from Kubernetes resource references.
# Inference runs before wrapping so `requires` affects the resource hash and
# the kix.run/depends-on annotation.

{ lib }:

let
  workloadKinds = [
    "Deployment"
    "StatefulSet"
    "DaemonSet"
    "Job"
    "CronJob"
  ];

  isWorkloadKind = kind: builtins.elem kind workloadKinds;

  # Extract pod spec from a raw workload resource.
  podSpecOf =
    r:
    if r.kind == "CronJob" then
      (((r.spec or { }).jobTemplate or { }).spec or { }).template.spec or { }
    else
      ((r.spec or { }).template or { }).spec or { };

  # Extract pod template labels from a raw workload resource.
  podLabelsOf =
    r:
    if r.kind == "CronJob" then
      ((((r.spec or { }).jobTemplate or { }).spec or { }).template.metadata or { }).labels or { }
    else
      (((r.spec or { }).template or { }).metadata or { }).labels or { };

  # Label subset match: every key in selector exists in labels with same value.
  isSubsetMatch =
    selector: labels:
    selector != { }
    && builtins.all (k: labels ? ${k} && labels.${k} == selector.${k}) (builtins.attrNames selector);

  # Safe list accessor: Helm charts can emit explicit `null` for list fields
  # (e.g. `volumes: null`), which `or` doesn't catch since the key exists.
  safeList = v: if builtins.isList v then v else [ ];

in
rec {
  inherit
    workloadKinds
    isWorkloadKind
    podLabelsOf
    isSubsetMatch
    ;

  # Identity key for a raw JSON resource within a chart.
  # Kind/name is unique within a single Helm release.
  resourceId = r: "${r.kind}/${(r.metadata or { }).name or ""}";

  # Infer edges from raw JSON resources before wrapping.
  # Returns a list of { from, to, type } where from/to are raw resource objects.
  #
  # Edge direction: `from` depends on `to` (from is deployed after to).
  inferEdges =
    resources:
    let
      # Lookup by "Kind/name".
      byKindName = builtins.listToAttrs (
        map (r: {
          name = "${r.kind}/${(r.metadata or { }).name or ""}";
          value = r;
        }) resources
      );

      workloads = builtins.filter (r: isWorkloadKind r.kind) resources;

      # Workload to ServiceAccount.
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

      # Workload to ConfigMap or Secret through volumes and environment.
      volumeEdges = builtins.concatMap (
        r:
        let
          ps = podSpecOf r;

          # Volume sources.
          volRefs = builtins.concatMap (
            v:
            let
              cmName = (v.configMap or { }).name or null;
              secName = (v.secret or { }).secretName or null;
              # Projected volume sources.
              projRefs = builtins.concatMap (
                s:
                let
                  pcm = (s.configMap or { }).name or null;
                  psec = (s.secret or { }).name or null;
                in
                (
                  if pcm != null && byKindName ? "ConfigMap/${pcm}" then
                    [
                      {
                        from = r;
                        to = byKindName."ConfigMap/${pcm}";
                        type = "mounts";
                      }
                    ]
                  else
                    [ ]
                )
                ++ (
                  if psec != null && byKindName ? "Secret/${psec}" then
                    [
                      {
                        from = r;
                        to = byKindName."Secret/${psec}";
                        type = "mounts";
                      }
                    ]
                  else
                    [ ]
                )
              ) (safeList ((v.projected or { }).sources or [ ]));
            in
            (
              if cmName != null && byKindName ? "ConfigMap/${cmName}" then
                [
                  {
                    from = r;
                    to = byKindName."ConfigMap/${cmName}";
                    type = "mounts";
                  }
                ]
              else
                [ ]
            )
            ++ (
              if secName != null && byKindName ? "Secret/${secName}" then
                [
                  {
                    from = r;
                    to = byKindName."Secret/${secName}";
                    type = "mounts";
                  }
                ]
              else
                [ ]
            )
            ++ projRefs
          ) (safeList (ps.volumes or [ ]));

          # envFrom references from all containers.
          containers = safeList (ps.containers or [ ]) ++ safeList (ps.initContainers or [ ]);
          envFromRefs = builtins.concatMap (
            c:
            builtins.concatMap (
              ef:
              let
                cmRef = (ef.configMapRef or { }).name or null;
                secRef = (ef.secretRef or { }).name or null;
              in
              (
                if cmRef != null && byKindName ? "ConfigMap/${cmRef}" then
                  [
                    {
                      from = r;
                      to = byKindName."ConfigMap/${cmRef}";
                      type = "mounts";
                    }
                  ]
                else
                  [ ]
              )
              ++ (
                if secRef != null && byKindName ? "Secret/${secRef}" then
                  [
                    {
                      from = r;
                      to = byKindName."Secret/${secRef}";
                      type = "mounts";
                    }
                  ]
                else
                  [ ]
              )
            ) (safeList (c.envFrom or [ ]))
          ) containers;

          # env[].valueFrom references.
          envValueFromRefs = builtins.concatMap (
            c:
            builtins.concatMap (
              e:
              let
                vf = e.valueFrom or { };
                cmKey = (vf.configMapKeyRef or { }).name or null;
                secKey = (vf.secretKeyRef or { }).name or null;
              in
              (
                if cmKey != null && byKindName ? "ConfigMap/${cmKey}" then
                  [
                    {
                      from = r;
                      to = byKindName."ConfigMap/${cmKey}";
                      type = "mounts";
                    }
                  ]
                else
                  [ ]
              )
              ++ (
                if secKey != null && byKindName ? "Secret/${secKey}" then
                  [
                    {
                      from = r;
                      to = byKindName."Secret/${secKey}";
                      type = "mounts";
                    }
                  ]
                else
                  [ ]
              )
            ) (safeList (c.env or [ ]))
          ) containers;
        in
        volRefs ++ envFromRefs ++ envValueFromRefs
      ) workloads;

      # Role bindings to ServiceAccounts.
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

      # Services to workloads selected by label subset.
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

      # HPAs to scale targets.
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

      # PDBs to workloads selected by labels.
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

      # Ingresses to backend Services.
      ingressEdges = builtins.concatMap (
        r:
        let
          # Default backend.
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
          # Rule backends.
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

      # HTTPRoutes to backend Services.
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

      # Custom resources to the chart's own CRD of their group and kind, so
      # the deploy applies the CR after the CRD is served. A chart resource
      # of a kind the chart does not ship gets no edge here; the cluster
      # build refuses it unless it depends on a declaration (check 21).
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

      # ServiceMonitors to Services selected by labels.
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

  # Convert edges to a resourceId -> [resourceId] map.
  # Direction: from depends on to.
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

  # Set of resourceIds that are depended on by other resources.
  # These are reachable through the DAG and don't need to be direct
  # requires of the package root.
  dependedOnIds = edges: lib.unique (map (e: resourceId e.to) edges);

  # The root of an imported chart: the only Service, else the only
  # Deployment, StatefulSet or DaemonSet. Consumers read the root's
  # out.selector and out.fqdn, so any other case throws instead of guessing.
  # `resources` are wrapped resources (with `kind` and `name`).
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
      fix =
        kind: name:
        ''Name it: resources.mkParts { root = resources.get "${kind}" "${name}"; }, or kix.helmChart { root = { kind = "${kind}"; name = "${name}"; }; ... }.'';
      first = rs: builtins.head rs;
    in
    if builtins.length services == 1 then
      first services
    else if services != [ ] then
      throw "importChart (${releaseName}): autoRoot cannot choose a root: the chart renders ${toString (builtins.length services)} Services (${names services}). Consumers read the root's out.selector and out.fqdn, so the root must be the resource they connect to. ${fix "Service" (first services).name}"
    else if builtins.length workloads == 1 then
      first workloads
    else if workloads != [ ] then
      throw "importChart (${releaseName}): autoRoot cannot choose a root: the chart renders no Service and ${toString (builtins.length workloads)} workloads (${names workloads}). Consumers read the root's out.selector, so the root must be the workload they connect to. ${fix (first workloads).kind (first workloads).name}"
    else
      throw "importChart (${releaseName}): autoRoot cannot choose a root: the chart renders no Service, Deployment, StatefulSet or DaemonSet. Name the root resource: resources.mkParts { root = resources.get \"<kind>\" \"<name>\"; }, or kix.helmChart { root = { kind = \"<kind>\"; name = \"<name>\"; }; ... }.";
}
