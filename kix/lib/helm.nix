# Import Helm charts as Kix resources.
#
# Inline use:
#     package = kix.helmChart { repo = "..."; name = "loki"; version = "..."; hash = "..."; };
#   The root is the chart's only Service, else its only workload. For a
#   chart with several, name it: `root = { kind = "Service"; name = "loki"; };`.
#
# Package use:
#     build = { scope, ... }:
#       let resources = scope.helm.importChart { chart = ...; scope = ...; };
#       in resources.mkParts { root = resources.get "Deployment" "foo"; };
#
# `mkParts` exposes every resource through `out.byKind`. For a workload root
# selected by exactly one Service, it also promotes that Service's outputs.
#
# A chart fetch and a chart render take one of two routes, chosen by
# `helmRoute`:
#
# - "placeholder" (the `kix` builder): Nix does not run Helm. A fetch and a
#   render are placeholder derivations of system `kix-helm`, which no Nix
#   machine can build. The `kix` command reads each one whose output
#   evaluation needs, runs the Helm release its spec names, writes the output
#   into Kix's own store, and evaluates again.
# - "nix" (the `nix` builder): a fetch and a render are ordinary derivations
#   that run the same Helm release, and evaluation reads their output through
#   import from derivation.
#
# Both routes build the Helm command line from the same spec, and a chart
# fetch has the same store path under both.

{
  lib,
  # The nixpkgs package set. Only the "nix" route uses it.
  pkgs ? null,
  # "placeholder" or "nix", as described above.
  helmRoute ? "placeholder",
  # Return the resource list a render derivation's output holds. Tests
  # replace it to evaluate a chart import without running Helm.
  readRender ? drv: builtins.fromJSON (builtins.readFile drv),
}:

assert lib.assertOneOf "helmRoute" helmRoute [
  "placeholder"
  "nix"
];

