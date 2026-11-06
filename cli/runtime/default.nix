# Build the inputs of a Kix runtime directory for the platform of `pkgs`.
#
# The result is one JSON file that names every file to ship, the licence
# texts, and the LGPL sources. assemble.py turns it into libexec/kix/.
# Building it fetches every program and source it names.
{ pkgs }:
let
  runtime = import ./runtime.nix { inherit pkgs; };

  legal =
    pkgs.runCommand "kix-runtime-legal-${runtime.system}"
      {
        nativeBuildInputs = [
          pkgs.python3
          pkgs.lzip
          pkgs.zstd
        ];
        components = builtins.toJSON runtime.components;
        passAsFile = [ "components" ];
      }
      ''
        python3 ${./legal.py} "$componentsPath" "$out"
      '';
in
pkgs.writeText "kix-runtime-spec-${runtime.system}.json" (
  builtins.toJSON {
    inherit (runtime) system programs;
    # The store paths of every package each program is built from, which
    # assemble.py checks bundled libraries against.
    packages = builtins.mapAttrs (_: cs: builtins.concatMap (c: c.storePaths or [ ]) cs) (
      builtins.groupBy (c: c.program) runtime.components
    );
    licenses = "${legal}/THIRD_PARTY_LICENSES";
    sources = "${legal}/sources";
  }
)
