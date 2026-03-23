# Nix flake integration for the kix CLI binary.
#
# This file shows how to add `packages.kix` and `apps.kix` outputs
# to the kixpkgs flake. It uses Crane for building and links against
# Nix C libraries for FFI evaluation.
#
# To integrate, add the inputs and merge the perSystem outputs into
# the existing flake.nix.
#
# Prerequisites:
#   - Nix >= 2.28.0 with flakes enabled
#   - nix-bindings-rust crates (from github:cachix/nix-bindings-rust, branch for-upstream)
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
  #
  # inputs.nix-src = {
  #   url = "github:NixOS/nix/2.28.0";
  # };
  #
  # inputs.nix-bindings-rust = {
  #   url = "github:cachix/nix-bindings-rust/for-upstream";
  #   inputs.nix.follows = "nix-src";
  # };

  # --- perSystem output (inside flake-parts perSystem module) ---
  #
  # { system, pkgs, lib, self', inputs', ... }:

  mkKixPackage =
    {
      pkgs,
      lib,
      crane,
      nix-src,
      ...
    }:
    let
      craneLib = crane.mkLib pkgs;

      # Nix C libraries needed for FFI
      nixPkg = nix-src.packages.${pkgs.system}.default;
      nixLibs = [
        nixPkg.libs.nix-expr-c
        nixPkg.libs.nix-store-c
        nixPkg.libs.nix-util-c
        nixPkg.libs.nix-flake-c
        nixPkg.libs.nix-fetchers-c
      ];

      # pkg-config names that nix-bindings-*-sys crates look for:
      #   nix-util-c, nix-store-c, nix-expr-c, nix-flake-c, nix-fetchers-c, bdw-gc
      #
      # bindgenHook sets LIBCLANG_PATH for generating Rust bindings from C headers.

      commonArgs = {
        src = craneLib.cleanCargoSource ../cli;
        strictDeps = true;

        buildInputs =
          nixLibs
          ++ [
            pkgs.boehmgc
            pkgs.openssl
          ]
          ++ lib.optionals pkgs.stdenv.isLinux [ pkgs.dbus ]
          ++ lib.optionals pkgs.stdenv.isDarwin [
            pkgs.darwin.apple_sdk.frameworks.Security
            pkgs.darwin.apple_sdk.frameworks.SystemConfiguration
          ];

        nativeBuildInputs = [
          pkgs.pkg-config
          pkgs.rustPlatform.bindgenHook
        ];

        # Enable the nix-ffi feature for real FFI evaluation
        cargoExtraArgs = "--features nix-ffi";

        # Ensure Nix C libraries are found at runtime
        postFixup = ''
          patchelf --add-rpath ${lib.makeLibraryPath nixLibs} $out/bin/kix
        '';
      };

      # Build dependencies separately for caching
      cargoArtifacts = craneLib.buildDepsOnly commonArgs;

      # Build the kix binary
      kix = craneLib.buildPackage (
        commonArgs
        // {
          inherit cargoArtifacts;

          # Run cargo test during build
          doCheck = true;

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
