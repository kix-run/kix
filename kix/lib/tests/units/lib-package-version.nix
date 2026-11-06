# Tests for the `spec.version` of the PackageInstance record: it is omitted
# when the package has no version, comes from `out.version` when the
# package reports one, and `meta.version` and the instance's `version` take
# precedence over it.
# Loaded by ../default.nix with the other files in this directory.

{
  lib,
  mkCluster,
  manifests,
  ofKind,
  ...
}:

let
  # A ConfigMap package. `meta.version` and `out.version` are set only when
  # given, so the record sees the same shapes real packages produce.
  mkPackage =
    {
      metaVersion ? null,
      outVersion ? null,
    }:
    {
      meta = {
        description = "version fixture";
        owner = "test";
      }
      // lib.optionalAttrs (metaVersion != null) { version = metaVersion; };
      build =
        { self, scope, ... }:
        {
          cm = scope.mkResource {
            apiVersion = "v1";
            kind = "ConfigMap";
            name = "cm";
          };
          root = {
            resource = self.cm;
          }
          // lib.optionalAttrs (outVersion != null) { out.version = outVersion; };
        };
    };

  recordOf =
    instance:
    builtins.head (
      ofKind "PackageInstance" (
        manifests (mkCluster [
          {
            namespaces.x = { };
            instances.x.app = instance;
          }
        ])
      )
    );

  specOf = instance: (recordOf instance).spec;
in
{
  lib-package-version-omitted-without-version =
    let
      spec = specOf { package = mkPackage { }; };
    in
    !(spec ? version) || throw "spec carries a version: ${builtins.toJSON spec}";

  lib-package-version-from-out =
    let
      spec = specOf { package = mkPackage { outVersion = "17"; }; };
    in
    (spec.version or null) == "17" || throw "spec: ${builtins.toJSON spec}";

  lib-package-version-meta-over-out =
    let
      spec = specOf {
        package = mkPackage {
          metaVersion = "1.2.3";
          outVersion = "17";
        };
      };
    in
    (spec.version or null) == "1.2.3" || throw "spec: ${builtins.toJSON spec}";

  lib-package-version-instance-over-out =
    let
      spec = specOf {
        package = mkPackage { outVersion = "17"; };
        version = "pinned";
      };
    in
    (spec.version or null) == "pinned" || throw "spec: ${builtins.toJSON spec}";
}
