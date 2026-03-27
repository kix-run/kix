# Cluster builder — top-level entry point that composes modules, runs
# auto-instantiation, builds the nested fixpoint, and collects resources.

{
  lib,
  k8s,
  meta,
  kixlib,
  helpers,
  netpol,
  mkNamespace,
  computeAutoInstances,
  buildResolutionIndex,
  evaluateInstance,
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
            };
          }
        ) nsInsts
      ) mergedInstances;

      resolutionIndex = buildResolutionIndex staticMeta;

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

    in
    builtins.seq clusterDiagnostics.assertionCheck {
      _type = "k8s-cluster-v2";
      inherit name;

      inherit clusterInstances;
      instances = clusterInstances;

      namespaces = nsResources;

      inherit activation packageIndex;

      # Cluster-level diagnostics for tooling
      diagnostics = {
        inherit (clusterDiagnostics) warnings assertions failedAssertions;
      };

      rawManifests = map (
        r: builtins.fromJSON (builtins.unsafeDiscardStringContext (builtins.toJSON r.rawManifest))
      ) allResources;
    };
}
