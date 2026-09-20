# Shared helper namespace for cluster definitions, package evaluation, and tests.
# Import this module to include composition, availability, and pin helpers.
{ lib }:
let
  compose = import ./compose.nix { inherit lib; };
  availability = import ../core/availability.nix { inherit lib; };
in
compose
// {
  # Map availability levels to package replica counts and quorums:
  # kix.availability.pick level { none = 1; pod = 2; node = 2; zone = 3; }
  # kix.availability.atLeast "node" level
  availability = {
    inherit (availability)
      levels
      pick
      atLeast
      rank
      ;
  };
  pins = import ./pins.nix {
    inherit lib;
    inherit (compose) image;
  };
}
