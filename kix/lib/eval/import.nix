{
  lib,
  k8s,
  rbac,
  kixlib,
  helpers,
  evaluateInstanceConfig,
  buildEntriesOf,
  discoverBuildDeps,
  systemArgNames,
}:

let
  # Kix's own annotation keys and API names, spelled once in
  # core/annotations.nix.
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
      # Registry roles this environment-provided service fills (weak symbols;
      # a managed instance with the same role shadows it). The role name is
      # also the import's DI alias, so no instance-level `aliases` are needed.
      roles ? [ ],
      # CustomResourceDefinitions the environment installs, each given as
      # scope.mkCRDRef's arguments without `installedBy`. Each entry becomes
      # `out.crds.<kind>`, a handle consumers pass to scope.mkCR, and a CRD
      # marker the deploy waits for while the import is active.
      crds ? [ ],
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
        inherit roles;
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
          # Import-mode refs have no store resource, so facts are the
          # first channel that lets them participate in edge detection
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

      # Import mode renders no resources, but a package reaches its
      # workloads on the way to the `out` values an import does need:
      # `kix.service.fromWorkload` reads the workload's selector and its
      # container ports, and that is the documented way to write a Service.
      # Without these builders such a package failed on a bare
      # `attribute 'mkStatefulSet' missing` naming its own line
      # (housekeeping 2026-09-20). They seal nothing, patch nothing and emit
      # nothing: what an import promises is the root's `out`, so a workload
      # only has to carry the selector and the ports a Service is built from.
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
            spec.selector.matchLabels or templateMeta.labels
              or (throw "Import instance '${instanceName}': ${kind} '${args.name or "?"}' has no spec.selector.matchLabels and no pod template labels. Use scope.selectorLabels.");
          ref = mkRes namespaceResource (
            {
              inherit apiVersion kind spec;
              name = args.name or (throw "Import instance '${instanceName}': ${kind} needs a name");
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

      scope = {
        inherit instanceName namespaceName selectorLabels;
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

  evaluateImportInstance =
    {
      instanceName,
      namespaceName,
      instCfg,
      namespaceResource,
      clusterLabels,
      clusterConfig ? { },
      clusterCtx ? { },
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

            fnArgs = builtins.functionArgs importDef.from;
            depArgNames = builtins.attrNames (removeAttrs fnArgs systemArgNames);
            mkDepProxy =
              depName:
              builtins.throw "Import instance '${instanceName}': package accessed dependency '${depName}', but imports run without dependency resolution. Either use a raw 'out' override (mkImport { out = { ... }; }) or use a mixed import (mkImport { from = ...; out = { fieldThatNeedsDep = \"value\"; }; }).";
            nullDeps = builtins.listToAttrs (
              map (name: {
                inherit name;
                value = mkDepProxy name;
              }) depArgNames
            );
            raw = importDef.from (
              {
                scope = importScope;
                inherit lib;
              }
              // lib.optionalAttrs (fnArgs ? kix) { kix = kixlib; }
              # An import renders no workloads of its own, so the level it
              # sees only shapes option defaults nobody reads; "none" keeps
              # every mapped default at its floor.
              // lib.optionalAttrs (fnArgs ? availability) { availability = "none"; }
              // nullDeps
            );

            evaluatedConfig = evaluateInstanceConfig {
              packageOptions = raw.options or { };
              unsafeGrants = raw.meta.unsafe or [ ];
              packageConfig = raw.config or { };
              packageConfigFile = "package config of ${namespaceName}/${instanceName}";
              inherit
                instCfg
                clusterConfig
                namespaceName
                instanceName
                ;
            };

            # Build entries run as they do for a managed instance, with the
            # import scope, availability "none", no resolved `deps`, and a
            # throwing proxy for each dependency an entry asks for by name.
            # Part overlays do not apply.
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
              parts.root or (throw "Import instance '${instanceName}': package build must define 'root'");
            rootRes =
              if rawRoot ? resource then
                rawRoot.resource
              else if rawRoot ? _type then
                rawRoot
              else
                throw "Import instance '${instanceName}': root must be a resource or { resource, requires }";
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

      # Markers for the CRDs the import declares, built with the import's
      # namespace and labels.
      crdHandleArgs = [
        "group"
        "kind"
        "plural"
        "version"
        "servedVersions"
        "crdScope"
        "factBehavior"
        "readiness"
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
          throw "${who}: each mkImport crds entry is an attribute set of scope.mkCRDRef arguments; got ${builtins.typeOf entry}."
        else if missing != [ ] then
          throw "${who}: a mkImport crds entry is missing ${builtins.concatStringsSep ", " missing}. Give group, kind, plural and version as the CustomResourceDefinition declares them."
        else if unknown != [ ] then
          throw "${who}: mkImport crds entry ${entry.group}/${entry.kind} has unknown keys ${builtins.concatStringsSep ", " unknown}. Accepted keys: ${builtins.concatStringsSep ", " crdHandleArgs}. The environment installs an import's CRDs, so installedBy does not apply."
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
              throw "${who}: mkImport crds is a list of scope.mkCRDRef argument sets; got ${builtins.typeOf importDef.crds}.";
          kinds = map (e: e.kind) entries;
          repeated = lib.unique (builtins.filter (k: lib.count (x: x == k) kinds > 1) kinds);
        in
        if repeated == [ ] then
          entries
        else
          throw "${who}: mkImport crds declares ${builtins.concatStringsSep ", " repeated} more than once. out.crds holds one handle per kind; keep one entry for each.";
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

      out = derived.out // lib.optionalAttrs (crdEntries != [ ]) { crds = crdHandles; };

      networkConfig = clusterConfig.networkPolicy or { enable = false; };
      rawPlatformIntents = instCfg.platformIntents or { };

      # Fallback materializer intents must be extraDeps on the marker and
      # sealed at mkResource time; instanceProcessors run too late.
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
              # Same as plugins/netpol/derive.nix: platform intents are sealed
              # without a scope, so mark them kix-managed here.
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

      instanceExtraDeps = (instCfg.extraDeps or [ ]) ++ materializedIntentPolicies;

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
        aliases = instCfg.aliases or [ ];
      };
    };
}
