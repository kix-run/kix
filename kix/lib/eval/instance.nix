# Instance evaluation — evaluates a single package instance within a namespace.
# Handles DI, fixpoint, closure computation, diagnostics, and view construction.

{
  lib,
  k8s,
  meta,
  helpers,
  netpol,
  kixlib,
  scorecard,
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
      # Lazy handle to the network-policy enforcer's `out` (currently only
      # exposes `cnpCrdRef`). Resolved at cluster level via
      # `meta.provides ∋ "network-policy-enforcer"`. Null when no enforcer
      # is declared or when this instance IS the enforcer (self-dep guard).
      # See v2_discussions/83 and `kix/lib/eval/cluster.nix` → `enforcerOut`.
      networkPolicyEnforcer ? null,
    }@args:

    # Import instances take a separate evaluation path — no resource collection,
    # no closure computation, just out derivation + marker CR.
    if (instCfg.package._type or "") == "kix-import" then
      evaluateImportInstance args

    else
      let
        # Peek package metadata BEFORE the scope is constructed, so
        # `mkScope` can honor `meta.provides` (self-dep guard for the
        # enforcer) and `meta.network.intents` (declared connectivity)
        # at scope-level netpol emission time. `peekPackageMeta`
        # is cheap — it invokes function packages with an empty scope and
        # reads `.meta` without calling `build`.
        peekedPackageMeta = meta.peekPackageMeta {
          package = instCfg.package;
          inherit kixlib;
        };

        # If this instance IS the enforcer (e.g. the cilium package
        # itself), disable scope-level per-workload CNP emission: its
        # own workloads must not declare CNPs that transitively depend on
        # the enforcer's own CRD marker. The cluster-level lookup in
        # `cluster.nix → isSelfEnforcer` already nullifies
        # `networkPolicyEnforcer` for this scope, but we also suppress
        # the `buildWorkloadCnps` call so no fallback-path CNPs are
        # emitted either.
        _skipWorkloadNetpol = builtins.elem "network-policy-enforcer" (peekedPackageMeta.provides or [ ]);

        # Resolve the DNS instance via DI. The root is passed to the scope
        # and injected into workloads that reference cross-instance Services
        # (detected via store-path context in buildWorkloadCnps).
        # Self-dep guard: if this instance IS the dns provider, skip.
        _dnsResolution = resolveArg {
          argName = "dns";
          inherit resolutionIndex;
          requesterNamespace = namespaceName;
          hasDefault = true;
          explicitOverride = null;
        };
        # TODO: turn this into a hard error once all cluster definitions
        # declare a DNS instance (platform flavors already do via
        # platform-dns). Every cluster needs DNS — a missing instance is
        # a misconfiguration.
        _dnsResolutionCheck =
          if !_dnsResolution.found then
            builtins.trace "[kix] warning: no DNS instance (alias 'dns') found in cluster — workloads will not depend on DNS readiness" null
          else
            null;
        # DNS instance root resource (or null). Passed to the scope; only
        # injected into workloads that actually reference cross-instance
        # Services (detected by buildWorkloadCnps via store-path context).
        _dnsRoot =
          if !_dnsResolution.found || (_dnsResolution.direct or false) then
            null
          else
            let
              dnsInst = allInstances.${_dnsResolution.namespace}.${_dnsResolution.instanceName};
            in
            # Self-dep guard: the DNS provider's own workloads must not
            # depend on its own root (that would be circular).
            if _dnsResolution.namespace == namespaceName && _dnsResolution.instanceName == instanceName then
              null
            else if dnsInst ? root then
              dnsInst.root
            else
              null;

        scope' = mkScope {
          inherit
            instanceName
            namespaceName
            namespaceResource
            clusterLabels
            networkPolicyEnforcer
            peekedPackageMeta
            ;
          dnsRoot = _dnsRoot;
          namespaces = nsResources;
          labelStyle = instCfg.labelStyle;
          selectorLabelsOverride = instCfg.selectorLabels;
          clusterDomain = clusterConfig.clusterDomain or "cluster.local";
          capabilities = clusterConfig.cluster.capabilities or { };
          networkConfig = clusterConfig.networkPolicy or { enable = false; };
          # Lazy: dep resources for scope-level netpol edge discovery.
          # `resolvedDepMeta` is computed below (line ~97) in the same
          # `let` and fully forced before the `parts` fixpoint runs
          # `scope.mkDeployment`, so referencing it here is safe via
          # Nix laziness.
          depResourcesForNetpol = _depResourcesForNetpol;
          skipWorkloadNetpol = _skipWorkloadNetpol;
        };

        # Flatten every DI-resolved dep instance's raw resources into a
        # single list. This mirrors the `depResources` computation inside
        # `netpol.processInstance` — moved up here so `mkScope` can hand
        # a Service registry to `buildWorkloadCnps` at workload-
        # construction time. Lazy: only forced when the first
        # `mkDeployment`/`mkStatefulSet`/`mkDaemonSet` runs, by which
        # point `resolvedDepMeta` is fully settled.
        _depResourcesForNetpol = builtins.concatMap (
          argName:
          let
            depParts = resolvedDepMeta.${argName}.instance.raw or { };
          in
          builtins.filter (v: (v._type or "") == "k8s-resource") (
            collectTypedAttrs {
              excludeKeys = [
                "root"
                "meta"
              ];
            } depParts
          )
        ) (builtins.attrNames resolvedDepMeta);

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

        # root can be either { resource = ...; requires = [...]; postHooks = [...]; } or a resource directly
        rootRes =
          if rawRoot ? resource then
            rawRoot.resource
          else if rawRoot ? _type && rawRoot._type == "k8s-resource" then
            rawRoot
          else
            throw "Instance '${instanceName}': root must be a resource or { resource, requires, postHooks }";

        # Package-level requires come from the root's explicit `requires`
        # (set by the package author via `root = { resource = ...; requires = [...]; }`).
        # Cross-package edges from other sources (DI-resolved deps referenced
        # in manifest string context) are handled by the CLI wave computation,
        # which collapses any cross-package edge onto the target package's
        # PackageInstance marker — see `cli/kix/src/cluster/graph.rs` Phase 2b.
        packageRequires = if rawRoot ? resource then rawRoot.requires or [ ] else [ ];

        # Post-hooks: resources deployed AFTER all other package resources complete.
        # Must depend on forward-closure resources (typically root or its descendants)
        # so wave ordering places them after the main package resources.
        # The PackageInstance CR depends on them, so the package isn't "done" until
        # post-hooks finish. Jobs use readiness = status.succeeded >= 1.
        postHooks = if rawRoot ? resource then rawRoot.postHooks or [ ] else [ ];

        # Package-level out extensions (functions, complex types beyond string outputs).
        # Merged on top of the root resource's auto-derived out.
        packageOut = if rawRoot ? resource then rawRoot.out or { } else { };

        # --- Forward closure computation ---
        # Follows both store-path references in manifests AND explicit `requires`.
        # `requires` are structural forward deps (SA needed by Deployment, etc.).

        # Collect all resources from parts (for the local registry).
        # Filters out null values so disabled/modal parts are excluded.
        _partResourcesFromParts = builtins.filter (v: (v._type or "") == "k8s-resource") (
          collectTypedAttrs {
            excludeKeys = [
              "root"
              "meta"
            ];
          } parts
        );

        # Drain scope-emitted per-workload CNPs off every workload and
        # fold them into the instance's resource pool. `scope.mkWorkload`
        # constructs these at resource-construction time — the workload's
        # own `extraDeps` already lists them, so the forward closure will
        # reach them via the workload's store-path context, but we still
        # need them explicitly in `allPartResources` so `collectResources`
        # in cluster.nix can serialize them as YAML documents. See
        # v2_discussions/83 → "scope-level workload interception".
        _scopeEmittedNetpolCnps = builtins.concatMap (r: r._generatedNetpol or [ ]) _partResourcesFromParts;

        allPartResources = _partResourcesFromParts ++ _scopeEmittedNetpolCnps;

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
        # + extraDeps. `extraDeps` are folded into the resource's own
        # store-path context (see k8s.nix `manifestJsonWithDeps`) so they
        # influence content addressing, but they don't appear in the raw
        # manifest JSON's context — which means the walker won't find them
        # unless we list them here explicitly. Critical for scope-level
        # per-workload CNPs that are attached via extraDeps from
        # `scope.mkWorkload` (see v2_discussions/83): without this edge
        # the workload's CNPs would show up as orphans in the instance
        # forward closure.
        getForwardDeps =
          resource:
          let
            ctx = builtins.getContext (builtins.toJSON resource.rawManifest);
            k8sPaths = builtins.filter (p: builtins.hasAttr p localRegistry) (builtins.attrNames ctx);
            manifestDeps = map (p: localRegistry.${p}.resource) k8sPaths;
            requiresDeps = builtins.filter (r: builtins.isAttrs r && (r._type or "") == "k8s-resource") (
              resource.requires or [ ]
            );
            extraDepsDeps = builtins.filter (r: builtins.isAttrs r && (r._type or "") == "k8s-resource") (
              resource.extraDeps or [ ]
            );
          in
          manifestDeps ++ requiresDeps ++ extraDepsDeps;

        # Compute the forward closure from rootRes + packageRequires + postHooks
        forwardRoots = [ rootRes ] ++ packageRequires ++ postHooks;
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
                # Explicit `requires` entries count as forward references too:
                # they're declared dependencies on forward-closure resources,
                # even if the dependency isn't expressed via string context in
                # the manifest body. Without this, resources that only use
                # requires (e.g. `scope.mkCRDRef { installedBy = ...; }`) would
                # be flagged as orphans instead of classified as inverse deps.
                requiresPaths = map (dep: builtins.unsafeDiscardStringContext dep.outPath) (
                  builtins.filter (dep: builtins.isAttrs dep && (dep._type or "") == "k8s-resource") (
                    r.requires or [ ]
                  )
                );
              in
              builtins.any (p: builtins.hasAttr p forwardPaths) (ctxPaths ++ requiresPaths);
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
                allPartResources
                networkPolicyEnforcer
                ;
              networkConfig = clusterConfig.networkPolicy;
              inherit packageMeta;
            }
          else
            {
              policies = [ ];
              warnings = [ ];
            };

        # --- Scorecard rule evaluation (manifest + package level) ---
        scorecardConfig = clusterConfig.scorecard or { };
        scorecardEnabled = (scorecardConfig.enable or false) && (scorecardConfig.rules or { }) != { };
        owner = packageMeta.owner or null;

        scorecardManifestFindings =
          if scorecardEnabled then
            builtins.concatMap (
              resource:
              scorecard.evaluateManifestRules {
                rules = scorecardConfig.rules;
                inherit
                  resource
                  instanceName
                  namespaceName
                  owner
                  ;
                ruleDefaults = scorecardConfig.ruleDefaults or { };
                ruleOverrides = scorecardConfig.ruleOverrides or { };
              }
            ) (builtins.filter (r: r ? kind) (map (r: r.rawManifest or { }) allPartResources))
          else
            [ ];

        scorecardPackageFindings =
          if scorecardEnabled then
            scorecard.evaluatePackageRules {
              rules = scorecardConfig.rules;
              resources = map (r: r.rawManifest or { }) allPartResources;
              inherit
                parts
                instanceName
                namespaceName
                owner
                ;
              config = evaluatedConfig;
              meta = packageMeta;
              ruleDefaults = scorecardConfig.ruleDefaults or { };
              ruleOverrides = scorecardConfig.ruleOverrides or { };
            }
          else
            [ ];

        scorecardFindings = scorecardManifestFindings ++ scorecardPackageFindings;
        scorecardDiag = scorecard.scorecardToWarnings scorecardFindings;

        # --- Create PackageInstance CRD (Phase 5) ---
        # Lists root.requires as package-requires and true inverse deps.
        # Structural deps (via `requires`) are tracked by the cluster-level
        # closure which also follows `requires`.
        packageInstance = mkPackageInstance {
          inherit instanceName namespaceName;
          namespace = namespaceResource;
          mainResource = rootRes;
          inherit packageRequires postHooks;
          inverseDeps = inverseDeps ++ networkResult.policies;
          lifecycle = packageMeta.lifecycle or null;
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

        # 4. Post-hooks without forward-closure dependencies: would not be ordered
        # after root in the deploy graph — likely a bug.
        postHookWarnings =
          let
            # Forward paths excluding the post-hooks themselves
            nonPostHookForwardPaths = builtins.removeAttrs forwardPaths (
              map (r: builtins.unsafeDiscardStringContext r.outPath) postHooks
            );
            hookMissingDep =
              hook:
              let
                deps = getForwardDeps hook;
                depPaths = map (d: builtins.unsafeDiscardStringContext d.outPath) deps;
              in
              !(builtins.any (p: builtins.hasAttr p nonPostHookForwardPaths) depPaths);
          in
          builtins.filter hookMissingDep postHooks;

        # --- Package-declared warnings and assertions (post-build) ---
        packageResultRaw = meta.evaluatePackageDiagnostics {
          inherit
            raw
            evaluatedConfig
            parts
            resolvedDepMeta
            depsEnrichment
            resolvedDeps
            ;
        };
        # Merge scorecard error-level findings as assertions
        packageResult = {
          warnings = packageResultRaw.warnings;
          assertions = packageResultRaw.assertions ++ scorecardDiag.assertions;
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
            (warn (
              r:
              "post-hook '${res r}' does not depend on any forward-closure resource — it won't be ordered after root in the deploy graph"
            ) postHookWarnings)
            networkResult.warnings
            scorecardDiag.warnings
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
        builtins.seq _dnsResolutionCheck (
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
                    evaluatedConfig
                    ;
                  rootOut = (rootRes.out or { }) // packageOut;
                  aliases = instCfg.aliases or [ ];
                };
              in
              view'
              // {
                # `_networkPolicies` is the full set of CNPs owned by this
                # instance: per-workload CNPs emitted at scope time (drained
                # off `_generatedNetpol` on every workload) + supplementary
                # api-server / external-ingress CNPs emitted post-fixpoint by
                # `netpol.processInstance`. cluster.nix reads this via
                # `inst._networkPolicies` in `collectResources`.
                _networkPolicies = _scopeEmittedNetpolCnps ++ networkResult.policies;
                _scorecardFindings = scorecardFindings;
                _diagnostics = {
                  warnings = diagnostics.allWarnings;
                  assertions = diagnostics.allAssertions;
                  inherit (diagnostics) failedAssertions;
                };
              }
            )
          )
        )
      );
}
