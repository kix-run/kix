# Tests for what `kix.healthCheck` does with its `requires` list.
# Loaded by ../default.nix with the other files in this directory.

{
  lib,
  kixlib,
  mkCluster,
  manifests,
  ofKind,
  ...
}:

let
  configMap =
    scope: name:
    scope.mkResource {
      apiVersion = "v1";
      kind = "ConfigMap";
      inherit name;
      data.key = name;
    };

  package = {
    meta.version = "test";
    build = [
      (
        { self, scope, ... }:
        {
          settings = configMap scope "settings";
          extra = configMap scope "extra";
          root = self.settings;
        }
      )
      (kixlib.healthCheck {
        script = "print('ok')";
        requires =
          { self, ... }:
          [
            self.extra
            "not a resource"
          ];
      })
    ];
  };

  job = builtins.head (
    builtins.filter (m: m.metadata.name == "app-health") (
      ofKind "Job" (
        manifests (mkCluster [
          {
            namespaces.x = { };
            instances.x.app.package = package;
          }
        ])
      )
    )
  );
in
{
  # A `requires` entry that is not a resource is skipped, as `mkResource`
  # skips it. A required resource's checksum annotation is named after its
  # kind and name.
  lib-health-check-requires-names-checksums =
    let
      annotations = job.spec.template.metadata.annotations;
    in
    (
      annotations ? "checksum/configmap-extra"
      && annotations ? "checksum/root"
      && !(lib.any (lib.hasPrefix "checksum/requires-") (builtins.attrNames annotations))
    )
    || throw "health check annotations: ${builtins.toJSON annotations}";
}
