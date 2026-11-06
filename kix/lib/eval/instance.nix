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
  kixAnnotations = import ../core/annotations.nix;
  kixKeys = kixAnnotations.keys;
  inherit (k8s) mkPackageInstance;
  inherit (helpers) collectTypedAttrs;
  inherit (scope) mkScope;
  inherit (view) mkPackageView;
  inherit (resolve)
    resolveArg
    targetsOf
    describeRequester
    evaluateInstanceConfig
    callPackagePhase1
    buildEntriesOf
    discoverBuildDeps
    resolveDeclaredDeps
    ;
  inherit (import_) evaluateImportInstance;
  availabilityLib = import ../core/availability.nix { inherit lib; };
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
      # This instance's pins from the cluster's pin file (eval/instance-pins.nix).
      instancePins ? null,
      workloadInterceptors ? [ ],
      instanceProcessors ? [ ],
      clusterCtx ? { },
      annotationDomainIndex ? { },
      factBehaviorOverrides ? { },
      # Report whether namespace/instance renders. Read by import instances
      # whose extraDeps may name another instance.
      isInstanceActive,
    }@args:

    if (instCfg.package._type or "") == "kix-import" then
      evaluateImportInstance args

    else
      let
        peekedPackageMeta = meta.peekPackageMeta {
          package = instCfg.package;
          inherit kixlib;
        };

        where = "${namespaceName}/${instanceName}";

        # Resolve the instance override or cluster default against the package
        # ceiling and substrate capabilities. Pass the result to the package,
        # workload interceptors, and instance processors.
        availability = availabilityLib.resolve {
          capabilities = clusterConfig.cluster.capabilities or { };
          clusterDefault =
            ((clusterConfig.cluster or { }).availability or { }).default
              or (availabilityLib.substrate (clusterConfig.cluster.capabilities or { })).level;
          instanceOverride = instCfg.availability or null;
          ceiling = availabilityLib.ceilingOfMeta {
            value = peekedPackageMeta.availability or null;
            inherit where;
          };
          inherit where;
        };

        packageKix = kixlib // {
          availability =
            kixlib.availability
            // availabilityLib.underCeiling {
              inherit (availability) ceiling;
              inherit where;
            };
        };

        requester = describeRequester namespaceName instanceName instCfg;

        _dnsResolution = resolveArg {
          argName = "dns";
          inherit resolutionIndex requester;
          requesterNamespace = namespaceName;
          hasDefault = true;
          explicitOverride = null;
        };
        # Missing DNS prevents Kix from ordering workloads after a DNS provider.
        # This remains a warning until diagnostics support severity levels.
        # An inactive optional instance answering `dns`, such as a flavour's
        # platform-dns import, declares DNS without ordering on it.
        _dnsResolutionCheck =
          if !_dnsResolution.found && !((clusterCtx.inactiveOptionalKeys or { }) ? dns) then
            builtins.trace "[kix] warning: no DNS instance (alias 'dns') was found. Kix will not wait for DNS to be ready before deploying workloads. Add a DNS provider or import if this ordering is required" null
          else
            null;
        _dnsRoot =
          if !_dnsResolution.found || (_dnsResolution.direct or false) then
            null
          else
            let
              dnsInst = allInstances.${_dnsResolution.namespace}.${_dnsResolution.instanceName};
            in
            if _dnsResolution.namespace == namespaceName && _dnsResolution.instanceName == instanceName then
              null
            # Depend on the provider's root resource rather than its PackageInstance (`dnsInst.root`).
            # Import instances have no parts, so their marker in `root` is the only resource to depend on.
            else if dnsInst ? raw then
              dnsInst.raw.root.resource or dnsInst.raw.root
            else if dnsInst ? root then
              dnsInst.root
            else
              null;

        _enforcerProvider =
          if !(clusterCtx ? findRoleProvider) then
            null
          else
            clusterCtx.findRoleProvider "network-policy-enforcer";

        _isSelfEnforcer =
          _enforcerProvider != null
          && _enforcerProvider.ns == namespaceName
          && _enforcerProvider.inst == instanceName;

        # The netpol plugin declares networkPolicy.enable, so clusters without
        # the plugin default to false.
        _netpolEnabled = (clusterConfig.networkPolicy or { }).enable or false;

        _networkPolicyEnforcer =
          if !_netpolEnabled || _enforcerProvider == null || _isSelfEnforcer then
            null
          else
            _enforcerProvider.out;

        _edgeAnalysis = rec {
          serviceRegistry = edgeAnalysis.mkServiceRegistry _depResourcesForEdges;
          serviceRefRegistry = edgeAnalysis.mkServiceRefRegistry _depResourcesForEdges;
          serviceIndex = edgeAnalysis.mkServiceIndex _depResourcesForEdges;
          inherit (edgeAnalysis) isServiceRef;
          dnsRoot = _dnsRoot;
          edgesFor =
            workloadInput:
            edgeAnalysis.analyzeEdges {
              json = builtins.toJSON workloadInput;
              # Helm rendering can discard address facts while retaining
              # resource identity, so treat identity matches as connections.
              conservative = workloadInput ? _helmNetworkDeps;
              inherit serviceRegistry serviceRefRegistry serviceIndex;
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
            availability
            ;
          networkPolicyEnforcer = _networkPolicyEnforcer;
          namespaces = nsResources;
          labelStyle = instCfg.labelStyle;
          selectorLabelsOverride = instCfg.selectorLabels;
          inherit (clusterConfig) clusterDomain;
          capabilities = clusterConfig.cluster.capabilities or { };
          inherit factBehaviorOverrides;
          # The outer fixpoint settles this value before the first mkWorkload call forces it.
          edgeAnalysis = _edgeAnalysis;
        };

        _depResourcesForEdges = builtins.concatMap (
          depTarget:
          builtins.filter (v: (v._type or "") == "k8s-resource") (
            collectTypedAttrs {
              excludeKeys = [
                "root"
                "meta"
              ];
            } (depTarget.instance.raw or { })
          )
        ) allDepTargets;

        raw = callPackagePhase1 {
          package = instCfg.package;
          scope = scope';
          availability = availability.level;
          kix = packageKix;
        };

        packageMeta = raw.meta or { };

        discoveredDeps = discoverBuildDeps raw.build;
        depsEnrichment = raw.deps or { };
        depArgNames = builtins.attrNames discoveredDeps;
        deps = instCfg.deps or { };

        resolvedDeps = resolveDeclaredDeps {
          declaredDeps = discoveredDeps;
          inherit resolutionIndex allInstances requester;
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
              inherit
                argName
                resolutionIndex
                explicitOverride
                requester
                ;
              requesterNamespace = namespaceName;
              hasDefault = isOptional;
            };
          in
          if resolution.found && !(resolution.direct or false) then
            acc
            // {
              ${argName} = {
                targets = map (t: {
                  resolution = t;
                  instance = allInstances.${t.namespace}.${t.instanceName};
                }) (targetsOf resolution);
                value = resolvedDeps.${argName};
              };
            }
          else
            acc
        ) { } depArgNames;

        allDepTargets = builtins.concatMap (depInfo: depInfo.targets) (builtins.attrValues resolvedDepMeta);

        _crossNsCheck =
          let
            crossNsDeps = builtins.filter (
              depTarget:
              let
                depScope = (depTarget.instance._meta.packageMeta or { }).scope or "cluster";
              in
              depTarget.resolution.namespace != namespaceName && depScope == "namespace"
            ) allDepTargets;
          in
          lib.foldl' (
            _: depTarget:
            throw "instance '${instanceName}' (namespace '${namespaceName}') depends on '${depTarget.resolution.instanceName}' (namespace '${depTarget.resolution.namespace}') which declares meta.scope = \"namespace\" and can only be used within its own namespace"
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
          packageConfig = raw.config or { };
          packageConfigFile = "package config of ${namespaceName}/${instanceName}";
          inherit
            instCfg
            clusterConfig
            configInjections
            instancePins
            namespaceName
            instanceName
            ;
        };

        allOverlays = globalPartsOverlays ++ (instCfg.partsOverlays or [ ]);
        boundOverlays = map (o: o scope') allOverlays;

        rawBuildEntries = buildEntriesOf raw.build;

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
              // lib.optionalAttrs (args ? kix) { kix = packageKix; }
              // lib.optionalAttrs (args ? deps) { deps = resolvedDeps; }
              // lib.optionalAttrs (args ? availability) { availability = availability.level; };
            depArgs = lib.intersectAttrs args resolvedDeps;
          in
          fn (base // extra // depArgs);

        parts = lib.fix (
          self:
          let
            # mergeCollide compares key sets only, keeping the fixpoint lazy.
            # partsOverlays use `//` so they can replace existing parts.
            merged = builtins.foldl' (
              acc: fn:
              helpers.mergeCollide
                "${namespaceName}/${instanceName}: two build entries define the same part, and the later one would silently replace the earlier. Rename one of them (kix.expose takes partName and exposurePart; kix.monitor takes monitorPart and rulesPart), or use partsOverlays to replace a part on purpose. Duplicated part"
                acc
                (callBuildFn self fn)
            ) { } rawBuildEntries;
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

        # Monitor and rule objects reference nothing else in the instance,
        # so the PackageInstance requires them directly. Matching by kind
        # also covers a part a partsOverlay replaces and a PodMonitor a
        # package builds itself.
        packageRequires =
          let
            declared = if rawRoot ? resource then rawRoot.requires or [ ] else [ ];
            declaredPaths = map (r: builtins.unsafeDiscardStringContext (r.outPath or "")) declared;
            monitorKinds = [
              "ServiceMonitor"
              "PodMonitor"
              "PrometheusRule"
              "VMRule"
            ];
            monitorParts = builtins.filter (
              r:
              builtins.elem (r.kind or null) monitorKinds
              && !(builtins.elem (builtins.unsafeDiscardStringContext r.outPath) declaredPaths)
            ) _partResourcesFromParts;
          in
          declared ++ monitorParts;

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

        # Collect resources that workload interceptors attached before sealing.
        _scopeInjectedResources = builtins.concatMap (
          r: r._injectedResources or [ ]
        ) _partResourcesFromParts;

        # collectTypedAttrs excludes root, so the root resource must also be
        # assigned to a named part to be included in the manifest set.
        _rootRendersCheck =
          let
            plainPath = r: builtins.unsafeDiscardStringContext r.outPath;
            partPaths = map plainPath _partResourcesFromParts;
          in
          if builtins.elem (plainPath rootRes) partPaths then
            null
          else
            throw (
              "Instance '${instanceName}' in namespace '${namespaceName}': `root` points at "
              + "${rootRes.kind or "a resource"}/${rootRes.name or "?"}, which is not assigned to "
              + "any named part, so its manifest will not be included in the build. "
              + "Assign the resource to a named part and reference it from root, for example "
              + "`myPart = scope.mkResource { ... }; root = self.myPart;`."
            );

        allPartResources = builtins.seq _rootRendersCheck (
          _partResourcesFromParts ++ _scopeInjectedResources
        );

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
            availability
            ;
          cluster = clusterCtx;
          # Check only the forward closure because processor output is added to
          # inverseDeps and would cause infinite recursion.
          forwardReachable = r: builtins.hasAttr (builtins.unsafeDiscardStringContext r.outPath) forwardPaths;
        };
        processorResults = map (p: p processorCtx) instanceProcessors;
        processorResources = builtins.concatMap (r: r.resources or [ ]) processorResults;
        processorWarnings = builtins.concatMap (r: r.warnings or [ ]) processorResults;

        # Record each dependency as "namespace/instance" with its evaluated view.
        # resolvedDepMeta covers auto-resolved dependencies, while directly
        # wired dependencies expose their identity through _meta.
        directDepLinks =
          let
            linkOf =
              v:
              let
                m = if builtins.isAttrs v then v._meta or null else null;
              in
              if builtins.isAttrs m && m ? namespaceName && m ? instanceName then
                [
                  {
                    id = "${m.namespaceName}/${m.instanceName}";
                    instance = v;
                  }
                ]
              else
                [ ];
          in
          map (depTarget: {
            id = "${depTarget.resolution.namespace}/${depTarget.resolution.instanceName}";
            instance = depTarget.instance;
          }) allDepTargets
          ++ builtins.concatMap (v: if builtins.isList v then builtins.concatMap linkOf v else linkOf v) (
            builtins.attrValues deps
          );

        # Follow _depLinks transitively so annotation-domain checks recognize
        # declarers reached through another dependency.
        transitiveDepTargets =
          let
            go =
              seen: queue:
              if queue == [ ] then
                seen
              else
                let
                  link = builtins.head queue;
                  rest = builtins.tail queue;
                in
                if builtins.hasAttr link.id seen then
                  go seen rest
                else
                  go (seen // { ${link.id} = true; }) (rest ++ (link.instance._depLinks or [ ]));
          in
          builtins.attrNames (go { } directDepLinks);

        scorecardConfig = clusterConfig.scorecard or { };
        scorecardEnabled = (scorecardConfig.enable or false) && (scorecardConfig.rules or { }) != { };
        owner = packageMeta.owner or null;

        shippedResources = allPartResources ++ processorResources;

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
                meta = packageMeta;
                ruleDefaults = scorecardConfig.ruleDefaults or { };
                ruleOverrides = scorecardConfig.ruleOverrides or { };
                maxSeverity = scorecardConfig.maxSeverity or "error";
                acceptedSecretSources = ((clusterConfig.cluster or { }).secrets or { }).accept or null;
              }
            ) (builtins.filter (r: r ? kind) (map (r: r.rawManifest or { }) shippedResources))
          else
            [ ];

        scorecardPackageFindings =
          if scorecardEnabled then
            scorecard.evaluatePackageRules {
              rules = scorecardConfig.rules;
              resources = map (r: r.rawManifest or { }) shippedResources;
              resourceObjects = shippedResources;
              inherit
                parts
                instanceName
                namespaceName
                owner
                annotationDomainIndex
                ;
              config = evaluatedConfig;
              meta = packageMeta;
              resolvedDepTargets = transitiveDepTargets;
              knownAnnotationDomains = scorecardConfig.knownAnnotationDomains or [ ];
              ruleDefaults = scorecardConfig.ruleDefaults or { };
              ruleOverrides = scorecardConfig.ruleOverrides or { };
              maxSeverity = scorecardConfig.maxSeverity or "error";
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
          # Packages whose software version varies per instance, such as a
          # database cluster, report it through `out.version`. A package
          # that deploys no software has none, and the record then omits it.
          version =
            let
              v = instCfg.version or null;
            in
            if v != null then
              v
            else if (packageMeta.version or null) != null then
              packageMeta.version
            else
              packageOut.version or null;
          labels = clusterLabels // {
            "app.kubernetes.io/instance" = instanceName;
            "app.kubernetes.io/managed-by" = "kix";
          };
          extraAnnotations =
            lib.optionalAttrs (instCfg._autoInstantiated or false) {
              ${kixKeys.autoInstantiated} = "true";
            }
            // lib.optionalAttrs (instCfg.optional or false) {
              ${kixKeys.optionalActivated} = "true";
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
              "resource '${res w.resource}' already references '${res w.req}'. Remove the redundant entry from requires; Kix tracks this dependency automatically."
            ) redundantRequiresWarnings)
            (warn (
              w: "resource '${res w.resource}' requires '${res w.req}' multiple times"
            ) duplicateRequiresWarnings)
            (warn (
              r:
              "resource '${res r}' is not referenced by root or its dependencies. Reference it from root, add it to requires, or remove the unused definition."
            ) orphanedWarnings)
            (warn (
              r:
              "post-hook '${res r}' has no dependency on root or any resource that root requires. Add a dependency to ensure the hook runs after the resource it needs."
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
                _depLinks = directDepLinks;
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
