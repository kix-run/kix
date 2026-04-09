# Helm chart bridge — imports Helm charts as v2 packages via IFD.
#
# This is intentionally separate from the pure v2 lib (which takes only `lib`).
# helm.nix requires `pkgs` for derivations (helm, yq, fetchurl, runCommand).
#
# Usage:
#   kixHelm = import ./lib/v2/helm.nix { inherit pkgs lib; };
#   packages.postgresql = kixHelm.fromHelmChart { chart = ...; values = { ... }; };

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

in

rec {

  inherit isClusterScopedKind;

  # Fixed-output derivation: fetch a Helm chart from an OCI or HTTP registry.
  #
  # For OCI registries (e.g., oci://registry-1.docker.io/bitnamicharts):
  #   fetchHelmChart { repo = "oci://..."; name = "postgresql"; version = "12.5.6"; hash = "sha256-..."; }
  #
  # Returns a .tgz chart archive.
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

  # Wraps a single parsed JSON K8s resource into a v2 resource via scope.
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

  # Main entry point: import a Helm chart as a v2 package function.
  #
  # Returns a package function with the standard { options, build } signature.
  # `config.values` at the cluster level deep-merges with package-level `values`.
  fromHelmChart =
    {
      chart,
      values ? { },
      releaseName ? "release",
      includeCrds ? true,
      includeHooks ? true,
      extraFlags ? [ ],
      rootSelector ? null, # { kind = "Service"; } or { kind = "Service"; name = "my-svc"; }
      version ? chart.version or null, # Auto-extracted from fetchHelmChart derivation
      patchResources ? lib.id, # Function applied to the list of raw JSON resources before wrapping
      # Extra meta merged into the auto-generated `meta` (`isHelm`, `version`).
      # Use this to declare `provides` / `defaultAliases` for Helm-wrapped
      # packages that participate in DI as capability owners.
      extraMeta ? { },
      # Builders exposed through `root.out`. This is how Helm-wrapped
      # packages contribute DI builders (e.g. `reflector.out.reflectSecret`).
      # The function receives `{ scope, lib, self, config, clusterConfig }`
      # and must return an attrset; that attrset becomes `root.out`.
      # Consumers call these builders passing their own `scope` so the
      # emitted resources are owned by the consumer namespace.
      rootOut ? null,
    }:
    {
      scope,
      lib,
    }:
    {
      meta = {
        isHelm = true;
      }
      // lib.optionalAttrs (version != null) { inherit version; }
      // extraMeta;

      options = {
        values = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = { };
          description = "Helm values to deep-merge with the chart's package-level values.";
        };
      };

      build =
        {
          self,
          config,
          clusterConfig,
        }:
        let
          # Deep-merge package-level values with cluster-level config.values.
          mergedValues = lib.recursiveUpdate values (config.values or { });

          # IFD: build the helm template derivation and import the JSON result.
          templateDrv = helmTemplateDerivation {
            inherit
              chart
              releaseName
              includeCrds
              includeHooks
              extraFlags
              ;
            namespace = scope.namespaceName;
            values = mergedValues;
          };

          # Import the JSON array of resources (this is the IFD step).
          rawResources = builtins.fromJSON (builtins.readFile templateDrv);

          # Filter out Helm test hooks.
          isTestHook =
            r:
            let
              annotations = (r.metadata or { }).annotations or { };
              hookVal = annotations."helm.sh/hook" or "";
            in
            lib.hasInfix "test" hookVal;

          # Unpack List resources (helm templates can bundle multiple resources
          # into a single kind:List document, e.g. additionalPrometheusRules,
          # additionalServiceMonitors).
          expandedResources = builtins.concatMap (
            r:
            if
              r != null && builtins.isAttrs r && (r.kind or "") == "List" && builtins.isList (r.items or null)
            then
              r.items
            else
              [ r ]
          ) rawResources;

          # Filter out null/empty documents (helm template can emit empty YAML docs).
          # Also filter resources missing required fields (kind, metadata.name).
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

          # Wrap each resource into a v2 resource.
          wrappedResources = map (
            r:
            wrapHelmResource {
              inherit scope;
              resource = r;
            }
          ) patchedResources;

          # Select the root resource.
          findBySelector =
            selector:
            let
              matches = builtins.filter (
                r:
                (!(selector ? kind) || r.kind == selector.kind) && (!(selector ? name) || r.name == selector.name)
              ) wrappedResources;
            in
            if matches == [ ] then null else builtins.head matches;

          # Auto-select: first Service, then first Deployment, then first resource.
          autoSelectRoot =
            let
              services = builtins.filter (r: r.kind == "Service") wrappedResources;
              deployments = builtins.filter (r: r.kind == "Deployment") wrappedResources;
              statefulsets = builtins.filter (r: r.kind == "StatefulSet") wrappedResources;
            in
            if services != [ ] then
              builtins.head services
            else if deployments != [ ] then
              builtins.head deployments
            else if statefulsets != [ ] then
              builtins.head statefulsets
            else if wrappedResources != [ ] then
              builtins.head wrappedResources
            else
              throw "fromHelmChart: chart produced no resources";

          rootResource =
            if rootSelector != null then
              let
                selected = findBySelector rootSelector;
              in
              if selected != null then
                selected
              else
                throw "fromHelmChart: rootSelector ${builtins.toJSON rootSelector} matched no resources"
            else
              autoSelectRoot;

          # All non-root resources become requires of root.
          nonRootResources = builtins.filter (r: r.outPath != rootResource.outPath) wrappedResources;

          # Every workload emitted by the chart. Exposed to `rootOut` so
          # packages that install CRDs via `mkCRDRef { installedBy = ...; }`
          # can gate their CR consumers on *all* chart workloads being Ready,
          # not just the single hand-picked root.
          #
          # Motivation: for helm-bundled operators (cilium, cert-manager, etc.)
          # the CRDs are served by webhooks that live in more than one workload
          # — e.g. cilium's CNP validating webhook runs in `cilium-operator`,
          # while the datapath lives in the `cilium` DaemonSet. Gating only on
          # `self.root.resource` leaves the operator Deployment in the same
          # wave as every other non-root helm resource, so its readiness is
          # checked *once* at that wave boundary and never re-gated when the
          # CR wave lands two waves later. Listing every workload in the CRD
          # marker's `installedBy` adds direct marker → workload edges, which
          # forces the wave engine to treat each workload as a hard dependency
          # of the marker and re-observe their readiness at the marker's own
          # wave boundary.
          workloadKinds = [
            "Deployment"
            "StatefulSet"
            "DaemonSet"
          ];
          helmWorkloads = builtins.filter (r: builtins.elem r.kind workloadKinds) wrappedResources;

          # Expose each resource as a named attribute so buildCluster's
          # collectResources can find them for the registry.
          resourceAttrs = builtins.listToAttrs (
            map (r: {
              name = "${lib.toLower r.kind}-${r.name}";
              value = r;
            }) wrappedResources
          );

          # Evaluate rootOut once so we can both (a) install it as `root.out`
          # and (b) surface any k8s-resources it produced at the top level of
          # parts. Helm-wrapped packages that expose CRD/secret ref markers
          # via rootOut (e.g. cilium's `cnpCrdRef`) need those marker resources
          # to land in parts so cluster.nix's `collectResources` picks them up
          # — it walks everything except the `root` key, so a marker living
          # only under `root.out` is invisible to the plan and the CNPs that
          # `requires` it end up with a phantom store-path edge.
          #
          # `workloads` is passed in addition to `self` so `rootOut` can wire
          # CRD refs against every chart workload without having to re-walk
          # `self`'s parts tree by hand.
          rootOutAttrs =
            if rootOut != null then
              rootOut {
                inherit
                  scope
                  lib
                  self
                  config
                  clusterConfig
                  ;
                workloads = helmWorkloads;
              }
            else
              { };

          # Pick up any k8s-resource valued attrs from rootOut and expose them
          # as sibling parts. Functions / plain attrsets (reflector-style
          # builders) are ignored.
          rootOutResourceParts = lib.filterAttrs (_: v: (v._type or "") == "k8s-resource") rootOutAttrs;
        in
        resourceAttrs
        // rootOutResourceParts
        // {
          root = {
            resource = rootResource;
            requires = nonRootResources;
          }
          // lib.optionalAttrs (rootOut != null) {
            out = rootOutAttrs;
          };
        };
    };
}
