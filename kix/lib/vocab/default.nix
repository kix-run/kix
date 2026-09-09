# The cluster and package vocabulary, assembled.
#
# `compose.nix` composes Kubernetes objects in memory. `pins.nix` reads a
# committed record off disk. They are separate files for that reason and one
# namespace here, so every caller sees the same `kixlib` and no caller has to
# know which file a name came from.
#
# Assembled here rather than in `../default.nix` because three places import
# the vocabulary (`../default.nix`, `../eval/default.nix` and the tests) and
# an assembly written out in each of them drifts. It already did: `pins`
# moved out of `compose.nix` and the tests kept importing the file rather
# than the namespace.
{ lib }:
let
  compose = import ./compose.nix { inherit lib; };
in
compose
// {
  pins = import ./pins.nix {
    inherit lib;
    inherit (compose) image;
  };
}
