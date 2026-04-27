# Nix flake integration for the kix CLI binary.
#
# This file shows how to add `packages.kix` and `apps.kix` outputs
# to the kixpkgs flake. It uses Crane for building.
#
# To integrate, add the inputs and merge the perSystem outputs into
# the existing flake.nix.
#
# Prerequisites:
#   - Nix >= 2.28.0 with flakes enabled
#   - Cargo.lock up to date
#
# Usage:
#   nix build .#kix
#   nix run .#kix -- build nw1
#   nix profile install .#kix

{
  # --- Inputs to add to flake.nix ---
  #
  # inputs.crane = {
  #   url = "github:ipetkov/crane";
  #   inputs.nixpkgs.follows = "nixpkgs";
  # };

  # --- perSystem output (inside flake-parts perSystem module) ---
  #
  # { system, pkgs, lib, self', inputs', ... }:

  mkKixPackage =
    {
      pkgs,
      lib,
      crane,
      ...
    }:
    let
      craneLib = crane.mkLib pkgs;

      commonArgs = {
        src = craneLib.cleanCargoSource ../cli;
        strictDeps = true;

        buildInputs = [ pkgs.openssl ] ++ lib.optionals pkgs.stdenv.isLinux [ pkgs.dbus ];

        nativeBuildInputs = [ pkgs.pkg-config ];
      };

      # Build dependencies separately for caching
      cargoArtifacts = craneLib.buildDepsOnly commonArgs;

      # Build the kix binary
      kix = craneLib.buildPackage (
        commonArgs
        // {
          inherit cargoArtifacts;

          # Integration tests require a writable nix store (eval cache),
          # which is unavailable inside the nix build sandbox.
          doCheck = false;

          meta = {
            description = "Kubernetes manifest generator CLI";
            homepage = "https://github.com/kixpkgs/kixpkgs";
            license = lib.licenses.mit;
            mainProgram = "kix";
          };
        }
      );
    in
    kix;

  # --- Outputs to merge into perSystem ---
  #
  # packages.kix = mkKixPackage { inherit pkgs lib; crane = inputs'.crane; nix-src = inputs'.nix-src; };
  #
  # apps.kix = {
  #   type = "app";
  #   program = "${self'.packages.kix}/bin/kix";
  # };
  #
  # # Optional: add kix to devShells.default for development
  # devShells.default = pkgs.mkShell {
  #   inputsFrom = [ self'.packages.kix ];
  #   packages = [ pkgs.cargo pkgs.rustc pkgs.rust-analyzer pkgs.clippy ];
  # };

  # --- Cachix binary cache (add to flake.nix) ---
  #
  # nixConfig = {
  #   extra-substituters = [ "https://kixpkgs.cachix.org" ];
  #   extra-trusted-public-keys = [ "kixpkgs.cachix.org-1:XXXX" ];
  # };
}
