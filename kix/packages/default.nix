# Build the package set a cluster definition receives as `packages`.
#
# `stable/` holds packages that break only in a minor release.
# `experimental/` holds packages that may break in any release. A cluster
# reaches them as `packages.<name>` and `packages.experimental.<name>`.
# A package listed in `removed.toml` fails under both names.
{ lib }:
let
  levels = import ../lib/core/levels.nix { inherit lib; };
  wasStable = import ./was-stable.nix;
  removed = lib.mapAttrs' (
    key: error:
    assert lib.assertMsg (lib.hasPrefix "experimental/" key)
      "kix/packages/removed.toml: ${key} must start with experimental/. A stable package's old name is not supported.";
    lib.nameValuePair (lib.removePrefix "experimental/" key) error
  ) (builtins.fromTOML (builtins.readFile ./removed.toml));
  inherit (import ../lib/core/error.nix { inherit lib; }) fail;
  byLevel = import ./by-level.nix { inherit lib; };

  merged = levels.merge (
    {
      prefix = "packages";
      # The old name of a package that moved to experimental is a marker
      # rather than a throw, so that `availablePackages = packages` skips it.
      # It has no `package` key, which would make the registry take it.
      # An instance whose `package` is the marker fails with the message, and
      # a dependency that only the marked package would answer from
      # `availablePackages` fails with advice to add it.
      demoted = name: error: {
        _type = "kix-moved";
        inherit name error;
        spelled = "packages.${name}";
        experimentalPackage = byLevel.experimental.${name};
      };
      demotedNames = wasStable.names;
      demotedId = wasStable.id;
    }
    // {
      inherit (byLevel) stable experimental;
    }
  );

  # `packages.stable.<name>` for an experimental package is the same kind of
  # marker, so an instance that names it fails with the right spelling.
  # The name of a removed package at the top is a marker rather than a
  # throw, so that `availablePackages = packages` skips it. An instance whose
  # `package` is the marker fails with the entry's error.
  removedMarkers = lib.mapAttrs (name: error: {
    _type = "kix-removed";
    inherit name error;
  }) removed;

  misplaced = lib.mapAttrs (name: package: {
    _type = "kix-moved";
    inherit name;
    error.message = "`packages.stable.${name}` does not exist, because ${name} is an experimental package. Write `packages.experimental.${name}`.";
    spelled = "packages.stable.${name}";
    experimentalPackage = package;
  }) (removeAttrs byLevel.experimental (builtins.attrNames byLevel.stable));
in
removedMarkers
// merged
// {
  stable = misplaced // merged.stable;
  # An attribute is evaluated only when a cluster names it, so the error
  # shows only then.
  experimental = lib.mapAttrs (_: fail) removed // merged.experimental;
}
