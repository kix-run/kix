# v2 cluster evaluation — buildCluster, dependency injection, scopes.
#
# Replaces v1's cluster.nix (169 lines) + package.nix (87 lines) with
# namespace-scoped instances, DNS-like dependency injection, and a nested
# fixpoint that ties everything together.

{ lib, k8s }:

let
  inherit (k8s)
    clusterScoped
    mkResource
    mkPackageInstance
    postProcessManifest
    computeClosure
    buildRegistry
    ;
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
        );

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
        );

      # Merge user config with package defaults using deep merge.
      # lib.recursiveUpdate ensures nested attrsets (e.g., backend.hpa)
      # are merged rather than replaced wholesale.
      defaults =
        config: defs:
        let
          knownKeys = builtins.attrNames defs;
          configKeys = builtins.attrNames config;
          unknownKeys = builtins.filter (k: !(builtins.elem k knownKeys)) configKeys;
          result = lib.recursiveUpdate defs config;
        in
        if unknownKeys == [ ] then
          result
        else
          builtins.trace "warning: unknown config keys for instance '${instanceName}': ${builtins.toJSON unknownKeys}" result;
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

  # Introspect package function args, resolve deps, call function.
  # allInstances is the outer fixpoint — used to look up resolved deps.
  kixCallPackage =
    {
      packageFn,
      instanceConfig,
      scope,
      resolutionIndex,
      allInstances,
    }:
    let
      fnArgs = builtins.functionArgs packageFn;
      systemArgNames = [
        "scope"
        "config"
        "lib"
      ];
      depArgNames = builtins.attrNames (removeAttrs fnArgs systemArgNames);

      # Resolve each dependency
      resolvedDeps = builtins.foldl' (
        acc: argName:
        let
          explicitOverride = instanceConfig.${argName} or null;
          resolution = resolveArg {
            inherit argName resolutionIndex explicitOverride;
            requesterNamespace = instanceConfig._namespace;
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
        config = instanceConfig.config or { };
      }
      // resolvedDeps
    );

  # Evaluate a single instance.
  evaluateInstance =
    {
      instanceName,
      namespaceName,
      instanceConfig,
      namespaceResource,
      clusterLabels,
      resolutionIndex,
      allInstances,
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

      packageFn = instanceConfig.package;

      # Get the inner fixpoint function from kixCallPackage
      innerFn = kixCallPackage {
        inherit
          packageFn
          instanceConfig
          scope
          resolutionIndex
          allInstances
          ;
      };

      # Apply parts override if present
      partsOverride = instanceConfig.parts or null;

      # Build the inner fixpoint
      parts =
        if partsOverride != null then
          lib.fix (
            self:
            let
              base = innerFn self;
            in
            base // (partsOverride self base)
          )
        else
          lib.fix innerFn;

      # Derive packageType from function name or instance name
      packageType = instanceConfig.packageType or instanceName;

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
        version = instanceConfig.version or null;
        labels = clusterLabels // {
          "app.kubernetes.io/instance" = instanceName;
          "app.kubernetes.io/managed-by" = "kix";
        };
      };

    in
    parts
    // {
      _type = "k8s-instance";
      _packageInstance = packageInstance;

      # The PackageInstance is the new closure root — it references
      # mainRes, inverse deps, and package requires via store path annotations.
      main = packageInstance;
      fqdn = mainRes.fqdn or null;
      out = mainRes.out or { };

      _meta = {
        inherit instanceName namespaceName packageType;
        namespace = namespaceName;
        aliases = instanceConfig.aliases or [ ];
      };
    };

  # The top-level cluster builder.
  buildCluster =
    {
      namespaces ? { },
      instances,
      clusterLabels ? { },
    }:
    let
      # Collect all namespace names from both explicit namespaces and instances
      instancesFn = if builtins.isFunction instances then instances else (_: instances);
      # We need to peek at namespace names from instances — call with a stub ref
      # that returns a lazy error if actually accessed for values.
      stubRef = lib.fix (_: { });
      rawInstances = instancesFn { ref = stubRef; };
      allNsNames = lib.unique (builtins.attrNames namespaces ++ builtins.attrNames rawInstances);

      # Create namespace resources
      nsResources = builtins.listToAttrs (
        map (nsName: {
          name = nsName;
          value = mkNamespace (
            {
              name = nsName;
            }
            // (namespaces.${nsName} or { })
          );
        }) allNsNames
      );

      # Build the resolution index from STATIC instance config (no inner fixpoint eval).
      # This avoids infinite recursion: _meta is computed from instance config, not
      # from the evaluated package.
      staticMeta = builtins.listToAttrs (
        map (nsName: {
          name = nsName;
          value =
            let
              nsInstances = rawInstances.${nsName} or { };
            in
            builtins.listToAttrs (
              map (instName: {
                name = instName;
                value = {
                  _meta = {
                    instanceName = instName;
                    namespaceName = nsName;
                    namespace = nsName;
                    packageType = nsInstances.${instName}.packageType or instName;
                    aliases = nsInstances.${instName}.aliases or [ ];
                  };
                };
              }) (builtins.attrNames nsInstances)
            );
        }) allNsNames
      );

      resolutionIndex = buildResolutionIndex staticMeta;

      # Build the nested fixpoint (uses pre-computed resolutionIndex)
      clusterInstances = lib.fix (
        self:
        let
          instanceDefs = instancesFn { ref = self; };
        in
        builtins.listToAttrs (
          map (nsName: {
            name = nsName;
            value =
              let
                nsInstances = instanceDefs.${nsName} or { };
              in
              builtins.listToAttrs (
                map (instName: {
                  name = instName;
                  value = evaluateInstance {
                    instanceName = instName;
                    namespaceName = nsName;
                    instanceConfig = nsInstances.${instName} // {
                      _namespace = nsName;
                    };
                    namespaceResource = nsResources.${nsName};
                    allInstances = self;
                    inherit clusterLabels resolutionIndex;
                  };
                }) (builtins.attrNames nsInstances)
              );
          }) allNsNames
        )
      );

      # Collect all resources across all instances for the registry
      allInstancesList = builtins.concatMap (
        nsName:
        map (instName: clusterInstances.${nsName}.${instName}) (
          builtins.attrNames (clusterInstances.${nsName} or { })
        )
      ) (builtins.attrNames clusterInstances);

      # Build registry from all resources we can find
      # We need to collect ALL resources, not just mains + PackageInstance resources
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
          resources = lib.filterAttrs (_: v: builtins.isAttrs v && (v._type or "") == "k8s-resource") parts;
        in
        builtins.attrValues resources
        # Include the PackageInstance resource itself
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

      # Compute closures per instance
      instanceClosures = builtins.listToAttrs (
        map (
          inst:
          let
            main = inst.main;
            closure = computeClosure registry main;
          in
          {
            name = "${inst._meta.namespace}/${inst._meta.instanceName}";
            value = closure;
          }
        ) allInstancesList
      );

      # All manifests (deduplicated)
      allClosureResources = builtins.concatMap (k: instanceClosures.${k}) (
        builtins.attrNames instanceClosures
      );
      dedup =
        resources:
        let
          go =
            {
              seen,
              order,
              queue,
            }:
            if queue == [ ] then
              order
            else
              let
                head = builtins.head queue;
                rest = builtins.tail queue;
                ns =
                  if head.namespace or null == null then
                    "_cluster_"
                  else if builtins.isAttrs head.namespace then
                    if (head.namespace._type or "") == "k8s-cluster-scoped" then
                      "_cluster_"
                    else
                      head.namespace.name or "_cluster_"
                  else
                    head.namespace;
                id = "${head.kind}/${head.name}@${ns}";
              in
              if builtins.hasAttr id seen then
                go {
                  inherit seen order;
                  queue = rest;
                }
              else
                go {
                  seen = seen // {
                    ${id} = true;
                  };
                  order = order ++ [ head ];
                  queue = rest;
                };
        in
        go {
          seen = { };
          order = [ ];
          queue = resources;
        };

      allManifestsRaw = dedup allClosureResources;

    in
    {
      _type = "k8s-cluster-v2";

      # The nested fixpoint of all instances
      inherit clusterInstances;
      instances = clusterInstances;

      # Namespace resources
      namespaces = nsResources;

      # Cluster-wide registry (store path → resource metadata)
      inherit registry;

      # All manifests post-processed (store paths → K8s names)
      manifests = map (r: postProcessManifest registry r.manifest) allManifestsRaw;

      # Raw manifests (with store paths, for debugging)
      rawManifests = map (r: r.manifest) allManifestsRaw;

      # All raw resources
      resources = allManifestsRaw;

      # Per-instance closures
      closures = instanceClosures;

      # DAG visualization
      dagDot = k8s.closureToDot registry (builtins.head allManifestsRaw);
      dagTree = k8s.closureToTree registry (builtins.head allManifestsRaw);

      # Deploy group: merge closures of listed instances, deduplicate
      deployGroup =
        instancePaths:
        let
          resources' = builtins.concatMap (path: instanceClosures.${path} or [ ]) instancePaths;
          dedupResources = dedup resources';
        in
        map (r: postProcessManifest registry r.manifest) dedupResources;

      # Package-level access (for compatibility)
      packages = lib.mapAttrs (
        _nsName: nsInsts: lib.mapAttrs (_instName: inst: inst) nsInsts
      ) clusterInstances;
    };

}
