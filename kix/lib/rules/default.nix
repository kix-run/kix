# Built-in scorecard rule library.
#
# Usage in cluster definitions:
#   rules = kix.rules;                    # all rules
#   rules = { security = kix.rules.security; };  # selective

{ lib }:

{
  security = import ./security.nix { inherit lib; };
  reliability = import ./reliability.nix { inherit lib; };
  governance = import ./governance.nix { inherit lib; };
  architecture = import ./architecture.nix { inherit lib; };
}
