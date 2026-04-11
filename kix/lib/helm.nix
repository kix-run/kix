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
  helmDag = import ./helm-dag.nix { inherit lib; };

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

      # Cross-package network dependencies.
      # List of context-carrying values (e.g. loki.out.fqdn) whose
      # store-path context should be visible to the CNP generator.
      # Injected into helm workloads as _helmNetworkDeps so
      # extractServiceEdgesFromJson discovers the egress edges.
      # The DI dep must also be declared in the build function args
      # so its Services appear in _netpolServiceRegistry.
      networkDeps ? [ ],
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
      # `requires` is a list of already-wrapped resources this resource depends on
      # (inferred from the DAG reconstruction pass).
      wrapResource =
        {
          resource,
          requires ? [ ],
        }:
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

          # Workload kinds route through scope.mkHelmWorkload for per-workload
          # CNP generation (DNS egress, cross-package service egress,
          # self-ingress for StatefulSets). This skips the validation checks
          # that mkDeployment/mkStatefulSet/mkDaemonSet perform (those checks
          # expect DI-tracked references which helm manifests don't have).
          isWorkload = builtins.elem kind [
            "Deployment"
            "StatefulSet"
            "DaemonSet"
          ];
          mkFn =
            if isClusterScopedKind kind then
              scope.mkClusterResource
            else if isWorkload then
              effectiveScope.mkHelmWorkload
            else
              effectiveScope.mkResource;

          commonArgs = {
            inherit apiVersion kind name;
          }
          // lib.optionalAttrs (requires != [ ]) { inherit requires; }
          // lib.optionalAttrs (cleanedAnnotations != { }) { annotations = cleanedAnnotations; }
          // lib.optionalAttrs (cleanedLabels != { }) { labels = cleanedLabels; }
          // lib.optionalAttrs (resource ? spec) { spec = effectiveCleanSpec resource.spec; }
          // lib.optionalAttrs (resource ? data) { data = resource.data; }
          // lib.optionalAttrs (resource ? stringData) { stringData = resource.stringData; }
          // lib.optionalAttrs (extra != { }) { inherit extra; };
        in
        mkFn (
          commonArgs
          # Inject cross-package network deps so their store-path context
          # appears in the workload JSON, making extractServiceEdgesFromJson
          # discover the egress edges.
          // lib.optionalAttrs (isWorkload && networkDeps != [ ]) {
            _helmNetworkDeps = networkDeps;
          }
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

      # ── DAG reconstruction (from raw JSON, before wrapping) ────────
      #
      # Infer edges between raw resources, then wrap each resource with
      # its inferred dependencies as `requires`. Uses Nix laziness:
      # wrappedResources references itself through indexByRawId, but
      # each element only forces its dependencies (no cycles in K8s
      # resource graphs).
      rawEdges = helmDag.inferEdges patchedResources;
      rawDepsMap = helmDag.buildDepsMap rawEdges;

      # Index: rawId → position in patchedResources list.
      indexByRawId = builtins.listToAttrs (
        lib.imap0 (i: raw: {
          name = helmDag.resourceId raw;
          value = i;
        }) patchedResources
      );

      # Wrap each resource with its DAG-inferred requires.
      # Lazy self-reference: element i looks up its deps in wrappedResources
      # by index. Safe because K8s resource deps are acyclic.
      wrappedResources = lib.imap0 (
        i: raw:
        let
          rawId = helmDag.resourceId raw;
          depIds = rawDepsMap.${rawId} or [ ];
          requires = builtins.concatMap (
            depId:
            if indexByRawId ? ${depId} then
              [ (builtins.elemAt wrappedResources indexByRawId.${depId}) ]
            else
              [ ] # dep not in chart (external reference)
          ) depIds;
        in
        wrapResource {
          resource = raw;
          inherit requires;
        }
      ) patchedResources;

      # Map raw edges to wrapped resource edges for the collection API.
      wrappedEdges = builtins.concatMap (
        e:
        let
          fromId = helmDag.resourceId e.from;
          toId = helmDag.resourceId e.to;
        in
        if indexByRawId ? ${fromId} && indexByRawId ? ${toId} then
          [
            {
              from = builtins.elemAt wrappedResources indexByRawId.${fromId};
              to = builtins.elemAt wrappedResources indexByRawId.${toId};
              inherit (e) type;
            }
          ]
        else
          [ ]
      ) rawEdges;

      # Build a map from wrapped resource outPath to its inferred deps.
      depsMap = builtins.foldl' (
        acc: edge:
        let
          key = edge.from.outPath;
          existing = acc.${key} or [ ];
        in
        acc // { ${key} = existing ++ [ edge.to ]; }
      ) { } wrappedEdges;

      # ResourceIds that are targets of edges — reachable through the DAG,
      # so root doesn't need to directly require them.
      depTargetIds = helmDag.dependedOnIds rawEdges;

      # Diagnostics: detect orphan selectors/refs.
      orphans = helmDag.findOrphans patchedResources rawEdges;

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
        workloads = builtins.filter (r: builtins.elem r.kind helmDag.workloadKinds) wrappedResources;

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

        # Inferred internal dependencies for a wrapped resource.
        depsOf = resource: depsMap.${resource.outPath} or [ ];

        # All link edges as { from, to, type } triples (wrapped resources).
        edges = wrappedEdges;

        # Diagnostic orphans (selectors/refs matching nothing in chart).
        inherit orphans;

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
        #
        # DAG-aware: root only directly requires resources that are NOT
        # targets of intra-chart edges. Everything else is reachable
        # through the DAG (each resource carries its own `requires`
        # in kix.dev/depends-on). This gives the same forward-closure
        # behavior as native kix packages.
        mkParts =
          {
            root, # the root resource (explicit — no heuristic)
            extraParts ? { }, # additional parts to merge (CRD refs, etc.)
            extraRequires ? [ ], # additional root.requires beyond chart resources
            out ? { }, # root.out (DI builders, CRD refs, etc.)
          }:
          let
            # Non-root resources that are NOT depended on by other chart
            # resources. These are the DAG "entry points" that root must
            # directly require — everything else is pulled in transitively.
            dagRootRequires = builtins.filter (
              r: r.outPath != root.outPath && !(builtins.elem "${r.kind}/${r.name}" depTargetIds)
            ) wrappedResources;

            allRequires = dagRootRequires ++ extraRequires;
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
