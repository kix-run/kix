# Build the package set a cluster definition receives as `packages`.
#
# `stable/` holds packages that break only in a minor release.
# `experimental/` holds packages that may break in any release. A cluster
# reaches them as `packages.<name>` and `packages.experimental.<name>`.
{ lib }:
let
  levels = import ../lib/core/levels.nix { inherit lib; };
  wasStable = import ./was-stable.nix;
  byLevel = import ./by-level.nix { inherit lib; };
in
levels.merge (
  {
    prefix = "packages";
    # The old name of a package that moved to experimental is a marker
    # rather than a throw, so that `availablePackages = packages` skips it.
    # It has no `package` key, which would make the registry take it.
    # An instance whose `package` is the marker fails with the message, and
    # a dependency that only the marked package would answer from
    # `availablePackages` fails with advice to add it.
    demoted = name: message: {
      _type = "kix-moved";
      inherit name message;
      experimentalPackage = byLevel.experimental.${name};
    };
    demotedNames = wasStable.names;
    demotedId = wasStable.id;
  }
  // {
    inherit (byLevel) stable experimental;
  }
)
