{ lib }:

import ./resource.nix { inherit lib; } // import ./activation.nix { inherit lib; }
