# Instance evaluation — evaluates a single package instance within a namespace.
# Handles DI, fixpoint, closure computation, diagnostics, and view construction.

{
  lib,
  k8s,
  meta,
  helpers,
  netpol,
  kixlib,
  scope,
  view,
  resolve,
  import_,
}:

let
  inherit (k8s) mkPackageInstance;
  inherit (helpers) collectTypedAttrs;
  inherit (scope) mkScope;
  inherit (view) mkPackageView;
  inherit (resolve)
    resolveArg
    evaluateInstanceConfig
    callPackagePhase1
    discoverBuildDeps
    resolveDeclaredDeps
    ;
  inherit (import_) evaluateImportInstance;
in

{
  # Evaluate a single instance.
  evaluateInstance =
    {
      instanceName,
      namespaceName,
      instCfg,
      namespaceResource,
      nsResources ? { },
      clusterLabels,
      resolutionIndex,
      allInstances,
      globalPartsOverlays ? [ ],
      clusterConfig ? { },
      configInjections ? [ ],
    }@args:

    # Import instances take a separate evaluation path — no resource collection,
    # no closure computation, just out derivation + marker CR.
    if (instCfg.package._type or "") == "kix-import" then
      evaluateImportInstance args

    else
      let
        scope' = mkScope {
          inherit
            instanceName
            namespaceName
            namespaceResource
            clusterLabels
            ;
          namespaces = nsResources;
          labelStyle = instCfg.labelStyle;
          selectorLabelsOverride = instCfg.selectorLabels;
          clusterDomain = clusterConfig.clusterDomain or "cluster.local";
          capabilities = clusterConfig.cluster.capabilities or { };
        };

        # 1. Phase 1: normalize package (function or inline attrset) with system args
        raw = callPackagePhase1 {
          package = instCfg.package;
          scope = scope';
        };

        # Package-declared metadata (lifecycle, scope, etc.)
        packageMeta = raw.meta or { };

        # 2. Discover deps from build function args
        discoveredDeps = discoverBuildDeps raw.build;
        # Merge with optional deps enrichment (assertions/warnings per dep)
        depsEnrichment = raw.deps or { };
        # All dep names come from build args — enrichment only adds metadata
        depArgNames = builtins.attrNames discoveredDeps;
        deps = instCfg.deps or { };

        # 3. Resolve deps
        resolvedDeps = resolveDeclaredDeps {
          declaredDeps = discoveredDeps;
          inherit resolutionIndex allInstances;
          namespace = namespaceName;
          explicitOverrides = deps;
        };

        # Resolve dep metadata for cross-checks
        resolvedDepMeta = builtins.foldl' (
          acc: argName:
          let
            depSpec = discoveredDeps.${argName};
            isOptional = depSpec.optional or false;
            explicitOverride = deps.${argName} or null;
            resolution = resolveArg {
              inherit argName resolutionIndex explicitOverride;
              requesterNamespace = namespaceName;
              hasDefault = isOptional;
            };
          in
          if resolution.found && !(resolution.direct or false) then
            acc
            // {
              ${argName} = {
                inherit resolution;
                instance = allInstances.${resolution.namespace}.${resolution.instanceName};
              };
            }
          else
            acc
        ) { } depArgNames;

        # --- Cross-namespace scope validation ---
        _crossNsCheck =
          let
            crossNsDeps = lib.filterAttrs (
              _: depInfo:
              let
                depScope = (depInfo.instance._meta.packageMeta or { }).scope or "cluster";
              in
              (depInfo.resolution.namespace or namespaceName) != namespaceName && depScope == "namespace"
            ) resolvedDepMeta;
          in
          lib.foldlAttrs (
            acc: argName: depInfo:
            throw "instance '${instanceName}' (namespace '${namespaceName}') depends on '${depInfo.resolution.instanceName}' (namespace '${depInfo.resolution.namespace}') which declares meta.scope = \"namespace\" — cross-namespace reference not allowed"
          ) null crossNsDeps;

        # --- Meta-derived assertions and warnings (static, before build) ---
        metaResult = meta.checkMetaStatic {
          inherit
            packageMeta
            instanceName
            namespaceName
            clusterConfig
            resolvedDepMeta
            resolutionIndex
            ;
        };

        # 2. Evaluate typed config: package options + instance config + dep injections
        evaluatedConfig = evaluateInstanceConfig {
          packageOptions = raw.options or { };
          inherit instCfg clusterConfig configInjections;
        };

        # 3. Combine global + instance overlays (signature: scope → self → base → attrset)
        allOverlays = globalPartsOverlays ++ (instCfg.partsOverlays or [ ]);
        boundOverlays = map (o: o scope') allOverlays;

        # 4. Build the inner fixpoint — build receives { self, config, clusterConfig }
        #    build can be a function (single-file) or a list of paths/functions (multi-file).
        #    Paths are imported; all entries are called with { self, config, clusterConfig }
        #    and optionally { scope, lib } if the function accepts them (arg introspection).
        rawBuildEntries =
          if builtins.isList raw.build then
            map (entry: if builtins.isPath entry then import entry else entry) raw.build
          else
            [ raw.build ];

        callBuildFn =
          self: fn:
          let
            args = builtins.functionArgs fn;
            base = {
              inherit self clusterConfig;
              config = evaluatedConfig;
            };
            extra =
              lib.optionalAttrs (args ? scope) { scope = scope'; }
              // lib.optionalAttrs (args ? lib) { inherit lib; }
              // lib.optionalAttrs (args ? kix) { kix = kixlib; }
              // lib.optionalAttrs (args ? deps) { deps = resolvedDeps; };
            # Pass resolved DI deps by name — build entries request what they need
            depArgs = lib.intersectAttrs args resolvedDeps;
          in
          fn (base // extra // depArgs);

        parts = lib.fix (
          self:
          let
            merged = builtins.foldl' (acc: fn: acc // (callBuildFn self fn)) { } rawBuildEntries;
          in
          if boundOverlays != [ ] then
            builtins.foldl' (acc: overlay: acc // (overlay self acc)) merged boundOverlays
          else
            merged
        );

        # --- Resolve root resource and package-level requires ---
        rawRoot =
          parts.root
            or (throw "Instance '${instanceName}' in namespace '${namespaceName}' must define 'root'");

        # root can be either { resource = ...; requires = [...]; } or a resource directly
        rootRes =
          if rawRoot ? resource then
            rawRoot.resource
          else if rawRoot ? _type && rawRoot._type == "k8s-resource" then
            rawRoot
          else
            throw "Instance '${instanceName}': root must be a resource or { resource, requires }";

        packageRequires = if rawRoot ? resource then rawRoot.requires or [ ] else [ ];

        # Package-level out extensions (functions, complex types beyond string outputs).
        # Merged on top of the root resource's auto-derived out.
        packageOut = if rawRoot ? resource then rawRoot.out or { } else { };

        # --- Forward closure computation ---
        # Follows both store-path references in manifests AND explicit `requires`.
        # `requires` are structural forward deps (SA needed by Deployment, etc.).

        # Collect all resources from parts (for the local registry).
        # Filters out null values so disabled/modal parts are excluded.
        allPartResources = builtins.filter (v: (v._type or "") == "k8s-resource") (
          collectTypedAttrs {
            excludeKeys = [
              "root"
              "meta"
            ];
          } parts
        );

        # Local store-path → resource lookup for forward closure walking.
        # TODO: potentially move the PI collection to kix-cli for faster eval
        localRegistry = builtins.foldl' (
          acc: r:
          acc
          // {
            ${builtins.unsafeDiscardStringContext r.outPath} = {
              resource = r;
            };
          }
        ) { } allPartResources;

        # Get forward deps: store-path refs in manifest + explicit requires
        getForwardDeps =
          resource:
          let
            ctx = builtins.getContext (builtins.toJSON resource.rawManifest);
            k8sPaths = builtins.filter (p: builtins.hasAttr p localRegistry) (builtins.attrNames ctx);
            manifestDeps = map (p: localRegistry.${p}.resource) k8sPaths;
            requiresDeps = builtins.filter (r: builtins.isAttrs r && (r._type or "") == "k8s-resource") (
              resource.requires or [ ]
            );
          in
          manifestDeps ++ requiresDeps;

        # Compute the forward closure from rootRes + packageRequires
        forwardRoots = [ rootRes ] ++ packageRequires;
        forwardClosure =
          let
            go =
              {
                seen,
                result,
                queue,
              }:
              if queue == [ ] then
                result
              else
                let
                  head = builtins.head queue;
                  rest = builtins.tail queue;
                  headPath = builtins.unsafeDiscardStringContext head.outPath;
                in
                if builtins.hasAttr headPath seen then
                  go {
                    inherit seen result;
                    queue = rest;
                  }
                else
                  go {
                    seen = seen // {
                      ${headPath} = true;
                    };
                    result = result ++ [ head ];
                    queue = rest ++ (getForwardDeps head);
                  };
          in
          go {
            seen = { };
            result = [ ];
            queue = forwardRoots;
          };

        forwardPaths = builtins.listToAttrs (
          map (r: {
            name = builtins.unsafeDiscardStringContext r.outPath;
            value = true;
          }) forwardClosure
        );

        # --- Inverse dependency detection ---
        # Find resources NOT in the forward closure whose manifest references
        # a resource that IS in the forward closure. Only tracks the actual
        # inverse deps — not their forward expansions (e.g. a ClusterRoleBinding
        # that references a SA is an inverse dep, but the ClusterRole it binds is
        # just a forward dep of the binding, not an inverse dep itself).
        inverseDeps =
          let
            nonForward = builtins.filter (
              r: !(builtins.hasAttr (builtins.unsafeDiscardStringContext r.outPath) forwardPaths)
            ) allPartResources;

            referencesForward =
              r:
              let
                ctx = builtins.getContext (builtins.toJSON r.rawManifest);
                ctxPaths = builtins.attrNames ctx;
              in
              builtins.any (p: builtins.hasAttr p forwardPaths) ctxPaths;
          in
          builtins.filter referencesForward nonForward;

        # Deduplicate inverse deps
        uniqueInverseDeps =
          let
            go =
              {
                seen,
                result,
                queue,
              }:
              if queue == [ ] then
                result
              else
                let
                  head = builtins.head queue;
                  rest = builtins.tail queue;
                  headPath = builtins.unsafeDiscardStringContext head.outPath;
                in
                if builtins.hasAttr headPath seen then
                  go {
                    inherit seen result;
                    queue = rest;
                  }
                else
                  go {
                    seen = seen // {
                      ${headPath} = true;
                    };
                    result = result ++ [ head ];
                    queue = rest;
                  };
          in
          go {
            seen = { };
            result = [ ];
            queue = inverseDeps;
          };

        # --- Network policy generation ---
        networkResult =
          if (clusterConfig.networkPolicy or { }).enable or false then
            netpol.processInstance {
              scope = scope';
              inherit
                instanceName
                namespaceName
                allPartResources
                resolvedDepMeta
                ;
              networkConfig = clusterConfig.networkPolicy;
              inherit packageMeta;
            }
          else
            {
              policies = [ ];
              edges = [ ];
              warnings = [ ];
            };

        # --- Create PackageInstance CRD (Phase 5) ---
        # Lists root.requires as package-requires and true inverse deps.
        # Structural deps (via `requires`) are tracked by the cluster-level
        # closure which also follows `requires`.
        packageInstance = mkPackageInstance {
          inherit instanceName namespaceName;
          namespace = namespaceResource;
          mainResource = rootRes;
          inherit packageRequires;
          inverseDeps = inverseDeps ++ networkResult.policies;
          version =
            let
              v = instCfg.version or null;
            in
            if v != null then v else packageMeta.version or null;
          labels = clusterLabels // {
            "app.kubernetes.io/instance" = instanceName;
            "app.kubernetes.io/managed-by" = "kix";
          };
          extraAnnotations =
            lib.optionalAttrs (instCfg._autoInstantiated or false) {
              "kix.dev/auto-instantiated" = "true";
            }
            // lib.optionalAttrs (instCfg.optional or false) {
              "kix.dev/optional-activated" = "true";
            };
        };

        # --- Eval-time warnings ---

        # 1. Redundant requires: resource has requires on something already in its manifest context
        redundantRequiresWarnings = builtins.concatMap (
          resource:
          let
            reqs = resource.requires or [ ];
            ctx = builtins.getContext (builtins.toJSON resource.rawManifest);
          in
          builtins.concatMap (
            req:
            let
              reqPath = builtins.unsafeDiscardStringContext req.outPath;
            in
            if builtins.hasAttr reqPath ctx then
              [
                {
                  inherit resource req;
                }
              ]
            else
              [ ]
          ) (builtins.filter (r: builtins.isAttrs r && (r._type or "") == "k8s-resource") reqs)
        ) allPartResources;

        # 2. Duplicate requires: same resource required multiple times
        duplicateRequiresWarnings = builtins.concatMap (
          resource:
          let
            reqs = builtins.filter (r: builtins.isAttrs r && (r._type or "") == "k8s-resource") (
              resource.requires or [ ]
            );
            reqPaths = map (r: {
              path = builtins.unsafeDiscardStringContext r.outPath;
              req = r;
            }) reqs;
            go =
              {
                seen,
                dupes,
                queue,
              }:
              if queue == [ ] then
                dupes
              else
                let
                  head = builtins.head queue;
                  rest = builtins.tail queue;
                in
                if builtins.hasAttr head.path seen then
                  go {
                    inherit seen;
                    dupes = dupes ++ [
                      {
                        inherit resource;
                        req = head.req;
                      }
                    ];
                    queue = rest;
                  }
                else
                  go {
                    seen = seen // {
                      ${head.path} = true;
                    };
                    inherit dupes;
                    queue = rest;
                  };
          in
          go {
            seen = { };
            dupes = [ ];
            queue = reqPaths;
          }
        ) allPartResources;

        # 3. Orphaned resources: defined in parts but not reachable from root
        reachablePaths =
          let
            inverseSet = builtins.listToAttrs (
              map (r: {
                name = builtins.unsafeDiscardStringContext r.outPath;
                value = true;
              }) uniqueInverseDeps
            );
            inverseFwdClosure = builtins.concatMap (r: getForwardDeps r) uniqueInverseDeps;
            inverseFwdSet = builtins.listToAttrs (
              map (r: {
                name = builtins.unsafeDiscardStringContext r.outPath;
                value = true;
              }) inverseFwdClosure
            );
          in
          forwardPaths // inverseSet // inverseFwdSet;

        orphanedWarnings = builtins.filter (
          r: !(builtins.hasAttr (builtins.unsafeDiscardStringContext r.outPath) reachablePaths)
        ) allPartResources;

        # --- Package-declared warnings and assertions (post-build) ---
        packageResult = meta.evaluatePackageDiagnostics {
          inherit
            raw
            evaluatedConfig
            parts
            resolvedDepMeta
            depsEnrichment
            resolvedDeps
            ;
        };

        # --- Combine all diagnostics ---
        structuralWarnings =
          let
            res = r: "${r.kind}/${r.name}";
            warn = msg: items: map (x: "[${instanceName}] ${msg x}") items;
          in
          lib.concatLists [
            (warn (
              w:
              "resource '${res w.resource}' has redundant requires on '${res w.req}' — already tracked via store path reference"
            ) redundantRequiresWarnings)
            (warn (
              w: "resource '${res w.resource}' requires '${res w.req}' multiple times"
            ) duplicateRequiresWarnings)
            (warn (r: "resource '${res r}' is defined but not reachable from root (orphaned)") orphanedWarnings)
            networkResult.warnings
          ];

        diagnostics = meta.combineDiagnostics {
          inherit
            instanceName
            metaResult
            packageResult
            structuralWarnings
            ;
        };

      in
      builtins.seq _crossNsCheck (
        builtins.seq diagnostics.emitWarnings (
          builtins.seq diagnostics.emitAssertionWarnings (
            let
              view' = mkPackageView {
                inherit
                  parts
                  instanceName
                  namespaceName
                  packageMeta
                  packageInstance
                  ;
                rootOut = (rootRes.out or { }) // packageOut;
                aliases = instCfg.aliases or [ ];
              };
            in
            view'
            // {
              _networkPolicies = networkResult.policies;
              _networkEdges = networkResult.edges;
              _diagnostics = {
                warnings = diagnostics.allWarnings;
                assertions = diagnostics.allAssertions;
                inherit (diagnostics) failedAssertions;
              };
            }
          )
        )
      );
}
