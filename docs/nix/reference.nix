# Auto-generated reference docs for Kix packages.
#
# Imports a Kix package, evaluates its `options` declaration through
# `lib.evalModules`, and runs the result through `pkgs.nixosOptionsDoc`
# to emit a CommonMark-derived MDX file per package. Each file gets YAML frontmatter
# so Starlight picks it up under `reference/package-catalog/`.
#
# Scope: this phase generates reference for three smoke-test packages
# (echo-server, cert-manager, cilium). Cluster-level options, meta
# schema, instance schema, and the remaining 58 packages are deferred.
#
# Entry points:
#   mkPackageReference { packagePath, packageName } → derivation
#   mkAllReferences    { packages }                 → derivation

{ pkgs, lib }:

let
  compose = import ../../kix/lib/vocab/compose.nix { inherit lib; };

  # Evaluate a single package's options.
  #
  # The package function gets `scope` and `kix` thunks that throw if
  # touched: options declarations should only need `lib`. If a package
  # reaches for `scope`/`kix` at the options level, the thrown error
  # identifies which package is misbehaving.
  evalPackageOptions =
    { packagePath, packageName }:
    let
      package = import packagePath;
      # Only pass arguments the package function actually declares:
      # several packages (e.g. cert-manager, cilium) take `{ scope, lib }`
      # without `kix`, and Nix's strict arity check rejects unexpected args.
      fnArgs = builtins.functionArgs package;
      stubs = {
        inherit lib;
        scope = throw "kix-reference: package '${packageName}' touched `scope` during options-declaration evaluation; refactor so `options` is static.";
        # Option defaults read `kix.availability.pick availability { ... }`
        # to size replica counts, and nixosOptionsDoc renders every default
        # that has no `defaultText`. The package sees the level a cluster
        # without an availability setting resolves to, so the rendered
        # default is the single-replica one. Option helpers come from
        # `kix.options` and option types from `kix.types`. Any other `kix`
        # attribute is missing here, and the error names it.
        kix.availability = import ../../kix/lib/core/availability.nix { inherit lib; };
        kix.options = compose.options;
        kix.types = compose.types;
        availability = "none";
      };
      pkg = package (lib.intersectAttrs fnArgs stubs);
      # nixosOptionsDoc renders each option's declared default. A package
      # whose `config` defaults an option from another option gives that
      # option a `defaultText` (for an image, `kix.options.image`'s
      # `tagText`), so the package's `config` is not evaluated here.
      evaluated = lib.evalModules {
        modules = [ { options = pkg.options or { }; } ];
      };
    in
    # Strip `_module`, which `evalModules` injects and which pollutes the doc.
    removeAttrs evaluated.options [ "_module" ];

  # Build the MDX reference for a single package.
  mkPackageReference =
    { packagePath, packageName }:
    let
      options = evalPackageOptions { inherit packagePath packageName; };
      # Strict mode: every option must declare a `description`. Missing
      # descriptions fail the docs build so reference pages stay useful.
      optionsDoc = pkgs.nixosOptionsDoc {
        inherit options;
        warningsAreErrors = true;
      };
    in
    pkgs.runCommand "kix-reference-${packageName}"
      {
        # Surface the commonMark path for downstream debugging.
        inherit (optionsDoc) optionsCommonMark;
      }
      ''
        mkdir -p "$out"
        {
          printf -- '---\n'
          printf 'title: %s\n' '${packageName}'
          printf 'description: Auto-generated from %s package options. Do not edit by hand.\n' '${packageName}'
          printf -- '---\n\n'
          cat "$optionsCommonMark"
        } > "$out/${packageName}.mdx"
      '';

  # Merge per-package outputs into one directory.
  mkAllReferences =
    { packages }:
    let
      perPackage = map (
        { path, name }:
        mkPackageReference {
          packagePath = path;
          packageName = name;
        }
      ) packages;
    in
    pkgs.runCommand "kix-reference-all"
      {
        passthru = { inherit perPackage; };
      }
      ''
        mkdir -p "$out"
        ${lib.concatMapStringsSep "\n" (drv: ''
          cp -r ${drv}/. "$out/"
        '') perPackage}
      '';
in
{
  inherit mkPackageReference mkAllReferences;
}