let
  inherit (import ./core/error.nix { inherit lib; }) fail;
  k8s = import ./core { inherit lib; };
  helmDag = import ./helm-dag.nix { inherit lib; };

  helmVersions = lib.importJSON ./helm-versions.json;

  # The exact Helm release Kix runs for each major version it ships. The kix
  # binary of the same release ships these, and refuses a spec that names a
  # release it does not ship.
  helmReleases = lib.mapAttrs (_: release: release.version) helmVersions;

  helmMajors = lib.sort (a: b: lib.toInt a < lib.toInt b) (builtins.attrNames helmReleases);

  newestHelmMajor = lib.last helmMajors;

  # Return the exact Helm release Kix renders with for the major `helmVersion`.
  helmRelease =
    helmVersion:
    helmReleases.${toString helmVersion} or (fail {
      message = "Helm ${toString helmVersion} is not supported.";
      fix = "Set `helmVersion` to ${lib.concatStringsSep " or " helmMajors}.";
    });

  nixPkgs =
    if pkgs == null then
      fail {
        message = "The nix Helm route needs `pkgs`.";
        fix = "Pass the nixpkgs package set as `pkgs` when you import the Kix library with helmRoute = \"nix\".";
      }
    else
      pkgs;

  # The name of Helm's release archive for each Nix system.
  helmPlatforms = {
    x86_64-linux = "linux-amd64";
    aarch64-linux = "linux-arm64";
    x86_64-darwin = "darwin-amd64";
    aarch64-darwin = "darwin-arm64";
  };

  # Return the official Helm build of major `helmVersion` for the system
  # `pkgs` builds for, from the archive and hash helm-versions.json names.
  # The Kix runtime ships the same builds.
  helmPackage =
    helmVersion:
    let
      release = builtins.seq (helmRelease helmVersion) helmVersions.${toString helmVersion};
      system = nixPkgs.stdenv.hostPlatform.system;
      platform =
        helmPlatforms.${system} or (fail {
          message = "Helm is supported on ${lib.concatStringsSep ", " (builtins.attrNames helmPlatforms)}, not ${system}.";
          fix = "Build this project on one of those systems.";
        });
      tarball = nixPkgs.fetchurl {
        url = "https://get.helm.sh/helm-v${release.version}-${platform}.tar.gz";
        sha256 =
          release.sha256.${system}
            or (fail "kix/lib/helm-versions.json has no hash for Helm ${release.version} on ${system}.");
      };
    in
    nixPkgs.runCommand "helm-${release.version}" { } ''
      mkdir -p $out/bin unpacked
      tar -xzf ${tarball} -C unpacked --strip-components=1
      install -m755 unpacked/helm $out/bin/helm
    '';

  # Set up an empty Helm home, so no user setting or repository changes what
  # Helm does. The CLI gives Helm the same environment.
  helmHome = ''
    export HOME="$(mktemp -d)"
    export HELM_CACHE_HOME="$HOME/cache"
    export HELM_CONFIG_HOME="$HOME/config"
    export HELM_DATA_HOME="$HOME/data"
  '';

  helpers = import ./eval/helpers.nix { inherit lib; };

  # Return true when kind is cluster-scoped and rendered with no namespace.
  isClusterScopedKind = kind: builtins.elem kind helpers.builtInClusterScopedKinds;

  helmAnnotationPrefixes = [
    "meta.helm.sh/"
    "helm.sh/"
    "checksum/"
  ];
  helmLabelKeys = [
    "app.kubernetes.io/managed-by" # Replaced with "kix" by Kix resource builders.
    "helm.sh/chart"
  ];

  isHelmAnnotation = key: builtins.any (prefix: lib.hasPrefix prefix key) helmAnnotationPrefixes;

  stripHelmAnnotations = annotations: lib.filterAttrs (k: _: !(isHelmAnnotation k)) annotations;

  stripHelmLabels = labels: lib.filterAttrs (k: _: !(builtins.elem k helmLabelKeys)) labels;

  # Strip Helm-injected pod template annotations and server-default rollout
  # strategies that Kubernetes does not persist.
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
      cleanedTmpl =
        if tmpl == null then
          null
        else if cleanedTmplMeta == { } then
          builtins.removeAttrs tmpl [ "metadata" ]
        else
          tmpl // { metadata = cleanedTmplMeta; };

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

  # A Job that Kubernetes deletes after it finishes looks missing to every
  # comparison with the live cluster, which would run it again. A chart's
  # TTL serves Helm's hook lifecycle, which Kix does not run: a finished Job
  # stays until a later build drops it.
  stripJobTtl =
    kind: spec: if kind == "Job" then builtins.removeAttrs spec [ "ttlSecondsAfterFinished" ] else spec;

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

  # Fetch a Helm chart from an OCI or HTTP registry. The result is a
  # fixed-output derivation, so Nix computes its path from `hash` and the
  # name alone, and the path is the same under both routes. Under the
  # placeholder route, `kix` pulls the chart with the newest Helm it ships,
  # checks the hash, and adds the file at that path. Under the nix route, the
  # derivation runs the same `helm pull`.
  fetchHelmChart =
    {
      repo,
      name,
      version,
      hash,
    }:
    let
      spec = fetchSpec { inherit repo name version; };
      fixedOutput = {
        name = "helm-chart-${name}-${version}";
        outputHashAlgo = if lib.hasPrefix "sha256-" hash then "sha256" else "sha512";
        outputHash = hash;
        outputHashMode = "flat";
      };
    in
    if helmRoute == "nix" then
      nixPkgs.runCommand fixedOutput.name
        (
          builtins.removeAttrs fixedOutput [ "name" ]
          // {
            nativeBuildInputs = [
              (helmPackage newestHelmMajor)
              nixPkgs.cacert
            ];
            impureEnvVars = lib.fetchers.proxyImpureEnvVars;
            passthru.helmArgs = helmPullArgs spec;
          }
        )
        ''
          ${helmHome}
          mkdir pull
          helm ${lib.escapeShellArgs (helmPullArgs spec)}
          cp pull/* $out
        ''
    else
      derivation (
        fixedOutput
        // {
          system = "kix-helm";
          builder = "kix";
          allowSubstitutes = false;
          kixHelmFetch = builtins.toJSON spec;
        }
      );

  # Return the spec of a chart fetch. The placeholder route hands it to
  # `kix` as JSON, and the nix route turns it into a `helm pull` command line.
  fetchSpec =
    {
      repo,
      name,
      version,
    }:
    {
      specVersion = 1;
      helm = helmRelease newestHelmMajor;
      inherit repo name version;
    };

  # Return the arguments of the `helm pull` that `spec` describes, as the
  # CLI passes them, writing the chart into the directory `pull`.
  helmPullArgs =
    spec:
    [ "pull" ]
    ++ (
      if lib.hasPrefix "oci://" spec.repo then
        [ "${lib.removeSuffix "/" spec.repo}/${spec.name}" ]
      else
        [
          spec.name
          "--repo"
          spec.repo
        ]
    )
    ++ [
      "--version"
      spec.version
      "--destination"
      "pull"
    ];

  # Render a chart with `helm template`. The output is a JSON array with one
  # element per YAML document Helm prints.
  #
  # The spec names the exact Helm release and a `specVersion`, so a new Helm
  # release or a change to how `kix` converts YAML gives a new output path.
  helmTemplateDerivation =
    args:
    let
      spec = renderSpec args;
    in
    if helmRoute == "nix" then
      nixPkgs.runCommand "helm-render-${spec.releaseName}.json"
        {
          nativeBuildInputs = [
            (helmPackage (args.helmVersion or newestHelmMajor))
            nixPkgs.yq-go
          ];
          inherit (spec) values;
          passAsFile = [ "values" ];
          passthru.helmArgs = helmTemplateArgs spec;
        }
        ''
          set -o pipefail
          ${helmHome}
          mkdir work
          cd work
          cp "$valuesPath" values.json
          helm ${lib.escapeShellArgs (helmTemplateArgs spec)} \
            | yq eval-all -o=json '[.]' > $out
        ''
    else
      derivation {
        name = "helm-render-${spec.releaseName}.json";
        system = "kix-helm";
        builder = "kix";
        allowSubstitutes = false;
        preferLocalBuild = true;
        kixHelmSpec = builtins.toJSON spec;
      };

  # Return the spec of a chart render. The placeholder route hands it to
  # `kix` as JSON, and the nix route turns it into a `helm template` command
  # line with `helmTemplateArgs`, so the two routes pass the same flags.
  renderSpec =
    {
      chart,
      releaseName ? "release",
      namespace ? "default",
      values ? { },
      includeCrds ? true,
      includeHooks ? true,
      # Passed to `--kube-version`. With null, Helm uses its own default.
      kubeVersion ? null,
      # Further `helm template` arguments, one list element per argument.
      extraFlags ? [ ],
      # The Helm major version to render with, as a string such as "3".
      helmVersion ? newestHelmMajor,
    }:
    {
      specVersion = 1;
      helm = helmRelease helmVersion;
      chart = "${chart}";
      inherit
        releaseName
        namespace
        includeCrds
        includeHooks
        kubeVersion
        extraFlags
        ;
      # Without the string context of dependency outputs in `values`, a
      # dependency's manifest change does not re-render the chart. `deps`
      # and `networkDeps` record those dependencies instead.
      values = builtins.unsafeDiscardStringContext (builtins.toJSON values);
    };

  # Return the arguments of the `helm template` that `spec` describes, in the
  # order the CLI passes them (`render` in cli/kix-core/src/eval/helm.rs). The
  # values file is `values.json` in the working directory.
  helmTemplateArgs =
    spec:
    [
      "template"
      spec.releaseName
      spec.chart
      "--values"
      "values.json"
    ]
    ++ lib.optionals (spec.namespace != null) [
      "--namespace"
      spec.namespace
    ]
    ++ lib.optional spec.includeCrds "--include-crds"
    ++ lib.optional (!spec.includeHooks) "--no-hooks"
    ++ lib.optionals (spec.kubeVersion != null) [
      "--kube-version"
      spec.kubeVersion
    ]
    ++ spec.extraFlags;

  # Render a chart's CRDs and wrap them as cluster-scoped resources.
  importChartCrds =
    {
      chart,
      scope,
      releaseName ? "release",
      values ? { },
      helmVersion ? newestHelmMajor,
    }:
    let
      raw = readRender (helmTemplateDerivation {
        inherit
          chart
          releaseName
          values
          helmVersion
          ;
        includeHooks = false;
        kubeVersion = "1.32.0";
      });
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

  # Wrap a parsed JSON resource into a Kix resource through scope.
  wrapHelmResource =
    { scope, resource }:
    let
      kind = resource.kind or (fail "helm resource missing 'kind'");
      apiVersion = resource.apiVersion or (fail "helm resource missing 'apiVersion'");
      meta = resource.metadata or { };
      name = meta.name or (fail "helm resource missing 'metadata.name'");
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

      rawExtra = lib.filterAttrs (k: _: !(builtins.elem k standardFields)) resource;

      # Set Secret type to "Opaque" when omitted so the manifest matches the
      # server default.
      extra =
        if kind == "Secret" && !(rawExtra ? type) then rawExtra // { type = "Opaque"; } else rawExtra;

      # Preserve a resource's explicit namespace when it differs from the scope
      # namespace.
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
      // lib.optionalAttrs (resource ? spec) { spec = stripJobTtl kind (cleanSpec resource.spec); }
      // lib.optionalAttrs (resource ? data) { data = resource.data; }
      // lib.optionalAttrs (resource ? stringData) { stringData = resource.stringData; }
      // lib.optionalAttrs (extra != { }) { inherit extra; }
    );

  # Render a chart with `helm template` and return a resource collection for use
  # inside a package's `build` function.
  importChart =
    {
      chart,
      scope,
      values ? { },
      releaseName ? "release",
      namespace ? scope.namespaceName,
      includeCrds ? true,
      includeHooks ? true,
      extraFlags ? [ ],
      kubeVersion ? null,
      # The Helm major version to render with, as a string such as "3".
      helmVersion ? newestHelmMajor,

      strip ? { },
      preserveAnnotationPrefixes ? [ ],

      patchResources ? lib.id,

      # Extra intra-chart dependency edges `{ from = { kind; name; }; to = { kind; name; }; }`
      # injected before wrapping when DAG reconstruction cannot infer them from
      # manifest references. `from` depends on `to`.
      extraEdges ? [ ],

      # Context-carrying values (such as `loki.out.fqdn`) injected into Helm
      # workloads as `_helmNetworkDeps` so `edgeAnalysis.analyzeEdges` discovers
      # their egress dependencies. The dependency must also be declared in the
      # `build` function arguments so its Services appear in `serviceRegistry`.
      # Use this for values that `deps` does not collect automatically, such as
      # nested `dep.out.byKind` outputs.
      networkDeps ? [ ],

      # Cross-package DI dependencies referenced by the chart's manifests.
      # Context-carrying strings at `dep.out.*` are merged into `networkDeps`.
      deps ? [ ],
    }:
    let
      doStripAnnotations = strip.helmAnnotations or true;
      doStripLabels = strip.helmLabels or true;
      doStripStrategy = strip.defaultStrategy or true;

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

      # Collect context-carrying strings from each dependency's top-level `out`
      # attributes so the network policy generator discovers cross-package
      # egress when a chart interpolates them. Nested values such as
      # `dep.out.byKind` must be passed through `networkDeps`.
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

      # Wrap a single resource with the effective strip settings and inferred requires.
      wrapResource =
        {
          resource,
          requires ? [ ],
        }:
        let
          kind = resource.kind or (fail "helm resource missing 'kind'");
          apiVersion = resource.apiVersion or (fail "helm resource missing 'apiVersion'");
          meta = resource.metadata or { };
          name = meta.name or (fail "helm resource missing 'metadata.name'");
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

          # Route workloads through scope.mkHelmWorkload to generate network
          # policies and run pod-spec validators without requiring DI-tracked
          # resource names.
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
          // lib.optionalAttrs (resource ? spec) {
            spec = stripJobTtl kind (effectiveCleanSpec resource.spec);
          }
          // lib.optionalAttrs (resource ? data) { data = resource.data; }
          // lib.optionalAttrs (resource ? stringData) { stringData = resource.stringData; }
          // lib.optionalAttrs (extra != { }) { inherit extra; };
        in
        mkFn (
          commonArgs
          # Attach cross-package network dependencies so `edgeAnalysis.analyzeEdges`
          # discovers their egress edges from the workload JSON.
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
          kubeVersion
          helmVersion
          ;
      };

      rawResources = readRender templateDrv;

      isTestHook =
        r:
        let
          annotations = (r.metadata or { }).annotations or { };
          hookVal = annotations."helm.sh/hook" or "";
        in
        lib.hasInfix "test" hookVal;

      expandedResources = builtins.concatMap (
        r:
        if
          r != null && builtins.isAttrs r && (r.kind or "") == "List" && builtins.isList (r.items or null)
        then
          r.items
        else
          [ r ]
      ) rawResources;

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

      patchedResources = patchResources filteredResources;

      inferredEdges = helmDag.inferEdges patchedResources;

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
          || fail "importChart: extraEdges: no resource ${fromId} in chart ${releaseName}";
        assert
          rawByKindName ? ${toId}
          || fail "importChart: extraEdges: no resource ${toId} in chart ${releaseName}";
        {
          from = rawByKindName.${fromId};
          to = rawByKindName.${toId};
          type = "extra";
        }
      ) extraEdges;

      rawEdges = inferredEdges ++ resolvedExtraEdges;
      rawDepsMap = helmDag.buildDepsMap rawEdges;

      indexByRawId = builtins.listToAttrs (
        lib.imap0 (i: raw: {
          name = helmDag.resourceId raw;
          value = i;
        }) patchedResources
      );

      # Wrap each resource with its DAG-inferred requires. Looking up
      # dependencies in `wrappedResources` by index is safe because Kubernetes
      # resource dependencies are acyclic.
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
              [ ]
          ) depIds;
        in
        wrapResource {
          resource = raw;
          inherit requires;
        }
      ) patchedResources;

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

      # Build the resource collection recursively so `replaceResource` returns a
      # new collection with the replacement applied to lookups, `mkParts`, and
      # DAG queries.
      mkResourceCollection =
        replacements:
        let
          isReplacedKey = key: replacements ? ${key};
          isReplaced = r: isReplacedKey "${r.kind}/${r.name}";

          effectiveResources =
            (builtins.filter (r: !(isReplaced r)) wrappedResources) ++ (builtins.attrValues replacements);

          # Drop edges touching a replaced resource. The caller wires the
          # replacement's `requires` directly.
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

          # Build `{ cr, mkCR }` for every CRD the chart ships. Each builder
          # adds the CRD and all chart workloads to `requires` so consumer CRs
          # wait for the CRD and any admission or conversion webhook.
          chartCrds = builtins.filter (r: r.kind == "CustomResourceDefinition") effectiveResources;

          chartWorkloads = builtins.filter (r: builtins.elem r.kind helmDag.workloadKinds) effectiveResources;

          instanceLabel = "${namespace}/${scope.instanceName or releaseName}";

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
              k8s.mkCRDBuilders {
                crdOrRef = crdRes;
                extraRequires = chartWorkloads;
                kind = crKind;
                servedVersions = map (v: v.name) (builtins.filter (v: v.served or true) versions);
                declaredBy = "the chart's CustomResourceDefinition ${crdRes.name} in ${instanceLabel}";
                inherit group version crdScope;
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
          all = effectiveResources;

          # Return the resource matching kind and name, or fail if not found.
          get =
            kind: name:
            let
              matches = builtins.filter (r: r.kind == kind && r.name == name) effectiveResources;
            in
            if matches == [ ] then
              fail "importChart: no resource found with kind=${kind} name=${name} in chart ${releaseName}"
            else
              builtins.head matches;

          # Return the resource matching kind and name, or null if not found.
          find =
            kind: name:
            let
              matches = builtins.filter (r: r.kind == kind && r.name == name) effectiveResources;
            in
            if matches == [ ] then null else builtins.head matches;

          # Return all resources of the given kind.
          byKind = kind: builtins.filter (r: r.kind == kind) effectiveResources;

          workloads = builtins.filter (r: builtins.elem r.kind helmDag.workloadKinds) effectiveResources;

          # Return all resources except those in `resources`.
          excluding =
            resources:
            let
              excludePaths = map (r: r.outPath) resources;
            in
            builtins.filter (r: !(builtins.elem r.outPath excludePaths)) effectiveResources;

          attrs = builtins.listToAttrs (
            map (r: {
              name = "${lib.toLower r.kind}-${r.name}";
              value = r;
            }) effectiveResources
          );

          # Return the inferred internal dependencies for a wrapped resource.
          depsOf = resource: effectiveDepsMap.${resource.outPath} or [ ];

          edges = effectiveEdges;

          crds = crdBuilders;

          # Return a new collection with the named chart resource replaced by
          # `newResource`. Inbound DAG edges to the replaced resource are
          # dropped, while outbound dependencies remain reachable through
          # `mkParts`.
          replaceResource =
            kind: name: newResource:
            let
              key = "${kind}/${name}";
            in
            if !(builtins.any (r: r.kind == kind && r.name == name) wrappedResources) then
              fail "importChart: replaceResource: no resource ${key} in chart ${releaseName}"
            else
              mkResourceCollection (replacements // { ${key} = newResource; });

          autoRoot = helmDag.pickRoot releaseName effectiveResources;

          # Build a parts attrset where `root` requires all DAG entry points
          # and exposes chart resources under `out.byKind`. When a workload root
          # is selected by a single Service, promote that Service's outputs onto
          # `root.out`.
          mkParts =
            {
              root,
              extraParts ? { },
              extraRequires ? [ ],
              out ? { },
            }:
            let
              # Non-root resources that no other chart resource depends on.
              dagRootRequires = builtins.filter (
                r: r.outPath != root.outPath && !(builtins.elem "${r.kind}/${r.name}" effectiveDepTargetIds)
              ) effectiveResources;

              allRequires = dagRootRequires ++ extraRequires;

              byKindLookup = builtins.foldl' (
                acc: r:
                acc
                // {
                  ${r.kind} = (acc.${r.kind} or { }) // {
                    ${r.name} = r;
                  };
                }
              ) { } effectiveResources;

              matchingServices =
                if helmDag.isWorkloadKind root.kind then
                  map (e: e.from) (
                    builtins.filter (
                      e: e.type == "selects" && e.from.kind == "Service" && e.to.outPath == root.outPath
                    ) effectiveEdges
                  )
                else
                  [ ];

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
              collision = helpers.mergeCollide "importChart (${releaseName}): extraParts names a part the chart already renders (or names root). Rename the extra part";
            in
            collision (collision attrs extraParts) {
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

  # Build an inline chart package with a `values` option. Uses `root = { kind; name; }`
  # when provided, or `autoRoot` otherwise.
  helmChart =
    {
      repo,
      name,
      version,
      hash,
      releaseName ? name,
      root ? null,
      includeCrds ? true,
      strip ? { },
      patchResources ? lib.id,
      # The Helm major version to render with, as a string such as "3".
      helmVersion ? newestHelmMajor,
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
              helmVersion
              ;
            values = config.values or { };
          };
        in
        resources.mkParts {
          root = if root == null then resources.autoRoot else resources.get root.kind root.name;
        };
    };
}
