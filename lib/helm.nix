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
  ];
  helmLabelKeys = [
    "app.kubernetes.io/managed-by" # Helm sets this to "Helm"; we replace with "kix"
    "helm.sh/chart"
  ];

  isHelmAnnotation = key: builtins.any (prefix: lib.hasPrefix prefix key) helmAnnotationPrefixes;

  stripHelmAnnotations = annotations: lib.filterAttrs (k: _: !(isHelmAnnotation k)) annotations;

  stripHelmLabels = labels: lib.filterAttrs (k: _: !(builtins.elem k helmLabelKeys)) labels;

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
      includeHooks ? false,
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
      extra = lib.filterAttrs (k: _: !(builtins.elem k standardFields)) resource;

      mkFn = if isClusterScopedKind kind then scope.mkClusterResource else scope.mkResource;
    in
    mkFn (
      {
        inherit apiVersion kind name;
      }
      // lib.optionalAttrs (cleanedAnnotations != { }) { annotations = cleanedAnnotations; }
      // lib.optionalAttrs (cleanedLabels != { }) { labels = cleanedLabels; }
      // lib.optionalAttrs (resource ? spec) { spec = resource.spec; }
      // lib.optionalAttrs (resource ? data) { data = resource.data; }
      // lib.optionalAttrs (resource ? stringData) { stringData = resource.stringData; }
      // lib.optionalAttrs (extra != { }) { inherit extra; }
    );

  # Main entry point: import a Helm chart as a v2 package function.
  #
  # Returns a package function with the standard signature:
  #   { scope, config, lib }: self: { main = ...; }
  #
  # `config.values` at the cluster level deep-merges with package-level `values`.
  fromHelmChart =
    {
      chart,
      values ? { },
      releaseName ? "release",
      includeCrds ? true,
      includeHooks ? false,
      extraFlags ? [ ],
      mainSelector ? null, # { kind = "Service"; } or { kind = "Service"; name = "my-svc"; }
    }:
    {
      scope,
      config,
      lib,
    }:
    _self:
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
      ) rawResources;

      # Wrap each resource into a v2 resource.
      wrappedResources = map (
        r:
        wrapHelmResource {
          inherit scope;
          resource = r;
        }
      ) filteredResources;

      # Select the main resource.
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
      autoSelectMain =
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

      mainResource =
        if mainSelector != null then
          let
            selected = findBySelector mainSelector;
          in
          if selected != null then
            selected
          else
            throw "fromHelmChart: mainSelector ${builtins.toJSON mainSelector} matched no resources"
        else
          autoSelectMain;

      # All non-main resources become requires of main.
      nonMainResources = builtins.filter (r: r.outPath != mainResource.outPath) wrappedResources;

      # Expose each resource as a named attribute so buildCluster's
      # collectResources can find them for the registry.
      resourceAttrs = builtins.listToAttrs (
        map (r: {
          name = "${lib.toLower r.kind}-${r.name}";
          value = r;
        }) wrappedResources
      );

    in
    resourceAttrs
    // {
      main = {
        resource = mainResource;
        requires = nonMainResources;
      };
    };
}
