# Import Helm charts as kix resources through IFD.
#
# Inline use:
#     package = kix.helmChart { repo = "..."; name = "loki"; version = "..."; hash = "..."; };
#
# Package use:
#     build = { scope, ... }:
#       let resources = scope.helm.importChart { chart = ...; scope = ...; };
#       in resources.mkParts { root = resources.get "Deployment" "foo"; };
#
# `mkParts` exposes every resource through `out.byKind`. For a workload root
# selected by exactly one Service, it also promotes that Service's outputs.

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
      # Dep-derived values (e.g. `loki.out.fqdn`) carry store-path context
      # that would make this derivation depend on those manifests and
      # re-render the chart whenever a dep changes, even though helm only
      # reads the text. Context never survives the readFile after IFD anyway
      # (cross-package edges are re-established via `deps`/`networkDeps`),
      # so drop it: the render is cached purely by chart + values + flags.
      valuesFile = pkgs.writeText "helm-values.json" (
        builtins.unsafeDiscardStringContext (builtins.toJSON values)
      );

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

  # Render a chart's CRDs and wrap them as cluster-scoped resources.
  importChartCrds =
    {
      chart,
      scope,
      releaseName ? "release",
      values ? { },
    }:
    let
      drv =
        pkgs.runCommand "helm-crds-${releaseName}"
          {
            nativeBuildInputs = [
              pkgs.kubernetes-helm
              pkgs.yq-go
            ];
          }
          ''
            export HOME=$(mktemp -d)
            # `helm template --include-crds` interleaves CRDs with regular
            # resources. Filter to kind=CustomResourceDefinition only.
            valuesFile=${
              # Same context-drop as helmTemplateDerivation: cache the render
              # by values text, not by whatever manifests the values reference.
              pkgs.writeText "helm-values.json" (builtins.unsafeDiscardStringContext (builtins.toJSON values))
            }
            helm template "${releaseName}" "${chart}" \
              --values "$valuesFile" \
              --include-crds \
              --no-hooks \
              --kube-version "1.32.0" \
              | yq eval-all -o=json '[. | select(.kind == "CustomResourceDefinition")]' \
              > $out
          '';
      raw = builtins.fromJSON (builtins.readFile drv);
      crds = builtins.filter (
        r: r != null && builtins.isAttrs r && (r.kind or "") == "CustomResourceDefinition"
      ) raw;
    in
    map (
      r:
      wrapHelmResource {
        inherit scope;
        resource = r;
      }
    ) crds;

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

  # Run `helm template` through IFD and return a resource collection for use
  # inside a package's `build` function.
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

      # Annotation and label control.
      strip ? { },
      preserveAnnotationPrefixes ? [ ],

      # Applied to parsed resources before wrapping.
      patchResources ? lib.id,

      # Extra intra-chart dependency edges injected before wrapping.
      # Each element is { from = { kind; name; }; to = { kind; name; }; }
      # meaning "from depends on to" (to is deployed before from).
      # Useful when a chart has implicit runtime dependencies that the
      # DAG reconstruction can't infer from K8s manifest references.
      extraEdges ? [ ],

      # Cross-package network dependencies.
      # List of context-carrying values (e.g. loki.out.fqdn) whose
      # store-path context should be visible to the CNP generator.
      # Injected into helm workloads as _helmNetworkDeps so
      # extractServiceEdgesFromJson discovers the egress edges.
      # The DI dep must also be declared in the build function args
      # so its Services appear in _netpolServiceRegistry.
      #
      # Use this for context that auto-discovery (`deps`) misses, including
      # values nested inside `dep.out.byKind` or explicitly constructed strings
      # that don't appear at `dep.out.*`.
      networkDeps ? [ ],

      # Cross-package DI dependencies the chart's manifests reference.
      # Each entry is a dep package instance (the same value the build
      # function receives as an argument). Context-carrying strings at
      # `dep.out.*` are merged into `networkDeps`.
      deps ? [ ],
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

      # Auto-collect context-carrying string values from each DI dep's
      # top-level `out` attrs. Anything bearing Nix string context here
      # is a candidate egress edge. A chart that interpolates the
      # value (FQDN, name, host) into a manifest gives the netpol
      # generator a hook to discover the cross-package edge. Nested
      # values (e.g. `dep.out.byKind.Service.x.out.fqdn`) are NOT
      # collected; pass them via `networkDeps` if needed.
      depContextValues = builtins.concatMap (
        dep:
        let
          outAttrs = dep.out or { };
        in
        builtins.filter (v: builtins.isString v && builtins.getContext v != { }) (
          builtins.attrValues outAttrs
        )
      ) deps;

      effectiveNetworkDeps = networkDeps ++ depContextValues;

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
          # self-ingress for StatefulSets). It runs the pod-spec validators
          # mkDeployment/mkStatefulSet/mkDaemonSet run, except the reference
          # check that expects DI-tracked names (helm manifests have none).
          isWorkload = builtins.elem kind [
            "Deployment"
            "StatefulSet"
            "DaemonSet"
            "Job"
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
          // lib.optionalAttrs (isWorkload && effectiveNetworkDeps != [ ]) {
            _helmNetworkDeps = effectiveNetworkDeps;
          }
        );

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

      # Infer edges between raw resources, then wrap each resource with
      # its inferred dependencies as `requires`. Uses Nix laziness:
      # wrappedResources references itself through indexByRawId, but
      # each element only forces its dependencies (no cycles in K8s
      # resource graphs).
      inferredEdges = helmDag.inferEdges patchedResources;

      # Resolve user-supplied extraEdges to raw resource references.
      rawByKindName = builtins.listToAttrs (
        map (r: {
          name = helmDag.resourceId r;
          value = r;
        }) patchedResources
      );
      resolvedExtraEdges = map (
        e:
        let
          fromId = "${e.from.kind}/${e.from.name}";
          toId = "${e.to.kind}/${e.to.name}";
        in
        assert
          rawByKindName ? ${fromId}
          || throw "importChart: extraEdges: no resource ${fromId} in chart ${releaseName}";
        assert
          rawByKindName ? ${toId}
          || throw "importChart: extraEdges: no resource ${toId} in chart ${releaseName}";
        {
          from = rawByKindName.${fromId};
          to = rawByKindName.${toId};
          type = "extra";
        }
      ) extraEdges;

      rawEdges = inferredEdges ++ resolvedExtraEdges;
      rawDepsMap = helmDag.buildDepsMap rawEdges;

      # Map each rawId to its position in patchedResources.
      indexByRawId = builtins.listToAttrs (
        lib.imap0 (i: raw: {
          name = helmDag.resourceId raw;
          value = i;
        }) patchedResources
      );

      # Wrap each resource with its DAG-inferred requires.
      # Lazy self-reference: each element looks up its deps in wrappedResources
      # by index. Safe because K8s resource deps are acyclic.
      wrappedResources = map (
        raw:
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

      # Built recursively to support `replaceResource`: substituting a
      # chart resource with a kix-native one returns a new collection
      # with the swap applied to all lookups, mkParts, and DAG-aware
      # operations.
      mkResourceCollection =
        replacements:
        let
          # `replacements` is an attrset keyed by "Kind/name", where each
          # value is the substitute kix resource.
          isReplacedKey = key: replacements ? ${key};
          isReplaced = r: isReplacedKey "${r.kind}/${r.name}";

          effectiveResources =
            (builtins.filter (r: !(isReplaced r)) wrappedResources) ++ (builtins.attrValues replacements);

          # Edges where neither endpoint has been replaced form the chart-internal
          # DAG that the substitution preserves untouched. Edges touching a
          # replaced resource are dropped; the caller must wire the new
          # resource's `requires` themselves.
          effectiveEdges = builtins.filter (e: !(isReplaced e.from) && !(isReplaced e.to)) wrappedEdges;

          effectiveDepsMap = builtins.foldl' (
            acc: edge:
            let
              key = edge.from.outPath;
              existing = acc.${key} or [ ];
            in
            acc // { ${key} = existing ++ [ edge.to ]; }
          ) { } effectiveEdges;

          effectiveDepTargetIds = lib.unique (map (e: "${e.to.kind}/${e.to.name}") effectiveEdges);

          # For every CustomResourceDefinition the chart ships, emit a
          # builder pair { cr, mkCR } so consumer packages can construct
          # CRs from the chart's declarations. The builder adds the CRD and every
          # chart workload to `requires`, so a consumer CR waits for:
          #   1. the CRD being Established, and
          #   2. every controller workload being Ready (any of them
          #      could be the admission/conversion webhook).
          chartCrds = builtins.filter (r: r.kind == "CustomResourceDefinition") effectiveResources;

          chartWorkloads = builtins.filter (r: builtins.elem r.kind helmDag.workloadKinds) effectiveResources;

          mkCrdBuilder =
            crdRes:
            let
              spec = crdRes.rawManifest.spec or { };
              group = spec.group or null;
              crKind = spec.names.kind or null;
              crdScope = spec.scope or "Namespaced";
              versions = spec.versions or [ ];
              storage = builtins.filter (v: (v.storage or false) == true) versions;
              version =
                if storage != [ ] then
                  (builtins.head storage).name
                else if versions != [ ] then
                  (builtins.head versions).name
                else
                  null;
            in
            if group == null || crKind == null || version == null then
              null
            else
              let
                crApiVersion = "${group}/${version}";
                cr =
                  args:
                  args
                  // {
                    apiVersion = crApiVersion;
                    kind = crKind;
                    requires = (args.requires or [ ]) ++ [ crdRes ] ++ chartWorkloads;
                  };
                mkCR =
                  consumerScope: args:
                  let
                    enriched = cr args;
                  in
                  if crdScope == "Cluster" then
                    consumerScope.mkClusterResource enriched
                  else
                    consumerScope.mkResource enriched;
              in
              {
                inherit cr mkCR;
              };

          crdBuilders = builtins.foldl' (
            acc: crdRes:
            let
              builder = mkCrdBuilder crdRes;
              kindName = crdRes.rawManifest.spec.names.kind or null;
            in
            if builder == null || kindName == null then acc else acc // { ${kindName} = builder; }
          ) { } chartCrds;
        in
        rec {
          # All effective resources as a flat list.
          all = effectiveResources;

          # Lookup by kind + name (throws if not found).
          get =
            kind: name:
            let
              matches = builtins.filter (r: r.kind == kind && r.name == name) effectiveResources;
            in
            if matches == [ ] then
              throw "importChart: no resource found with kind=${kind} name=${name} in chart ${releaseName}"
            else
              builtins.head matches;

          # Lookup by kind + name (returns null if not found).
          find =
            kind: name:
            let
              matches = builtins.filter (r: r.kind == kind && r.name == name) effectiveResources;
            in
            if matches == [ ] then null else builtins.head matches;

          # Filter by kind.
          byKind = kind: builtins.filter (r: r.kind == kind) effectiveResources;

          # All workloads (Deployment, StatefulSet, DaemonSet, Job, CronJob).
          workloads = builtins.filter (r: builtins.elem r.kind helmDag.workloadKinds) effectiveResources;

          # Everything except the given resources.
          excluding =
            resources:
            let
              excludePaths = map (r: r.outPath) resources;
            in
            builtins.filter (r: !(builtins.elem r.outPath excludePaths)) effectiveResources;

          # As an attrset keyed by "${toLower kind}-${name}".
          attrs = builtins.listToAttrs (
            map (r: {
              name = "${lib.toLower r.kind}-${r.name}";
              value = r;
            }) effectiveResources
          );

          # Inferred internal dependencies for a wrapped resource.
          # Returns [] for replacement resources; the caller is
          # responsible for setting the new resource's own `requires`.
          depsOf = resource: effectiveDepsMap.${resource.outPath} or [ ];

          # All link edges as { from, to, type } triples (wrapped resources).
          edges = effectiveEdges;

          # Auto-derived `{ cr, mkCR }` builder pair for every CRD the
          # chart ships, keyed by CR kind. See mkCrdBuilder above.
          crds = crdBuilders;

          # Replace a chart resource with a kix-native one, returning a
          # new collection. Build the replacement first, then substitute it.
          #
          # DAG edges into the original are dropped; the
          # replacement must declare its own `requires` if it needs to
          # wait for chart resources to come up. For leaf resources
          # (Ingress, ServiceMonitor, etc.) this is usually nothing.
          #
          # Edges OUT of the original (resources the original depended
          # on) are still in the chart DAG via `mkParts`'s
          # `dagRootRequires`, so the replacement does not need to thread
          # them through.
          replaceResource =
            kind: name: newResource:
            let
              key = "${kind}/${name}";
            in
            if !(builtins.any (r: r.kind == kind && r.name == name) wrappedResources) then
              throw "importChart: replaceResource: no resource ${key} in chart ${releaseName}"
            else
              mkResourceCollection (replacements // { ${key} = newResource; });

          # Select the first Service, Deployment, StatefulSet, DaemonSet, or
          # other resource, in that order.
          autoRoot =
            let
              services = builtins.filter (r: r.kind == "Service") effectiveResources;
              deployments = builtins.filter (r: r.kind == "Deployment") effectiveResources;
              statefulsets = builtins.filter (r: r.kind == "StatefulSet") effectiveResources;
              daemonsets = builtins.filter (r: r.kind == "DaemonSet") effectiveResources;
            in
            if services != [ ] then
              builtins.head services
            else if deployments != [ ] then
              builtins.head deployments
            else if statefulsets != [ ] then
              builtins.head statefulsets
            else if daemonsets != [ ] then
              builtins.head daemonsets
            else if effectiveResources != [ ] then
              builtins.head effectiveResources
            else
              throw "importChart: chart ${releaseName} produced no resources";

          # Build a complete parts tree for simple charts.
          #
          # The root directly requires DAG entry points; their dependencies
          # remain reachable through each resource's `requires`.
          # `out.byKind` contains every wrapped resource. A unique Service
          # selecting a workload root contributes its public outputs. CRD
          # builders appear under `out.crds`. Explicit `out` values win.
          mkParts =
            {
              root, # Explicit root resource.
              extraParts ? { }, # additional parts to merge (CRD refs, etc.)
              extraRequires ? [ ], # additional root.requires beyond chart resources
              out ? { }, # root.out overrides (DI builders, CRD refs, etc.)
            }:
            let
              # Non-root resources that no other chart resource depends on.
              # The root directly requires these DAG entry points; the rest follows
              # in transitively.
              dagRootRequires = builtins.filter (
                r: r.outPath != root.outPath && !(builtins.elem "${r.kind}/${r.name}" effectiveDepTargetIds)
              ) effectiveResources;

              allRequires = dagRootRequires ++ extraRequires;

              # byKind.<Kind>.<name> = wrapped resource.
              byKindLookup = builtins.foldl' (
                acc: r:
                acc
                // {
                  ${r.kind} = (acc.${r.kind} or { }) // {
                    ${r.name} = r;
                  };
                }
              ) { } effectiveResources;

              # Services that select this workload root, via the existing
              # DAG `selects` edges. For Service roots, this is empty
              # (k8s.mkResource already produced the right outs on root).
              matchingServices =
                if helmDag.isWorkloadKind root.kind then
                  map (e: e.from) (
                    builtins.filter (
                      e: e.type == "selects" && e.from.kind == "Service" && e.to.outPath == root.outPath
                    ) effectiveEdges
                  )
                else
                  [ ];

              # Promote a unique matching Service's outs onto a workload
              # root. Skipped when 0 or >1 Services match (caller should
              # override via the explicit `out` arg).
              promotedServiceOut =
                if root.kind == "Service" then
                  { }
                else if builtins.length matchingServices == 1 then
                  builtins.intersectAttrs {
                    name = null;
                    fqdn = null;
                    selector = null;
                    ports = null;
                    url = null;
                  } (builtins.head matchingServices).out
                else
                  { };

              autoOut =
                promotedServiceOut
                // {
                  byKind = byKindLookup;
                }
                // lib.optionalAttrs (crdBuilders != { }) {
                  crds = crdBuilders;
                };

              effectiveOut = autoOut // out;
            in
            attrs
            // extraParts
            // {
              root = {
                resource = root;
                requires = allRequires;
                out = effectiveOut;
              };
            };
        };

      resourceCollection = mkResourceCollection { };
    in
    resourceCollection;

  # Define a chart inline in the cluster definition:
  #   package = kix.helmChart { repo = "..."; name = "loki"; version = "..."; hash = "..."; };
  #
  # Returns a package function with a `values` option and an automatic root.
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
      # Extra meta merged over the defaults, e.g. `metaExtra.unsafe =
      # [ "raw-pvc" ]` for charts that render their own PVCs.
      metaExtra ? { },
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
      }
      // metaExtra;

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
