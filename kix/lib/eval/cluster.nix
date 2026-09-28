{
  lib,
  k8s,
  meta,
  kixlib,
  helpers,
  scorecard,
  validate,
  hooks,
  roles,
  mkNamespace,
  computeAutoInstances,
  possibleInstanceNames,
  buildResolutionIndex,
  callPackagePhase1,
  discoverBuildDeps,
  resolveDepTargets,
  buildConfigInjections,
  evaluateInstanceConfig,
  evaluateInstance,
  mkImport,
}:

{
  buildCluster =
    {
      name ? "cluster",
      modules,
      specialArgs ? { },
    }:
    let
      # Module merge stays lazy: ref thunks in config values are not forced here.
      evaluated = lib.evalModules {
        modules = [ (import ../modules.nix) ] ++ modules;
        specialArgs = {
          inherit ref;
          kix = {
            inherit mkImport;
          };
        }
        // specialArgs;
      };

      cfg = evaluated.config;

      autoResult = computeAutoInstances {
        explicitInstances = cfg.instances;
        availablePackages = cfg.availablePackages;
        autoNamespace = cfg.autoNamespace;
        clusterRoles = cfg.cluster.roles;
      };

      mergedInstances = lib.recursiveUpdate autoResult.autoInstances cfg.instances;

      # `ref.<ns>.<inst>` is a pointer to an instance, not the instance. It
      # is built over every name auto-instantiation could produce, which is
      # known before auto-instantiation runs, so computeAutoInstances and the
      # phase-1 pre-pass can both read `deps.x = ref.a.b` without recursion:
      # the wired dep then resolves like an auto-resolved one (config
      # injection lands on it, meta.scope and version constraints apply to
      # it). resolveArg dereferences it. A name outside that set fails at the
      # `ref.a.b` access; one inside it that was not created fails in
      # _refTargetsCheck.
      ref =
        lib.mapAttrs
          (
            nsName: instNames:
            lib.genAttrs instNames (instName: {
              _type = "kix-ref";
              namespace = nsName;
              instanceName = instName;
            })
          )
          (possibleInstanceNames {
            explicitInstances = cfg.instances;
            availablePackages = cfg.availablePackages;
            autoNamespace = cfg.autoNamespace;
          });

      _refTargetsCheck = lib.foldlAttrs (
        acc: nsName: nsInsts:
        lib.foldlAttrs (
          acc: instName: instCfg:
          lib.foldlAttrs (
            acc: arg: v:
            if
              builtins.isAttrs v
              && (v._type or "") == "kix-ref"
              && !((mergedInstances.${v.namespace} or { }) ? ${v.instanceName})
            then
              throw "kix: ${nsName}/${instName} sets deps.${arg} = ref.${v.namespace}.${v.instanceName}, which is not an instance. It names a package in availablePackages that nothing auto-instantiated there; declare it under instances.${v.namespace}.${v.instanceName}."
            else
              acc
          ) acc (instCfg.deps or { })
        ) acc nsInsts
      ) null cfg.instances;

      allNsNames = lib.unique (builtins.attrNames cfg.namespaces ++ builtins.attrNames mergedInstances);

      isSentinelNs = nsName: lib.hasPrefix "_" nsName;
      realNsNames = builtins.filter (n: !isSentinelNs n) allNsNames;

      # Pod Security Standards from most to least permissive. A namespace
      # uses the most permissive level required by any of its instances.
      podSecurityLevels = [
        "privileged"
        "baseline"
        "restricted"
      ];
      podSecurityRank =
        nsName: instName: level:
        let
          i = lib.lists.findFirstIndex (l: l == level) null podSecurityLevels;
        in
        if i == null then
          throw (
            "[${nsName}/${instName}] meta.podSecurity = \"${toString level}\" is not one of "
            + lib.concatStringsSep ", " podSecurityLevels
          )
        else
          i;

      # Derive the namespace level from its instances unless the cluster sets
      # one explicitly. Reject an explicit level that is more restrictive than
      # an instance requirement before Kubernetes rejects the resulting pod.
      namespacePodSecurity =
        nsName:
        let
          declared = (cfg.namespaces.${nsName} or { }).podSecurity or null;
          needs = lib.filter (n: n.level != null) (
            lib.mapAttrsToList (instName: _: {
              inherit instName;
              level = (peekedMetas.${nsName}.${instName}).podSecurity or null;
            }) (mergedInstances.${nsName} or { })
          );
          ranked = map (n: n // { rank = podSecurityRank nsName n.instName n.level; }) needs;
          mostPermissive = builtins.foldl' (
            acc: n: if acc == null || n.rank < acc.rank then n else acc
          ) null ranked;
          declaredRank = if declared == null then null else podSecurityRank nsName "namespace" declared;
        in
        if mostPermissive == null then
          declared
        else if declaredRank != null && declaredRank > mostPermissive.rank then
          throw (
            "namespace '${nsName}' sets podSecurity = \"${declared}\", but instance "
            + "'${mostPermissive.instName}' declares meta.podSecurity = \"${mostPermissive.level}\": "
            + "its pods would be refused. Raise the namespace level, or move the instance."
          )
        else
          mostPermissive.level;

      nsResources = builtins.listToAttrs (
        map (nsName: {
          name = nsName;
          value = mkNamespace (
            {
              name = nsName;
            }
            // (cfg.namespaces.${nsName} or { })
            // {
              podSecurity = namespacePodSecurity nsName;
            }
          );
        }) allNsNames
      );

      # Cache package metadata once per instance for the resolution indexes
      # and instanceInfo.
      peekedMetas = lib.mapAttrs (
        _nsName: nsInsts:
        lib.mapAttrs (
          _instName: instCfg:
          meta.peekPackageMeta {
            package = instCfg.package;
            inherit kixlib;
          }
        ) nsInsts
      ) mergedInstances;

      # Resolve dependencies, roles, and annotation domains against active
      # managed instances and all platform imports. Inactive optional instances
      # emit no resources and must not satisfy a dependency.
      isResolvable =
        nsName: instName:
        isActive nsName instName
        || (mergedInstances.${nsName}.${instName}.package._type or "") == "kix-import";

      resolvableInstances = lib.mapAttrs (
        nsName: nsInsts: lib.filterAttrs (instName: _: isResolvable nsName instName) nsInsts
      ) mergedInstances;

      staticMeta = lib.mapAttrs (
        nsName: nsInsts:
        lib.mapAttrs (
          instName: instCfg:
          let
            packageMeta = peekedMetas.${nsName}.${instName};
          in
          {
            _meta = {
              instanceName = instName;
              namespaceName = nsName;
              namespace = nsName;
              aliases = meta.effectiveAliases {
                instanceAliases = instCfg.aliases or [ ];
                inherit packageMeta;
              };
              isImport = (instCfg.package._type or "") == "kix-import";
            };
          }
        ) nsInsts
      ) resolvableInstances;

      resolutionIndex = buildResolutionIndex staticMeta;

      # Validate role declarations for every configured instance, including
      # inactive optionals. Role lookup uses the filtered rolesIndex below.
      rolesIndexAll = hooks.buildRolesIndex {
        instances = mergedInstances;
        inherit peekedMetas;
      };
      _rolesValidation = builtins.deepSeq rolesIndexAll null;

      rolesIndex = lib.mapAttrs (
        nsName: nsInsts: lib.filterAttrs (instName: _: isResolvable nsName instName) nsInsts
      ) rolesIndexAll;

      # Map annotation domains to declarers. Force the index below so duplicate
      # or malformed declarations fail even when the scorecard is disabled.
      annotationDomainIndex = hooks.buildAnnotationDomainIndex {
        instances = resolvableInstances;
        inherit peekedMetas;
      };
      # Force annotation-domain and fact-behavior validation together.
      _annotationDomainsCheck = builtins.seq (builtins.deepSeq annotationDomainIndex null) _factBehaviorCheck;

      # cluster.factBehavior overrides CRD declarations and covers custom
      # resources without typed builders. Require "group/Kind" keys because
      # different API groups can define the same kind. Validate every entry
      # even when the cluster contains no resource of that kind.
      factBehaviorOverrides = cfg.cluster.factBehavior or { };
      _factBehaviorCheck = builtins.foldl' (
        acc: key:
        let
          _shape =
            if !(lib.hasInfix "/" key) then
              throw (
                "kix: cluster.factBehavior key '${key}' must be \"group/Kind\" "
                + "(e.g. \"stackgres.io/SGCluster\"). bare kinds collide across API groups."
              )
            else
              null;
        in
        builtins.seq _shape (
          builtins.seq (k8s.facts.validateBehavior "cluster.factBehavior" key
            factBehaviorOverrides.${key}
          ) acc
        )
      ) null (builtins.attrNames factBehaviorOverrides);

      # Keep provider outputs lazy because they read the clusterInstances
      # fixpoint. Check each output contract when a consumer first accesses
      # the role. Memoize one provider lookup per role because many consumers
      # can request the same provider.
      roleProviders = lib.genAttrs roles.roleNames (
        role:
        let
          lookup = hooks.findRoleProvider {
            inherit role rolesIndex;
            clusterRoles = cfg.cluster.roles;
          };
        in
        if lookup == null then
          null
        else
          lookup
          // {
            out = roles.checkOutContract {
              inherit role;
              providerLabel = "${lookup.ns}/${lookup.inst}";
              out = clusterInstances.${lookup.ns}.${lookup.inst}.out or null;
            };
          }
      );

      findRoleProvider =
        role: builtins.seq (roles.assertKnownRole "findRoleProvider" role) roleProviders.${role};

      # Reject exclusive-binding conflicts and duplicate strong providers even
      # when no consumer requests the role.
      _roleBindingsCheck = hooks.checkRoleBindings {
        clusterRoles = cfg.cluster.roles;
        inherit rolesIndex;
      };

      clusterCtx = {
        config = cfg;
        inherit findRoleProvider;
      };

      workloadInterceptors = hooks.collectHooks cfg "workloadInterceptors";
      instanceProcessors = hooks.collectHooks cfg "instanceProcessors";
      clusterProcessors = hooks.collectHooks cfg "clusterProcessors";

      # Only `ref` pointers are read here. Any other explicit dep value is a
      # foreign object the fixpoint may own, so it is bound in step 7 and
      # never injected into.
      phase1Instances = lib.mapAttrs (
        nsName: nsInsts:
        lib.mapAttrs (
          instName: instCfg:
          if (instCfg.package._type or "") == "kix-import" then
            {
              discoveredDeps = { };
              depsEnrichment = { };
              resolvedTargets = { };
              packageOptions = { };
            }
          else
            let
              raw = callPackagePhase1 {
                package = instCfg.package;
                scope = {
                  instanceName = instName;
                  namespaceName = nsName;
                };
              };
              discoveredDeps = discoverBuildDeps raw.build;
              depsEnrichment = raw.deps or { };
              resolvedTargets = resolveDepTargets {
                declaredDeps = discoveredDeps;
                inherit resolutionIndex;
                namespace = nsName;
                explicitOverrides = lib.filterAttrs (_: v: builtins.isAttrs v && (v._type or "") == "kix-ref") (
                  instCfg.deps or { }
                );
              };
            in
            {
              inherit discoveredDeps depsEnrichment resolvedTargets;
              packageOptions = raw.options or { };
            }
        ) nsInsts
      ) mergedInstances;

      configInjections = buildConfigInjections phase1Instances;

      resolveInjectionsAgainst =
        configMap: nsName: instName:
        map (
          inj:
          if builtins.isFunction inj.config then
            let
              consumerCfg = (configMap.${inj.consumerNs} or { }).${inj.consumerInst} or { };
            in
            inj // { config = inj.config consumerCfg; }
          else
            inj
        ) (configInjections.${nsName}.${instName} or [ ]);

      # Resolve consumer-to-dependency config injections in a config-only
      # fixpoint so they do not depend on full instance views.
      instanceConfigs = lib.fix (
        selfCfg:
        lib.mapAttrs (
          nsName: nsInsts:
          lib.mapAttrs (
            instName: instCfg:
            if (instCfg.package._type or "") == "kix-import" then
              { }
            else
              evaluateInstanceConfig {
                packageOptions = phase1Instances.${nsName}.${instName}.packageOptions;
                inherit instCfg;
                clusterConfig = cfg;
                configInjections = resolveInjectionsAgainst selfCfg nsName instName;
              }
          ) nsInsts
        ) mergedInstances
      );

      resolveInjections = resolveInjectionsAgainst instanceConfigs;

      # Evaluate full instance views after every injected config is an attrset.
      clusterInstances = lib.fix (
        self:
        lib.mapAttrs (
          nsName: nsInsts:
          lib.mapAttrs (
            instName: instCfg:
            evaluateInstance {
              instanceName = instName;
              namespaceName = nsName;
              inherit instCfg nsResources;
              namespaceResource = nsResources.${nsName};
              allInstances = self;
              clusterLabels = cfg.clusterLabels;
              clusterConfig = cfg;
              inherit resolutionIndex;
              globalPartsOverlays = cfg.globalPartsOverlays;
              configInjections = resolveInjections nsName instName;
              inherit workloadInterceptors instanceProcessors clusterCtx;
              inherit annotationDomainIndex factBehaviorOverrides;
            }
          ) nsInsts
        ) mergedInstances
      );

      isActive =
        nsName: instName:
        let
          instCfg = mergedInstances.${nsName}.${instName};
          isOptional = instCfg.optional or false;
          isActivated = builtins.hasAttr "${nsName}/${instName}" autoResult.activatedOptionals;
        in
        !isOptional || isActivated;

      allInstancesList = builtins.concatMap (
        nsName:
        builtins.filter (inst: inst != null) (
          map (instName: if isActive nsName instName then clusterInstances.${nsName}.${instName} else null) (
            builtins.attrNames (clusterInstances.${nsName} or { })
          )
        )
      ) (builtins.attrNames clusterInstances);

      collectResources =
        inst:
        helpers.instancePartResources inst
        ++ (if inst ? _packageInstance then [ inst._packageInstance ] else [ ])
        ++ (inst._hookResources or [ ]);

      clusterHookCtx = {
        cluster = clusterCtx;
        inherit nsResources realNsNames;
      };
      clusterHookResults = map (p: p clusterHookCtx) clusterProcessors;
      # Preserve hook execution order (priority, then name) in both Activation
      # dependencies and the manifest list because order affects output hashes.
      clusterHookResources = builtins.concatMap (r: r.resources or [ ]) clusterHookResults;
      clusterHookChecks = builtins.concatMap (r: r.checks or [ ]) clusterHookResults;
      clusterHookWarnings = builtins.concatMap (r: r.warnings or [ ]) clusterHookResults;

      scorecardConfig = cfg.scorecard or { };
      scorecardEnabled = (scorecardConfig.enable or false) && (scorecardConfig.rules or { }) != { };

      instanceScorecardFindings =
        if scorecardEnabled then
          builtins.concatMap (inst: inst._scorecardFindings or [ ]) allInstancesList
        else
          [ ];

      # The enforcer's policy kinds reach the namespace rules through the
      # role lookup, so the rules stay free of any enforcer's vocabulary.
      networkPolicyKinds =
        let
          provider = findRoleProvider "network-policy-enforcer";
        in
        [ "NetworkPolicy" ] ++ (if provider == null then [ ] else provider.out.netpol.policyKinds or [ ]);

      namespaceScorecardFindings =
        if scorecardEnabled then
          builtins.concatMap (
            nsName:
            let
              nsInstances = clusterInstances.${nsName} or { };
              activeNsInstances = lib.filterAttrs (instName: _: isActive nsName instName) nsInstances;
              nsResources = builtins.concatMap (inst: map (r: r.rawManifest or { }) (collectResources inst)) (
                builtins.attrValues activeNsInstances
              );
            in
            scorecard.evaluateNamespaceRules {
              rules = scorecardConfig.rules;
              instances = activeNsInstances;
              resources = nsResources;
              namespaceName = nsName;
              inherit networkPolicyKinds;
              ruleDefaults = scorecardConfig.ruleDefaults or { };
              ruleOverrides = scorecardConfig.ruleOverrides or { };
              maxSeverity = scorecardConfig.maxSeverity or "error";
            }
          ) realNsNames
        else
          [ ];

      clusterScorecardFindings =
        if scorecardEnabled then
          scorecard.evaluateClusterRules {
            rules = scorecardConfig.rules;
            externalNames = externalRefNames;
            # Cluster rules see active instances in real namespaces. Inactive
            # optionals and sentinel namespaces do not make a namespace managed.
            allInstances = lib.filterAttrs (_: insts: insts != { }) (
              lib.mapAttrs (nsName: nsInsts: lib.filterAttrs (instName: _: isActive nsName instName) nsInsts) (
                lib.filterAttrs (nsName: _: builtins.elem nsName realNsNames) clusterInstances
              )
            );
            allResources = builtins.concatMap (
              inst: map (r: r.rawManifest or { }) (collectResources inst)
            ) allInstancesList;
            clusterConfig = cfg;
            ruleDefaults = scorecardConfig.ruleDefaults or { };
            ruleOverrides = scorecardConfig.ruleOverrides or { };
            maxSeverity = scorecardConfig.maxSeverity or "error";
          }
        else
          [ ];

      allScorecardFindings =
        instanceScorecardFindings ++ namespaceScorecardFindings ++ clusterScorecardFindings;

      extraImages =
        let
          perInstance = builtins.concatMap (
            inst:
            let
              imgs = inst.out.extraImages or [ ];
              instName = inst._meta.instanceName or "<unknown>";
              nsName = inst._meta.namespaceName or "<unknown>";
            in
            map (img: {
              image = img;
              source = {
                kind = "PackageInstance";
                namespace = nsName;
                name = instName;
                container = "<operator-managed>";
              };
            }) imgs
          ) allInstancesList;
        in
        if perInstance == [ ] then null else perInstance;

      scorecardReport =
        if scorecardEnabled then
          scorecard.buildScorecardReport { findings = allScorecardFindings; }
        else
          null;

      # collectResources can encounter aliases of the same resource. Collapse
      # equal store paths before checking identity collisions and writing the
      # manifest list.
      allResources = dedupeByOutPath (
        [
          k8s.kixCRDs.packageInstance
          k8s.kixCRDs.activation
        ]
        ++ (builtins.concatMap collectResources allInstancesList)
        ++ (builtins.concatMap (
          nsName:
          let
            ns = nsResources.${nsName};
          in
          [ ns.resource ]
          ++ (if ns.quota != null then [ ns.quota ] else [ ])
          ++ builtins.attrValues ns.netpols
        ) realNsNames)
        ++ clusterHookResources
        ++ [ activation ]
      );

      # Remove Nix string context from the manifest list consumed by the CLI,
      # manifest writer, and cross-resource validation.
      rawManifestList = map (
        r: builtins.fromJSON (builtins.unsafeDiscardStringContext (builtins.toJSON r.rawManifest))
      ) allResources;

      dedupeByOutPath =
        rs:
        let
          step =
            acc: r:
            let
              key = if r ? outPath then builtins.unsafeDiscardStringContext (toString r.outPath) else null;
            in
            if key == null then
              acc // { list = acc.list ++ [ r ]; }
            else if acc.seen ? ${key} then
              acc
            else
              {
                seen = acc.seen // {
                  ${key} = true;
                };
                list = acc.list ++ [ r ];
              };
        in
        (builtins.foldl' step {
          seen = { };
          list = [ ];
        } rs).list;

      activeClusterInstances = lib.mapAttrs (
        nsName: nsInsts: lib.filterAttrs (instName: _: isActive nsName instName) nsInsts
      ) clusterInstances;

      activation = k8s.mkActivation {
        inherit name;
        instances = lib.mapAttrs (
          _nsName: nsInsts: lib.mapAttrs (_: inst: inst._packageInstance.out.name) nsInsts
        ) activeClusterInstances;
        extraDeps = clusterHookResources;
      };

      packageIndex = builtins.toFile "kix-packages.json" (
        builtins.toJSON {
          cluster = name;
          packages = builtins.listToAttrs (
            map (inst: {
              name = builtins.unsafeDiscardStringContext (toString inst._packageInstance.outPath);
              value = map (r: builtins.unsafeDiscardStringContext (toString r.outPath)) (collectResources inst);
            }) allInstancesList
          );
        }
      );

      # Surface namespace and cluster scorecard findings here because no
      # instance owns them. Warnings trace during evaluation; error findings
      # become build assertions.
      crossScorecardDiag = scorecard.scorecardToWarnings (
        namespaceScorecardFindings ++ clusterScorecardFindings
      );

      # Run cross-resource checks on the finished manifest list and convert
      # each failure into a build assertion.
      crossResourceAssertions =
        map
          (f: {
            assertion = false;
            message = "[validate] ${f}";
          })
          (
            validate.crossResourceFailures {
              manifests = rawManifestList;
              externalNames = externalRefNames;
            }
          );

      # Collect names marked with kix.untrackedRef before rawManifestList
      # removes string context. Key entries by the referring resource's
      # namespace so an exemption does not apply across namespaces. Each
      # value is { creatorNamed; }, true only when every reference to that
      # key named its kind and creator.
      externalRefNames =
        let
          markersOf =
            s: builtins.filter k8s.markers.isUntrackedRefPath (builtins.attrNames (builtins.getContext s));
          walk =
            v:
            if builtins.isString v then
              (
                let
                  ms = markersOf v;
                in
                if ms != [ ] then
                  [
                    {
                      name = builtins.unsafeDiscardStringContext v;
                      creatorNamed = builtins.all k8s.markers.namesCreator ms;
                    }
                  ]
                else
                  [ ]
              )
            # rawManifest is JSON-shaped: sealing goes through builtins.toFile,
            # which refuses derivation references, so no self-referential
            # derivation attrset can be here.
            else if builtins.isAttrs v then
              builtins.concatMap walk (builtins.attrValues v)
            else if builtins.isList v then
              builtins.concatMap walk v
            else
              [ ];
          # Attribute names may not carry context; the namespace value does.
          nsOf =
            r:
            builtins.unsafeDiscardStringContext (
              toString (r.rawManifest.metadata.namespace or "cluster-scoped")
            );
        in
        builtins.foldl'
          (
            acc: e:
            acc
            // {
              ${e.key}.creatorNamed = e.creatorNamed && (acc.${e.key}.creatorNamed or true);
            }
          )
          { }
          (
            builtins.concatMap (
              r:
              map (n: {
                key = "${nsOf r}/${n.name}";
                inherit (n) creatorNamed;
              }) (walk r.rawManifest)
            ) allResources
          );

      clusterDiagnostics = meta.collectClusterDiagnostics {
        clusterName = name;
        inherit allInstancesList;
        extraWarnings = crossScorecardDiag.warnings;
        extraAssertions = crossScorecardDiag.assertions ++ crossResourceAssertions;
      };

      isInlinePackage = v: builtins.isAttrs v && v ? build && (v._type or "") != "kix-import";

      isPackageEntry =
        v:
        builtins.isFunction v
        || (v._type or "") == "kix-import"
        || (builtins.isAttrs v && v ? package)
        || (builtins.isAttrs v && v ? build);

      getPackageFromEntry =
        v:
        if builtins.isFunction v then
          v
        else if (v._type or "") == "kix-import" then
          v
        else if builtins.isAttrs v && v ? build then
          v
        else
          v.package;

      instanceInfo = lib.mapAttrs (
        nsName: nsInsts:
        lib.mapAttrs (
          instName: instCfg:
          let
            pkgMeta = peekedMetas.${nsName}.${instName};
          in
          {
            version = pkgMeta.version or null;
            owner = pkgMeta.owner or null;
            auto = instCfg._autoInstantiated or false;
            isImport = (instCfg.package._type or "") == "kix-import";
          }
        ) nsInsts
      ) mergedInstances;

      availablePackagesInfo = lib.mapAttrs (
        _name: value:
        let
          pkgMeta =
            if isInlinePackage value then
              { }
            else
              meta.peekPackageMeta {
                package = getPackageFromEntry value;
                inherit kixlib;
              };
          version = if isInlinePackage value then "inline" else pkgMeta.version or null;
        in
        {
          inherit version;
          owner = pkgMeta.owner or null;
        }
      ) (lib.filterAttrs (_: isPackageEntry) cfg.availablePackages);

      info = {
        instances = instanceInfo;
        availablePackages = availablePackagesInfo;
      };

      _clusterHookChecksRun = hooks.runChecks clusterHookChecks;

    in
    builtins.seq _refTargetsCheck (
      builtins.seq _rolesValidation (
        builtins.seq _roleBindingsCheck (
          builtins.seq _annotationDomainsCheck (
            builtins.seq _clusterHookChecksRun (
              builtins.seq clusterDiagnostics.emitExtraWarnings (
                builtins.seq clusterDiagnostics.assertionCheck {
                  _type = "k8s-cluster-v2";
                  inherit name;

                  inherit clusterInstances;
                  instances = clusterInstances;

                  namespaces = nsResources;

                  inherit
                    activation
                    packageIndex
                    info
                    extraImages
                    ;

                  diagnostics = {
                    warnings = clusterDiagnostics.warnings ++ clusterHookWarnings;
                    inherit (clusterDiagnostics) assertions failedAssertions;
                  };

                  out = {
                    maintenance = {
                      enable = cfg.cluster.maintenance.enable or false;
                      reason = cfg.cluster.maintenance.reason or null;
                      until = cfg.cluster.maintenance.until or null;
                    };
                  };

                  inherit scorecardReport;

                  rawManifests = rawManifestList;
                }
              )
            )
          )
        )
      )
    );
}
