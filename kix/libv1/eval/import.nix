# Import system — lightweight import markers and import-mode evaluation.

{
  lib,
  k8s,
  rbac,
  kixlib,
  evaluateInstanceConfig,
}:

let
  inherit (k8s)
    clusterScoped
    mkResource
    mkImportResource
    kixCRDs
    ;
in

rec {
  # Create an import marker — used as the `package` field for imported instances.
  # `from`: optional package function to derive out from (via lazy eval).
  # `out`: manual out overrides, merged on top of derived values.
  mkImport =
    {
      from ? null,
      out ? { },
      kind ? null,
      apiVersion ? null,
    }:
    {
      _type = "kix-import";
      inherit
        from
        out
        kind
        apiVersion
        ;
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

      # Import-mode mirrors of scope.mkServiceRef / scope.mkSecretRef. The
      # real versions (kix/lib/eval/scope.nix:1332, 1437) emit a
      # PackageInstance marker and attach its store-path context to each
      # `out` field so consumers pick up the dep edge automatically. In
      # import mode we don't emit markers (the import's own PackageInstance
      # — created by evaluateImportInstance — is the deploy-graph edge);
      # we only need the derived `out` shape so the imported package's
      # build can compute its own root.out. Context-attach is therefore
      # identity.
      mkServiceRefImport =
        {
          name,
          selector,
          ports,
          requires ? [ ],
        }:
        {
          out = {
            inherit selector ports;
            inherit name;
            fqdn = "${name}.${namespaceName}.svc";
            port = toString (builtins.head ports).port;
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
        # In import mode, mkCR ignores the CRD argument (which would come
        # from a dep proxy that throws) and delegates to mkResource.
        # Only out values matter; dependency tracking is irrelevant for imports.
        mkCR = _crd: args: scope.mkResource args;
        mkServiceRef = mkServiceRefImport;
        mkSecretRef = mkSecretRefImport;
        inherit rbac;
      };
    in
    scope;

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
      # Lazy handle to the network-policy enforcer's `out`. Used to
      # materialize platformIntents declared on the import instance.
      networkPolicyEnforcer ? null,
      ...
    }:
    let
      importDef = instCfg.package; # { _type = "kix-import"; from, out }

      # Derive out: from package build (lazy) + manual overrides
      derived =
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

            # Call the package function with proxy deps that throw clear errors.
            # Laziness ensures only out-relevant code paths are forced;
            # if the package tries to access a dep, the proxy explains why it fails.
            fnArgs = builtins.functionArgs importDef.from;
            depArgNames = builtins.attrNames (
              removeAttrs fnArgs [
                "scope"
                "lib"
                "kix"
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
              // nullDeps
            );

            # Evaluate typed config (same as normal path)
            evaluatedConfig = evaluateInstanceConfig {
              packageOptions = raw.options or { };
              inherit instCfg clusterConfig;
            };

            # Run fixpoint — only out will be forced.
            # Proxy deps: imports run in isolation, deps aren't resolved.
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

            # Extract root's out
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

      # --- Platform intent materialization ---
      #
      # When the import declares `platformIntents` and a network-policy
      # enforcer is available, materialize each intent into a CNP/CCNP
      # resource and inject them as extraDeps on the marker. This
      # establishes: workload → import marker → CNPs → enforcer.
      networkConfig = clusterConfig.networkPolicy or { enable = false; };
      rawPlatformIntents = instCfg.platformIntents or { };

      materializedIntentPolicies =
        if rawPlatformIntents == { } || !networkConfig.enable || networkPolicyEnforcer == null then
          [ ]
        else
          let
            enforcerApi = networkPolicyEnforcer.netpol;
          in
          lib.mapAttrsToList (
            intentName: intent:
            let
              isClusterwide = (intent.scope or "namespaced") == "clusterwide";
            in
            enforcerApi.materializePlatformIntent {
              intent = intent // {
                name = intentName;
              };
              inherit mkResource namespaceResource;
              inherit (k8s) clusterScoped;
            }
          ) rawPlatformIntents;

      # Marker PackageInstance — deployed to mark this import in the cluster.
      # Carries import metadata so deploy tooling can verify the external resource.
      # Instance-level extraDeps (from modules.nix) inject ordering edges
      # that aren't captured by store-path context. Materialized platform
      # intent CNPs are also injected so the marker transitively depends
      # on the enforcer.
      instanceExtraDeps = (instCfg.extraDeps or [ ]) ++ materializedIntentPolicies;

      markerResource = mkResource {
        apiVersion = "kix.dev/v1alpha1";
        kind = "PackageInstance";
        name = instanceName;
        namespace = namespaceResource;
        requires = [ kixCRDs.packageInstance ];
        extraDeps = instanceExtraDeps;
        annotations = {
          "kix.dev/mode" = "import";
        }
        // lib.optionalAttrs (derived.out ? name) {
          "kix.dev/import-name" = derived.out.name;
        }
        // lib.optionalAttrs (derived.out ? fqdn) {
          "kix.dev/import-fqdn" = derived.out.fqdn;
        }
        // lib.optionalAttrs (derived.hints ? kind) {
          "kix.dev/import-kind" = derived.hints.kind;
        }
        // lib.optionalAttrs (derived.hints ? apiVersion) {
          "kix.dev/import-apiversion" = derived.hints.apiVersion;
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
      _networkPolicies = materializedIntentPolicies;
      root = markerResource;
      out = derived.out;
      _meta = {
        inherit instanceName namespaceName;
        namespace = namespaceName;
        aliases = instCfg.aliases or [ ];
      };
    };
}
