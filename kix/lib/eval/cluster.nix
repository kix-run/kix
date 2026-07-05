{
  lib,
  k8s,
  meta,
  kixlib,
  helpers,
  scorecard,
  hooks,
  roles,
  mkNamespace,
  computeAutoInstances,
  buildResolutionIndex,
  callPackagePhase1,
  discoverBuildDeps,
  resolveDepTargets,
  buildConfigInjections,
  evaluateInstanceConfig,
  evaluateInstance,
  mkImport,
}:

let
  inherit (helpers) collectTypedAttrs;
in

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
          ref = clusterInstances;
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
      };

      mergedInstances = lib.recursiveUpdate autoResult.autoInstances cfg.instances;

      allNsNames = lib.unique (builtins.attrNames cfg.namespaces ++ builtins.attrNames mergedInstances);

      isSentinelNs = nsName: lib.hasPrefix "_" nsName;
      realNsNames = builtins.filter (n: !isSentinelNs n) allNsNames;

      nsResources = builtins.listToAttrs (
        map (nsName: {
          name = nsName;
          value = mkNamespace (
            {
              name = nsName;
            }
            // (cfg.namespaces.${nsName} or { })
          );
        }) allNsNames
      );

      staticMeta = lib.mapAttrs (
        nsName: nsInsts:
        lib.mapAttrs (
          instName: instCfg:
          let
            packageMeta = meta.peekPackageMeta {
              package = instCfg.package;
              inherit kixlib;
            };
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
      ) mergedInstances;

      resolutionIndex = buildResolutionIndex staticMeta;

      rolesIndex = hooks.buildRolesIndex mergedInstances;

      # `out` reads from the cluster fixpoint lazily — must not be forced during
      # module merge. The shallow role out-contract is checked at the same lazy
      # point (first consumer force), never eagerly.
      findRoleProvider =
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
          };

      # Eager refusal pass: exclusive-binding conflicts and duplicate strong
      # providers must throw even when no consumer looks the role up.
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

      # explicitOverrides stays {} — instCfg.deps may reference the cluster fixpoint and must not be forced here
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
                explicitOverrides = { };
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

      # config-only fixpoint: consumer→dep injection must not cycle through the full view
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

      # Phase 2b: full-evaluation fixpoint — every injection's config is a plain attrset by now.
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
        let
          raw =
            inst.raw or (removeAttrs inst [
              "_type"
              "_meta"
              "_packageInstance"
              "_diagnostics"
              "_scorecardFindings"
              "_isImport"
              "root"
              "fqdn"
              "out"
              "overrideParts"
            ]);
        in
        builtins.filter (v: (v._type or "") == "k8s-resource") (
          collectTypedAttrs {
            excludeKeys = [
              "root"
              "meta"
            ];
          } raw
        )
        ++ (if inst ? _packageInstance then [ inst._packageInstance ] else [ ])
        ++ (inst._hookResources or [ ]);

      clusterHookCtx = {
        cluster = clusterCtx;
        inherit nsResources realNsNames;
      };
      clusterHookResults = map (p: p clusterHookCtx) clusterProcessors;
      # Canonical order: hook execution order (priority, then name), used for
      # BOTH the Activation extraDeps and the manifest list. This order is
      # content-addressed into the output.
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
              ruleDefaults = scorecardConfig.ruleDefaults or { };
              ruleOverrides = scorecardConfig.ruleOverrides or { };
            }
          ) realNsNames
        else
          [ ];

      clusterScorecardFindings =
        if scorecardEnabled then
          scorecard.evaluateClusterRules {
            rules = scorecardConfig.rules;
            allInstances = clusterInstances;
            allResources = builtins.concatMap (
              inst: map (r: r.rawManifest or { }) (collectResources inst)
            ) allInstancesList;
            clusterConfig = cfg;
            ruleDefaults = scorecardConfig.ruleDefaults or { };
            ruleOverrides = scorecardConfig.ruleOverrides or { };
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

      allResources = [
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
      ++ [ activation ];

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

      clusterDiagnostics = meta.collectClusterDiagnostics {
        clusterName = name;
        inherit allInstancesList;
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
        _nsName: nsInsts:
        lib.mapAttrs (
          _instName: instCfg:
          let
            pkgMeta = meta.peekPackageMeta {
              package = instCfg.package;
              inherit kixlib;
            };
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
    builtins.seq _roleBindingsCheck (
      builtins.seq _clusterHookChecksRun (
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

          rawManifests = map (
            r: builtins.fromJSON (builtins.unsafeDiscardStringContext (builtins.toJSON r.rawManifest))
          ) allResources;
        }
      )
    );
}
