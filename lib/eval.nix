# Cluster evaluation — buildCluster, dependency injection, scopes.
#
# Uses the NixOS module system (lib/modules.nix) for cluster composition.
# Namespace-scoped instances, DNS-like dependency injection, and a nested
# fixpoint that ties everything together.
# See v2_discussions/20_module_system_design.md for design rationale.

{ lib, k8s }:

let
  inherit (k8s)
    clusterScoped
    mkResource
    mkPackageInstance
    buildRegistry
    ;

  rbac = import ./rbac.nix { inherit lib; };
in

rec {

  # Per-instance context injected into packages.
  mkScope =
    {
      instanceName,
      namespaceName,
      namespaceResource,
      clusterLabels ? { },
    }:
    {
      inherit instanceName namespaceName;
      namespace = namespaceResource;

      mkResource =
        {
          labels ? { },
          ...
        }@args:
        k8s.mkResource (
          removeAttrs args [ "labels" ]
          // {
            namespace = namespaceResource;
            labels =
              clusterLabels
              // {
                "app.kubernetes.io/instance" = instanceName;
                "app.kubernetes.io/managed-by" = "kix";
              }
              // labels;
          }
        ) // { packageLabels = labels; };

      mkClusterResource =
        {
          labels ? { },
          ...
        }@args:
        k8s.mkResource (
          removeAttrs args [ "labels" ]
          // {
            namespace = clusterScoped;
            labels =
              clusterLabels
              // {
                "app.kubernetes.io/instance" = instanceName;
                "app.kubernetes.io/managed-by" = "kix";
              }
              // labels;
          }
        ) // { packageLabels = labels; };

      inherit rbac;
    };

  # Namespace as a small inner fixpoint — Namespace resource + policies.
  mkNamespace =
    {
      name,
      labels ? { },
      annotations ? { },
      resourceQuota ? null,
      networkPolicies ? { },
    }:
    lib.fix (ns: {
      resource = mkResource {
        apiVersion = "v1";
        kind = "Namespace";
        inherit name;
        namespace = clusterScoped;
        labels = labels // {
          "kubernetes.io/metadata.name" = name;
          "app.kubernetes.io/managed-by" = "kix";
        };
        inherit annotations;
        requires = lib.optional (resourceQuota != null) ns.quota ++ builtins.attrValues ns.netpols;
      };

      quota =
        if resourceQuota != null then
          mkResource {
            apiVersion = "v1";
            kind = "ResourceQuota";
            name = "${name}-quota";
            namespace = name; # plain string — internal to namespace package
            spec.hard = resourceQuota;
          }
        else
          null;

      netpols = lib.mapAttrs (
        polName: pol:
        mkResource {
          apiVersion = "networking.k8s.io/v1";
          kind = "NetworkPolicy";
          name = "${name}-${polName}";
          namespace = name;
          spec = pol;
        }
      ) networkPolicies;

      main = ns.resource;
      inherit name;
      outPath = ns.resource.outPath;
    });

  # Build the resolution index from static metadata.
  # Returns { byKey = { argName = [ { namespace, instanceName, ... } ]; }; }
  # Only uses _meta — no inner fixpoint evaluation triggered.
  buildResolutionIndex =
    staticMeta:
    let
      nsNames = builtins.attrNames staticMeta;
      entries = builtins.concatMap (
        ns:
        builtins.concatMap (
          instName:
          let
            meta = staticMeta.${ns}.${instName}._meta;
            keys = [ meta.packageType ] ++ (meta.aliases or [ ]);
          in
          map (key: {
            inherit key;
            namespace = ns;
            inherit instName;
            meta = meta;
          }) keys
        ) (builtins.attrNames staticMeta.${ns})
      ) nsNames;

      byKey = lib.foldl' (
        acc: entry:
        acc
        // {
          ${entry.key} = (acc.${entry.key} or [ ]) ++ [ entry ];
        }
      ) { } entries;

    in
    {
      inherit byKey;
    };

  # DNS-like dependency resolution.
  # Returns { found, namespace?, instanceName? } — caller looks up actual instance from fixpoint.
  resolveArg =
    {
      argName,
      resolutionIndex,
      requesterNamespace,
      hasDefault,
      explicitOverride,
    }:
    # 1. Explicit override always wins
    if explicitOverride != null then
      {
        found = true;
        value = explicitOverride;
        direct = true;
      }

    # 2. DNS-like resolution
    else
      let
        candidates = resolutionIndex.byKey.${argName} or [ ];
        sameNs = builtins.filter (c: c.namespace == requesterNamespace) candidates;
        otherNs = builtins.filter (c: c.namespace != requesterNamespace) candidates;
      in
      # Same namespace, exactly one → use it
      if builtins.length sameNs == 1 then
        let
          c = builtins.head sameNs;
        in
        {
          found = true;
          namespace = c.namespace;
          instanceName = c.instName;
          direct = false;
        }

      # Same namespace, multiple → ambiguous
      else if builtins.length sameNs > 1 then
        throw "ambiguous auto-resolution for '${argName}' in namespace '${requesterNamespace}': multiple matches"

      # No same-ns, one cluster-wide → use it
      else if sameNs == [ ] && builtins.length otherNs == 1 then
        let
          c = builtins.head otherNs;
        in
        {
          found = true;
          namespace = c.namespace;
          instanceName = c.instName;
          direct = false;
        }

      # Multiple cluster-wide → ambiguous
      else if builtins.length otherNs > 1 then
        throw "ambiguous auto-resolution for '${argName}': found in multiple namespaces — specify explicitly"

      # No candidates, has Nix default → let Nix handle it
      else if hasDefault then
        { found = false; }

      # No candidates, no default → error
      else
        throw "no '${argName}' found in cluster for namespace '${requesterNamespace}'";

  # Extract raw config attrsets from a deferredModule value.
  # deferredModuleWith wraps each definition as { _file = "..."; imports = [ actualValue ]; }.
  # This unwraps that structure to get the actual config values.
  extractDeferredValues =
    deferredConfig:
    let
      modules = deferredConfig.imports or [];
      extractOne = m:
        if builtins.isAttrs m && m ? _file && m ? imports then
          # deferredModuleWith wrapper — unwrap
          builtins.concatMap extractOne m.imports
        else if builtins.isAttrs m then
          [ m ]
        else if builtins.isFunction m then
          [ m ]
        else
          [];
    in
    builtins.concatMap extractOne modules;

  # Evaluate instance config using the package's typed options.
  # Runs evalModules with the package's option declarations, global defaults,
  # and instance config (a deferredModule from the cluster module system).
  #
  # After evaluation, deep-merges the option defaults onto the result.
  # This preserves nested defaults for `lib.types.anything` options, which
  # don't deep-merge user values with defaults (a user setting `backend.image`
  # would otherwise drop `backend.hpa` from the default).  This matches the
  # deep-merge semantics of the old `scope.defaults` pattern.
  evaluateInstanceConfig =
    {
      packageOptions,
      instCfg,
      clusterConfig ? {},
    }:
    let
      deferredConfig = instCfg.config;
      configValues = extractDeferredValues deferredConfig;
      wrappedModules = map (v:
        if builtins.isFunction v then v
        else { config = v; }
      ) configValues;

      evaluated = removeAttrs (lib.evalModules {
        modules = [
          { options = packageOptions; }
          { config = clusterConfig.global or {}; }
        ] ++ wrappedModules;
      }).config [ "_module" ];

      # Collect option defaults for deep merge.
      optionDefaults = lib.filterAttrs (_: v: v != null) (
        lib.mapAttrs (_: opt:
          if opt ? default then opt.default else null
        ) packageOptions
      );
    in
    lib.recursiveUpdate optionDefaults evaluated;

  # Introspect package function args, resolve deps, call function.
  # Returns { options, build } — the package's typed options and build function.
  # allInstances is the outer fixpoint — used to look up resolved deps.
  kixCallPackage =
    {
      packageFn,
      scope,
      resolutionIndex,
      allInstances,
      deps ? {},
      namespace,
    }:
    let
      fnArgs = builtins.functionArgs packageFn;
      systemArgNames = [
        "scope"
        "lib"
      ];
      depArgNames = builtins.attrNames (removeAttrs fnArgs systemArgNames);

      # Resolve each dependency
      resolvedDeps = builtins.foldl' (
        acc: argName:
        let
          explicitOverride = deps.${argName} or null;
          resolution = resolveArg {
            inherit argName resolutionIndex explicitOverride;
            requesterNamespace = namespace;
            hasDefault = fnArgs.${argName} or false;
          };
        in
        if resolution.found then
          acc
          // {
            ${argName} =
              if resolution.direct or false then
                resolution.value
              else
                allInstances.${resolution.namespace}.${resolution.instanceName};
          }
        else
          acc # arg has Nix default, let it fall through
      ) { } depArgNames;

    in
    packageFn (
      {
        inherit scope lib;
      }
      // resolvedDeps
    );

  # Evaluate a single instance.
  evaluateInstance =
    {
      instanceName,
      namespaceName,
      instCfg,
      namespaceResource,
      clusterLabels,
      resolutionIndex,
      allInstances,
      globalPartsOverlays ? [],
      clusterConfig ? {},
    }:
    let
      scope = mkScope {
        inherit
          instanceName
          namespaceName
          namespaceResource
          clusterLabels
          ;
      };

      # 1. Call the package function with DI deps — returns { options, build }
      raw = kixCallPackage {
        packageFn = instCfg.package;
        inherit scope resolutionIndex allInstances;
        deps = instCfg.deps;
        namespace = namespaceName;
      };

      # 2. Evaluate typed config: package options + instance config
      evaluatedConfig = evaluateInstanceConfig {
        packageOptions = raw.options or {};
        inherit instCfg clusterConfig;
      };

      # 3. Combine global + instance overlays (signature: scope → self → base → attrset)
      allOverlays = globalPartsOverlays ++ (instCfg.partsOverlays or []);
      boundOverlays = map (o: o scope) allOverlays;

      # 4. Build the inner fixpoint — build receives { self, config, clusterConfig }
      parts =
        if boundOverlays != [] then
          lib.fix (
            self:
            builtins.foldl'
              (acc: overlay: acc // (overlay self acc))
              (raw.build { inherit self clusterConfig; config = evaluatedConfig; })
              boundOverlays
          )
        else
          lib.fix (self:
            raw.build { inherit self clusterConfig; config = evaluatedConfig; }
          );

      # Derive packageType from function name or instance name
      packageType = instCfg.packageType or instanceName;

      # --- Resolve main resource and package-level requires ---
      rawMain =
        parts.main
          or (throw "Instance '${instanceName}' in namespace '${namespaceName}' must define 'main'");

      # main can be either { resource = ...; requires = [...]; } or a resource directly
      mainRes =
        if rawMain ? resource then
          rawMain.resource
        else if rawMain ? _type && rawMain._type == "k8s-resource" then
          rawMain
        else
          throw "Instance '${instanceName}': main must be a resource or { resource, requires }";

      packageRequires = if rawMain ? resource then rawMain.requires or [ ] else [ ];

      # --- Forward closure computation ---
      # Follows both store-path references in manifests AND explicit `requires`.
      # `requires` are structural forward deps (SA needed by Deployment, etc.).

      # Collect all resources from parts (for the local registry).
      # Filters out null values so disabled/modal parts are excluded.
      allPartResources =
        let
          partNames = builtins.attrNames (removeAttrs parts [ "main" ]);
          vals = map (n: {
            name = n;
            value = parts.${n};
          }) partNames;
          resourceVals = builtins.filter (
            v: v.value != null && builtins.isAttrs v.value && (v.value._type or "") == "k8s-resource"
          ) vals;
        in
        map (v: v.value) resourceVals;

      # Build a local mini-registry for this instance's resources
      localRegistry = buildRegistry allPartResources;

      # Get forward deps: store-path refs in manifest + explicit requires
      getForwardDeps =
        resource:
        let
          ctx = builtins.getContext (builtins.toJSON resource.rawManifest);
          k8sPaths = builtins.filter (p: builtins.hasAttr p localRegistry) (builtins.attrNames ctx);
          manifestDeps = map (p: localRegistry.${p}.resource) k8sPaths;
          requiresDeps = builtins.filter (r: builtins.isAttrs r && (r._type or "") == "k8s-resource") (
            resource.requires or [ ]
          );
        in
        manifestDeps ++ requiresDeps;

      # Compute the forward closure from mainRes + packageRequires
      forwardRoots = [ mainRes ] ++ packageRequires;
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
            in
            builtins.any (p: builtins.hasAttr p forwardPaths) ctxPaths;
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

      # --- Create PackageInstance CRD (Phase 5) ---
      # Lists main.requires as package-requires and true inverse deps.
      # Structural deps (via `requires`) are tracked by the cluster-level
      # closure which also follows `requires`.
      packageInstance = mkPackageInstance {
        inherit instanceName namespaceName;
        namespace = namespaceResource;
        mainResource = mainRes;
        inherit packageRequires;
        inherit inverseDeps;
        version = instCfg.version or null;
        labels = clusterLabels // {
          "app.kubernetes.io/instance" = instanceName;
          "app.kubernetes.io/managed-by" = "kix";
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

      # 3. Orphaned resources: defined in parts but not reachable from main
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

      # Emit warnings via builtins.trace
      _w1 = lib.foldl' (
        acc: w:
        builtins.trace "warning: resource '${w.resource.kind}/${w.resource.name}' has redundant requires on '${w.req.kind}/${w.req.name}' — already tracked via store path reference"
          acc
      ) null redundantRequiresWarnings;

      _w2 = lib.foldl' (
        acc: w:
        builtins.trace "warning: resource '${w.resource.kind}/${w.resource.name}' requires '${w.req.kind}/${w.req.name}' multiple times"
          acc
      ) null duplicateRequiresWarnings;

      _w3 = lib.foldl' (
        acc: r:
        builtins.trace "warning: resource '${r.kind}/${r.name}' in instance '${instanceName}' is defined but not reachable from main (orphaned)"
          acc
      ) null orphanedWarnings;

    in
    builtins.seq _w1 (builtins.seq _w2 (builtins.seq _w3 (
    parts
    // {
      _type = "k8s-instance";
      _packageInstance = packageInstance;

      # The PackageInstance is the new closure root — it references
      # mainRes, inverse deps, and package requires via annotations.
      main = packageInstance;
      out = mainRes.out or { };

      _meta = {
        inherit instanceName namespaceName packageType;
        namespace = namespaceName;
        aliases = instCfg.aliases or [ ];
      };
    })));

  # The top-level cluster builder.
  # Uses lib.evalModules to compose cluster definitions from modules.
  # Each module can declare options and set instances, namespaces, etc.
  # `ref` (the lazy fixpoint of all instances) is available via specialArgs.
  buildCluster =
    {
      name ? "cluster",
      modules,
    }:
    let
      # 1. Evaluate modules — produces merged config lazily.
      #    ref thunks in config values are NOT forced during merge
      #    (config fields are deferredModule — stored as-is).
      evaluated = lib.evalModules {
        modules = [ (import ./modules.nix) ] ++ modules;
        specialArgs = {
          ref = clusterInstances; # lazy — resolved during fixpoint
        };
      };

      cfg = evaluated.config;

      # 2. Derive namespace list from instances keys ∪ explicit namespaces
      allNsNames = lib.unique (
        builtins.attrNames cfg.namespaces
        ++ builtins.attrNames cfg.instances
      );

      # 3. Create namespace resources
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

      # 4. Build static metadata for DI resolution (reads only packageType/aliases)
      staticMeta = lib.mapAttrs (nsName: nsInsts:
        lib.mapAttrs (instName: instCfg: {
          _meta = {
            instanceName = instName;
            namespaceName = nsName;
            namespace = nsName;
            packageType = if instCfg.packageType != null then instCfg.packageType else instName;
            aliases = instCfg.aliases;
          };
        }) nsInsts
      ) cfg.instances;

      resolutionIndex = buildResolutionIndex staticMeta;

      # 5. Build nested fixpoint
      clusterInstances = lib.fix (self:
        lib.mapAttrs (nsName: nsInsts:
          lib.mapAttrs (instName: instCfg:
            evaluateInstance {
              instanceName = instName;
              namespaceName = nsName;
              inherit instCfg;
              namespaceResource = nsResources.${nsName};
              allInstances = self;
              clusterLabels = cfg.clusterLabels;
              clusterConfig = cfg;
              inherit resolutionIndex;
              globalPartsOverlays = cfg.globalPartsOverlays;
            }
          ) nsInsts
        ) cfg.instances
      );

      # --- Resource collection (unchanged from pre-module system) ---

      allInstancesList = builtins.concatMap (
        nsName:
        map (instName: clusterInstances.${nsName}.${instName}) (
          builtins.attrNames (clusterInstances.${nsName} or { })
        )
      ) (builtins.attrNames clusterInstances);

      collectResources =
        inst:
        let
          parts = removeAttrs inst [
            "_type"
            "_meta"
            "_packageInstance"
            "main"
            "fqdn"
            "out"
            "overrideParts"
          ];
          resources = lib.filterAttrs (
            _: v: v != null && builtins.isAttrs v && (v._type or "") == "k8s-resource"
          ) parts;
        in
        builtins.attrValues resources
        ++ (if inst ? _packageInstance then [ inst._packageInstance ] else [ ]);

      allResources =
        (builtins.concatMap collectResources allInstancesList)
        ++ (builtins.concatMap (
          nsName:
          let
            ns = nsResources.${nsName};
          in
          [ ns.resource ]
          ++ (if ns.quota != null then [ ns.quota ] else [ ])
          ++ builtins.attrValues ns.netpols
        ) allNsNames);

      registry = buildRegistry allResources;

      # Activation CRD — cluster-level root of the Nix store DAG.
      activation = k8s.mkActivation {
        inherit name;
        instances = lib.mapAttrs (
          _nsName: nsInsts:
          lib.mapAttrs (_: inst: inst._packageInstance.out.name) nsInsts
        ) clusterInstances;
      };

    in
    {
      _type = "k8s-cluster-v2";
      inherit name;

      inherit clusterInstances;
      instances = clusterInstances;

      namespaces = nsResources;

      inherit activation;

      rawManifests = map (r:
        builtins.fromJSON (builtins.unsafeDiscardStringContext (builtins.toJSON r.rawManifest))
      ) allResources;
    };

}
