{
  lib,
  k8s,
  rbac,
  kixlib,
  evaluateInstanceConfig,
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
      # also the import's DI alias — no instance-level `aliases` needed.
      roles ? [ ],
    }:
    {
      _type = "kix-import";
      inherit
        from
        out
        kind
        apiVersion
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
      clusterDomain ? "cluster.local",
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
          # import-mode refs have no store resource at all — facts are the
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

      scope = {
        inherit instanceName namespaceName selectorLabels;
        labelStyle = "kix";
        namespace = namespaceResource;
        mkResource = mkRes namespaceResource;
        mkClusterResource = mkRes clusterScoped;
        mkCR = _crd: args: scope.mkResource args;
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
              clusterDomain = clusterConfig.clusterDomain or "cluster.local";
              inherit
                instanceName
                namespaceName
                namespaceResource
                clusterLabels
                ;
            };

            fnArgs = builtins.functionArgs importDef.from;
            depArgNames = builtins.attrNames (
              removeAttrs fnArgs [
                "scope"
                "lib"
                "kix"
                "availability"
              ]
            );
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
              inherit instCfg clusterConfig;
            };

            buildEntries =
              if builtins.isList raw.build then
                map (entry: if builtins.isPath entry then import entry else entry) raw.build
              else
                [ raw.build ];
            allBuildArgs = builtins.foldl' (acc: fn: acc // builtins.functionArgs fn) { } buildEntries;
            depArgNames' = builtins.attrNames (
              removeAttrs allBuildArgs [
                "self"
                "config"
                "clusterConfig"
                "scope"
                "lib"
                "kix"
                "deps"
              ]
            );
            nullBuildDeps = builtins.listToAttrs (
              map (name: {
                inherit name;
                value = mkDepProxy name;
              }) depArgNames'
            );
            parts = lib.fix (
              self:
              raw.build (
                {
                  inherit self clusterConfig;
                  config = evaluatedConfig;
                }
                // nullBuildDeps
              )
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

      networkConfig = clusterConfig.networkPolicy or { enable = false; };
      rawPlatformIntents = instCfg.platformIntents or { };

      # Fallback materializer path (v2_discussions/121): intents must be extraDeps on the marker, sealed at mkResource time — instanceProcessors run too late.
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
      _hookResources = materializedIntentPolicies;
      root = markerResource;
      out = derived.out;
      _meta = {
        inherit instanceName namespaceName;
        namespace = namespaceName;
        aliases = instCfg.aliases or [ ];
      };
    };
}
