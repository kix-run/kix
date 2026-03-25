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
    mkImportResource
    mkPackageInstance
    ;

  rbac = import ./rbac.nix { inherit lib; };
  kixlib = import ./compose.nix { inherit lib; };
  meta = import ./meta.nix { inherit lib; };

in

rec {

  # ---------------------------------------------------------------------------
  # Helpers: merge-with-collision and recursive typed-attr walker
  # ---------------------------------------------------------------------------

  # Merge two attrsets, throwing on key collision.
  mergeCollide =
    context: a: b:
    let
      collisions = builtins.intersectAttrs a b;
    in
    if collisions == { } then
      a // b
    else
      throw "${context}: key collision on ${builtins.concatStringsSep ", " (builtins.attrNames collisions)}";

  # Collect all typed objects (anything with _type) from nested attrsets,
  # up to maxDepth levels deep. Stops at _type boundaries — never descends
  # into typed objects. Plain attrsets without _type are treated as folders.
  collectTypedAttrs =
    {
      excludeKeys ? [ ],
      maxDepth ? 3,
    }:
    attrs:
    let
      go =
        depth: a:
        builtins.concatMap (
          n:
          let
            v = a.${n};
          in
          if v == null then
            [ ]
          else if !(builtins.isAttrs v) then
            [ ]
          else if v ? _type then
            [ v ]
          else if depth >= maxDepth then
            [ ]
          else
            go (depth + 1) v
        ) (builtins.attrNames (removeAttrs a excludeKeys));
    in
    go 0 attrs;

  # Well-known folders that get content-type validation warnings.
  knownFolders = {
    secrets = {
      expectedTypes = [ "k8s-resource" ];
    };
    crds = {
      expectedTypes = [
        "k8s-resource"
        "crd-ref"
      ];
    };
  };

  # Build the consumer-facing view of a package instance.
  #
  # Three layers, all merged with collision detection:
  #   1. folders  — plain attrsets from parts (no _type), excluding "main"
  #   2. autoKeys — auto-copied from main.out (fqdn, name, selector, etc.)
  #   3. system   — evaluator plumbing (_type, _meta, main, out, raw)
  #
  # Root-level resources (typed values) live only in raw, not on the surface.
  mkPackageView =
    {
      parts,
      mainOut,
      instanceName,
      packageInstance,
      packageMeta,
      namespaceName,
      aliases,
    }:
    let
      ctx = "instance '${instanceName}'";

      # Layer 1: folders — only plain attrsets (no _type), excluding "main"
      folders = lib.filterAttrs (
        n: v: n != "main" && v != null && builtins.isAttrs v && !(v ? _type)
      ) parts;

      # Layer 2: auto-copied main.out (fqdn, name, selector, etc.)
      autoKeys = mainOut;

      # Layer 3: system/evaluator plumbing
      system = {
        _type = "k8s-instance";
        _packageInstance = packageInstance;
        main = packageInstance;
        out = mainOut;
        raw = parts;
        _meta = {
          inherit
            instanceName
            namespaceName
            aliases
            packageMeta
            ;
          namespace = namespaceName;
        };
      };

      # Known-folder structure check: resource directly on a known folder key → error
      _folderStructureChecks = builtins.foldl' (
        acc: folderName:
        let
          v = parts.${folderName} or null;
        in
        if v != null && builtins.isAttrs v && v ? _type then
          throw "${ctx}: '${folderName}' must be an attrset of resources, not a resource directly. Use '${folderName}.someName = ...' instead."
        else
          acc
      ) null (builtins.attrNames knownFolders);

      # Known-folder content warnings: wrong _type inside a known folder → trace warning
      _folderContentChecks = builtins.foldl' (
        acc: folderName:
        let
          spec = knownFolders.${folderName};
          contents = parts.${folderName} or { };
          typed = collectTypedAttrs { } contents;
          bad = builtins.filter (r: !(builtins.elem (r._type or "") spec.expectedTypes)) typed;
        in
        lib.foldl' (
          inner: r:
          builtins.trace "warning: ${ctx}.${folderName} contains ${r.kind or "?"}/${r.name or "?"} — unexpected _type '${r._type or "unknown"}'" inner
        ) acc bad
      ) null (builtins.attrNames knownFolders);

    in
    builtins.seq _folderStructureChecks (
      builtins.seq _folderContentChecks (
        mergeCollide "${ctx}: folder key collides with main.out" folders autoKeys
        |> mergeCollide "${ctx}: package key collides with system key" system
      )
    );

  # Per-instance context injected into packages.
  mkScope =
    {
      instanceName,
      namespaceName,
      namespaceResource,
      namespaces ? { },
      clusterLabels ? { },
      labelStyle ? "kix",
      selectorLabelsOverride ? null,
      clusterDomain ? "cluster.local",
    }:
    let
      selectorLabels =
        if selectorLabelsOverride != null then
          selectorLabelsOverride
        else if labelStyle == "helm" then
          {
            app = instanceName;
            release = instanceName;
          }
        else
          {
            "app.kubernetes.io/name" = instanceName;
            "app.kubernetes.io/instance" = instanceName;
          };

      instanceLabels =
        if labelStyle == "helm" then
          {
            release = instanceName;
            "app.kubernetes.io/managed-by" = "kix";
          }
        else
          {
            "app.kubernetes.io/instance" = instanceName;
            "app.kubernetes.io/managed-by" = "kix";
          };

      scopeMkResource =
        {
          labels ? { },
          ...
        }@args:
        k8s.mkResource (
          removeAttrs args [ "labels" ]
          // {
            namespace = namespaceResource;
            inherit clusterDomain;
            labels = clusterLabels // instanceLabels // labels;
          }
        )
        // {
          packageLabels = labels;
        };

      # WARNING: StatefulSet.spec.serviceName must use .name (plain string),
      # NOT .out.name (context-carrying). Using .out.name creates a store DAG
      # edge to the Service. If the Service also has `requires` pointing back
      # to the StatefulSet, this causes infinite recursion during evaluation.
      # The serviceName field is a plain K8s name match, not a dependency.
      mkWorkload =
        apiVersion: kind: attrs:
        let
          spec = attrs.spec or { };
          selector =
            spec.selector.matchLabels
              or (throw "mkWorkload (${kind}): spec.selector.matchLabels is required — use scope.selectorLabels");
          templateMeta = spec.template.metadata or { };
          templateSpec = spec.template.spec or { };
        in
        scopeMkResource (
          removeAttrs attrs [ "spec" ]
          // {
            inherit apiVersion kind;
            spec =
              removeAttrs spec [
                "selector"
                "template"
              ]
              // {
                selector.matchLabels = selector;
                template = {
                  metadata = templateMeta // {
                    labels = templateMeta.labels or selector;
                  };
                  spec = templateSpec;
                };
              };
          }
        );

      scopeMkClusterResource =
        {
          labels ? { },
          ...
        }@args:
        k8s.mkResource (
          removeAttrs args [ "labels" ]
          // {
            namespace = clusterScoped;
            inherit clusterDomain;
            labels = clusterLabels // instanceLabels // labels;
          }
        )
        // {
          packageLabels = labels;
        };

      # ── CRD support ──────────────────────────────────────────────────

      # Create a CRD resource with auto-attached CR builders on .out.
      # Returns a resource (usable in requires, etc.) with .out.{cr, mkCR}.
      mkCRD =
        {
          group,
          kind,
          plural,
          singular,
          listKind,
          version ? "v1",
          crdScope ? "Namespaced",
          labels ? { },
          shortNames ? [ ],
          categories ? [ ],
          printerColumns ? [ ],
          schema ?
            builtins.trace
              "mkCRD: no schema provided for ${kind}, using permissive default — consider adding an OpenAPI schema"
              {
                type = "object";
                "x-kubernetes-preserve-unknown-fields" = true;
              },
        }:
        let
          crdResource = scopeMkClusterResource {
            apiVersion = "apiextensions.k8s.io/v1";
            kind = "CustomResourceDefinition";
            name = "${plural}.${group}";
            inherit labels;
            extra.spec = {
              inherit group;
              scope = crdScope;
              names = {
                inherit
                  kind
                  listKind
                  plural
                  singular
                  ;
              }
              // lib.optionalAttrs (shortNames != [ ]) { inherit shortNames; }
              // lib.optionalAttrs (categories != [ ]) { inherit categories; };
              versions = [
                (
                  {
                    name = version;
                    served = true;
                    storage = true;
                    subresources.status = { };
                    schema.openAPIV3Schema = {
                      type = "object";
                      properties = {
                        apiVersion = {
                          type = "string";
                        };
                        kind = {
                          type = "string";
                        };
                        metadata = {
                          type = "object";
                        };
                        spec = schema;
                        status = {
                          type = "object";
                          "x-kubernetes-preserve-unknown-fields" = true;
                        };
                      };
                    };
                  }
                  // lib.optionalAttrs (printerColumns != [ ]) {
                    additionalPrinterColumns = printerColumns;
                  }
                )
              ];
            };
          };

          builders = k8s.mkCRDBuilders {
            crdOrRef = crdResource;
            inherit
              group
              kind
              version
              crdScope
              ;
          };
        in
        crdResource
        // {
          out = crdResource.out // builders;
        };

      # Create a CRD reference for externally-managed CRDs (Helm, pre-existing).
      # Has its own store path for dependency tracking but produces no deployable manifest.
      # Same .out.{cr, mkCR} interface as mkCRD.
      mkCRDRef =
        {
          group,
          kind,
          plural,
          version ? "v1",
          crdScope ? "Namespaced",
          requires ? [ ],
        }:
        let
          refPath = builtins.toFile "crd-ref-${kind}" (
            builtins.toJSON {
              inherit
                group
                kind
                version
                crdScope
                ;
            }
          );
          ref = {
            _type = "crd-ref";
            outPath = refPath;
            inherit requires;
            out = {
              name = "${plural}.${group}";
            }
            // builders;
          };
          builders = k8s.mkCRDBuilders {
            crdOrRef = ref;
            inherit
              group
              kind
              version
              crdScope
              ;
          };
        in
        ref;

      # Scope-side CRD builder: reads the CRD's scope and auto-routes.
      # Uses scopeObj (lazy self-reference) so crd.out.mkCR gets the full scope.
      mkCR = crd: args: crd.out.mkCR scopeObj args;

      # The scope object — self-referencing via Nix laziness so mkCR can pass
      # the full scope to crd.out.mkCR.
      scopeObj = {
        inherit
          instanceName
          namespaceName
          selectorLabels
          labelStyle
          namespaces
          ;
        namespace = namespaceResource;

        mkResource = scopeMkResource;

        forNamespace =
          nsName:
          let
            nsRes =
              namespaces.${nsName}
                or (throw "scope.forNamespace: namespace '${nsName}' does not exist in the cluster");
          in
          mkScope {
            inherit
              instanceName
              namespaces
              clusterLabels
              labelStyle
              ;
            namespaceName = nsName;
            namespaceResource = nsRes;
          };

        mkClusterResource = scopeMkClusterResource;

        inherit rbac;

        mkDeployment = mkWorkload "apps/v1" "Deployment";
        mkStatefulSet = mkWorkload "apps/v1" "StatefulSet";
        mkDaemonSet = mkWorkload "apps/v1" "DaemonSet";

        inherit mkCRD mkCRDRef mkCR;
      };
    in
    scopeObj;

  # Create an import marker — used as the `package` field for imported instances.
  # `from`: optional package function to derive out from (via lazy eval).
  # `out`: manual out overrides, merged on top of derived values.
  mkImport =
    {
      from ? null,
      out ? { },
    }:
    {
      _type = "kix-import";
      inherit from out;
    };

  # Per-instance context for import mode.
  # Swaps mkResource/mkClusterResource for lightweight ref constructors
  # that compute out without creating store paths or manifests.
  mkImportScope =
    {
      instanceName,
      namespaceName,
      namespaceResource,
      clusterLabels ? { },
    }:
    let
      selectorLabels = {
        "app.kubernetes.io/name" = instanceName;
        "app.kubernetes.io/instance" = instanceName;
      };
    in
    {
      inherit instanceName namespaceName selectorLabels;
      labelStyle = "kix";
      namespace = namespaceResource;

      mkResource =
        {
          labels ? { },
          ...
        }@args:
        mkImportResource (
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
        mkImportResource (
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

      inherit rbac;
    };

  # Evaluate an imported instance.
  # If `from` is provided, runs the real package build with import-mode scope
  # (lightweight mkResource) and extracts out via laziness. Otherwise uses
  # raw out directly. Creates a marker PackageInstance CR for the deploy graph.
  evaluateImportInstance =
    {
      instanceName,
      namespaceName,
      instCfg,
      namespaceResource,
      clusterLabels,
      clusterConfig ? { },
      ...
    }:
    let
      importDef = instCfg.package; # { _type = "kix-import"; from, out }

      # Derive out: from package build (lazy) + manual overrides
      derivedOut =
        if importDef.from != null then
          let
            importScope = mkImportScope {
              inherit
                instanceName
                namespaceName
                namespaceResource
                clusterLabels
                ;
            };

            # Call the package function with null for all dependency args.
            # Laziness ensures only out-relevant code paths are forced.
            fnArgs = builtins.functionArgs importDef.from;
            depArgNames = builtins.attrNames (
              removeAttrs fnArgs [
                "scope"
                "lib"
                "kix"
              ]
            );
            nullDeps = builtins.listToAttrs (
              map (name: {
                inherit name;
                value = null;
              }) depArgNames
            );
            raw = importDef.from (
              {
                scope = importScope;
                inherit lib;
              }
              // lib.optionalAttrs (fnArgs ? kix) { kix = kixlib; }
              // nullDeps
            );

            # Evaluate typed config (same as normal path)
            evaluatedConfig = evaluateInstanceConfig {
              packageOptions = raw.options or { };
              inherit instCfg clusterConfig;
            };

            # Run fixpoint — only out will be forced
            parts = lib.fix (
              self:
              raw.build {
                inherit self clusterConfig;
                config = evaluatedConfig;
              }
            );

            # Extract main's out
            rawMain =
              parts.main or (throw "Import instance '${instanceName}': package build must define 'main'");
            mainRes =
              if rawMain ? resource then
                rawMain.resource
              else if rawMain ? _type then
                rawMain
              else
                throw "Import instance '${instanceName}': main must be a resource or { resource, requires }";
          in
          (mainRes.out or { }) // importDef.out
        else
          importDef.out;

      # Marker PackageInstance — deployed to mark this import in the cluster.
      # Carries import metadata so deploy tooling can verify the external resource.
      markerResource = mkResource {
        apiVersion = "kix.dev/v1alpha1";
        kind = "PackageInstance";
        name = instanceName;
        namespace = namespaceResource;
        annotations = {
          "kix.dev/mode" = "import";
        }
        // lib.optionalAttrs (derivedOut ? name) {
          "kix.dev/import-name" = derivedOut.name;
        }
        // lib.optionalAttrs (derivedOut ? fqdn) {
          "kix.dev/import-fqdn" = derivedOut.fqdn;
        };
        labels = clusterLabels // {
          "app.kubernetes.io/instance" = instanceName;
          "app.kubernetes.io/managed-by" = "kix";
        };
        extra.spec = {
          inherit instanceName namespaceName;
          mode = "import";
        };
      };
    in
    {
      _type = "k8s-instance";
      _isImport = true;
      _packageInstance = markerResource;
      main = markerResource;
      out = derivedOut;
      _meta = {
        inherit instanceName namespaceName;
        namespace = namespaceName;
        aliases = instCfg.aliases or [ ];
      };
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
            keys = lib.unique ([ instName ] ++ (meta.aliases or [ ]));
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
      modules = deferredConfig.imports or [ ];
      extractOne =
        m:
        if builtins.isAttrs m && m ? _file && m ? imports then
          # deferredModuleWith wrapper — unwrap
          builtins.concatMap extractOne m.imports
        else if builtins.isAttrs m then
          [ m ]
        else if builtins.isFunction m then
          [ m ]
        else
          [ ];
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
      clusterConfig ? { },
    }:
    let
      deferredConfig = instCfg.config;
      configValues = extractDeferredValues deferredConfig;
      wrappedModules = map (v: if builtins.isFunction v then v else { config = v; }) configValues;

      evaluated =
        removeAttrs
          (lib.evalModules {
            modules = [
              { options = packageOptions; }
              { config = clusterConfig.global or { }; }
            ]
            ++ wrappedModules;
          }).config
          [ "_module" ];

      # Collect option defaults for deep merge.
      optionDefaults = lib.filterAttrs (_: v: v != null) (
        lib.mapAttrs (_: opt: if opt ? default then opt.default else null) packageOptions
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
      deps ? { },
      namespace,
    }:
    let
      fnArgs = builtins.functionArgs packageFn;
      systemArgNames = [
        "scope"
        "lib"
        "kix"
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
      // lib.optionalAttrs (fnArgs ? kix) { kix = kixlib; }
      // resolvedDeps
    );

  # Evaluate a single instance.
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
    }@args:

    # Import instances take a separate evaluation path — no resource collection,
    # no closure computation, just out derivation + marker CR.
    if (instCfg.package._type or "") == "kix-import" then
      evaluateImportInstance args

    else
      let
        scope = mkScope {
          inherit
            instanceName
            namespaceName
            namespaceResource
            clusterLabels
            ;
          namespaces = nsResources;
          labelStyle = instCfg.labelStyle;
          selectorLabelsOverride = instCfg.selectorLabels;
          clusterDomain = clusterConfig.clusterDomain or "cluster.local";
        };

        # 1. Call the package function with DI deps — returns { meta?, options, build }
        raw = kixCallPackage {
          packageFn = instCfg.package;
          inherit scope resolutionIndex allInstances;
          deps = instCfg.deps;
          namespace = namespaceName;
        };

        # Package-declared metadata (lifecycle, scope, etc.)
        packageMeta = raw.meta or { };

        # --- Resolved dependency info (for validation) ---
        fnArgs = builtins.functionArgs instCfg.package;
        depArgNames = builtins.attrNames (
          removeAttrs fnArgs [
            "scope"
            "lib"
            "kix"
          ]
        );
        deps = instCfg.deps or { };

        # Resolve dep metadata for cross-checks
        resolvedDepMeta = builtins.foldl' (
          acc: argName:
          let
            resolution = resolveArg {
              inherit argName resolutionIndex;
              requesterNamespace = namespaceName;
              hasDefault = fnArgs.${argName} or false;
              explicitOverride = deps.${argName} or null;
            };
          in
          if resolution.found && !(resolution.direct or false) then
            acc
            // {
              ${argName} = {
                inherit resolution;
                instance = allInstances.${resolution.namespace}.${resolution.instanceName};
              };
            }
          else
            acc
        ) { } depArgNames;

        # --- Cross-namespace scope validation ---
        _crossNsCheck =
          let
            crossNsDeps = lib.filterAttrs (
              _: depInfo:
              let
                depScope = (depInfo.instance._meta.packageMeta or { }).scope or "cluster";
              in
              (depInfo.resolution.namespace or namespaceName) != namespaceName && depScope == "namespace"
            ) resolvedDepMeta;
          in
          lib.foldlAttrs (
            acc: argName: depInfo:
            throw "instance '${instanceName}' (namespace '${namespaceName}') depends on '${depInfo.resolution.instanceName}' (namespace '${depInfo.resolution.namespace}') which declares meta.scope = \"namespace\" — cross-namespace reference not allowed"
          ) null crossNsDeps;

        # --- Meta-derived assertions and warnings (static, before build) ---
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

        # 2. Evaluate typed config: package options + instance config
        evaluatedConfig = evaluateInstanceConfig {
          packageOptions = raw.options or { };
          inherit instCfg clusterConfig;
        };

        # 3. Combine global + instance overlays (signature: scope → self → base → attrset)
        allOverlays = globalPartsOverlays ++ (instCfg.partsOverlays or [ ]);
        boundOverlays = map (o: o scope) allOverlays;

        # 4. Build the inner fixpoint — build receives { self, config, clusterConfig }
        parts =
          if boundOverlays != [ ] then
            lib.fix (
              self:
              builtins.foldl' (acc: overlay: acc // (overlay self acc)) (raw.build {
                inherit self clusterConfig;
                config = evaluatedConfig;
              }) boundOverlays
            )
          else
            lib.fix (
              self:
              raw.build {
                inherit self clusterConfig;
                config = evaluatedConfig;
              }
            );

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

        # Package-level out extensions (functions, complex types beyond string outputs).
        # Merged on top of the main resource's auto-derived out.
        packageOut = if rawMain ? resource then rawMain.out or { } else { };

        # --- Forward closure computation ---
        # Follows both store-path references in manifests AND explicit `requires`.
        # `requires` are structural forward deps (SA needed by Deployment, etc.).

        # Collect all resources from parts (for the local registry).
        # Filters out null values so disabled/modal parts are excluded.
        allPartResources = builtins.filter (v: (v._type or "") == "k8s-resource") (
          collectTypedAttrs {
            excludeKeys = [
              "main"
              "meta"
            ];
          } parts
        );

        # Local store-path → resource lookup for forward closure walking.
        # TODO: potentially move the PI collection to kix-cli for faster eval
        localRegistry = builtins.foldl' (
          acc: r:
          acc
          // {
            ${builtins.unsafeDiscardStringContext r.outPath} = {
              resource = r;
            };
          }
        ) { } allPartResources;

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

        # --- Package-declared warnings and assertions (post-build) ---
        packageResult = meta.evaluatePackageDiagnostics {
          inherit
            raw
            evaluatedConfig
            parts
            resolvedDepMeta
            ;
        };

        # --- Combine all diagnostics ---
        structuralWarnings =
          let
            res = r: "${r.kind}/${r.name}";
            warn = msg: items: map (x: "[${instanceName}] ${msg x}") items;
          in
          lib.concatLists [
            (warn (
              w:
              "resource '${res w.resource}' has redundant requires on '${res w.req}' — already tracked via store path reference"
            ) redundantRequiresWarnings)
            (warn (
              w: "resource '${res w.resource}' requires '${res w.req}' multiple times"
            ) duplicateRequiresWarnings)
            (warn (r: "resource '${res r}' is defined but not reachable from main (orphaned)") orphanedWarnings)
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
        builtins.seq diagnostics.emitWarnings (
          builtins.seq diagnostics.emitAssertionWarnings (
            let
              view = mkPackageView {
                inherit
                  parts
                  instanceName
                  namespaceName
                  packageMeta
                  packageInstance
                  ;
                mainOut = (mainRes.out or { }) // packageOut;
                aliases = instCfg.aliases or [ ];
              };
            in
            view
            // {
              _diagnostics = {
                warnings = diagnostics.allWarnings;
                assertions = diagnostics.allAssertions;
                inherit (diagnostics) failedAssertions;
              };
            }
          )
        )
      );

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
        modules = [ (import ./modules.nix) ] ++ modules;
        specialArgs = {
          ref = clusterInstances; # lazy — resolved during fixpoint
        }
        // specialArgs;
      };

      cfg = evaluated.config;

      # 2. Derive namespace list from instances keys ∪ explicit namespaces
      allNsNames = lib.unique (builtins.attrNames cfg.namespaces ++ builtins.attrNames cfg.instances);

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

      # 4. Build static metadata for DI resolution (instance name + aliases)
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
                instanceAliases = instCfg.aliases;
                inherit packageMeta;
              };
            };
          }
        ) nsInsts
      ) cfg.instances;

      resolutionIndex = buildResolutionIndex staticMeta;

      # 5. Build nested fixpoint
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
          raw =
            inst.raw or (removeAttrs inst [
              "_type"
              "_meta"
              "_packageInstance"
              "_diagnostics"
              "_isImport"
              "main"
              "fqdn"
              "out"
              "overrideParts"
            ]);
        in
        builtins.filter (v: (v._type or "") == "k8s-resource") (
          collectTypedAttrs {
            excludeKeys = [
              "main"
              "meta"
            ];
          } raw
        )
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

      # Activation CRD — cluster-level root of the Nix store DAG.
      activation = k8s.mkActivation {
        inherit name;
        instances = lib.mapAttrs (
          _nsName: nsInsts: lib.mapAttrs (_: inst: inst._packageInstance.out.name) nsInsts
        ) clusterInstances;
      };

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

      inherit activation;

      # Cluster-level diagnostics for tooling
      diagnostics = {
        inherit (clusterDiagnostics) warnings assertions failedAssertions;
      };

      rawManifests = map (
        r: builtins.fromJSON (builtins.unsafeDiscardStringContext (builtins.toJSON r.rawManifest))
      ) allResources;
    };

}
