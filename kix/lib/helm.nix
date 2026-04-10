# Helm chart bridge — imports Helm charts as kix resources via IFD.
#
# Two tiers of usage:
#
#   Tier 1 (inline, zero friction):
#     package = kix.helmChart { repo = "..."; name = "loki"; version = "..."; hash = "..."; };
#
#   Tier 2 (real package with full control):
#     build = { scope, ... }:
#       let resources = scope.helm.importChart { chart = ...; scope = ...; };
#       in resources.mkParts { root = resources.get "Deployment" "foo"; };
#
# See v2_discussions/87_helm_integration_v2.md for design rationale.

{ pkgs, lib }:

let
  # Kinds that are always cluster-scoped (no namespace in metadata).
  clusterScopedKinds = [
    "Namespace"
    "ClusterRole"
    "ClusterRoleBinding"
    "CustomResourceDefinition"
    "PersistentVolume"
    "StorageClass"
    "PriorityClass"
    "IngressClass"
    "ValidatingWebhookConfiguration"
    "MutatingWebhookConfiguration"
    "APIService"
    "CSIDriver"
    "CSINode"
    "VolumeAttachment"
  ];

  isClusterScopedKind = kind: builtins.elem kind clusterScopedKinds;

  # Annotations/labels injected by Helm that we strip.
  helmAnnotationPrefixes = [
    "meta.helm.sh/"
    "helm.sh/"
    "checksum/"
  ];
  helmLabelKeys = [
    "app.kubernetes.io/managed-by" # Helm sets this to "Helm"; we replace with "kix"
    "helm.sh/chart"
  ];

  isHelmAnnotation = key: builtins.any (prefix: lib.hasPrefix prefix key) helmAnnotationPrefixes;

  stripHelmAnnotations = annotations: lib.filterAttrs (k: _: !(isHelmAnnotation k)) annotations;

  stripHelmLabels = labels: lib.filterAttrs (k: _: !(builtins.elem k helmLabelKeys)) labels;

  # Strip Helm-injected annotations from pod template metadata inside a spec.
  # Handles spec.template.metadata.annotations for Deployments, StatefulSets, DaemonSets.
  # Also strips default strategy/updateStrategy that K8s adds server-side.
  cleanSpec =
    spec:
    let
      tmpl = spec.template or null;
      tmplMeta = if tmpl != null then (tmpl.metadata or { }) else { };
      rawTmplAnnotations = tmplMeta.annotations or { };
      tmplAnnotations = if rawTmplAnnotations == null then { } else rawTmplAnnotations;
      cleanedTmplAnnotations = stripHelmAnnotations tmplAnnotations;
      cleanedTmplMeta =
        if tmplAnnotations == { } then
          tmplMeta
        else if cleanedTmplAnnotations == { } then
          builtins.removeAttrs tmplMeta [ "annotations" ]
        else
          tmplMeta // { annotations = cleanedTmplAnnotations; };
      # If cleaned metadata is empty, remove it from the template entirely.
      cleanedTmpl =
        if tmpl == null then
          null
        else if cleanedTmplMeta == { } then
          builtins.removeAttrs tmpl [ "metadata" ]
        else
          tmpl // { metadata = cleanedTmplMeta; };

      # Strip default strategy/updateStrategy that Helm charts emit but K8s
      # doesn't persist (they match the built-in defaults).
      defaultStrategy = {
        type = "RollingUpdate";
      };
      defaultUpdateStrategy = {
        rollingUpdate = {
          partition = 0;
        };
      };
      specAfterTemplate = if tmpl == null then spec else spec // { template = cleanedTmpl; };
      specAfterStrategy =
        if (specAfterTemplate.strategy or null) == defaultStrategy then
          builtins.removeAttrs specAfterTemplate [ "strategy" ]
        else
          specAfterTemplate;
      specAfterUpdateStrategy =
        if (specAfterStrategy.updateStrategy or null) == defaultUpdateStrategy then
          builtins.removeAttrs specAfterStrategy [ "updateStrategy" ]
        else
          specAfterStrategy;
    in
    specAfterUpdateStrategy;

  # Standard top-level K8s manifest fields.
  standardFields = [
    "apiVersion"
    "kind"
    "metadata"
    "spec"
    "data"
    "stringData"
  ];

  # Workload kinds for the `workloads` accessor.
  workloadKinds = [
    "Deployment"
    "StatefulSet"
    "DaemonSet"
    "Job"
    "CronJob"
  ];

  # ── DAG linking helpers ──────────────────────────────────────────────
  # Infer intra-chart resource dependencies from well-known K8s patterns.
  # Returns a list of { from, to, type } edge triples.
  inferEdges =
    wrappedResources:
    let
      # Build lookup tables for efficient matching.
      byKindName = builtins.listToAttrs (
        map (r: {
          name = "${r.kind}/${r.name}";
          value = r;
        }) wrappedResources
      );

      # Helper: get raw resource data (the manifest fields) from a wrapped resource.
      # Wrapped resources store spec/data/labels etc. in their attributes.
      getSpec = r: r._spec or { };
      getLabels = r: r._labels or { };

      # 1. Workload → ServiceAccount (serviceAccountName)
      saEdges = builtins.concatMap (
        r:
        let
          spec = getSpec r;
          podSpec =
            (spec.template or { }).spec or (
              # Jobs have spec.template.spec
              if r.kind == "Job" then ((spec.template or { }).spec or { }) else { }
            );
          saName = podSpec.serviceAccountName or null;
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
      ) (builtins.filter (r: builtins.elem r.kind workloadKinds) wrappedResources);

      # 2. Workload → ConfigMap/Secret (volume mounts, envFrom)
      volumeEdges = builtins.concatMap (
        r:
        let
          spec = getSpec r;
          podSpec = ((spec.template or { }).spec or { });
          volumes = podSpec.volumes or [ ];
          # Extract ConfigMap/Secret names from volumes
          volRefs = builtins.concatMap (
            v:
            let
              cmName = (v.configMap or { }).name or null;
              secName = (v.secret or { }).secretName or null;
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
          ) volumes;
          # Extract envFrom refs from all containers
          containers = (podSpec.containers or [ ]) ++ (podSpec.initContainers or [ ]);
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
            ) (c.envFrom or [ ])
          ) containers;
        in
        volRefs ++ envFromRefs
      ) (builtins.filter (r: builtins.elem r.kind workloadKinds) wrappedResources);

      # 3. RoleBinding/ClusterRoleBinding → ServiceAccount (subjects)
      bindingEdges = builtins.concatMap (
        r:
        let
          extra = r._extra or { };
          subjects = extra.subjects or [ ];
        in
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
        ) subjects
      ) (builtins.filter (r: r.kind == "RoleBinding" || r.kind == "ClusterRoleBinding") wrappedResources);

      # 4. Service → Workload (selector label subset match)
      serviceEdges = builtins.concatMap (
        svc:
        let
          spec = getSpec svc;
          svcSelector = spec.selector or { };
          matchingWorkloads = builtins.filter (
            w:
            let
              wLabels = getLabels w;
              podLabels = ((getSpec w).template or { }).metadata.labels or wLabels;
            in
            svcSelector != { }
            && builtins.all (k: podLabels ? ${k} && podLabels.${k} == svcSelector.${k}) (
              builtins.attrNames svcSelector
            )
          ) (builtins.filter (r: builtins.elem r.kind workloadKinds) wrappedResources);
        in
        map (w: {
          from = svc;
          to = w;
          type = "selects";
        }) matchingWorkloads
      ) (builtins.filter (r: r.kind == "Service") wrappedResources);

      # 5. HPA → Workload (scaleTargetRef)
      hpaEdges = builtins.concatMap (
        r:
        let
          spec = getSpec r;
          targetRef = spec.scaleTargetRef or { };
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
      ) (builtins.filter (r: r.kind == "HorizontalPodAutoscaler") wrappedResources);

      # 6. PDB → Workload (selector match)
      pdbEdges = builtins.concatMap (
        r:
        let
          spec = getSpec r;
          pdbSelector = (spec.selector or { }).matchLabels or { };
          matchingWorkloads = builtins.filter (
            w:
            let
              podLabels = ((getSpec w).template or { }).metadata.labels or (getLabels w);
            in
            pdbSelector != { }
            && builtins.all (k: podLabels ? ${k} && podLabels.${k} == pdbSelector.${k}) (
              builtins.attrNames pdbSelector
            )
          ) (builtins.filter (r: builtins.elem r.kind workloadKinds) wrappedResources);
        in
        map (w: {
          from = r;
          to = w;
          type = "selects";
        }) matchingWorkloads
      ) (builtins.filter (r: r.kind == "PodDisruptionBudget") wrappedResources);
    in
    saEdges ++ volumeEdges ++ bindingEdges ++ serviceEdges ++ hpaEdges ++ pdbEdges;

