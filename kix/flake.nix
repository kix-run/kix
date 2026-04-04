# kix framework flake — exports lib.mkFlake and lib.forPkgs.
#
# No nixpkgs dependency: consumers provide their own via inputs.
# This flake is pure framework — no packages or clusters.

{
  description = "kix — Nix-based Kubernetes framework";

  outputs =
    { self }:
    {
      lib = {
        # Generate a complete flake from a minimal cluster spec.
        # See kix/lib/mkFlake.nix for full documentation.
        mkFlake = import ./lib/mkFlake.nix;

        # Direct API for external flake consumers who manage their own flake.nix.
        forPkgs =
          { pkgs, lib }:
          let
            kix = import ./lib { inherit pkgs lib; };
            entries = builtins.readDir ./packages;
            dirs = lib.filterAttrs (_: type: type == "directory") entries;
            packages = lib.mapAttrs (name: _: import ./packages/${name}) dirs;
          in
          {
            inherit kix packages;
            inherit (kix) mkManifests;
          };
      };
    };
}
