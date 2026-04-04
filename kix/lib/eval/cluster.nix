# Cluster builder — top-level entry point that composes modules, runs
# auto-instantiation, builds the nested fixpoint, and collects resources.

{
  lib,
  k8s,
  meta,
  kixlib,
  helpers,
  netpol,
  scorecard,
  mkNamespace,
  computeAutoInstances,
  buildResolutionIndex,
  callPackagePhase1,
  discoverBuildDeps,
  resolveDepTargets,
  buildConfigInjections,
  evaluateInstance,
  mkImport,
}:

let
  inherit (helpers) collectTypedAttrs;
in

{
  # The top-level cluster builder.
  # Uses lib.evalModules to compose cluster definitions from modules.
  # Each module can declare options and set instances, namespaces, etc.
  # `ref` (the lazy fixpoint of all instances) is available via specialArgs.
  buildCluster =
    {
      name ? "cluster",
      modules,
      specialArgs ? { },
    }:
    let
      # 1. Evaluate modules — produces merged config lazily.
      #    ref thunks in config values are NOT forced during merge
      #    (config fields are deferredModule — stored as-is).
      evaluated = lib.evalModules {
        modules = [ (import ../modules.nix) ] ++ modules;
        specialArgs = {
          ref = clusterInstances; # lazy — resolved during fixpoint
          # Expose mkImport to all modules (especially flavors) so they can
          # declare platform-provided imports without requiring the caller to
          # pass the full kix library via specialArgs.
          kix = { inherit mkImport; };
        }
        // specialArgs;
      };

      cfg = evaluated.config;

      # 2. Auto-instantiation: compute auto-instances and activated optionals.
      #    See v2_discussions/27_auto_instantiation.md for design rationale.
      autoResult = computeAutoInstances {
        explicitInstances = cfg.instances;
        availablePackages = cfg.availablePackages;
        autoNamespace = cfg.autoNamespace;
      };

      # Explicit instances always win over auto-instances.
      mergedInstances = lib.recursiveUpdate autoResult.autoInstances cfg.instances;

      # 3. Derive namespace list from merged instances ∪ explicit namespaces
      allNsNames = lib.unique (builtins.attrNames cfg.namespaces ++ builtins.attrNames mergedInstances);

      # 4. Create namespace resources
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

      # 5. Build static metadata for DI resolution (instance name + aliases)
      #    defaultAliases from package meta are used when the cluster definition
      #    doesn't set instance-level aliases.
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

      # 5b. Phase-1 pre-pass: resolve dep targets and collect config injections.
      #     Uses a minimal scope (just naming) — packages only use scope.instanceName
      #     at the top level. Build thunks are not called, only introspected.
      #     See v2_discussions/42_dep_config_injection.md for design rationale.
      #
      #     NOTE: explicitOverrides is {} — we deliberately skip instCfg.deps because
      #     it may reference `ref` (the cluster fixpoint), which would cause infinite
      #     recursion. DNS resolution via resolutionIndex handles resolution for the
      #     pre-pass. If a cluster author uses explicit dep overrides to re-target a
      #     dep, config injection uses DNS resolution as a best-effort fallback.
      phase1Instances = lib.mapAttrs (
        nsName: nsInsts:
        lib.mapAttrs (
          instName: instCfg:
          if (instCfg.package._type or "") == "kix-import" then
            {
              discoveredDeps = { };
              depsEnrichment = { };
              resolvedTargets = { };
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
            }
        ) nsInsts
      ) mergedInstances;

      configInjections = buildConfigInjections phase1Instances;

      # 6. Build nested fixpoint
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
              configInjections = configInjections.${nsName}.${instName} or [ ];
            }
          ) nsInsts
        ) mergedInstances
      );

      # --- Resource collection (filters inactive optionals) ---

      # An instance is active if it's not optional, or if it was activated
      # by the auto-instantiation pass (a non-optional instance needs it).
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
        ++ (inst._networkPolicies or [ ]);

      # --- Network policy generation (cluster-level) ---
      networkConfig = cfg.networkPolicy;

      allNetworkEdges =
        if networkConfig.enable then
          builtins.concatMap (inst: inst._networkEdges or [ ]) allInstancesList
        else
          [ ];

      clusterIngressPolicies =
        if networkConfig.enable then
          netpol.generateIngressPolicies {
            allEdges = allNetworkEdges;
            inherit nsResources networkConfig;
          }
        else
          [ ];

      defaultDenyPolicies =
        if networkConfig.enable && networkConfig.defaultDeny then
          map (
            nsName:
            netpol.generateDefaultDeny {
              namespaceName = nsName;
              nsResource = nsResources.${nsName};
              directions = networkConfig.directions;
            }
          ) allNsNames
        else
          [ ];

      # --- Scorecard evaluation (namespace + cluster level) ---
      scorecardConfig = cfg.scorecard or { };
      scorecardEnabled = (scorecardConfig.enable or false) && (scorecardConfig.rules or { }) != { };

      # Collect per-instance findings from the fixpoint
      instanceScorecardFindings =
        if scorecardEnabled then
          builtins.concatMap (inst: inst._scorecardFindings or [ ]) allInstancesList
        else
          [ ];

      # Namespace-level rules
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
          ) allNsNames
        else
          [ ];

      # Cluster-level rules
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
      ) allNsNames)
      ++ clusterIngressPolicies
      ++ defaultDenyPolicies
      ++ [ activation ];

      # Activation CRD — cluster-level root of the Nix store DAG.
      # Only includes active instances (excludes inactive optionals).
      activeClusterInstances = lib.mapAttrs (
        nsName: nsInsts: lib.filterAttrs (instName: _: isActive nsName instName) nsInsts
      ) clusterInstances;

      activation = k8s.mkActivation {
        inherit name;
        instances = lib.mapAttrs (
          _nsName: nsInsts: lib.mapAttrs (_: inst: inst._packageInstance.out.name) nsInsts
        ) activeClusterInstances;
        extraDeps = clusterIngressPolicies ++ defaultDenyPolicies;
      };

      # Package index — PI store path → owned resource store paths.
      # Used by the Rust CLI to build the in-memory store graph.
      # toString on store paths discards string context intentionally —
      # we want stable path strings in the JSON, not context-carrying values.
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

      # --- Collect cluster-wide diagnostics ---
      clusterDiagnostics = meta.collectClusterDiagnostics {
        clusterName = name;
        inherit allInstancesList;
      };

      # --- Lightweight metadata for CLI tooling (no manifest generation) ---

      # Detect inline attrset packages (have `build` but aren't kix-imports).
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

    in
    builtins.seq clusterDiagnostics.assertionCheck {
      _type = "k8s-cluster-v2";
      inherit name;

      inherit clusterInstances;
      instances = clusterInstances;

      namespaces = nsResources;

      inherit activation packageIndex info;

      # Cluster-level diagnostics for tooling
      diagnostics = {
        inherit (clusterDiagnostics) warnings assertions failedAssertions;
      };

      # Scorecard report (null if disabled)
      inherit scorecardReport;

      rawManifests = map (
        r: builtins.fromJSON (builtins.unsafeDiscardStringContext (builtins.toJSON r.rawManifest))
      ) allResources;
    };
}