in

rec {

  inherit isClusterScopedKind;

  # Fixed-output derivation: fetch a Helm chart from an OCI or HTTP registry.
  fetchHelmChart =
    {
      repo,
      name,
      version,
      hash,
    }:
    pkgs.stdenvNoCC.mkDerivation {
      pname = "helm-chart-${name}";
      inherit version;

      outputHashAlgo = if lib.hasPrefix "sha256-" hash then "sha256" else "sha512";
      outputHash = hash;
      outputHashMode = "flat";

      nativeBuildInputs = [ pkgs.kubernetes-helm ];

      buildCommand = ''
        export HOME=$(mktemp -d)
        if [[ "${repo}" == oci://* ]]; then
          helm pull "${repo}/${name}" --version "${version}" --destination .
        else
          helm repo add _fetchrepo "${repo}"
          helm pull "_fetchrepo/${name}" --version "${version}" --destination .
        fi
        cp *.tgz $out
      '';
    };

  # IFD derivation: runs `helm template` on a chart and produces a JSON array
  # of K8s resource objects.
  helmTemplateDerivation =
    {
      chart,
      releaseName ? "release",
      namespace ? "default",
      values ? { },
      includeCrds ? true,
      includeHooks ? true,
      extraFlags ? [ ],
    }:
    let
      valuesFile = pkgs.writeText "helm-values.json" (builtins.toJSON values);

      flagList = [
        "--namespace"
        namespace
      ]
      ++ lib.optional includeCrds "--include-crds"
      ++ lib.optional (!includeHooks) "--no-hooks"
      ++ extraFlags;

      flags = builtins.concatStringsSep " " flagList;
    in
    pkgs.runCommand "helm-template-${releaseName}"
      {
        nativeBuildInputs = [
          pkgs.kubernetes-helm
          pkgs.yq-go
        ];
      }
      ''
        export HOME=$(mktemp -d)
        helm template "${releaseName}" "${chart}" \
          --values "${valuesFile}" \
          ${flags} \
          | yq eval-all -o=json '[.]' \
          > $out
      '';

  # Wraps a single parsed JSON K8s resource into a kix resource via scope.
  wrapHelmResource =
    { scope, resource }:
    let
      kind = resource.kind or (throw "helm resource missing 'kind'");
      apiVersion = resource.apiVersion or (throw "helm resource missing 'apiVersion'");
      meta = resource.metadata or { };
      name = meta.name or (throw "helm resource missing 'metadata.name'");
      resourceNs = meta.namespace or null;

      rawAnnotations =
        let
          a = meta.annotations or { };
        in
        if a == null then { } else a;
      rawLabels =
        let
          l = meta.labels or { };
        in
        if l == null then { } else l;

      cleanedAnnotations = stripHelmAnnotations rawAnnotations;
      cleanedLabels = stripHelmLabels rawLabels;

      # Everything outside standard fields goes into `extra`.
      rawExtra = lib.filterAttrs (k: _: !(builtins.elem k standardFields)) resource;

      # Secrets default to type "Opaque" in K8s; ensure it's explicit so the
      # output matches what K8s stores.
      extra =
        if kind == "Secret" && !(rawExtra ? type) then rawExtra // { type = "Opaque"; } else rawExtra;

      # Respect the resource's original namespace when it differs from the
      # scope's namespace (e.g. kube-system services for control-plane
      # monitoring).  Cluster-scoped kinds always use scope.mkClusterResource.
      hasForeignNs = resourceNs != null && resourceNs != scope.namespaceName;
      effectiveScope = if hasForeignNs then scope.forNamespace resourceNs else scope;
      mkFn = if isClusterScopedKind kind then scope.mkClusterResource else effectiveScope.mkResource;
    in
    mkFn (
      {
        inherit apiVersion kind name;
      }
      // lib.optionalAttrs (cleanedAnnotations != { }) { annotations = cleanedAnnotations; }
      // lib.optionalAttrs (cleanedLabels != { }) { labels = cleanedLabels; }
      // lib.optionalAttrs (resource ? spec) { spec = cleanSpec resource.spec; }
      // lib.optionalAttrs (resource ? data) { data = resource.data; }
      // lib.optionalAttrs (resource ? stringData) { stringData = resource.stringData; }
      // lib.optionalAttrs (extra != { }) { inherit extra; }
    );

  # ── importChart — build-time resource import ──────────────────────────
  #
  # Runs `helm template` via IFD and returns a structured resource collection.
  # Not a package. Not a package factory. A tool that packages use inside
  # their `build` function.
  #
  # See v2_discussions/87_helm_integration_v2.md §Design.
  importChart =
    {
      chart, # from fetchHelmChart (or a local path)
      scope, # the package's scope (for mkResource/mkClusterResource)
      values ? { },
      releaseName ? "release",
      namespace ? scope.namespaceName,
      includeCrds ? true,
      includeHooks ? true,
      extraFlags ? [ ],

      # Annotation/label control
      strip ? { },
      preserveAnnotationPrefixes ? [ ],

      # Pre-wrap resource patching (same as current patchResources)
      patchResources ? lib.id,
    }:
    let
      # Strip configuration with defaults.
      doStripAnnotations = strip.helmAnnotations or true;
      doStripLabels = strip.helmLabels or true;
      doStripStrategy = strip.defaultStrategy or true;

      # Custom annotation stripping that respects preserveAnnotationPrefixes.
      effectiveStripAnnotations =
        annotations:
        if !doStripAnnotations then
          annotations
        else
          lib.filterAttrs (
            k: _:
            !(isHelmAnnotation k) || builtins.any (prefix: lib.hasPrefix prefix k) preserveAnnotationPrefixes
          ) annotations;

      effectiveStripLabels = labels: if !doStripLabels then labels else stripHelmLabels labels;

      effectiveCleanSpec = spec: if doStripStrategy then cleanSpec spec else spec;

      # Wrap a single resource with the effective strip settings.
      wrapResource =
        resource:
        let
          kind = resource.kind or (throw "helm resource missing 'kind'");
          apiVersion = resource.apiVersion or (throw "helm resource missing 'apiVersion'");
          meta = resource.metadata or { };
          name = meta.name or (throw "helm resource missing 'metadata.name'");
          resourceNs = meta.namespace or null;

          rawAnnotations =
            let
              a = meta.annotations or { };
            in
            if a == null then { } else a;
          rawLabels =
            let
              l = meta.labels or { };
            in
            if l == null then { } else l;

          cleanedAnnotations = effectiveStripAnnotations rawAnnotations;
          cleanedLabels = effectiveStripLabels rawLabels;

          rawExtra = lib.filterAttrs (k: _: !(builtins.elem k standardFields)) resource;
          extra =
            if kind == "Secret" && !(rawExtra ? type) then rawExtra // { type = "Opaque"; } else rawExtra;

          hasForeignNs = resourceNs != null && resourceNs != scope.namespaceName;
          effectiveScope = if hasForeignNs then scope.forNamespace resourceNs else scope;
          mkFn = if isClusterScopedKind kind then scope.mkClusterResource else effectiveScope.mkResource;
        in
        mkFn (
          {
            inherit apiVersion kind name;
          }
          // lib.optionalAttrs (cleanedAnnotations != { }) { annotations = cleanedAnnotations; }
          // lib.optionalAttrs (cleanedLabels != { }) { labels = cleanedLabels; }
          // lib.optionalAttrs (resource ? spec) { spec = effectiveCleanSpec resource.spec; }
          // lib.optionalAttrs (resource ? data) { data = resource.data; }
          // lib.optionalAttrs (resource ? stringData) { stringData = resource.stringData; }
          // lib.optionalAttrs (extra != { }) { inherit extra; }
        );

      # ── Helm template + parse + filter + wrap ────────────────────────
      templateDrv = helmTemplateDerivation {
        inherit
          chart
          releaseName
          namespace
          values
          includeCrds
          includeHooks
          extraFlags
          ;
      };

      rawResources = builtins.fromJSON (builtins.readFile templateDrv);

      # Filter out Helm test hooks.
      isTestHook =
        r:
        let
          annotations = (r.metadata or { }).annotations or { };
          hookVal = annotations."helm.sh/hook" or "";
        in
        lib.hasInfix "test" hookVal;

      # Unpack List resources.
      expandedResources = builtins.concatMap (
        r:
        if
          r != null && builtins.isAttrs r && (r.kind or "") == "List" && builtins.isList (r.items or null)
        then
          r.items
        else
          [ r ]
      ) rawResources;

      # Filter out null/empty documents and test hooks.
      filteredResources = builtins.filter (
        r:
        r != null
        && builtins.isAttrs r
        && r != { }
        && r ? kind
        && r ? metadata
        && builtins.isAttrs r.metadata
        && r.metadata ? name
        && !(isTestHook r)
      ) expandedResources;

      # Apply user-provided patches to raw resources before wrapping.
      patchedResources = patchResources filteredResources;

      # Wrap each resource.
      wrappedResources = map wrapResource patchedResources;

      # ── DAG linking ────────────────────────────────────────────────
      edges = inferEdges wrappedResources;

      # Build a map from resource outPath to its inferred dependencies.
      depsMap = builtins.foldl' (
        acc: edge:
        let
          key = edge.from.outPath;
          existing = acc.${key} or [ ];
        in
        acc // { ${key} = existing ++ [ edge.to ]; }
      ) { } edges;

      # ── Resource collection ────────────────────────────────────────
      resourceCollection = rec {
        # All wrapped resources as a flat list.
        all = wrappedResources;

        # Lookup by kind + name (throws if not found).
        get =
          kind: name:
          let
            matches = builtins.filter (r: r.kind == kind && r.name == name) wrappedResources;
          in
          if matches == [ ] then
            throw "importChart: no resource found with kind=${kind} name=${name} in chart ${releaseName}"
          else
            builtins.head matches;

        # Lookup by kind + name (returns null if not found).
        find =
          kind: name:
          let
            matches = builtins.filter (r: r.kind == kind && r.name == name) wrappedResources;
          in
          if matches == [ ] then null else builtins.head matches;

        # Filter by kind.
        byKind = kind: builtins.filter (r: r.kind == kind) wrappedResources;

        # All workloads (Deployment, StatefulSet, DaemonSet, Job, CronJob).
        workloads = builtins.filter (r: builtins.elem r.kind workloadKinds) wrappedResources;

        # Everything except the given resources.
        excluding =
          resources:
          let
            excludePaths = map (r: r.outPath) resources;
          in
          builtins.filter (r: !(builtins.elem r.outPath excludePaths)) wrappedResources;

        # As an attrset keyed by "${toLower kind}-${name}".
        attrs = builtins.listToAttrs (
          map (r: {
            name = "${lib.toLower r.kind}-${r.name}";
            value = r;
          }) wrappedResources
        );

        # ── DAG ──────────────────────────────────────────────────────

        # Inferred internal dependencies for a resource.
        depsOf = resource: depsMap.${resource.outPath} or [ ];

        # All link edges as { from, to, type } triples.
        inherit edges;

        # ── Root selection ────────────────────────────────────────────

        # Auto-selected root (first Service → Deployment → StatefulSet →
        # DaemonSet → first resource).
        autoRoot =
          let
            services = builtins.filter (r: r.kind == "Service") wrappedResources;
            deployments = builtins.filter (r: r.kind == "Deployment") wrappedResources;
            statefulsets = builtins.filter (r: r.kind == "StatefulSet") wrappedResources;
            daemonsets = builtins.filter (r: r.kind == "DaemonSet") wrappedResources;
          in
          if services != [ ] then
            builtins.head services
          else if deployments != [ ] then
            builtins.head deployments
          else if statefulsets != [ ] then
            builtins.head statefulsets
          else if daemonsets != [ ] then
            builtins.head daemonsets
          else if wrappedResources != [ ] then
            builtins.head wrappedResources
          else
            throw "importChart: chart ${releaseName} produced no resources";

        # ── Convenience ──────────────────────────────────────────────

        # Build a complete parts tree for simple charts.
        mkParts =
          {
            root, # the root resource (explicit — no heuristic)
            extraParts ? { }, # additional parts to merge (CRD refs, etc.)
            extraRequires ? [ ], # additional root.requires beyond chart resources
            out ? { }, # root.out (DI builders, CRD refs, etc.)
          }:
          let
            nonRootResources = builtins.filter (r: r.outPath != root.outPath) wrappedResources;

            # Order non-root resources: deps of each resource come before it.
            # For now, we pass them all as requires (flat) — the DAG edges
            # are available via `edges` for future wave ordering.
            allRequires = nonRootResources ++ extraRequires;
          in
          attrs
          // extraParts
          // {
            root = {
              resource = root;
              requires = allRequires;
            }
            // lib.optionalAttrs (out != { }) { inherit out; };
          };
      };
    in
    resourceCollection;

  # ── helmChart — Tier 1 inline convenience ───────────────────────────
  #
  # For new users or quick one-offs. Inline in the cluster definition:
  #   package = kix.helmChart { repo = "..."; name = "loki"; version = "..."; hash = "..."; };
  #
  # Returns a package function with a `values` option. Uses autoRoot.
  helmChart =
    {
      repo,
      name,
      version,
      hash,
      releaseName ? name,
      includeCrds ? true,
      strip ? { },
      patchResources ? lib.id,
    }:
    {
      scope,
      lib,
      ...
    }:
    {
      meta = {
        isHelm = true;
        inherit version;
      };

      options.values = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = { };
        description = "Helm values for the chart.";
      };

      build =
        { config, scope, ... }:
        let
          chart = fetchHelmChart {
            inherit
              repo
              name
              version
              hash
              ;
          };
          resources = importChart {
            inherit
              chart
              scope
              releaseName
              includeCrds
              strip
              patchResources
              ;
            values = config.values or { };
          };
        in
        resources.mkParts {
          root = resources.autoRoot;
        };
    };
}
