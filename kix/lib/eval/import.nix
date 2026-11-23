{
  lib,
  k8s,
  rbac,
  kixlib,
  helpers,
  mkScope,
  evaluateInstanceConfig,
  buildEntriesOf,
  discoverBuildDeps,
}:

let
  inherit (import ../core/error.nix { inherit lib; }) fail failFor;
  meta = import ../meta.nix { inherit lib; };
  packageLib = import ../core/package.nix { inherit lib; };
  kixAnnotations = import ../core/annotations.nix;
  kixKeys = kixAnnotations.keys;
  inherit (k8s)
    clusterScoped
    mkResource
    mkImportResource
    kixCRDs
    ;
in

rec {
  mkImport =
    {
      from ? null,
      out ? { },
      kind ? null,
      apiVersion ? null,
      # Roles that this environment-provided service fulfills. A managed
      # instance declaring the same role takes precedence over the import. Each
      # role name also acts as a dependency-resolution alias.
      roles ? [ ],
      # CustomResourceDefinitions installed by the environment, each given as
      # `scope.mkCRDRef` arguments without `installedBy`. Each entry populates
      # `out.crds.<kind>` for `scope.mkCR` consumers and emits a CRD marker
      # while the import is active.
      crds ? [ ],
      # Whether dependency resolution offers this import to consumers in
      # every namespace ("cluster") or in its own namespace only
      # ("namespace"). An environment-provided service is normally shared,
      # so the default is "cluster".
      scope ? "cluster",
    }:
    {
      _type = "kix-import";
      inherit
        from
        out
        kind
        apiVersion
        crds
        ;
      meta = {
        inherit roles scope;
      };
    };

  mkImportScope =
    {
      instanceName,
      namespaceName,
      namespaceResource,
      clusterLabels ? { },
      clusterDomain,
    }:
    let
      selectorLabels = {
        "app.kubernetes.io/name" = instanceName;
        "app.kubernetes.io/instance" = instanceName;
      };
      mkRes =
        ns:
        {
          labels ? { },
          ...
        }@args:
        mkImportResource (
          removeAttrs args [ "labels" ]
          // {
            inherit clusterDomain;
            namespace = ns;
            labels =
              clusterLabels
              // {
                "app.kubernetes.io/instance" = instanceName;
                "app.kubernetes.io/managed-by" = "kix";
              }
              // labels;
          }
        );

      mkServiceRefImport =
        {
          name,
          selector,
          ports,
          labels ? { },
          requires ? [ ],
        }:
        let
          # Attach an endpoint fact token so import-mode service refs
          # participate in network dependency detection without a store
          # resource.
          endpointFactCtx = k8s.facts.mkFact "endpoint" {
            inherit name selector ports;
            namespace = namespaceName;
          };
          attachConnectCtx = value: builtins.appendContext (toString value) endpointFactCtx;
        in
        {
          factTokens = {
            endpoint = endpointFactCtx;
          };
          out = {
            inherit selector ports labels;
            inherit name;
            fqdn = attachConnectCtx "${name}.${namespaceName}.svc.${clusterDomain}";
            port = attachConnectCtx (toString (builtins.head ports).port);
          };
        };
      mkSecretRefImport =
        {
          name,
          keys,
          type ? "Opaque",
          requires ? [ ],
          reflect ? false,
        }:
        {
          out = {
            inherit name;
          }
          // k8s.mkSecretHelpers {
            inherit name keys type;
            namespace = namespaceName;
            attachCtx = v: v;
            reflected = reflect;
          };
        };

      # Build a stub workload for import mode that exposes `rawSelector` and
      # `rawManifest` without sealing or emitting a Kubernetes resource.
      # Packages derived via `mkImport { from = ...; }` evaluate their workload
      # builders when `kix.service.fromWorkload` reads the workload's selector
      # and container ports to construct the root Service's `out`.
      mkWorkloadImport =
        apiVersion: kind: args:
        let
          spec = args.spec or { };
          templateMeta =
            if kind == "CronJob" then
              spec.jobTemplate.spec.template.metadata or { }
            else
              spec.template.metadata or { };
          selector =
            spec.selector.matchLabels or templateMeta.labels or (fail {
              message = "Import instance '${instanceName}': ${kind} '${args.name or "?"}' has no spec.selector.matchLabels and no pod template labels.";
              fix = "Use scope.selectorLabels.";
            });
          ref = mkRes namespaceResource (
            {
              inherit apiVersion kind spec;
              name = args.name or (fail "Import instance '${instanceName}': ${kind} needs a name");
              labels = args.labels or { };
            }
            // lib.optionalAttrs (args ? annotations) { inherit (args) annotations; }
            // lib.optionalAttrs (args ? outputs) { inherit (args) outputs; }
          );
        in
        ref
        // {
          rawSelector = selector;
          rawManifest = {
            inherit apiVersion kind spec;
            metadata = {
              name = args.name;
              namespace = namespaceName;
              labels = args.labels or { };
            };
          };
        };

      instance = "${namespaceName}/${instanceName}";

      # Every name the package scope offers. The import scope implements
      # some of them and refuses the rest with an error that names the
      # import and the scope attribute.
      packageScopeNames = builtins.attrNames (mkScope {
        inherit
          instanceName
          namespaceName
          namespaceResource
          clusterDomain
          ;
      });
      unsupported =
        name:
        fail {
          inherit instance;
          message = "kix.mkImport { from = ...; } evaluates the package to derive the import's out, and the package uses scope.${name}, which an import does not offer.";
          fix =
            "Set the import's output fields directly and omit 'from':"
            + "\n  kix.mkImport { out = { <field> = \"...\"; }; }"
            + "\nList the CRDs the environment installs in kix.mkImport { crds = [ ... ]; }.";
        };

      scope = lib.genAttrs packageScopeNames unsupported // {
        inherit instanceName namespaceName selectorLabels;
        fail = failFor instance;
        labelStyle = "kix";
        namespace = namespaceResource;
        mkResource = mkRes namespaceResource;
        mkClusterResource = mkRes clusterScoped;
        mkCR = _crd: args: scope.mkResource args;
        mkDeployment = mkWorkloadImport "apps/v1" "Deployment";
        mkStatefulSet = mkWorkloadImport "apps/v1" "StatefulSet";
        mkDaemonSet = mkWorkloadImport "apps/v1" "DaemonSet";
        mkJob = mkWorkloadImport "batch/v1" "Job";
        mkCronJob = mkWorkloadImport "batch/v1" "CronJob";
        mkServiceRef = mkServiceRefImport;
        mkSecretRef = mkSecretRefImport;
        inherit rbac;
      };
    in
    scope;

  # Validate `extraDeps` on every declared instance, active or inactive, before
  # evaluating instances. Reject non-empty `extraDeps` on managed instances,
  # entries that are neither resources nor `ref` pointers, self-references, and
  # references to undeclared instances. Target activation is checked when the
  # import marker is built.
  checkExtraDeps =
    { instances, mergedInstances }:
    let
      describe =
        v:
        if builtins.isAttrs v then
          "an attribute set with keys ${builtins.concatStringsSep ", " (builtins.attrNames v)}"
        else
          builtins.typeOf v;

      checkEntry =
        nsName: instName: entry:
        let
          instance = "${nsName}/${instName}";
        in
        if builtins.isAttrs entry && (entry._type or "") == "kix-ref" then
          let
            refText = "ref.${entry.namespace}.${entry.instanceName}";
          in
          if entry.namespace == nsName && entry.instanceName == instName then
            fail {
              inherit instance;
              message = "extraDeps names ${refText}, the import itself. An import cannot depend on itself.";
              fix = "Remove ${refText} from instances.${nsName}.${instName}.extraDeps.";
            }
          else if !((mergedInstances.${entry.namespace} or { }) ? ${entry.instanceName}) then
            fail {
              inherit instance;
              message = "extraDeps lists ${refText}, which is not a declared instance. '${entry.instanceName}' is in availablePackages, and a ref pointer in extraDeps does not create it automatically.";
              fix =
                "Declare the instance in your cluster definition:"
                + "\n  instances.${entry.namespace}.${entry.instanceName}.package = packages.<package>;";
            }
          else
            null
        else if builtins.isAttrs entry && (entry._type or "") == "k8s-resource" then
          null
        else
          fail {
            inherit instance;
            message = "extraDeps contains ${describe entry}, which is neither a resource nor a ref.<namespace>.<instance> pointer.";
            fix = "Pass only resources or ref.<namespace>.<instance> pointers in instances.${nsName}.${instName}.extraDeps.";
          };

      checkInstance =
        nsName: instName: instCfg:
        let
          entries = instCfg.extraDeps or [ ];
        in
        if entries == [ ] then
          null
        else if (instCfg.package._type or "") != "kix-import" then
          fail {
            instance = "${nsName}/${instName}";
            message = "extraDeps is set, and this instance is not a kix.mkImport. Instance-level extraDeps orders only kix.mkImport instances.";
            fix = "Remove instances.${nsName}.${instName}.extraDeps, and set `requires` or `extraDeps` on the `scope.mk*` resource builder call in the package instead.";
          }
        else
          builtins.foldl' (acc: e: builtins.seq (checkEntry nsName instName e) acc) null entries;
    in
    lib.foldlAttrs (
      acc: nsName: nsInsts:
      lib.foldlAttrs (
        acc: instName: instCfg:
        builtins.seq (checkInstance nsName instName instCfg) acc
      ) acc nsInsts
    ) null instances;

  evaluateImportInstance =
    {
      instanceName,
      namespaceName,
      instCfg,
      namespaceResource,
      clusterLabels,
      clusterConfig ? { },
      clusterCtx ? { },
      # Evaluated cluster instances and their activation predicate, used by
      # `extraDeps` to read `root` from referenced instances.
      allInstances,
      isInstanceActive,
      ...
    }:
    let
      importDef = instCfg.package;

      derived =
        if importDef.from != null then
          let
            importScope = mkImportScope {
              inherit (clusterConfig) clusterDomain;
              inherit
                instanceName
                namespaceName
                namespaceResource
                clusterLabels
                ;
            };

            depArgNames = builtins.attrNames (
              removeAttrs (packageLib.argsOf importDef.from) packageLib.systemArgNames
            );
            mkDepProxy =
              depName:
              fail {
                instance = "${namespaceName}/${instanceName}";
                message = "kix.mkImport { from = ...; } tried to read dependency '${depName}' while deriving 'out' from the package. Imports represent external services and do not resolve package dependencies.";
                fix =
                  "Set the output fields that depend on '${depName}' directly in instances.${namespaceName}.${instanceName}.package:"
                  + "\n  kix.mkImport { from = ...; out = { <field> = \"...\"; }; }"
                  + "\nIf you know all output fields, omit 'from' and write `kix.mkImport { out = { ... }; }`.";
              };
            nullDeps = builtins.listToAttrs (
              map (name: {
                inherit name;
                value = mkDepProxy name;
              }) depArgNames
            );
            # Pass `availability = "none"` so availability-mapped option
            # defaults evaluate cleanly when building the import's `out`.
            raw = packageLib.call {
              package = importDef.from;
              scope = importScope;
              kix = kixlib;
              availability = "none";
              extraArgs = nullDeps;
            };

            evaluatedConfig = evaluateInstanceConfig {
              packageOptions = raw.options or { };
              packageConfig = raw.config or { };
              packageConfigFile = "package config of ${namespaceName}/${instanceName}";
              inherit
                instCfg
                clusterConfig
                namespaceName
                instanceName
                ;
            };

            # Evaluate build entries with the import scope, `availability = "none"`,
            # empty `deps`, and throwing proxies for named dependencies. Part
            # overlays do not apply to imports.
            buildDepProxies = lib.mapAttrs (name: _: mkDepProxy name) (discoverBuildDeps raw.build);
            callBuildFn =
              self: fn:
              let
                args = builtins.functionArgs fn;
              in
              fn (
                {
                  inherit self clusterConfig;
                  config = evaluatedConfig;
                }
                // lib.optionalAttrs (args ? scope) { scope = importScope; }
                // lib.optionalAttrs (args ? lib) { inherit lib; }
                // lib.optionalAttrs (args ? kix) { kix = kixlib; }
                // lib.optionalAttrs (args ? deps) { deps = { }; }
                // lib.optionalAttrs (args ? availability) { availability = "none"; }
                // lib.intersectAttrs args buildDepProxies
              );
            parts = lib.fix (
              self:
              builtins.foldl' (
                acc: fn:
                helpers.mergeCollide
                  "Import instance '${instanceName}': two build entries define the same part. Duplicated part"
                  acc
                  (callBuildFn self fn)
              ) { } (buildEntriesOf raw.build)
            );

            rawRoot =
              parts.root or (fail "Import instance '${instanceName}': package build must define 'root'");
            rootRes =
              if rawRoot ? resource then
                rawRoot.resource
              else if rawRoot ? _type then
                rawRoot
              else
                fail "Import instance '${instanceName}': root must be a resource or { resource, requires }";
          in
          {
            out = (rootRes.out or { }) // importDef.out;
            hints =
              lib.optionalAttrs (rootRes.kind or "" != "") {
                kind = rootRes.kind;
              }
              // lib.optionalAttrs (rootRes.apiVersion or "" != "") {
                apiVersion = rootRes.apiVersion;
              }
              // lib.optionalAttrs (importDef.kind != null) {
                kind = importDef.kind;
              }
              // lib.optionalAttrs (importDef.apiVersion != null) {
                apiVersion = importDef.apiVersion;
              };
          }
        else
          {
            out = importDef.out;
            hints =
              lib.optionalAttrs (importDef.kind != null) {
                kind = importDef.kind;
              }
              // lib.optionalAttrs (importDef.apiVersion != null) {
                apiVersion = importDef.apiVersion;
              };
          };

      crdHandleArgs = [
        "group"
        "kind"
        "plural"
        "version"
        "servedVersions"
        "crdScope"
        "factBehavior"
        "readiness"
        "usesAtLeast"
        "holdsData"
      ];
      who = "Import instance '${namespaceName}/${instanceName}'";
      checkCrdEntry =
        entry:
        let
          unknown = builtins.attrNames (removeAttrs entry crdHandleArgs);
          missing = builtins.filter (k: !(entry ? ${k})) [
            "group"
            "kind"
            "plural"
          ];
        in
        if !builtins.isAttrs entry then
          fail "${who}: each mkImport crds entry is an attribute set of scope.mkCRDRef arguments; got ${builtins.typeOf entry}."
        else if missing != [ ] then
          fail {
            message = "${who}: a mkImport crds entry is missing ${builtins.concatStringsSep ", " missing}.";
            fix = "Give group, kind, plural, and version as the CustomResourceDefinition declares them.";
          }
        else if unknown != [ ] then
          fail {
            message = "${who}: mkImport crds entry ${entry.group}/${entry.kind} has unknown keys ${builtins.concatStringsSep ", " unknown}. The environment installs an import's CRDs, so installedBy does not apply.";
            fix = "Use only these keys: ${builtins.concatStringsSep ", " crdHandleArgs}.";
          }
        else
          entry;
      mkCrdHandle = k8s.mkCRDRefHandle {
        mkResource =
          args:
          mkResource (
            args
            // {
              namespace = namespaceResource;
              labels = clusterLabels // {
                "app.kubernetes.io/instance" = instanceName;
                "app.kubernetes.io/managed-by" = "kix";
              };
            }
          );
        inherit instanceName namespaceName;
        site = "mkImport crds";
      };

      crdEntries =
        let
          entries =
            if builtins.isList importDef.crds then
              map checkCrdEntry importDef.crds
            else
              fail "${who}: mkImport crds is a list of scope.mkCRDRef argument sets; got ${builtins.typeOf importDef.crds}.";
          kinds = map (e: e.kind) entries;
          repeated = lib.unique (builtins.filter (k: lib.count (x: x == k) kinds > 1) kinds);
        in
        if repeated == [ ] then
          entries
        else
          fail {
            message = "${who}: mkImport crds declares ${builtins.concatStringsSep ", " repeated} more than once. out.crds holds one handle per kind.";
            fix = "Keep one entry for each kind.";
          };
      crdHandleList = map (entry: {
        inherit (entry) kind;
        handle = mkCrdHandle entry;
      }) crdEntries;
      crdHandles = builtins.foldl' (
        acc: h:
        helpers.mergeCollide
          "${who}: mkImport crds declares a kind the package's out.crds already has. Kind"
          acc
          { ${h.kind} = h.handle; }
      ) (derived.out.crds or { }) crdHandleList;

      isRef = v: builtins.isAttrs v && (v._type or "") == "kix-ref";
      isPlainAttrs = v: builtins.isAttrs v && !(v ? _type);

      # Return the instance a `ref` in `out` names. An import has no
      # dependency resolution, so `ref` is how its `out` carries another
      # instance, such as the Secret that holds a login. A ref does not
      # activate an optional target.
      resolveOutRef =
        path: entry:
        let
          refText = "ref.${entry.namespace}.${entry.instanceName}";
        in
        if entry.namespace == namespaceName && entry.instanceName == instanceName then
          fail {
            message = "${who}: out.${path} names ${refText}, the import itself.";
            fix = "Point out.${path} at another instance, or remove it.";
          }
        else if isInstanceActive entry.namespace entry.instanceName then
          allInstances.${entry.namespace}.${entry.instanceName}
        else
          fail {
            message = "${who}: out.${path} names ${refText}, which is not an active instance. A ref in out does not activate an optional instance.";
            fix = "Declare it under instances.${entry.namespace}.${entry.instanceName}, or set optional = false on it.";
          };

      # Replace each ref in `out`, at any depth of plain attribute sets.
      resolveOutRefs =
        path: v:
        if isRef v then
          resolveOutRef path v
        else if isPlainAttrs v then
          lib.mapAttrs (k: resolveOutRefs (if path == "" then k else "${path}.${k}")) v
        else
          v;

      # Collect the refs the cluster definition wrote in `out`, so the
      # import's marker waits for each target at deploy time.
      outRefTargets =
        let
          collect =
            path: v:
            if isRef v then
              [ (resolveOutRef path v).root ]
            else if isPlainAttrs v then
              lib.concatLists (lib.mapAttrsToList (k: collect (if path == "" then k else "${path}.${k}")) v)
            else
              [ ];
        in
        collect "" importDef.out;

      out = resolveOutRefs "" (
        derived.out // lib.optionalAttrs (crdEntries != [ ]) { crds = crdHandles; }
      );

      networkConfig = clusterConfig.networkPolicy or { enable = false; };
      rawPlatformIntents = instCfg.platformIntents or { };

      # Materialize platform network-policy intents here so they can be attached
      # to `markerResource.extraDeps` when the marker is sealed, before
      # `instanceProcessors` run.
      intentProvider =
        if rawPlatformIntents == { } || !networkConfig.enable || !(clusterCtx ? findRoleProvider) then
          null
        else
          clusterCtx.findRoleProvider "network-policy-enforcer";

      intentProviderOut =
        if
          intentProvider == null
          || (intentProvider.ns == namespaceName && intentProvider.inst == instanceName)
        then
          null
        else
          intentProvider.out;

      materializedIntentPolicies =
        if intentProviderOut == null then
          [ ]
        else
          let
            enforcerApi = intentProviderOut.netpol;
          in
          lib.mapAttrsToList (
            intentName: intent:
            enforcerApi.materializePlatformIntent {
              intent = intent // {
                name = intentName;
              };
              # Mark materialized platform intent policies as Kix-managed
              # because they are sealed outside a package scope.
              mkResource =
                args:
                mkResource (
                  args
                  // {
                    labels = (args.labels or { }) // {
                      "app.kubernetes.io/managed-by" = "kix";
                    };
                  }
                );
              inherit namespaceResource;
              inherit (k8s) clusterScoped;
            }
          ) rawPlatformIntents;

      # Resolve an `extraDeps` entry to a resource. `checkExtraDeps` already
      # validated the entry shape, so a `ref` pointer resolves to the target
      # instance's `root` PackageInstance marker without activating optional
      # targets.
      resolveExtraDep =
        entry:
        if (entry._type or "") == "kix-ref" then
          if isInstanceActive entry.namespace entry.instanceName then
            allInstances.${entry.namespace}.${entry.instanceName}.root
          else
            fail {
              message = "${who}: extraDeps names ref.${entry.namespace}.${entry.instanceName}, an optional instance that is not active. Kix renders no marker for it, so the import's marker would wait for a resource that is never deployed. An extraDeps ref does not activate its target.";
              fix = "Set optional = false on instances.${entry.namespace}.${entry.instanceName}, or remove the entry.";
            }
        else
          entry;

      instanceExtraDeps =
        map resolveExtraDep (instCfg.extraDeps or [ ]) ++ outRefTargets ++ materializedIntentPolicies;

      markerResource = mkResource {
        apiVersion = kixAnnotations.apiVersion;
        kind = "PackageInstance";
        name = instanceName;
        namespace = namespaceResource;
        requires = [ kixCRDs.packageInstance ];
        extraDeps = instanceExtraDeps;
        annotations = {
          ${kixKeys.mode} = "import";
        }
        // lib.optionalAttrs (derived.out ? name) {
          ${kixKeys.importName} = derived.out.name;
        }
        // lib.optionalAttrs (derived.out ? fqdn) {
          ${kixKeys.importFqdn} = derived.out.fqdn;
        }
        // lib.optionalAttrs (derived.hints ? kind) {
          ${kixKeys.importKind} = derived.hints.kind;
        }
        // lib.optionalAttrs (derived.hints ? apiVersion) {
          ${kixKeys.importApiVersion} = derived.hints.apiVersion;
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
      _hookResources = materializedIntentPolicies ++ map (h: h.handle) crdHandleList;
      root = markerResource;
      inherit out;
      _meta = {
        inherit instanceName namespaceName;
        namespace = namespaceName;
        aliases = if (instCfg.aliases or null) == null then [ ] else instCfg.aliases;
        version = meta.instanceVersion {
          inherit instCfg;
          packageOut = out;
          packageMeta = { };
        };
      };
    };
}
