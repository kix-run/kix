# kixpkgs root flake — aggregates all clusters.
#
# Prefer using the per-directory flakes (ludo/, clusters/) directly.
# This root flake exists for backwards compatibility and CI.
#
# Build a cluster:
#   nix build .#cluster-ludo --extra-experimental-features pipe-operators

{
  description = "kixpkgs - Kubernetes packages built with Nix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    crane.url = "github:ipetkov/crane";
  };

  outputs =
    inputs:
    let
      mkFlake = import ./kix/lib/mkFlake.nix;
      lib = inputs.nixpkgs.lib;

      clusterOutputs = mkFlake {
        inherit inputs;
        clusters = {
          # Test clusters
          minimal = ./clusters/test-minimal.nix;
          example = ./clusters/example.nix;
          full = ./clusters/test-full.nix;
          helm = ./clusters/test-helm.nix;
          example-import = ./clusters/example-import.nix;
          auto = ./clusters/test-auto.nix;
          auto2 = ./clusters/test-auto2.nix;
          immich = ./clusters/test-immich.nix;
          kind = ./clusters/test-kind.nix;
          monitoring-helm = ./clusters/test-monitoring-helm.nix;
          monitoring-native = ./clusters/test-monitoring-native.nix;
          victoria-metrics = ./clusters/test-victoria-metrics.nix;
          victoria-metrics-crd-ref = ./clusters/test-victoria-metrics-crd-ref.nix;
          doc-how-tos = ./clusters/test-doc-how-tos.nix;

          # Register documented examples so routine builds catch evaluation
          # errors in them.
          example-multi-env-dev = ./clusters/example-multi-env/dev.nix;
          example-multi-env-prod = ./clusters/example-multi-env/prod.nix;

          # Production clusters
          ludo = ./ludo/cluster.nix;
        };
      };

      # kix CLI package (built with crane)
      mkKixPackage = (import ./cli/flake-integration.nix).mkKixPackage;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      cliPackages = lib.genAttrs systems (
        system:
        let
          pkgs = inputs.nixpkgs.legacyPackages.${system};
        in
        {
          kix = mkKixPackage {
            inherit pkgs;
            lib = pkgs.lib;
            crane = inputs.crane;
          };
        }
      );

      # The kix/lib evaluation test matrix (kix/lib/tests) as a flake check,
      # so `nix flake check` runs it. Until 2026-09 it ran only when someone
      # typed the nix eval by hand, and 13 of its 54 cases were failing on
      # main unnoticed. Forcing `ok` evaluates every case; a failure throws
      # with the failing names.
      libTests = lib.genAttrs systems (system: {
        kix-lib-tests =
          let
            pkgs = inputs.nixpkgs.legacyPackages.${system};
            result = (import ./kix/lib/tests { inherit lib; }).result;
          in
          assert result.ok;
          pkgs.runCommand "kix-lib-tests" { } ''
            echo "${toString (builtins.length result.passed)} kix/lib tests passed."
            touch $out
          '';
      });
      # A shell that can build and TEST the CLI.
      #
      # The crane package (`packages.kix`) sets `doCheck = false`, because
      # the integration tests need a writable Nix store for the eval cache
      # and the build sandbox has none. So `nix flake check` cannot run
      # them and CI needs somewhere outside a build to run them from. This
      # is that place, and it is also the one entry point that does not
      # need devenv installed.
      #
      # The Nix C libraries are what the nix-bindings-*-sys crates find
      # through pkg-config; mkShell puts their .dev outputs on
      # PKG_CONFIG_PATH. devenv.nix lists the same set for the same reason.
      devShells = lib.genAttrs systems (
        system:
        let
          pkgs = inputs.nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.cargo
              pkgs.rustc
              pkgs.clippy
              pkgs.rustfmt
              pkgs.pkg-config
              pkgs.openssl
              pkgs.nix.libs.nix-expr-c
              pkgs.nix.libs.nix-store-c
              pkgs.nix.libs.nix-util-c
              pkgs.nix.libs.nix-flake-c
              pkgs.nix.libs.nix-fetchers-c
              pkgs.nix.libs.nix-main-c
            ]
            ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.dbus ];

            # Keyed on the checkout path and kept OUT of the checkout, for
            # the reason devenv.nix spells out at length: a `path:` flakeref
            # copies a directory into the store with no filtering at all, so
            # an in-tree target dir is copied verbatim on every change. Same
            # scheme as devenv's, so the two share a directory rather than
            # building two cold copies of the same tree.
            shellHook = ''
              export CARGO_TARGET_DIR="''${XDG_CACHE_HOME:-$HOME/.cache}/kix-cargo-target/$(basename "$PWD")-$(printf %s "$PWD" | sha256sum | cut -c1-12)"
              mkdir -p "$CARGO_TARGET_DIR"
            '';
          };
        }
      );
    in
    clusterOutputs
    // {
      inherit devShells;

      # Merge kix CLI into per-system packages alongside cluster outputs.
      packages = lib.mapAttrs (
        system: clusterPkgs: clusterPkgs // (cliPackages.${system} or { })
      ) clusterOutputs.packages;

      checks = lib.mapAttrs (
        system: clusterChecks: clusterChecks // (libTests.${system} or { })
      ) clusterOutputs.checks;

      # Preserve the forPkgs API for external consumers.
      lib.forPkgs =
        { pkgs, lib }:
        let
          kix = import ./kix/lib { inherit pkgs lib; };
          entries = builtins.readDir ./kix/packages;
          dirs = lib.filterAttrs (_: type: type == "directory") entries;
          packages = lib.mapAttrs (name: _: import ./kix/packages/${name}) dirs;
        in
        {
          inherit kix packages;
          inherit (kix) mkManifests;
        };

      # mkFlake helper for external consumers — wraps cluster definitions
      # into a complete per-system flake output.
      #
      #   outputs = inputs: inputs.kixpkgs.lib.mkFlake {
      #     inherit inputs;
      #     clusters.my-cluster = ./cluster.nix;
      #   };
      lib.mkFlake = mkFlake;
    };
}
