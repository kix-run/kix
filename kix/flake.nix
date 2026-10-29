# Kix framework flake: exports lib.mkFlake and lib.forPkgs.
#
# No nixpkgs dependency: consumers provide their own via inputs.
# This flake is pure framework, with no packages or clusters.

{
  description = "kix — Nix-based Kubernetes framework";

  outputs =
    { self }:
    {
      lib = {
        # Generate a complete flake from a minimal cluster spec.
        # See kix/lib/mkFlake.nix for full documentation.
        mkFlake = import ./lib/mkFlake.nix;

        # Build the Kix library and package set for an explicit `pkgs` and `lib`.
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
