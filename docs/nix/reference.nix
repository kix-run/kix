# Auto-generated reference docs for Kix packages.
#
# Imports a Kix package, evaluates its `options` declaration through
# `lib.evalModules`, and runs the result through `pkgs.nixosOptionsDoc`
# to emit a CommonMark file per package. Each file gets YAML frontmatter
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
  # Evaluate a single package's options.
  #
  # The package function gets `scope` and `kix` thunks that throw if
  # touched — options declarations should only need `lib`. If a package
  # reaches for `scope`/`kix` at the options level, the thrown error
  # identifies which package is misbehaving.
  evalPackageOptions =
    { packagePath, packageName }:
    let
      package = import packagePath;
      # Only pass arguments the package function actually declares —
      # several packages (e.g. cert-manager, cilium) take `{ scope, lib }`
      # without `kix`, and Nix's strict arity check rejects unexpected args.
      fnArgs = builtins.functionArgs package;
      stubs = {
        inherit lib;
        scope = throw "kix-reference: package '${packageName}' touched `scope` during options-declaration evaluation; refactor so `options` is static.";
        kix = throw "kix-reference: package '${packageName}' touched `kix` during options-declaration evaluation; refactor so `options` is static.";
      };
      pkg = package (lib.intersectAttrs fnArgs stubs);
      evaluated = lib.evalModules {
        modules = [ { options = pkg.options or { }; } ];
      };
    in
    # Strip `_module` — `evalModules` injects it and it pollutes the doc.
    removeAttrs evaluated.options [ "_module" ];

  # Build the Markdown reference for a single package.
  mkPackageReference =
    { packagePath, packageName }:
    let
      options = evalPackageOptions { inherit packagePath packageName; };
      # `warningsAreErrors = false`: Kix packages don't yet describe every
      # option, and a missing `description` is otherwise treated as a hard
      # failure. We render whatever's there; the missing-description gap
      # is a real one but should be fixed in the packages, not by failing
      # the docs build.
      optionsDoc = pkgs.nixosOptionsDoc {
        inherit options;
        warningsAreErrors = false;
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
        } > "$out/${packageName}.md"
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
