# Cluster builder — top-level entry point that composes modules, runs
# auto-instantiation, builds the nested fixpoint, and collects resources.

{
  lib,
  k8s,
  meta,
  kixlib,
  helpers,
  netpol,
  netpolInterface,
  scorecard,
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

      # 5a. Network-policy enforcer lookup — find an instance whose package
      # declares `meta.provides` containing "network-policy-enforcer"
      # (currently only `kix/packages/cilium`). If found, its `out.cnpCrdRef`
      # is surfaced to every instance's scope via `scope.networkPolicyEnforcer`,
      # and `kix/lib/netpol.nix` routes every generated CiliumNetworkPolicy
      # through `cnpCrdRef.out.cr` so the CNP → CRD marker → enforcer root
      # edge is installed transitively. When `networkPolicy.enable = true`
      # and no enforcer instance is declared we throw below — there is no
      # silent fallback, because an unrouted CNP has no store-path edge to
      # cilium and will race the operator at apply time. Externally-managed
      # cilium should be declared via an import-style package that only
      # emits the CRD ref marker (see `kix/packages/cilium` → `external`).
      # See v2_discussions/83.
      #
      # If two instances advertise the capability we throw — ambiguous.
      enforcerCandidates = builtins.concatMap (
        nsName:
        let
          nsInsts = mergedInstances.${nsName};
        in
        builtins.concatMap (
          instName:
          let
            instCfg = nsInsts.${instName};
            pkgMeta = meta.peekPackageMeta {
              package = instCfg.package;
              inherit kixlib;
            };
            provides = pkgMeta.provides or [ ];
          in
          if builtins.elem "network-policy-enforcer" provides then
            [
              {
                ns = nsName;
                inst = instName;
              }
            ]
          else
            [ ]
        ) (builtins.attrNames nsInsts)
      ) (builtins.attrNames mergedInstances);

      enforcerLookup =
        if enforcerCandidates == [ ] then
          null
        else if builtins.length enforcerCandidates > 1 then
          throw (
            "kix: multiple instances advertise `meta.provides = [\"network-policy-enforcer\"]`: "
            + builtins.concatStringsSep ", " (map (c: "${c.ns}/${c.inst}") enforcerCandidates)
            + ". Declare exactly one enforcer (e.g. a single cilium instance)."
          )
        else
          builtins.head enforcerCandidates;

      # Lazy read from the cluster fixpoint. `out` is populated by the
      # enforcer's `rootOut` hook (see kix/packages/cilium/default.nix).
      # Null when no enforcer instance is declared.
      enforcerOut =
        if enforcerLookup == null then
          null
        else
          clusterInstances.${enforcerLookup.ns}.${enforcerLookup.inst}.out or null;

      # Eager assertion: `networkPolicy.enable = true` requires a resolved
      # enforcer. Throws at cluster eval time with an actionable message,
      # before any per-instance scope is constructed. See v2_discussions/83.
      _netpolEnforcerAssertion =
        if (cfg.networkPolicy.enable or false) && enforcerLookup == null then
          throw (
            "kix: `networkPolicy.enable = true` but no instance declares "
            + "`meta.provides = [\"network-policy-enforcer\"]`. Declare a cilium "
            + "instance in the cluster. For externally-managed cilium (k3s with "
            + "--flannel-backend=none, kind with helm-installed cilium, RKE2's "
            + "bundled cilium, etc.) use the external variant that emits only "
            + "the CRD ref marker, e.g.:\n\n"
            + "  instances.kube-system.cilium = {\n"
            + "    package = packages.\"cilium\".external;\n"
            + "  };\n"
          )
        else
          null;

      # Validate the enforcer's `out.netpol` against the formal interface.
      # Fires only when network policies are enabled and an enforcer is
      # declared. The validation reads from the cluster fixpoint (lazy),
      # so it runs at the same time as the first scope construction.
      _netpolInterfaceAssertion =
        if (cfg.networkPolicy.enable or false) && enforcerOut != null then
          let
            enforcerNetpol = enforcerOut.netpol or { };
            enforcerName = "${enforcerLookup.ns}/${enforcerLookup.inst}";
          in
          netpolInterface.validateEnforcerInterface {
            inherit enforcerNetpol enforcerName;
          }
        else
          null;

      # Self-dep guard: the enforcer's own scope must not depend on itself.
      isSelfEnforcer =
        nsName: instName:
        enforcerLookup != null && enforcerLookup.ns == nsName && enforcerLookup.inst == instName;

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

      # Force function-shaped injection configs against a consumer-config
      # lookup (phase 2a `instanceConfigs` or its own self-reference).
      # Literal-shaped injection configs pass through unchanged.
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

      # Phase 2a: config-only fixpoint.
      #
      # Some dep config injections are function-shaped — they read parts
      # of the *consumer's* evaluated config and project them into the
      # dep's config (e.g. stackgres-database taking its own
      # `extensions = ["vector"]` and forwarding it as
      # `[{ name = "vector"; }]` to its underlying postgres cluster).
      #
      # Resolving such an injection requires the consumer's evaluated
      # config — but we can't reach for the full instance view via `self`
      # in the main `clusterInstances` fixpoint, because that view also
      # depends on the consumer's *build*, which depends on its DI deps,
      # which (for a database) loops back to the postgres being injected
      # into. Stack overflow.
      #
      # The trick: split eval into two fixpoints. Phase 2a only computes
      # `evaluatedConfig` for every instance, with no build, no parts,
      # no deps. The function-injection resolver reads from this map
      # instead of from the full view, so the cycle disappears.
      # Phase 2b (`clusterInstances`) then runs the normal full eval
      # using the *resolved* injection list from phase 2a — by that
      # point every injection's `config` is a plain attrset.
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

      # Same resolver, run against phase-2a results, used to feed the
      # full eval below an injection list whose `config` fields are
      # plain attrsets (regardless of whether the package author wrote
      # a function or a literal).
      resolveInjections = resolveInjectionsAgainst instanceConfigs;

      # 6. Build nested fixpoint (phase 2b — full evaluation).
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
              networkPolicyEnforcer = if isSelfEnforcer nsName instName then null else enforcerOut;
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
      #
      # Per-workload egress/ingress CNPs (including the caller-side
      # paired ingress grants in the callee's namespace) are all emitted
      # at `scope.mkDeployment` time via `buildWorkloadCnps`. There is
      # no cluster-level inverted-ingress pass — v2_discussions/83
      # Phase C replaced it with caller-side `scope.forNamespace`
      # emission. Platform intents and default-deny remain at this level.
      networkConfig = cfg.networkPolicy;

      # --- Platform intent materialization ---
      #
      # Flavors declare `networkPolicy.platformIntents` for non-kix-managed
      # pods (CoreDNS, local-path-provisioner, etc.). The enforcer
      # materializes each intent into a standalone CNP or CCNP routed
      # through its CRD ref markers. See v2_discussions/92.
      platformIntentPolicies =
        if !networkConfig.enable || enforcerOut == null || networkConfig.platformIntents == { } then
          [ ]
        else
          let
            enforcerApi = enforcerOut.netpol;
          in
          lib.mapAttrsToList (
            intentName: intent:
            let
              isClusterwide = (intent.scope or "namespaced") == "clusterwide";
              nsName = intent.namespace or null;
              namespaceResource =
                if nsName != null && builtins.hasAttr nsName nsResources then nsResources.${nsName} else null;
            in
            enforcerApi.materializePlatformIntent {
              intent = intent // {
                name = intentName;
              };
              mkResource = k8s.mkResource;
              inherit namespaceResource;
              inherit (k8s) clusterScoped;
            }
          ) networkConfig.platformIntents;

      defaultDenyPolicies =
        if networkConfig.enable && networkConfig.defaultDeny then
          map (
            nsName:
            netpol.generateDefaultDeny {
              namespaceName = nsName;
              nsResource = nsResources.${nsName};
              directions = networkConfig.directions;
              networkPolicyEnforcer = enforcerOut;
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

      # --- Extra images (operator-spawned, not in manifests) ---
      #
      # Packages that manage operators (e.g. stackgres-cluster) can declare
      # `root.out.extraImages = [ "quay.io/..." ]` — images the operator will
      # pull at reconciliation time that don't appear in any kix-generated
      # manifest. Collected here so `kix images` can include them.
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
      ) allNsNames)
      ++ platformIntentPolicies
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
        extraDeps = defaultDenyPolicies ++ platformIntentPolicies;
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
    builtins.seq _netpolEnforcerAssertion (
      builtins.seq _netpolInterfaceAssertion (
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

          # Cluster-level diagnostics for tooling
          diagnostics = {
            inherit (clusterDiagnostics) warnings assertions failedAssertions;
          };

          # Scorecard report (null if disabled)
          inherit scorecardReport;

          rawManifests = map (
            r: builtins.fromJSON (builtins.unsafeDiscardStringContext (builtins.toJSON r.rawManifest))
          ) allResources;
        }
      )
    );
}
