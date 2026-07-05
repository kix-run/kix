{
  lib,
  k8s,
  meta,
  helpers,
  kixlib,
  scorecard,
  edgeAnalysis,
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
      workloadInterceptors ? [ ],
      instanceProcessors ? [ ],
      clusterCtx ? { },
    }@args:

    if (instCfg.package._type or "") == "kix-import" then
      evaluateImportInstance args

    else
      let
        peekedPackageMeta = meta.peekPackageMeta {
          package = instCfg.package;
          inherit kixlib;
        };

        _dnsResolution = resolveArg {
          argName = "dns";
          inherit resolutionIndex;
          requesterNamespace = namespaceName;
          hasDefault = true;
          explicitOverride = null;
        };
        _dnsResolutionCheck =
          if !_dnsResolution.found then
            builtins.trace "[kix] warning: no DNS instance (alias 'dns') found in cluster — workloads will not depend on DNS readiness" null
          else
            null;
        _dnsRoot =
          if !_dnsResolution.found || (_dnsResolution.direct or false) then
            null
          else
            let
              dnsInst = allInstances.${_dnsResolution.namespace}.${_dnsResolution.instanceName};
            in
            # Self-dep guard: the DNS provider's own workloads must not depend on their own root.
            if _dnsResolution.namespace == namespaceName && _dnsResolution.instanceName == instanceName then
              null
            else if dnsInst ? root then
              dnsInst.root
            else
              null;

        _enforcerProvider =
          if !(clusterCtx ? findCapabilityProvider) then
            null
          else
            clusterCtx.findCapabilityProvider "network-policy-enforcer";

        # Self-dep guard: the enforcer's own scope must not depend on itself.
        _isSelfEnforcer =
          _enforcerProvider != null
          && _enforcerProvider.ns == namespaceName
          && _enforcerProvider.inst == instanceName;

        # The package-facing handle contract (`scope.networkPolicyEnforcer`):
        # null unless policy generation is enabled cluster-wide, an enforcer
        # is declared, and this instance is not the enforcer itself. Packages
        # (e.g. stackgres-cluster) branch on this handle to decide whether to
        # emit their own policies — with `networkPolicy.enable = false` they
        # must see null even when an enforcer instance exists. The option is
        # declared by the netpol plugin, hence the `or false` read.
        _netpolEnabled = (clusterConfig.networkPolicy or { }).enable or false;

        _networkPolicyEnforcer =
          if !_netpolEnabled || _enforcerProvider == null || _isSelfEnforcer then
            null
          else
            _enforcerProvider.out;

        _edgeAnalysis = rec {
          serviceRegistry = edgeAnalysis.mkServiceRegistry _depResourcesForEdges;
          serviceRefRegistry = edgeAnalysis.mkServiceRefRegistry _depResourcesForEdges;
          inherit (edgeAnalysis) isServiceRef;
          dnsRoot = _dnsRoot;
          edgesFor =
            workloadInput:
            edgeAnalysis.extractServiceEdgesFromJson {
              json = builtins.toJSON workloadInput;
              inherit serviceRegistry serviceRefRegistry;
            };
        };

        scope' = mkScope {
          inherit
            instanceName
            namespaceName
            namespaceResource
            clusterLabels
            peekedPackageMeta
            workloadInterceptors
            clusterCtx
            ;
          networkPolicyEnforcer = _networkPolicyEnforcer;
          namespaces = nsResources;
          labelStyle = instCfg.labelStyle;
          selectorLabelsOverride = instCfg.selectorLabels;
          clusterDomain = clusterConfig.clusterDomain or "cluster.local";
          capabilities = clusterConfig.cluster.capabilities or { };
          # Lazy: settled by the outer fixpoint before the first mkWorkload forces it.
          edgeAnalysis = _edgeAnalysis;
        };

        _depResourcesForEdges = builtins.concatMap (
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

        raw = callPackagePhase1 {
          package = instCfg.package;
          scope = scope';
        };

        packageMeta = raw.meta or { };

        discoveredDeps = discoverBuildDeps raw.build;
        depsEnrichment = raw.deps or { };
        depArgNames = builtins.attrNames discoveredDeps;
        deps = instCfg.deps or { };

        resolvedDeps = resolveDeclaredDeps {
          declaredDeps = discoveredDeps;
          inherit resolutionIndex allInstances;
          namespace = namespaceName;
          explicitOverrides = deps;
        };

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

        evaluatedConfig = evaluateInstanceConfig {
          packageOptions = raw.options or { };
          inherit instCfg clusterConfig configInjections;
        };

        allOverlays = globalPartsOverlays ++ (instCfg.partsOverlays or [ ]);
        boundOverlays = map (o: o scope') allOverlays;

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

        rawRoot =
          parts.root
            or (throw "Instance '${instanceName}' in namespace '${namespaceName}' must define 'root'");

        rootRes =
          if rawRoot ? resource then
            rawRoot.resource
          else if rawRoot ? _type && rawRoot._type == "k8s-resource" then
            rawRoot
          else
            throw "Instance '${instanceName}': root must be a resource or { resource, requires, postHooks }";

        packageRequires = if rawRoot ? resource then rawRoot.requires or [ ] else [ ];

        postHooks = if rawRoot ? resource then rawRoot.postHooks or [ ] else [ ];

        packageOut = if rawRoot ? resource then rawRoot.out or { } else { };

        _partResourcesFromParts = builtins.filter (v: (v._type or "") == "k8s-resource") (
          collectTypedAttrs {
            excludeKeys = [
              "root"
              "meta"
            ];
          } parts
        );

        # Sideband drain: interceptor-emitted resources ride workloads' _injectedResources, attached pre-seal by scope.mkWorkload.
        _scopeInjectedResources = builtins.concatMap (
          r: r._injectedResources or [ ]
        ) _partResourcesFromParts;

        allPartResources = _partResourcesFromParts ++ _scopeInjectedResources;

        localRegistry = builtins.foldl' (
          acc: r:
          acc
          // {
            ${builtins.unsafeDiscardStringContext r.outPath} = {
              resource = r;
            };
          }
        ) { } allPartResources;

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
                requiresPaths = map (dep: builtins.unsafeDiscardStringContext dep.outPath) (
                  builtins.filter (dep: builtins.isAttrs dep && (dep._type or "") == "k8s-resource") (
                    r.requires or [ ]
                  )
                );
              in
              builtins.any (p: builtins.hasAttr p forwardPaths) (ctxPaths ++ requiresPaths);
          in
          builtins.filter referencesForward nonForward;

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

        processorCtx = {
          emit = scope'._emit;
          inherit
            instanceName
            namespaceName
            allPartResources
            packageMeta
            ;
          cluster = clusterCtx;
        };
        processorResults = map (p: p processorCtx) instanceProcessors;
        processorResources = builtins.concatMap (r: r.resources or [ ]) processorResults;
        processorWarnings = builtins.concatMap (r: r.warnings or [ ]) processorResults;

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

        packageInstance = mkPackageInstance {
          inherit instanceName namespaceName;
          namespace = namespaceResource;
          mainResource = rootRes;
          inherit packageRequires postHooks;
          inverseDeps = inverseDeps ++ processorResources;
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

        postHookWarnings =
          let
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
        packageResult = {
          warnings = packageResultRaw.warnings;
          assertions = packageResultRaw.assertions ++ scorecardDiag.assertions;
        };

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
            processorWarnings
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
                _hookResources = _scopeInjectedResources ++ processorResources;
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
