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
  inherit (import ../core/error.nix { inherit lib; }) fail;
  kixAnnotations = import ../core/annotations.nix;
  kixKeys = kixAnnotations.keys;
  inherit (k8s) mkPackageInstance;
  inherit (helpers) collectTypedAttrs knownFolders;
  inherit (scope) mkScope;
  inherit (view) mkPackageView;
  inherit (resolve)
    resolveArg
    targetsOf
    evaluateInstanceConfig
    callPackagePhase1
    buildEntriesOf
    discoverBuildDeps
    resolveDeclaredDeps
    ;
  inherit (import_) evaluateImportInstance;
  availabilityLib = import ../core/availability.nix { inherit lib; };
  packageLib = import ../core/package.nix { inherit lib; };
  cloudIdentityLib = import ../vocab/cloud-identity.nix { inherit lib; };
in

{
  evaluateInstance =
    {
      instanceName,
      namespaceName,
      instCfg,
      namespaceResource,
      # The namespace of this instance's PackageInstance record.
      recordNamespace ? namespaceResource,
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
            clusterConfig.cluster.availability.default
              or (availabilityLib.substrate (clusterConfig.cluster.capabilities or { })).level;
          instanceOverride = instCfg.availability or null;
          ceiling = availabilityLib.ceilingOfMeta {
            value = peekedPackageMeta.availability or null;
            inherit where;
          };
          ceilingReason = availabilityLib.ceilingReasonOfMeta (peekedPackageMeta.availability or null);
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

        requester = "${namespaceName}/${instanceName}";
        addedFor = instCfg._autoInstantiatedFor or [ ];

        _dnsResolution = resolveArg {
          argName = "dns";
          inherit resolutionIndex requester addedFor;
          requesterName = instanceName;
          requesterNamespace = namespaceName;
          hasDefault = true;
          explicitOverride = null;
        };
        # Return whether this instance answers `dns` itself. The resolver
        # never binds an instance to itself, so the DNS provider finds no
        # other provider and still counts as DNS for the cluster.
        _answersDns = builtins.any (c: c.namespace == namespaceName && c.instName == instanceName) (
          resolutionIndex.byKey.dns or [ ]
        );
        # Missing DNS prevents Kix from ordering workloads after a DNS provider.
        # The cluster reports it once as a warning. An inactive optional
        # instance answering `dns`, such as a flavour's platform-dns import,
        # declares DNS without ordering on it.
        _dnsMissing =
          !_dnsResolution.found && !_answersDns && !((clusterCtx.inactiveOptionalKeys or { }) ? dns);
        _dnsRoot =
          if !_dnsResolution.found || (_dnsResolution.direct or false) then
            null
          else
            let
              dnsInst = allInstances.${_dnsResolution.namespace}.${_dnsResolution.instanceName};
            in
            # Depend on the provider's root resource rather than its PackageInstance (`dnsInst.root`).
            # Import instances have no parts, so their marker in `root` is the only resource to depend on.
            if dnsInst ? raw then
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
        _netpolEnabled = clusterConfig.networkPolicy.enable or false;

        _networkPolicyEnforcer =
          if !_netpolEnabled || _enforcerProvider == null || _isSelfEnforcer then
            null
          else
            _enforcerProvider.out;

        # Resolve the instance's `cloudIdentity` against the provider of the
        # `cloudIdentity` role. A ServiceAccount the package binds depends on
        # the provider's root, so a webhook that is a Kix instance is
        # deployed first.
        _cloudIdentityValue = instCfg.cloudIdentity or null;
        _cloudIdentityProvider =
          if _cloudIdentityValue == null || !(clusterCtx ? findRoleProvider) then
            null
          else
            clusterCtx.findRoleProvider "cloudIdentity";
        _cloudIdentity = cloudIdentityLib.resolve {
          value = _cloudIdentityValue;
          provider = _cloudIdentityProvider;
        };
        _cloudIdentityRoot =
          let
            p = allInstances.${_cloudIdentityProvider.ns}.${_cloudIdentityProvider.inst};
          in
          if p ? raw then p.raw.root.resource or p.raw.root else p.root;
        _cloudIdentityHandle = cloudIdentityLib.handle {
          resolved = _cloudIdentity;
          requires = [ _cloudIdentityRoot ];
        };

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
          cloudIdentity = _cloudIdentityHandle;
          packageId = packageLib.idOf instCfg.package;
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
          instance = where;
        };

        packageMeta = packageLib.metaFrom raw;

        discoveredDeps = discoverBuildDeps raw.build;
        depsEnrichment = raw.deps or { };
        depArgNames = builtins.attrNames discoveredDeps;
        deps = instCfg.deps or { };

        resolvedDeps = resolveDeclaredDeps {
          declaredDeps = discoveredDeps;
          inherit
            resolutionIndex
            allInstances
            requester
            addedFor
            depsEnrichment
            ;
          requesterName = instanceName;
          namespace = namespaceName;
          explicitOverrides = deps;
        };

        resolutions = lib.mapAttrs (
          argName: depSpec:
          resolveArg {
            inherit
              argName
              resolutionIndex
              requester
              addedFor
              ;
            explicitOverride = deps.${argName} or null;
            requesterName = instanceName;
            requesterNamespace = namespaceName;
            hasDefault = depSpec.optional or false;
            renamedFrom = depsEnrichment.${argName}.renamedFrom or null;
          }
        ) discoveredDeps;

        resolutionWarnings = builtins.concatMap (r: r.warnings or [ ]) (builtins.attrValues resolutions);

        resolvedDepMeta = builtins.foldl' (
          acc: argName:
          let
            resolution = resolutions.${argName};
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
              helpers.mergeCollide {
                inherit (scope') fail;
                error = names: {
                  message = "Multiple `build` entries define the same part (${names}), and Kix does not allow one `build` entry to overwrite another.";
                  fix = "Give each part a unique name (for example, set `partName` or `exposurePart` on `kix.expose`, or `monitorPart` or `rulesPart` on `kix.monitor`), or use `partsOverlays` on the instance to modify an existing part.";
                };
              } acc (callBuildFn self fn)
            ) { } rawBuildEntries;
          in
          if boundOverlays != [ ] then
            builtins.foldl' (acc: overlay: acc // (overlay self acc)) merged boundOverlays
          else
            merged
        );

        rawRoot =
          parts.root or (fail {
            instance = "${namespaceName}/${instanceName}";
            message = "package build returned no 'root' attribute. Every package must set 'root' to the primary resource that other instances depend on.";
            fix = "Add `root = self.<part>;` to the attribute set returned by `build` in the package.";
          });

        rootRes =
          if rawRoot ? resource then
            rawRoot.resource
          else if rawRoot ? _type && rawRoot._type == "k8s-resource" then
            rawRoot
          else
            fail {
              instance = "${namespaceName}/${instanceName}";
              message = "package 'root' must be a resource (from scope.mk*) or `{ resource, requires?, postHooks?, out? }`.";
              fix = "Set `root = self.<part>;` or `root = { resource = self.<part>; requires = [ ... ]; };` in the package's `build`.";
            };

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

        # Collect the warnings attached to every resource the instance ships
        # (`_warnings`, `core/resource.nix` and `scope/builders.nix`): its
        # parts, the resources workload interceptors inject, and the
        # resources instance processors return. A resource that two parts
        # name gives its warnings once.
        _resourceWarnings = lib.unique (
          builtins.concatMap (r: r._warnings or [ ]) (
            _partResourcesFromParts ++ _scopeInjectedResources ++ processorResources
          )
        );

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
            fail {
              instance = "${namespaceName}/${instanceName}";
              message = "package 'root' points to ${rootRes.kind or "a resource"} '${rootRes.name or "?"}', which is not one of this package's named parts (for example, it was built inline on 'root' or taken from a dependency). Kix renders only named parts of the package, so a resource built inline on 'root' would be left out of the build.";
              fix =
                "Define the resource as a named part of this package and point 'root' to it:"
                + "\n  main = scope.mkResource { ... };"
                + "\n  root = self.main;";
            };

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

        # Return `roots` and every resource they reach through `getForwardDeps`.
        closureOf =
          roots:
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
            queue = roots;
          };

        forwardClosure = closureOf forwardRoots;

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
                acceptedSecretSources = clusterConfig.cluster.secrets.accept or null;
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

        instanceVersion = meta.instanceVersion { inherit instCfg packageOut packageMeta; };

        packageInstance = mkPackageInstance {
          inherit instanceName namespaceName;
          namespace = recordNamespace;
          mainResource = rootRes;
          inherit packageRequires postHooks;
          inverseDeps = inverseDeps ++ processorResources;
          lifecycle = packageMeta.lifecycle or null;
          # A package that deploys no software has no version, and the
          # record then omits it.
          version = instanceVersion;
          package = packageLib.idOf instCfg.package;
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

        # A post-hook runs after the package only when it reaches root or a
        # `root.requires` entry through its own dependencies.
        postHookWarnings =
          let
            plainPath = r: builtins.unsafeDiscardStringContext r.outPath;
            mainRootPaths = map plainPath ([ rootRes ] ++ packageRequires);
            hookMissingDep =
              hook:
              let
                reached = map plainPath (closureOf (getForwardDeps hook));
              in
              !(builtins.any (p: builtins.elem p reached) mainRootPaths);
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
            clusterConfig
            ;
        };
        packageResult = {
          warnings = packageResultRaw.warnings;
          assertions = packageResultRaw.assertions ++ scorecardDiag.assertions ++ cloudIdentityAssertions;
        };

        # Refuse a `cloudIdentity` the cluster cannot deliver, and one that
        # no ServiceAccount of the instance carries. `bind` leaves a
        # ServiceAccount unchanged when the first check fails, so the second
        # runs only when the first passes.
        cloudIdentityAssertions =
          let
            serviceAccountParts = builtins.filter (
              name:
              let
                v = parts.${name};
              in
              builtins.isAttrs v && (v._type or "") == "k8s-resource" && (v.kind or "") == "ServiceAccount"
            ) (builtins.attrNames (removeAttrs parts [ "root" ]));
            bound = builtins.any (r: (r._cloudIdentity or null) != null) _partResourcesFromParts;
            partName =
              if serviceAccountParts == [ ] then "serviceAccount" else builtins.head serviceAccountParts;
          in
          if !_cloudIdentity.isSet then
            [ ]
          else if _cloudIdentity.problem != null then
            [ ({ assertion = false; } // _cloudIdentity.problem) ]
          else
            [
              {
                assertion = bound;
                message =
                  "`cloudIdentity.${_cloudIdentity.cloud}` is set on this instance, but its package does not bind `scope.cloudIdentity` to a ServiceAccount. Kix did not write the cloud identity on any ServiceAccount, so the pods would start without cloud credentials. "
                  + (
                    if serviceAccountParts == [ ] then
                      "This package does not create a ServiceAccount."
                    else
                      "This package creates ServiceAccount part(s) ${
                        lib.concatMapStringsSep ", " (n: "`${n}`") serviceAccountParts
                      } without calling `scope.cloudIdentity.bind`."
                  );
                fix =
                  "Bind the ServiceAccount on this instance with `partsOverlays` (or in the package with `scope.cloudIdentity.bind`):"
                  + "\n  partsOverlays = [ (scope: self: base: {"
                  + "\n    ${partName} = scope.mkResource (scope.cloudIdentity.bind {"
                  + "\n      apiVersion = \"v1\"; kind = \"ServiceAccount\"; name = base.${partName}.name;"
                  + "\n    });"
                  + "\n  }) ];"
                  + "\nAlso check that the workload's pod spec sets `serviceAccount = self.${partName};` so pods restart when `cloudIdentity` changes.";
              }
            ];

        structuralWarnings =
          let
            res = r: "${r.kind}/${r.name}";
            about = r: message: fix: {
              object = { inherit (r) kind name; };
              inherit message fix;
            };
          in
          lib.concatLists [
            resolutionWarnings
            (map (
              w:
              about w.resource
                "${res w.resource} lists '${res w.req}' in requires, and its manifest already references '${res w.req}'. Kix already orders '${res w.resource}' after '${res w.req}'."
                "Remove '${res w.req}' from requires on ${res w.resource}."
            ) redundantRequiresWarnings)
            (map (
              w:
              about w.resource
                "${res w.resource} lists '${res w.req}' more than once in requires. Kix ignores the duplicate entry."
                "Remove the duplicate '${res w.req}' entry from requires on ${res w.resource}."
            ) duplicateRequiresWarnings)
            (map (
              r:
              about r
                "${res r} is not referenced by root or its dependencies. Kix still deploys ${res r}, and consumers of this instance do not wait for it."
                "Reference ${res r} from root, add it to requires, or remove the unused definition."
            ) orphanedWarnings)
            (map (
              r:
              about r
                "Post-hook ${res r} does not depend on root or any resource that root requires, so Kix can apply ${res r} before the package's resources are ready."
                "Reference root or one of its dependencies from ${res r}, or add one to requires on ${res r}."
            ) postHookWarnings)
            processorWarnings
            _resourceWarnings
            folderContentWarnings
          ];

        # A known folder (`secrets`, `crds`) renders only resources, so the
        # build leaves out any other typed value in it.
        folderContentWarnings = builtins.concatMap (
          folderName:
          let
            contents = parts.${folderName} or null;
            expected = knownFolders.${folderName}.expectedTypes;
          in
          if builtins.isAttrs contents && !(contents ? _type) then
            map (v: {
              message = "The '${folderName}' set in `build` contains a value with _type '${v._type}', which is not a resource. Kix left this value out of the build because '${folderName}' only holds resources.";
              fix = "Create a resource with a `scope.mk*` builder (such as `scope.mkSecret` or `scope.mkCRD`), or move this value outside '${folderName}' in `build`.";
            }) (builtins.filter (v: !(builtins.elem v._type expected)) (collectTypedAttrs { } contents))
          else
            [ ]
        ) (builtins.attrNames knownFolders);

        diagnostics = meta.combineDiagnostics {
          packageId = packageLib.idOf instCfg.package;
          inherit
            instanceName
            namespaceName
            metaResult
            packageResult
            structuralWarnings
            ;
          scorecardWarnings = scorecardDiag.warnings;
        };

      in
      builtins.seq _dnsMissing (
        builtins.seq diagnostics.evaluateWarnings (
          let
            view' = mkPackageView {
              inherit (scope') fail;
              inherit
                parts
                instanceName
                namespaceName
                packageMeta
                packageInstance
                evaluatedConfig
                ;
              version = instanceVersion;
              rootOut = (rootRes.out or { }) // packageOut;
              aliases = if (instCfg.aliases or null) == null then [ ] else instCfg.aliases;
            };
          in
          view'
          // {
            _depLinks = directDepLinks;
            _hookResources = _scopeInjectedResources ++ processorResources;
            _scorecardFindings = scorecardFindings;
            inherit _dnsMissing;
            _diagnostics = {
              warnings = diagnostics.allWarnings;
              assertions = diagnostics.allAssertions;
              inherit (diagnostics) failedAssertions;
            };
          }
        )
      );
}
