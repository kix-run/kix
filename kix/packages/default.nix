# Build the package set a cluster definition receives as `packages`.
#
# `stable/` holds packages that break only in a minor release.
# `experimental/` holds packages that may break in any release. A cluster
# reaches them as `packages.<name>` and `packages.experimental.<name>`.
{ lib }:
let
  levels = import ../lib/core/levels.nix { inherit lib; };
  wasStable = import ./was-stable.nix;
in
levels.merge (
  {
    prefix = "packages";
    # The old name of a package that moved to experimental is a marker
    # rather than a throw, so that `availablePackages = packages` skips it.
    # An instance whose `package` is the marker fails with the message.
    demoted = message: {
      _type = "kix-moved";
      inherit message;
    };
    demotedNames = wasStable.names;
    demotedId = wasStable.id;
  }
  // {
    inherit (import ./by-level.nix { inherit lib; }) stable experimental;
  }
)
