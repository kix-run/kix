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
  normalizeAvailablePackages,
  buildResolutionIndex,
  callPackagePhase1,
  discoverBuildDeps,
  resolveDepTargets,
  describeRequester,
  buildConfigInjections,
  checkRefTargets,
  checkDepsKeys,
  refsOf,
  evaluateInstanceModules,
  instancePinsLib,
  evaluateInstance,
  mkImport,
  checkExtraDeps,
  consumersMod,
  podSecurity,
  # The flake that defines these clusters (its `self`), or null when omitted.
  # Image sources record file paths relative to this flake.
  self,
}:

let
  inherit (import ../core/error.nix { inherit lib; }) fail warning;
  inherit (import ../core/util.nix { inherit lib; }) plain namespaceOf;
  versions = import ../core/version.nix { inherit lib; };
  kubernetes = import ../core/kubernetes.nix;
  packageLib = import ../core/package.nix { inherit lib; };
in
{
  buildCluster =
    {
      # The cluster's name. Kix writes it into the Activation record and the
      # package index, and every later deploy looks the cluster's state up
      # by it, so it must stay the same for the life of the cluster.
      # `mkFlake` supplies the cluster's `clusters` key when the definition
      # sets none.
      name ? fail {
        message = "kix.buildCluster needs a name. Kix stores it in the cluster's deploy records, so it must stay the same for the life of the cluster.";
        fix = "Set name = \"...\"; or list the cluster in kix.lib.mkFlake, which names it after its key.";
        clusterOption = "name";
      },
      # Set by `mkFlake` when it supplies `name` from the cluster's
      # `clusters` key. The index records it so that `kix deploy` and
      # `kix plan` can refuse to deploy a cluster that Kix 0.6 named
      # `cluster` under its new name.
      _nameFromFlakeKey ? false,
      modules,
      specialArgs ? { },
      # The cluster's pin file from `kix.pins`. `buildCluster` applies its
      # `instances` map directly. Cluster code reads its `images` map via
      # `pins.get`, and `imageSources` matches values back to those pins.
      pins ? null,
    }:
    let
      # Module evaluation stays lazy so `ref` thunks in config values are not
      # forced here.
      evaluated = lib.evalModules {
        modules = [ (import ../modules.nix) ] ++ modules;
        specialArgs = {
          inherit ref;
          kix = {
            inherit mkImport;
            inherit (consumersMod) interface;
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

      # Build `ref.<ns>.<inst>` pointers for every name auto-instantiation could
      # produce. Because this set is known before auto-instantiation runs,
      # `computeAutoInstances` and the phase-1 pre-pass can read `deps.x = ref.a.b`
      # without recursion. Wired dependencies then receive config injections and
      # `meta.scope` and version checks just like auto-resolved dependencies.
      # `resolveArg` dereferences each pointer, while `_refTargetsCheck` rejects
      # pointers to candidate instances that were never created.
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

      _refTargetsCheck = checkRefTargets {
        instances = cfg.instances;
        inherit mergedInstances;
      };

      # Validate `extraDeps` on inactive instances too so misplaced or malformed
      # entries fail before anything activates the instance.
      _extraDepsCheck = checkExtraDeps {
        instances = cfg.instances;
        inherit mergedInstances;
      };

      # Reject instance pins that target nonexistent instances or imports so
      # stale pins cannot silently go unused. A pin file with instance pins
      # belongs to a single cluster.
      _instancePinsCheck =
        if pins == null then
          null
        else
          builtins.foldl' (
            _: key:
            let
              parts = lib.splitString "/" key;
              nsName = builtins.elemAt parts 0;
              instName = builtins.elemAt parts 1;
              instCfg = mergedInstances.${nsName}.${instName} or null;
              where = if pins.file == null then "the pins attrset" else instancePinsLib.relativeFile pins.file;
            in
            if instCfg == null then
              fail {
                message = "kix.pins: ${where} pins instance '${key}', which cluster '${name}' does not have. Instances in namespace '${nsName}': ${
                  let
                    names = builtins.attrNames (mergedInstances.${nsName} or { });
                  in
                  if names == [ ] then "none" else builtins.concatStringsSep ", " names
                }.";
                fix = "A pin file with instance pins belongs to one cluster. Give each cluster that applies instance pins its own file.";
              }
            else if (instCfg.package._type or "") == "kix-import" then
              fail "kix.pins: ${where} pins instance '${key}', which is an import. An import renders no workloads, so it has no image to pin."
            else
              null
          ) null (builtins.attrNames pins.instances);

      # Return the `instances` pin entry for `<nsName>/<instName>`, or null.
      instancePinsOf =
        nsName: instName:
        let
          key = "${nsName}/${instName}";
        in
        if pins != null && pins.instances ? ${key} then
          {
            file = if pins.file == null then "the pins attrset" else pins.file;
            options = pins.instances.${key};
          }
        else
          null;

      allNsNames = lib.unique (builtins.attrNames cfg.namespaces ++ builtins.attrNames mergedInstances);

      isSentinelNs = nsName: lib.hasPrefix "_" nsName;
      realNsNames = builtins.filter (n: !isSentinelNs n) allNsNames;

      # Order Pod Security Standards from most to least permissive. A namespace
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
          fail {
            instance = "${nsName}/${instName}";
            message = "meta.podSecurity = \"${toString level}\" is not one of ${lib.concatStringsSep ", " podSecurityLevels}.";
          }
        else
          i;

      # When this cluster loads a platform interface, stamp every rendered
      # namespace with the interface's consumer label, Pod Security level, and
      # quota.
      consumerSide = consumersMod.consumer { inherit name cfg self; };
      namespaceConfig =
        nsName:
        let
          own = cfg.namespaces.${nsName} or { };
        in
        if consumerSide == null then own else consumerSide.stamp nsName own;

      # Derive the namespace level from its instances unless the cluster sets
      # one explicitly. Reject an explicit level that is more restrictive than
      # an instance requirement before Kubernetes rejects the resulting pod.
      namespacePodSecurity =
        nsName:
        let
          declared = (namespaceConfig nsName).podSecurity or null;
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
          fail {
            instance = "${nsName}/${mostPermissive.instName}";
            clusterOption = "namespaces.${nsName}.podSecurity";
            message = "package sets meta.podSecurity = \"${mostPermissive.level}\", which is more permissive than namespaces.${nsName}.podSecurity = \"${declared}\". Kubernetes would refuse its pods in namespace '${nsName}'.";
            fix = "Set `namespaces.${nsName}.podSecurity = \"${mostPermissive.level}\";` in your cluster definition, or move '${mostPermissive.instName}' to a namespace that allows \"${mostPermissive.level}\".";
          }
        else
          mostPermissive.level;

      nsResources = builtins.listToAttrs (
        map (nsName: {
          name = nsName;
          value = mkNamespace (
            {
              name = nsName;
            }
            // namespaceConfig nsName
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
      # instances only. An inactive optional instance emits nothing, and an
      # inactive optional import emits no marker, so the deploy would never
      # check the resource a consumer read from it. Only a demand in
      # computeAutoInstances activates an optional instance or import, and
      # isActive reads that result, not these resolutions.
      resolvableInstances = lib.mapAttrs (
        nsName: nsInsts: lib.filterAttrs (instName: _: isActive nsName instName) nsInsts
      ) mergedInstances;

      # Record the active instances that requested an auto-instantiated
      # instance, or null for explicitly declared instances.
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
                instanceAliases = instCfg.aliases or null;
                inherit packageMeta;
              };
              defaultAliases = packageMeta.defaultAliases or [ ];
              isImport = (instCfg.package._type or "") == "kix-import";
              scope = meta.scopeOf {
                inherit packageMeta;
                context = "${nsName}/${instName}";
              };
              servesCluster = meta.servesCluster {
                inherit packageMeta;
                context = "${nsName}/${instName}";
              };
              autoInstantiatedFor = instCfg._autoInstantiatedFor or null;
              # A dependency demand created this instance from
              # availablePackages or switched on this optional instance. The
              # cluster author chose where it lives, so it binds from any
              # namespace.
              demanded =
                (instCfg._autoInstantiatedFor or null) != null
                || ((instCfg.optional or false) && autoResult.activatedOptionals ? "${nsName}/${instName}");
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
        nsName: nsInsts: lib.filterAttrs (instName: _: isActive nsName instName) nsInsts
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
              fail {
                clusterOption = "cluster.factBehavior";
                message = "cluster.factBehavior key '${key}' must be \"group/Kind\", because bare kinds collide across API groups.";
                fix = "Write the key as, for example, \"stackgres.io/SGCluster\".";
              }
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

      # Collect every name and alias of inactive optional instances.
      # `evaluateInstance` checks this set when resolving the implicit `dns`
      # dependency so an inactive optional DNS import suppresses missing-DNS
      # warnings when the environment provides DNS.
      inactiveOptionalKeys = builtins.listToAttrs (
        builtins.concatMap (
          nsName:
          builtins.concatMap (
            instName:
            lib.optionals (!(isActive nsName instName)) (
              map (k: lib.nameValuePair k true) (
                [ instName ]
                ++ meta.effectiveAliases {
                  instanceAliases = mergedInstances.${nsName}.${instName}.aliases or null;
                  packageMeta = peekedMetas.${nsName}.${instName};
                }
              )
            )
          ) (builtins.attrNames mergedInstances.${nsName})
        ) (builtins.attrNames mergedInstances)
      );

      clusterCtx = {
        config = cfg;
        inherit findRoleProvider inactiveOptionalKeys;
      };

      workloadInterceptors = hooks.collectHooks cfg "workloadInterceptors";
      instanceProcessors = hooks.collectHooks cfg "instanceProcessors";
      clusterProcessors = hooks.collectHooks cfg "clusterProcessors";

      # Read only `ref` pointers in phase 1. Other explicit `deps` values may
      # come from the instance fixpoint, so they are bound during full instance
      # evaluation and do not receive config injections. An inactive optional
      # instance deploys nothing, so it resolves no dependency and injects no
      # config.
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
              packageConfig = { };
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
              resolvedTargets =
                if isActive nsName instName then
                  resolveDepTargets {
                    declaredDeps = discoveredDeps;
                    inherit resolutionIndex depsEnrichment;
                    namespace = nsName;
                    requester = describeRequester nsName instName instCfg;
                    requesterName = instName;
                    explicitOverrides = lib.filterAttrs (_: v: refsOf v != [ ]) (instCfg.deps or { });
                  }
                else
                  lib.mapAttrs (_: _: { found = false; }) discoveredDeps;
            in
            {
              inherit discoveredDeps depsEnrichment resolvedTargets;
              packageOptions = raw.options or { };
              packageConfig = raw.config or { };
            }
        ) nsInsts
      ) mergedInstances;

      _depsKeysCheck = checkDepsKeys { inherit mergedInstances phase1Instances; };

      configInjections = buildConfigInjections phase1Instances;

      resolveInjectionsAgainst =
        configMap: nsName: instName:
        map (
          inj:
          if builtins.isFunction inj.config then
            let
              consumerCfg = configMap.${inj.consumerNs}.${inj.consumerInst} or { };
            in
            inj // { config = inj.config consumerCfg; }
          else
            inj
        ) (configInjections.${nsName}.${instName} or [ ]);

      configsOf = lib.mapAttrs (_: lib.mapAttrs (_: e: e.config));

      # Resolve consumer-to-dependency config injections in a config-only
      # fixpoint so they do not depend on full instance views. The options
      # are kept for `imageSources`.
      instanceEvaluations = lib.fix (
        selfEval:
        lib.mapAttrs (
          nsName: nsInsts:
          lib.mapAttrs (
            instName: instCfg:
            if (instCfg.package._type or "") == "kix-import" then
              {
                config = { };
                options = { };
              }
            else
              evaluateInstanceModules {
                inherit (phase1Instances.${nsName}.${instName}) packageOptions packageConfig;
                packageConfigFile = "package config of ${nsName}/${instName}";
                namespaceName = nsName;
                instanceName = instName;
                inherit instCfg;
                clusterConfig = cfg;
                configInjections = resolveInjectionsAgainst (configsOf selfEval) nsName instName;
                instancePins = instancePinsOf nsName instName;
              }
          ) nsInsts
        ) mergedInstances
      );

      instanceConfigs = configsOf instanceEvaluations;

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
              # A sentinel key names no real namespace, so its record goes to
              # `cluster.recordNamespace`. Referencing that Namespace when the
              # cluster manages it orders the record after it.
              recordNamespace =
                if isSentinelNs nsName then
                  nsResources.${cfg.cluster.recordNamespace} or cfg.cluster.recordNamespace
                else
                  nsResources.${nsName};
              allInstances = self;
              clusterLabels = cfg.clusterLabels;
              clusterConfig = cfg;
              inherit resolutionIndex;
              globalPartsOverlays = cfg.globalPartsOverlays;
              configInjections = resolveInjections nsName instName;
              instancePins = instancePinsOf nsName instName;
              inherit workloadInterceptors instanceProcessors clusterCtx;
              inherit annotationDomainIndex factBehaviorOverrides;
              isInstanceActive = isActive;
            }
          ) nsInsts
        ) mergedInstances
      );

      isActive =
        nsName: instName:
        let
          instCfg = mergedInstances.${nsName}.${instName};
          isOptional = instCfg.optional or false;
        in
        !isOptional || autoResult.activatedOptionals ? "${nsName}/${instName}";

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

      # Return the `<namespace>/<instance>` key of an instance, the form a
      # resource's `_builtBy` uses.
      instanceKey = inst: "${inst._meta.namespaceName or "?"}/${inst._meta.instanceName or "?"}";

      # Instance keys that hold each store path, sorted, keyed by path.
      holdersOf = builtins.mapAttrs (_: keys: builtins.sort builtins.lessThan (lib.unique keys)) (
        builtins.zipAttrsWith (_: keys: keys) (
          map (
            inst:
            builtins.listToAttrs (
              map (r: {
                name = outPathKey r;
                value = instanceKey inst;
              }) (collectResources inst)
            )
          ) allInstancesList
        )
      );

      # Return the resources the package index and the owner map list under
      # an instance, so that every store path is listed under exactly one
      # instance. A resource that several instances hold, such as an import
      # marker a provider exposes through `out`, belongs to the instance whose
      # scope built it when that instance is active and holds it. Otherwise it
      # belongs to the first holder by instance key, which keeps its
      # `kix.run/package` stable across unrelated hash changes.
      ownedResources =
        inst:
        builtins.filter (
          r:
          let
            holders = holdersOf.${outPathKey r} or [ ];
            builder = r._builtBy or null;
            owner = if builder != null && builtins.elem builder holders then builder else builtins.head holders;
          in
          holders == [ ] || owner == instanceKey inst
        ) (collectResources inst);

      # `resources` holds the sealed resources of every active instance,
      # including the policies instance hooks derived.
      clusterHookCtx = {
        cluster = clusterCtx;
        inherit nsResources realNsNames;
        resources = builtins.concatMap collectResources allInstancesList;
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

      # Record the origin of each image option value for `kix-image-sources.json`.
      # Keep this metadata outside the Activation resource so moving an image
      # value between Nix code and a pin file does not change the Activation
      # hash.
      imageSources =
        let
          pinsFile = if pins == null then null else instancePinsLib.pathInFlake self pins.file;
        in
        {
          version = 1;
          cluster = name;
          inherit pinsFile;
          # Record why `pinsFile` is null when a pin file was provided: either
          # `self` was not passed (`flake_unknown`) or the file lives outside
          # `self` (`outside_flake`).
          pinsFileUnknown =
            if pins == null || pins.file == null || pinsFile != null then
              null
            else if self == null then
              "flake_unknown"
            else
              "outside_flake";
          images = builtins.concatMap (
            inst:
            let
              nsName = inst._meta.namespaceName;
              instName = inst._meta.instanceName;
            in
            if (mergedInstances.${nsName}.${instName}.package._type or "") == "kix-import" then
              [ ]
            else
              instancePinsLib.imageSources {
                namespaceName = nsName;
                instanceName = instName;
                evaluation = instanceEvaluations.${nsName}.${instName};
                packageConfigFile = "package config of ${nsName}/${instName}";
                instancePins = instancePinsOf nsName instName;
                inherit pins self;
              }
          ) allInstancesList;
        };

      scorecardReport =
        if scorecardEnabled then
          scorecard.buildScorecardReport { findings = allScorecardFindings; }
        else
          null;

      platformSide =
        if cfg.consumers == { } then
          null
        else
          consumersMod.platform {
            inherit
              name
              cfg
              realNsNames
              nsResources
              mergedInstances
              clusterInstances
              peekedMetas
              isActive
              ;
          };

      # `collectResources` can encounter aliases of the same resource. Collapse
      # equal store paths before checking identity collisions and writing the
      # manifest list.
      allResources = dedupeByOutPath (resourcesBeforeRecord ++ [ activation ]);

      # Collect every resource except the Activation record, which references
      # the package index built from these resources.
      resourcesBeforeRecord = [
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
      ++ (if platformSide == null then [ ] else platformSide.resources)
      ++ clusterHookResources;

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

      activation = k8s.mkActivation (
        {
          inherit name;
          instances = lib.mapAttrs (
            _nsName: nsInsts: lib.mapAttrs (_: inst: inst._packageInstance.out.name) nsInsts
          ) activeClusterInstances;
          index = packageIndex;
          extraDeps = clusterHookResources;
          kubernetesUid = cfg.cluster.kubernetes.uid;
        }
        // lib.optionalAttrs (platformSide != null) {
          consumers = platformSide.recordConsumers;
          inherit (platformSide) interfaceFiles;
        }
        // lib.optionalAttrs (consumerSide != null) {
          interfaces = consumerSide.recordInterfaces;
        }
      );

      # Preserve string context on every path in the index so the Activation
      # record retains store references to all resources, including import
      # markers that no other object references. Map keys can drop string
      # context because each instance's value list already includes its own
      # PackageInstance marker.
      packageIndex = builtins.toFile "kix-packages.json" (builtins.toJSON packageIndexContent);

      # List the store paths the CLI reads for this build. Each path keeps its
      # string context, so the index references every file it names and its
      # closure holds the whole build. Every listed file is a `builtins.toFile`
      # path, so evaluating the index builds nothing. Kix records this file's
      # store path as `kix.run/built-via`.
      activationIndex = builtins.toFile "kix-activation-${name}.json" (
        builtins.toJSON ({ version = 1; } // activationFiles)
      );

      # The store paths of the build's files, keyed as the activation index
      # names them. `mkFlake` links the same files into the
      # `cluster-<name>-activation` output of a project that uses the nix
      # builder.
      activationFiles =
        let
          jsonFile = fileName: value: builtins.toFile fileName (builtins.toJSON value);
        in
        {
          activation = "${activation}";
          packages = packageIndex;
          scorecard = if scorecardReport == null then null else jsonFile "kix-scorecard.json" scorecardReport;
          extraImages = if extraImages == null then null else jsonFile "kix-extra-images.json" extraImages;
          imageSources = jsonFile "kix-image-sources.json" imageSources;
          interfaces = if platformSide == null then { } else platformSide.interfaces;
          warnings = jsonFile "kix-warnings.json" libraryWarnings;
        };

      # The library's warnings that are not scorecard findings, as records
      # (`core/error.nix`). The CLI reads them from `kix-warnings.json`,
      # because it shows Nix's trace output only when an evaluation fails.
      # The scorecard report carries the scorecard's own warnings.
      libraryWarnings =
        clusterDiagnostics.warnings
        ++ map (warning null) (clusterHookWarnings ++ dnsWarnings ++ windowWarnings);

      # Report a `k8sVersion` outside the versions this Kix release supports.
      # A package refuses the cluster only where its own range says so.
      windowWarnings =
        let
          inherit (kubernetes) window;
          inside =
            versions.atLeast cfg.k8sVersion window.minVersion != false
            && versions.atMost cfg.k8sVersion window.maxVersion != false;
        in
        lib.optional (cfg.k8sVersion != null && !inside) {
          message = "cluster '${name}' sets k8sVersion to ${cfg.k8sVersion}. This Kix release supports Kubernetes ${window.minVersion} to ${window.maxVersion}. The build continues and still checks each package's Kubernetes version bounds.";
          fix = "Move the cluster to Kubernetes ${window.minVersion} to ${window.maxVersion} and update k8sVersion, or use a version of Kix that supports Kubernetes ${cfg.k8sVersion}.";
        };

      # Report missing DNS once for the cluster, however many instances
      # lack it.
      dnsWarnings = lib.optional (builtins.any (inst: inst._dnsMissing or false) allInstancesList) {
        message = "cluster '${name}' has no DNS instance, so Kix will not wait for DNS to be ready before deploying workloads.";
        fix = "If the cluster already runs DNS, add a cluster flavor (kix.flavors.<name>) to modules, or import the DNS workload with kix.mkImport (setting kind, apiVersion, roles = [ \"dns\" ], out.name, and out.fqdn). To deploy CoreDNS with Kix, add a packages.experimental.coredns instance.";
      };

      # The platform whose interface file supplied `k8sVersion`, or null when
      # the definition writes it or nothing sets it. `kix.interface` sets the
      # value with `mkDefault` (priority 1000), so a definition's own value
      # outranks it and the option's priority tells the two apart. The CLI's
      # refusal then names the platform and offers a new interface file as
      # the fix.
      k8sVersionFrom =
        let
          supplying = lib.filterAttrs (
            _: i: cfg.k8sVersion != null && (i.facts.k8sVersion or null) == cfg.k8sVersion
          ) cfg.interfaces;
        in
        if evaluated.options.k8sVersion.highestPrio == 1000 && supplying != { } then
          builtins.head (builtins.attrNames supplying)
        else
          null;

      packageIndexContent = {
        cluster = name;
        # The Kubernetes cluster the build is bound to and the version its
        # package checks ran against, read by the CLI before it writes
        # anything. `uid = null` means unbound; `version = null` means
        # `k8sVersion` is unset and the CLI does not compare versions.
        kubernetes = {
          uid = cfg.cluster.kubernetes.uid;
          version = cfg.k8sVersion;
          versionFrom = k8sVersionFrom;
        };
        packages = builtins.listToAttrs (
          map (inst: {
            name = builtins.unsafeDiscardStringContext (toString inst._packageInstance.outPath);
            value = map (r: toString r.outPath) (dedupeByOutPath (ownedResources inst));
          }) allInstancesList
        );
      }
      # `nameFromFlakeKey = true` says that `mkFlake` named the cluster after
      # its `clusters` key because the definition set no `name`. The CLI
      # reads a missing field as `false`. Other builds leave the field out,
      # so their index and Activation record stay as they were.
      // lib.optionalAttrs _nameFromFlakeKey { nameFromFlakeKey = true; };

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
          (
            f:
            {
              assertion = false;
            }
            // (if builtins.isString f then { message = f; } else f)
          )
          (
            validate.crossResourceFailures {
              manifests = rawManifestList;
              identityHashes = map (r: if r ? outPath then k8s.extractStoreHash r.outPath else null) allResources;
              owners = map (r: resourceOwners.${outPathKey r} or null) allResources;
              externalNames = externalRefNames;
            }
          );

      outPathKey =
        r: if r ? outPath then builtins.unsafeDiscardStringContext (toString r.outPath) else "";

      # Reject workloads that violate their namespace's Pod Security level so
      # evaluation fails with field-level fixes before Kubernetes admission
      # rejects the pods.
      podSecurityAssertions =
        let
          levelOf = ns: if builtins.elem ns allNsNames then namespacePodSecurity ns else null;
          sourceOf =
            ns:
            if consumerSide != null && consumerSide.podSecuritySourceOf ns != null then
              consumerSide.podSecuritySourceOf ns
            else if (cfg.namespaces.${ns}.podSecurity or null) != null then
              "set by namespaces.${ns}.podSecurity"
            else
              "the level its instances ask for in meta.podSecurity";
          ofInstance =
            inst:
            let
              owner = "${inst._meta.namespaceName or "?"}/${inst._meta.instanceName or "?"}";
            in
            builtins.concatMap (
              r:
              let
                m = r.rawManifest;
                ns = plain (m.metadata.namespace or (inst._meta.namespaceName or ""));
                level = levelOf ns;
                found = if level == null then [ ] else podSecurity.violations level m;
              in
              lib.optional (found != [ ]) {
                assertion = false;
                instance = owner;
                message =
                  "${plain m.kind} ${plain m.metadata.name} breaks Pod Security level \"${level}\", "
                  + "which namespace ${ns} enforces (${sourceOf ns}). Kubernetes would refuse its pods. Change:"
                  + lib.concatMapStrings (v: "\n      ${v.where}: ${v.problem}") found;
              }
            ) (builtins.filter (r: r ? rawManifest) (collectResources inst));
        in
        builtins.concatMap ofInstance allInstancesList;

      # Fail the build when the minimum usage in a namespace exceeds any
      # of its unscoped ResourceQuotas (`vocab/quota-use.nix`). Checked quotas
      # include `namespaces.<ns>.resourceQuota` (or the quota from a consumer's
      # platform interface) and any ResourceQuota rendered by an instance in
      # the namespace without `scopes` or `scopeSelector`.
      quotaAssertions =
        let
          quotaCheck = import ../vocab/quota-use.nix { inherit lib; };
          ofNamespace =
            nsName:
            let
              sealed = builtins.concatMap collectResources (
                builtins.attrValues (
                  lib.filterAttrs (instName: _: isActive nsName instName) (clusterInstances.${nsName} or { })
                )
              );
              resources = map (r: r.rawManifest or { }) sealed;
              own = (namespaceConfig nsName).resourceQuota or null;
              quotas =
                lib.optional (own != null) {
                  name = "${nsName}-quota";
                  hard = own;
                }
                ++
                  map
                    (m: {
                      name = plain m.metadata.name;
                      hard = m.spec.hard or { };
                    })
                    (
                      builtins.filter (
                        m:
                        (m.kind or "") == "ResourceQuota"
                        && !((m.spec or { }) ? scopes)
                        && !((m.spec or { }) ? scopeSelector)
                      ) resources
                    );
            in
            lib.optionals (quotas != [ ]) (
              quotaCheck.refusals {
                namespace = nsName;
                inherit quotas resources;
                # Pass every custom resource, so the refusal can list the
                # ones whose kind declares no `usesAtLeast`. A kind in a
                # built-in group (`*.k8s.io`) still counts when it declares one.
                customResources =
                  map
                    (r: {
                      manifest = r.rawManifest;
                      usesAtLeast = r.usesAtLeast or null;
                    })
                    (
                      builtins.filter (
                        r:
                        r ? rawManifest
                        && (
                          (r.usesAtLeast or null) != null || k8s.facts.isForeignGroup (plain (r.rawManifest.apiVersion or ""))
                        )
                      ) sealed
                    );
              }
            );
        in
        map (message: {
          assertion = false;
          message = "kix: ${message}";
        }) (builtins.concatMap ofNamespace realNsNames);

      # Fail the build when a stateful package renders a custom resource
      # whose kind does not declare `holdsData`. Deploy reads the resulting
      # `kix.run/holds-data` mark to decide which removals are data
      # migrations, and a stateful package is where a wrong guess costs data.
      # Only the package's own parts count: policies that hooks derive and
      # the PackageInstance record hold no data.
      holdsDataAssertions =
        let
          isStateful = inst: (inst._meta.packageMeta.lifecycle or null) == "stateful";
          ofInstance =
            inst:
            let
              owner = "${inst._meta.namespaceName or "?"}/${inst._meta.instanceName or "?"}";
              undeclared = builtins.filter (
                r:
                r ? rawManifest
                && (r.declaredHoldsData or null) == null
                && k8s.facts.isForeignGroup (plain r.apiVersion)
              ) (helpers.instancePartResources inst);
              byKind = builtins.groupBy (
                r: "${builtins.head (lib.splitString "/" (plain r.apiVersion))}/${plain r.kind}"
              ) undeclared;
            in
            lib.mapAttrsToList (
              groupKind: rs:
              let
                kind = plain (builtins.head rs).kind;
                names = builtins.concatStringsSep ", " (map (r: plain r.rawManifest.metadata.name) rs);
                declarations = lib.unique (builtins.filter (d: d != null) (map (r: r.crdDeclaredBy or null) rs));
                raw = builtins.filter (r: (r.crdDeclaredBy or null) == null) rs;
                answer = "true when deleting a ${kind} loses data (a database, a storage pool), false when it does not (monitoring, certificates, policy, configuration)";
              in
              {
                assertion = false;
                message =
                  "kix: instance ${owner} has lifecycle = \"stateful\" and renders ${kind} ${names}, "
                  + "but Kix does not know whether ${groupKind} objects hold data. "
                  + lib.optionalString (declarations != [ ]) (
                    "Set holdsData on ${builtins.concatStringsSep " and " declarations}, which declares the kind: ${answer}. "
                  )
                  + lib.optionalString (raw != [ ]) (
                    "${builtins.concatStringsSep ", " (map (r: plain r.rawManifest.metadata.name) raw)} "
                    + "is built with scope.mkResource, which carries no declaration. "
                    + "Build it with scope.mkCR from the scope.mkCRD or scope.mkCRDRef of ${groupKind}, and set holdsData there: ${answer}."
                  );
              }
            ) byKind;
        in
        builtins.concatMap ofInstance (builtins.filter isStateful allInstancesList);

      # Reject cluster-scoped objects rendered with the same API group, kind,
      # and name by multiple active instances. Identical copies would otherwise
      # be collapsed by `dedupeByOutPath`, and differing copies would fail
      # cross-resource validation without naming the owning instances.
      sharedClusterObjectAssertions =
        let
          owned = builtins.concatMap (
            inst:
            map
              (r: {
                owner = "${inst._meta.namespaceName or "?"}/${inst._meta.instanceName or "?"}";
                m = r.rawManifest;
              })
              (
                builtins.filter (r: r ? rawManifest && (r.rawManifest.metadata.namespace or null) == null) (
                  collectResources inst
                )
              )
          ) allInstancesList;
          identity =
            m:
            let
              parts = lib.splitString "/" (plain (m.apiVersion or ""));
              group = if builtins.length parts > 1 then builtins.head parts else "";
            in
            "${plain (m.kind or "?")} ${plain (m.metadata.name or "?")}${
              lib.optionalString (group != "") " (${group})"
            }";
          owners = builtins.mapAttrs (_: es: lib.unique (map (e: e.owner) es)) (
            builtins.groupBy (e: identity e.m) owned
          );
          shared = lib.filterAttrs (_: os: builtins.length os > 1) owners;
        in
        lib.mapAttrsToList (
          id: os:
          let
            requestersOf =
              o:
              let
                parts = lib.splitString "/" o;
              in
              mergedInstances.${builtins.head parts}.${builtins.elemAt parts 1}._autoInstantiatedFor or null;
            label =
              o:
              let
                rs = requestersOf o;
              in
              if rs == null then o else "${o} (auto-instantiated for ${builtins.concatStringsSep ", " rs})";
            anyAuto = builtins.any (o: requestersOf o != null) os;
          in
          {
            assertion = false;
            message =
              "kix: cluster-scoped ${id} is rendered by ${toString (builtins.length os)} instances: ${builtins.concatStringsSep ", " (map label os)}. Kubernetes holds one object under that name, so they would apply it over each other. "
              + (
                if anyAuto then
                  "Auto-instantiation places a package in each namespace that requires it. Declare the package once, under instances.<namespace>.<name>, and every consumer resolves to it."
                else
                  "Keep one of these instances, or give the object a name that differs per instance."
              );
          }
        ) shared;

      # Map each resource's store path to the `<ns>/<instance>` that owns it
      # (`ownedResources`). Namespace resources, cluster hook outputs, and the
      # Activation record have no instance owner.
      resourceOwners = builtins.listToAttrs (
        builtins.concatMap (
          inst:
          map (r: {
            name = outPathKey r;
            value = instanceKey inst;
          }) (ownedResources inst)
        ) allInstancesList
      );

      # Collect names marked with kix.untrackedRef before rawManifestList
      # removes string context. Key entries by the referring resource's
      # namespace so an exemption does not apply across namespaces. Each
      # value is { creatorNamed; }, true only when every reference to that
      # key names its creator: with `kind` and `by` (markers.hasCreator), or
      # with `by = "self"` when exactly one resource in the cluster carries a
      # self reference to that name. A self reference that reaches a second
      # resource, such as a consumer mounting the name from the creator's
      # `out`, says nothing about which of them creates the object. The count
      # is cluster-wide because such a consumer in another namespace would be
      # the only carrier in its own namespace.
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
                      markers = ms;
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
          nsOf = r: plain (namespaceOf r.rawManifest);
          refsByResource = map (r: {
            ns = nsOf r;
            refs = walk r.rawManifest;
          }) allResources;
          # Self-reference name -> number of resources carrying it.
          selfCarriers = builtins.foldl' (acc: name: acc // { ${name} = (acc.${name} or 0) + 1; }) { } (
            builtins.concatMap (
              rr:
              lib.unique (
                builtins.concatMap (
                  ref:
                  map (p: (k8s.markers.readMarker p).name) (builtins.filter k8s.markers.isSelfCreated ref.markers)
                ) rr.refs
              )
            ) refsByResource
          );
          namesCreator =
            p:
            k8s.markers.hasCreator p
            || (k8s.markers.isSelfCreated p && selfCarriers.${(k8s.markers.readMarker p).name} == 1);
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
              rr:
              map (ref: {
                key = "${rr.ns}/${ref.name}";
                creatorNamed = builtins.all namesCreator ref.markers;
              }) rr.refs
            ) refsByResource
          );

      clusterDiagnostics = meta.collectClusterDiagnostics {
        clusterName = name;
        inherit allInstancesList;
        scorecardWarnings = crossScorecardDiag.warnings;
        extraAssertions =
          crossScorecardDiag.assertions
          ++ map (refusal: { assertion = false; } // refusal) autoResult.besideConsumerRefusals
          ++ sharedClusterObjectAssertions
          ++ podSecurityAssertions
          ++ quotaAssertions
          ++ holdsDataAssertions
          ++ crossResourceAssertions
          ++ (if consumerSide == null then [ ] else consumerSide.assertionsFor rawManifestList);
      };

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
            package = packageLib.idOf instCfg.package;
            auto = instCfg._autoInstantiated or false;
            isImport = (instCfg.package._type or "") == "kix-import";
          }
        ) nsInsts
      ) mergedInstances;

      availablePackagesInfo = lib.mapAttrs (
        name: entry:
        let
          # An inline package given directly lists as "inline". One given as
          # `{ package = ...; }` lists by its `meta`.
          inline = packageLib.isInline cfg.availablePackages.${name};
          pkgMeta =
            if inline then
              { }
            else
              meta.peekPackageMeta {
                inherit (entry) package;
                inherit kixlib;
              };
        in
        {
          version = if inline then "inline" else pkgMeta.version or null;
          owner = pkgMeta.owner or null;
          package = packageLib.idOf entry.package;
        }
      ) (normalizeAvailablePackages cfg.availablePackages);

      info = {
        instances = instanceInfo;
        availablePackages = availablePackagesInfo;
      };

      _clusterHookChecksRun = hooks.runChecks clusterHookChecks;

    in
    builtins.seq _instancePinsCheck (
      builtins.seq _refTargetsCheck (
        builtins.seq _depsKeysCheck (
          builtins.seq _extraDepsCheck (
            builtins.seq _rolesValidation (
              builtins.seq _roleBindingsCheck (
                builtins.seq _annotationDomainsCheck (
                  builtins.seq _clusterHookChecksRun (
                    builtins.seq clusterDiagnostics.evaluateExtraWarnings (
                      builtins.seq clusterDiagnostics.assertionCheck {
                        _type = "k8s-cluster-v2";
                        inherit name;

                        inherit clusterInstances;
                        instances = clusterInstances;

                        namespaces = nsResources;

                        inherit
                          activation
                          activationIndex
                          activationFiles
                          packageIndex
                          packageIndexContent
                          info
                          extraImages
                          imageSources
                          ;

                        interfaces = if platformSide == null then { } else platformSide.interfaces;

                        diagnostics = {
                          warnings = libraryWarnings;
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
          )
        )
      )
    );
}
