# Helm DAG reconstruction — infer intra-chart resource dependencies
# from well-known K8s reference patterns.
#
# Works on raw JSON resources (pre-wrapping) so that inferred edges
# can be passed as `requires` to mkResource, making them part of the
# content-addressed hash and kix.dev/depends-on annotation.
#
# See v2_discussions/86_helm_dag_reconstruction.md for design rationale.

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

  # ── Edge inference ──────────────────────────────────────────────────
  #
  # Infer edges from raw JSON resources (before wrapping).
  # Returns a list of { from, to, type } where from/to are raw resource objects.
  #
  # Edge direction: `from` depends on `to` (from is deployed after to).
  inferEdges =
    resources:
    let
      # Lookup: "Kind/name" → resource
      byKindName = builtins.listToAttrs (
        map (r: {
          name = "${r.kind}/${(r.metadata or { }).name or ""}";
          value = r;
        }) resources
      );

      workloads = builtins.filter (r: isWorkloadKind r.kind) resources;

      # ── 1. Workload → ServiceAccount ──────────────────────────────
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

      # ── 2. Workload → ConfigMap/Secret (volumes, envFrom, env) ────
      volumeEdges = builtins.concatMap (
        r:
        let
          ps = podSpecOf r;

          # Volume mounts
          volRefs = builtins.concatMap (
            v:
            let
              cmName = (v.configMap or { }).name or null;
              secName = (v.secret or { }).secretName or null;
              # Projected volume sources
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

          # envFrom refs from all containers
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

          # env[].valueFrom.configMapKeyRef / secretKeyRef
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

      # ── 3. RoleBinding/ClusterRoleBinding → ServiceAccount ────────
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

      # ── 4. Service → Workload (selector label subset match) ───────
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

      # ── 5. HPA → Workload (scaleTargetRef) ────────────────────────
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

      # ── 6. PDB → Workload (selector match) ───────────────────────
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

      # ── 7. Ingress → Service (backend refs) ──────────────────────
      ingressEdges = builtins.concatMap (
        r:
        let
          # Default backend
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
          # Rule backends
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

      # ── 8. HTTPRoute → Service (backendRefs) ─────────────────────
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

      # ── 9. ServiceMonitor → Service (selector match) ──────────────
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
    ++ serviceMonitorEdges;

  # ── Dependency map ────────────────────────────────────────────────
  #
  # Converts edge list to resourceId → [resourceId] map.
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

  # ── Diagnostics ────────────────────────────────────────────────────
  #
  # Detect resources whose selectors/refs match nothing in the chart.
  # Returns a list of { resource, diagnostic } for surfacing as warnings.
  findOrphans =
    resources: edges:
    let
      edgeFromIds = type: map (e: resourceId e.from) (builtins.filter (e: e.type == type) edges);

      # Services with selectors matching zero workloads
      selectEdgeFromIds = edgeFromIds "selects";
      orphanServices = builtins.filter (
        r:
        r.kind == "Service"
        && (r.spec or { }).selector or { } != { }
        && !(builtins.elem (resourceId r) selectEdgeFromIds)
      ) resources;

      # PDBs with selectors matching zero workloads
      pdbSelectFromIds = map (e: resourceId e.from) (
        builtins.filter (e: e.type == "selects" && e.from.kind == "PodDisruptionBudget") edges
      );
      orphanPdbs = builtins.filter (
        r:
        r.kind == "PodDisruptionBudget"
        && ((r.spec or { }).selector or { }).matchLabels or { } != { }
        && !(builtins.elem (resourceId r) pdbSelectFromIds)
      ) resources;

      # HPAs targeting non-existent workloads
      scaleFromIds = edgeFromIds "scales";
      orphanHpas = builtins.filter (
        r:
        r.kind == "HorizontalPodAutoscaler"
        && (r.spec or { }).scaleTargetRef or { } != { }
        && !(builtins.elem (resourceId r) scaleFromIds)
      ) resources;
    in
    (map (r: {
      resource = r;
      diagnostic = "Service '${(r.metadata or { }).name or "?"}' selector matches no workload in chart";
    }) orphanServices)
    ++ (map (r: {
      resource = r;
      diagnostic = "PodDisruptionBudget '${
        (r.metadata or { }).name or "?"
      }' selector matches no workload in chart";
    }) orphanPdbs)
    ++ (map (r: {
      resource = r;
      diagnostic = "HorizontalPodAutoscaler '${
        (r.metadata or { }).name or "?"
      }' targets a workload not found in chart";
    }) orphanHpas);
}
