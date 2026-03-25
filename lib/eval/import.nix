# Import system — lightweight import markers and import-mode evaluation.

{
  lib,
  k8s,
  rbac,
  kixlib,
  evaluateInstanceConfig,
}:

let
  inherit (k8s) clusterScoped mkResource mkImportResource;
in

rec {
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
}
