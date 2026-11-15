# Build the `kix` package with Crane. The repository's flake.nix calls
# `mkKixPackage` for each system and exposes the result as `packages.kix`:
#
#   nix build .#kix
#   nix run .#kix -- build example-hello

{
  # `runtime` is a Kix runtime directory (`cli/runtime/in-store.nix`,
  # exposed as `packages.<system>.kix-runtime`). The package links it at
  # libexec/kix beside bin/kix, where kix looks for it. Without one, kix
  # finds no runtime unless KIX_RUNTIME_DIR names one.
  mkKixPackage =
    {
      pkgs,
      lib,
      crane,
      runtime ? null,
      ...
    }:
    let
      craneLib = crane.mkLib pkgs;

      commonArgs = {
        # kix-core/runtime/programs.json and the release keys in
        # kix/release-keys/ are compiled into Kix, so keep them beside the
        # Rust sources.
        src = lib.cleanSourceWith {
          src = ../cli;
          filter =
            path: type:
            craneLib.filterCargoSources path type
            || lib.hasSuffix "/cli/kix-core/runtime" path
            || lib.hasSuffix "/cli/kix-core/runtime/programs.json" path
            || lib.hasSuffix "/cli/kix/release-keys" path
            || (lib.hasInfix "/cli/kix/release-keys/" path && lib.hasSuffix ".pub" path);
        };
        strictDeps = true;

        buildInputs = [ pkgs.openssl ] ++ lib.optionals pkgs.stdenv.isLinux [ pkgs.dbus ];

        nativeBuildInputs = [ pkgs.pkg-config ];
      };

      # Build dependencies separately for caching
      cargoArtifacts = craneLib.buildDepsOnly commonArgs;

      # Build Kix
      kix = craneLib.buildPackage (
        commonArgs
        // {
          inherit cargoArtifacts;

          # cargo-auditable writes the list of crates into the binary, so
          # SBOM tools such as syft can see what kix is built from. Spelled
          # out because crane's cargoWithProfile puts --release before the
          # subcommand, ahead of `auditable`. Not in buildDepsOnly: only the
          # final binary carries the list.
          cargoBuildCommand = "cargo auditable build --release";
          nativeBuildInputs = commonArgs.nativeBuildInputs ++ [ pkgs.cargo-auditable ];

          # Integration tests require a writable nix store (eval cache),
          # which is unavailable inside the nix build sandbox.
          doCheck = false;

          meta = {
            description = "Kubernetes manifest generator CLI";
            homepage = "https://github.com/kix-run/kix";
            # Kix is proprietary, but nixpkgs refuses to evaluate a package
            # whose license is unfree unless allowUnfree is set, so the
            # license is left unset.
            mainProgram = "kix";
          };
        }
      );
    in
    if runtime == null then
      kix
    else
      # kix resolves links to its own binary before it looks for
      # ../libexec/kix, so bin/kix is a copy, not a link to the crane build.
      # The runtime is a separate derivation, so a runtime change does not
      # rebuild kix.
      pkgs.runCommand "kix-${kix.version}"
        {
          inherit (kix) version meta;
          passthru = {
            unwrapped = kix;
            inherit runtime;
          };
        }
        ''
          cp -R ${kix} $out
          chmod -R u+w $out
          mkdir -p $out/libexec
          ln -s ${runtime} $out/libexec/kix
        '';
}
