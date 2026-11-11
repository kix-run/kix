# Build the package set a cluster definition receives as `packages`.
#
# `stable/` holds packages that break only in a minor release.
# `experimental/` holds packages that may break in any release. A cluster
# reaches them as `packages.<name>` and `packages.experimental.<name>`.
{ lib }:
let
  levels = import ../lib/core/levels.nix { inherit lib; };
in
levels.merge ({ prefix = "packages"; } // import ./by-level.nix { inherit lib; })
